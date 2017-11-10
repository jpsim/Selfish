import Foundation
import SourceKittenFramework
import zlib

guard CommandLine.arguments.count == 2 else {
    print("Usage: selfish xcactivitylog-logs-directory")
    abort()
}

if CommandLine.arguments[1] == "-v" {
    print("0.0.9")
    exit(0)
}

let logDir = CommandLine.arguments[1]

extension Data {
    var isGzipped: Bool {
        return starts(with: [0x1f, 0x8b])
    }

    func gunzipped() -> Data? {
        guard !isEmpty else {
            return Data()
        }

        var stream = z_stream()
        withUnsafeBytes { (bytes: UnsafePointer<Bytef>) in
            stream.next_in = UnsafeMutablePointer(mutating: bytes)
        }
        stream.avail_in = uint(count)
        var status: Int32

        status = inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))

        guard status == Z_OK else {
            // Error
            return nil
        }

        var data = Data(capacity: count * 2)

        repeat {
            if Int(stream.total_out) >= data.count {
                data.count += count / 2
            }

            data.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<Bytef>) in
                stream.next_out = bytes.advanced(by: Int(stream.total_out))
            }
            stream.avail_out = uInt(data.count) - uInt(stream.total_out)

            status = inflate(&stream, Z_SYNC_FLUSH)
        } while status == Z_OK

        guard inflateEnd(&stream) == Z_OK && status == Z_STREAM_END else {
            // Error
            return nil
        }

        data.count = Int(stream.total_out)

        return data
    }
}

final class CompilableFile {
    let file: String
    let compilerArguments: [String]

    init?(file: String, logDir: String) {
        self.file = file.bridge().absolutePathRepresentation()
            .replacingOccurrences(of: "/Users/jsimard/Projects/Lyft-iOS/", with: "/Users/distiller/Lyft-iOS/")
        for logFile in activityLogs(inPath: logDir) {
            if let args = compileCommand(logFile: logFile, sourceFile: self.file) {
                compilerArguments = args
                return
            }
        }
        return nil
    }
}

extension FileManager {
    func recursiveFiles(inPath path: String, `extension`: String) -> [String] {
        let absolutePath = path.bridge()
            .absolutePathRepresentation(rootDirectory: currentDirectoryPath).bridge()
            .standardizingPath

        // if path is a file, it won't be returned in `enumerator(atPath:)`
        if absolutePath.bridge().pathExtension == `extension` && fileExists(atPath: absolutePath) {
            return [absolutePath]
        }

        return enumerator(atPath: absolutePath)?.flatMap { element -> String? in
            if let element = element as? String, element.bridge().pathExtension == `extension` {
                return absolutePath.bridge().appendingPathComponent(element)
            }
            return nil
            } ?? []
    }
}

func activityLogs(inPath path: String) -> [String] {
    let manager = FileManager.default
    return manager.recursiveFiles(inPath: path, extension: "xcactivitylog").sorted { file1, file2 in
        let date1 = try! manager.attributesOfItem(atPath: file1)[.modificationDate] as! Date
        let date2 = try! manager.attributesOfItem(atPath: file2)[.modificationDate] as! Date
        return date1 > date2
    }
}

func contentsOfGzippedFile(atPath path: String) -> String? {
    guard let compressedData = FileManager.default.contents(atPath: path),
        let decompressedData = compressedData.isGzipped ? compressedData.gunzipped() : compressedData else {
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

private let kindsToFind = Set([
    "source.lang.swift.ref.function.method.instance",
    "source.lang.swift.ref.var.instance"
])

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

    guard let compilableFile = CompilableFile(file: path, logDir: logDir) else {
        print("Couldn't find compiler arguments for file. Skipping: \(path)")
        return
    }

    print("Finding missing explicit references to 'self.' in file: \(path)")

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
