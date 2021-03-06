import Foundation
import SourceKittenFramework
import Yams

guard CommandLine.arguments.count == 2 else {
    print("Usage: selfish xcodebuild-log-path")
    abort()
}

if CommandLine.arguments[1] == "-v" {
    print("0.0.12")
    exit(0)
}

let logPath = CommandLine.arguments[1]

final class CompilableFile {
    let file: String
    let compilerArguments: [String]

    init?(file: String, arguments: [String]?) {
        self.file = file
        if let arguments = arguments {
            self.compilerArguments = arguments
        } else {
            return nil
        }
    }
}

func parseCLIArguments(_ string: String) -> [String] {
    let escapedSpacePlaceholder = "\u{0}"
    let scanner = Scanner(string: string)
    var result: NSString?
    var str = ""
    var didStart = false
    while scanner.scanUpTo("\"", into: &result), let theResult = result {
        if didStart {
            str += theResult.replacingOccurrences(of: " ", with: escapedSpacePlaceholder)
            str += " "
        } else {
            str += theResult.bridge()
        }
        scanner.scanString("\"", into: nil)
        didStart = !didStart
    }
    return filter(arguments:
        str.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "\\ ", with: escapedSpacePlaceholder)
        .components(separatedBy: " ")
        .map { $0.replacingOccurrences(of: escapedSpacePlaceholder, with: " ") }
    )
}

/**
 Partially filters compiler arguments from `xcodebuild` to something that SourceKit/Clang will accept.

 - parameter args: Compiler arguments, as parsed from `xcodebuild`.

 - returns: A tuple of partially filtered compiler arguments in `.0`, and whether or not there are
 more flags to remove in `.1`.
 */
private func partiallyFilter(arguments args: [String]) -> ([String], Bool) {
    guard let indexOfFlagToRemove = args.index(of: "-output-file-map") else {
        return (args, false)
    }
    var args = args
    args.remove(at: args.index(after: indexOfFlagToRemove))
    args.remove(at: indexOfFlagToRemove)
    return (args, true)
}

/**
 Filters compiler arguments from `xcodebuild` to something that SourceKit/Clang will accept.

 - parameter args: Compiler arguments, as parsed from `xcodebuild`.

 - returns: Filtered compiler arguments.
 */
private func filter(arguments args: [String]) -> [String] {
    var args = args
    args.append(contentsOf: ["-D", "DEBUG"])
    var shouldContinueToFilterArguments = true
    while shouldContinueToFilterArguments {
        (args, shouldContinueToFilterArguments) = partiallyFilter(arguments: args)
    }
    return args.filter {
        ![
            "-parseable-output",
            "-incremental",
            "-serialize-diagnostics",
            "-emit-dependencies"
        ].contains($0)
    }.map {
        if $0 == "-O" {
            return "-Onone"
        } else if $0 == "-DNDEBUG=1" {
            return "-DDEBUG=1"
        }
        return $0
    }
}

private enum ParsingError: LocalizedError {
    case failedToParse
    case invalidArguments(arguments: [String])

    var localizedDescription: String? {
        switch self {
        case .failedToParse:
            return "Failed to parse xcbuild definition"
        case .invalidArguments(let arguments):
            return "Unexpected arguments for swiftc: \(arguments.joined(separator: " "))"
        }
    }
}

private func parseXCBuildDefinition(_ logString: String) throws -> [String: [String]] {
    guard let yaml = (try? Yams.load(yaml: logString)) as? [String: Any],
        let commands = yaml["commands"] as? [String: Any] else {
            throw ParsingError.failedToParse
    }

    var fileToArgs = [String: [String]]()
    for (key, value) in commands {
        if !key.contains("com.apple.xcode.tools.swift.compiler") {
            continue
        }

        guard let valueDictionary = value as? [String: Any],
            let inputs = valueDictionary["inputs"] as? [String],
            let arguments = valueDictionary["args"] as? [String] else {
                continue
        }

        let filteredArgs = filter(arguments: arguments)
        for input in inputs where input.hasSuffix(".swift") {
            fileToArgs[input] = filteredArgs
        }
    }

    return fileToArgs
}

private let kindsToFind = Set([
    "source.lang.swift.ref.function.method.instance",
    "source.lang.swift.ref.var.instance"
])

public protocol LintableFileManager {
    func filesToLint(inPath: String, rootDirectory: String?) -> [String]
}

extension FileManager: LintableFileManager {
    public func filesToLint(inPath path: String, rootDirectory: String? = nil) -> [String] {
        let rootPath = rootDirectory ?? currentDirectoryPath
        let absolutePath = path.bridge()
            .absolutePathRepresentation(rootDirectory: rootPath).bridge()
            .standardizingPath

        // if path is a file, it won't be returned in `enumerator(atPath:)`
        if absolutePath.bridge().isSwiftFile() && fileExists(atPath: absolutePath) {
            return [absolutePath]
        }

        return enumerator(atPath: absolutePath)?.compactMap { element -> String? in
            if let element = element as? String, element.bridge().isSwiftFile() {
                return absolutePath.bridge().appendingPathComponent(element)
            }
            return nil
        } ?? []
    }
}

