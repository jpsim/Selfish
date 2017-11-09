import Foundation
import SourceKittenFramework

guard CommandLine.arguments.count == 2 else {
    print("Usage: selfish xcodebuild-log-path")
    abort()
}

if CommandLine.arguments[1] == "-v" {
    print("0.0.8")
    exit(0)
}

let logPath = CommandLine.arguments[1]

final class CompilableFile {
    let file: String
    let compilerArguments: [String]

    init?(file: String, logPath: String?) {
        self.file = file.bridge().absolutePathRepresentation()
        if let logPath = logPath,
          let args = compileCommand(logFile: logPath, sourceFile: self.file) {
            self.compilerArguments = args
        } else {
            return nil
        }
    }
}

func compileCommand(logFile: String, sourceFile: String) -> [String]? {
    var compileCommand: [String]?
    let escapedSourceFile = sourceFile.replacingOccurrences(of: " ", with: "\\ ")
    if let data = FileManager.default.contents(atPath: logFile),
        let contents = String(data: data, encoding: .utf8),
        contents.contains(escapedSourceFile)
    {
        contents.enumerateLines { line, stop in
            if line.contains(escapedSourceFile),
                let swiftcIndex = line.range(of: "swiftc ")?.upperBound,
                line.contains(" -module-name ") {
                compileCommand = parseCLIArguments(String(line[swiftcIndex...]))
                stop = true
            }
        }
    }
    return compileCommand
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

        return enumerator(atPath: absolutePath)?.flatMap { element -> String? in
            if let element = element as? String, element.bridge().isSwiftFile() {
                return absolutePath.bridge().appendingPathComponent(element)
            }
            return nil
        } ?? []
    }
}

extension File {
    fileprivate func allCursorInfo(compilerArguments: [String],
                                   atByteOffsets byteOffsets: [Int]) -> [[String: SourceKitRepresentable]] {
        return byteOffsets.flatMap { offset in
            if contents.substringWithByteRange(start: offset - 1, length: 1)! == "." { return nil }
            var cursorInfo = Request.cursorInfo(file: self.path!, offset: Int64(offset),
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

func binaryOffsets(for compilableFile: CompilableFile) -> [Int] {
    let index = Request.index(file: compilableFile.file, arguments: compilableFile.compilerArguments).send()
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

let runMode = RunMode.log
var didFindViolations = false

let files = swiftFilesChangedFromMaster()!
DispatchQueue.concurrentPerform(iterations: files.count) { index in
    let path = files[index]

    guard let compilableFile = CompilableFile(file: path, logPath: logPath) else {
        print("Couldn't find compiler arguments for file. Skipping: \(path)")
        return
    }

    let byteOffsets = binaryOffsets(for: compilableFile)

    let file = File(path: compilableFile.file)!
    let allCursorInfo = file.allCursorInfo(compilerArguments: compilableFile.compilerArguments, atByteOffsets: byteOffsets)
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
            didFindViolations = true
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

    if !cursorsMissingExplicitSelf.isEmpty {
        didFindViolations = true
    }
}

exit(didFindViolations ? 1 : 0)
