import Foundation
import Gzip
import SourceKittenFramework
import SwiftHash

let path: String
let logPath: String?
if CommandLine.arguments.count == 3 {
  path = CommandLine.arguments[1]
  logPath = CommandLine.arguments[2]
} else if CommandLine.arguments.count == 2 {
  path = CommandLine.arguments[1]
  logPath = nil
} else {
  path = FileManager.default.currentDirectoryPath
  logPath = nil
}

final class CompilableFile {
    let file: String
    let compilerArguments: [String]

    init?(file: String, logPath: String?) {
        self.file = file
        if let logPath = logPath,
          let args = compileCommand(logFile: logPath, sourceFile: file) {
            self.compilerArguments = args
        } else if let args = getCompilerArguments(forSourceFile: file) {
            self.compilerArguments = args
        } else {
            return nil
        }
    }
}

// Thanks to: http://samdmarshall.com/blog/xcode_deriveddata_hashes.html

/// Create the unique identifier string for a Xcode project path.
///
/// - parameter path: String path to the ".xcodeproj" or ".xcworkspace" file.
///
/// - returns: Hash string for the identifier.
func hashString(forPath path: String) -> String {
    func convert<S: StringProtocol>(hex: S) -> String {
        var startValue = UInt64(hex, radix: 16)!
        var resultStr = ""
        let aValue = Int(("a" as Unicode.Scalar).value)
        for _ in 0...13 {
            let charScalar = Int(startValue % 26)
            let unicodeScalar = Unicode.Scalar(charScalar + aValue)!
            resultStr.insert(Character(unicodeScalar), at: resultStr.startIndex)
            startValue /= 26
        }
        return resultStr
    }
    let md5 = MD5(path)
    let first16 = md5[..<md5.index(md5.startIndex, offsetBy: 16)]
    let last16 = md5[md5.index(md5.startIndex, offsetBy: 16)...]
    return [first16, last16].reduce("") { $0 + convert(hex: $1) }
}

func logDirectoryForProject(_ projectPath: String) -> String? {
    let projectName = URL(fileURLWithPath: projectPath).lastPathComponent.split(separator: ".")[0]
    let homeDir = NSHomeDirectory()
    let underscoredProjectName = String(projectName).replacingOccurrences(of: " ", with: "_")
    let projectHash = hashString(forPath: projectPath)
    return "\(homeDir)/Library/Developer/Xcode/DerivedData/\(underscoredProjectName)-\(projectHash)/Logs/Build"
}

func fileWithExtension(_ pathExtension: String, inFiles files: [String]) -> String? {
    return files.first { file in
        return NSString(string: file).pathExtension == pathExtension
    }
}

func projectForSourceFile(_ sourceFile: String) -> String? {
    let directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().path
    guard directory != "/" else {
        return nil
    }
    let manager = FileManager.default
    guard let fileList = try? manager.contentsOfDirectory(atPath: directory) else {
        fatalError("Could not read contents of directory: \(directory)")
    }
    let optionalProjectFile = fileWithExtension("xcworkspace", inFiles: fileList) ??
        fileWithExtension("xcodeproj", inFiles: fileList)
    guard let projectFile = optionalProjectFile else {
        return projectForSourceFile(directory)
    }

    let projectPath = URL(fileURLWithPath: directory).appendingPathComponent(projectFile).path
    if let logDir = logDirectoryForProject(projectPath),
        manager.fileExists(atPath: logDir) {
        return projectPath
    }
    return projectForSourceFile(directory)
}

func activityLogs(inPath path: String) -> [String] {
    let manager = FileManager.default
    guard let fileList = try? manager.contentsOfDirectory(atPath: path) else {
        fatalError("Could not read contents of directory: \(path)")
    }
    return fileList
        .filter { file in
            return file.hasSuffix(".xcactivitylog")
        }
        .map { file in
            return "\(path)/\(file)"
        }
        .sorted { file1, file2 in
            let date1 = try! manager.attributesOfItem(atPath: file1)[.modificationDate] as! Date
            let date2 = try! manager.attributesOfItem(atPath: file2)[.modificationDate] as! Date
            return date1 > date2
    }
}

func contentsOfGzippedFile(atPath path: String) -> String? {
    guard let compressedData = FileManager.default.contents(atPath: path),
        let decompressedData = compressedData.isGzipped ? try? compressedData.gunzipped() : compressedData else {
            return nil
    }
    return String(data: decompressedData, encoding: .utf8)
}

func compileCommand(logFile: String, sourceFile: String) -> [String]? {
    var compileCommand: [String]?
    let escapedSourceFile = sourceFile.replacingOccurrences(of: " ", with: "\\ ")
    if let contents = contentsOfGzippedFile(atPath: logFile), contents.contains(escapedSourceFile) {
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

func getCompilerArguments(forSourceFile sourceFile: String) -> [String]? {
    guard let project = projectForSourceFile(sourceFile),
        let logDir = logDirectoryForProject(project) else {
            return nil
    }
    for log in activityLogs(inPath: logDir) {
        if let compileCommand = compileCommand(logFile: log, sourceFile: sourceFile) {
            return compileCommand
        }
    }
    return nil
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
    let absoluteFile = compilableFile.file.bridge().absolutePathRepresentation()
    let index = Request.index(file: absoluteFile, arguments: compilableFile.compilerArguments).send()
    let file = File(path: compilableFile.file)!
    let binaryOffsets = file.contents.bridge().recursiveByteOffsets(index)
    return binaryOffsets.sorted()
}

enum RunMode {
  case log
  case overwrite
}

let mode = RunMode.log

let files = FileManager.default.filesToLint(inPath: path)
DispatchQueue.concurrentPerform(iterations: files.count) { index in
    let path = files[index]
    // print("\(index + 1)/\(files.count): \(path)")

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

    if mode == .log {
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