extension File {
    fileprivate func allCursorInfo(compilerArguments: [String],
                                   atByteOffsets byteOffsets: [Int]) throws -> [[String: SourceKitRepresentable]] {
        return try byteOffsets.compactMap { offset in
            if contents.substringWithByteRange(start: offset - 1, length: 1)! == "." { return nil }
            var cursorInfo = try Request.cursorInfo(file: self.path!, offset: Int64(offset),
                                                    arguments: compilerArguments).send()
            cursorInfo["jp.offset"] = Int64(offset)
            return cursorInfo
        }
    }
}

extension NSString {
    func byteOffset(forLine line: Int, column: Int) -> Int {
        var byteOffset = 0
        for line in lines()[..<(line - 1)] {
            byteOffset += line.byteRange.length
        }
        return byteOffset + column - 1
    }

    func recursiveByteOffsets(_ dict: [String: Any]) -> [Int] {
        let cur: [Int]
        if let line = dict["key.line"] as? Int64,
            let column = dict["key.column"] as? Int64,
            let kindString = dict["key.kind"] as? String,
            kindsToFind.contains(kindString) {
            cur = [byteOffset(forLine: Int(line), column: Int(column))]
        } else {
            cur = []
        }
        if let entities = dict["key.entities"] as? [[String: Any]] {
            return entities.flatMap(recursiveByteOffsets) + cur
        }
        return cur
    }
}

func binaryOffsets(for compilableFile: CompilableFile) throws -> [Int] {
    let absoluteFile = compilableFile.file.bridge().absolutePathRepresentation()
    let index = try Request.index(file: absoluteFile, arguments: compilableFile.compilerArguments).send()
    let file = File(path: compilableFile.file)!
    let binaryOffsets = file.contents.bridge().recursiveByteOffsets(index)
    return binaryOffsets.sorted()
}

func swiftFilesChangedFromMaster() -> [String]? {
    let task = Process()
    task.launchPath = "/usr/bin/git"
    task.arguments = ["diff", "--name-only", "origin/master", "HEAD"]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.launch()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else {
        return nil
    }
    return output.components(separatedBy: .newlines)
        .filter { !$0.isEmpty }
        .filter { file in
            return file.bridge().isSwiftFile() && FileManager.default.fileExists(atPath: file)
    }
}

enum RunMode {
  case log
  case overwrite
}

let runMode = RunMode.overwrite
var didFindViolations = false

guard let data = FileManager.default.contents(atPath: logPath),
    let logContents = String(data: data, encoding: .utf8) else {
        fatalError("couldn't read log file at path '\(logPath)'")
}

let buildDefinition = try parseXCBuildDefinition(logContents)
let files = FileManager.default.filesToLint(inPath: "")
DispatchQueue.concurrentPerform(iterations: files.count) { index in
    let path = files[index]
    let arguments = buildDefinition[path]

    guard let compilableFile = CompilableFile(file: path, arguments: arguments) else {
        print("Couldn't find compiler arguments for file. Skipping: \(path)")
        return
    }

    guard let file = File(path: compilableFile.file) else {
        print("Couldn't read contents of file. Skipping: \(path)")
        return
    }

    print("Linting \(index)/\(files.count) \(path)")

    let byteOffsets: [Int]
    let allCursorInfo: [[String: SourceKitRepresentable]]
    do {
        byteOffsets = try binaryOffsets(for: compilableFile)
        allCursorInfo = try file.allCursorInfo(compilerArguments: compilableFile.compilerArguments,
                                               atByteOffsets: byteOffsets)
    } catch {
        print(error)
        return
    }

    let cursorsMissingExplicitSelf = allCursorInfo.filter { cursorInfo in
        guard let kindString = cursorInfo["key.kind"] as? String else { return false }
        return kindsToFind.contains(kindString)
    }

    let contents = file.contents.bridge().mutableCopy() as! NSMutableString

    if runMode == .log {
        for cursorInfo in cursorsMissingExplicitSelf {
            guard let byteOffset = cursorInfo["jp.offset"] as? Int64,
                let (line, char) = contents.lineAndCharacter(forByteOffset: Int(byteOffset))
                else { fatalError("couldn't convert offsets") }
            print("\(compilableFile.file):\(line):\(char): error: Missing explicit reference to 'self.'")
        }
        return
    }

    for cursorInfo in cursorsMissingExplicitSelf.reversed() {
        guard let byteOffset = cursorInfo["jp.offset"] as? Int64,
            let nsrangeToInsert = contents.byteRangeToNSRange(start: Int(byteOffset), length: 0)
            else { fatalError("couldn't convert offsets") }
        contents.replaceCharacters(in: nsrangeToInsert, with: "self.")
    }

    guard let stringData = contents.bridge().data(using: .utf8) else {
        fatalError("can't encode '\(contents)' with UTF8")
    }

    do {
        try stringData.write(to: URL(fileURLWithPath: compilableFile.file), options: .atomic)
    } catch {
        fatalError("can't write file to \(compilableFile.file)")
    }
}
