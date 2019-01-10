import Foundation
import SourceKittenFramework
import Yams

//Rough flow iboutletlint
//
//1. Collect all storyboard/xib outlets
//1. class
//2. module
//3. type
//4. property name
//5. containing resource bundle
//2. Collect all IBOutlets declared in source code + superclasses
//3. Collect all storyboard/xib IBActions
//4. Collect all IBActions declared in source code + superclasses

extension Dictionary where Key: ExpressibleByStringLiteral {
    /// Accessibility.
    var accessibility: String? {
        return self["key.accessibility"] as? String
    }
    /// Body length.
    var bodyLength: Int? {
        return (self["key.bodylength"] as? Int64).flatMap({ Int($0) })
    }
    /// Body offset.
    var bodyOffset: Int? {
        return (self["key.bodyoffset"] as? Int64).flatMap({ Int($0) })
    }
    /// Kind.
    var kind: String? {
        return self["key.kind"] as? String
    }
    /// Length.
    var length: Int? {
        return (self["key.length"] as? Int64).flatMap({ Int($0) })
    }
    /// Name.
    var name: String? {
        return self["key.name"] as? String
    }
    /// Name length.
    var nameLength: Int? {
        return (self["key.namelength"] as? Int64).flatMap({ Int($0) })
    }
    /// Name offset.
    var nameOffset: Int? {
        return (self["key.nameoffset"] as? Int64).flatMap({ Int($0) })
    }
    /// Offset.
    var offset: Int? {
        return (self["key.offset"] as? Int64).flatMap({ Int($0) })
    }
    /// Setter accessibility.
    var setterAccessibility: String? {
        return self["key.setter_accessibility"] as? String
    }
    /// Type name.
    var typeName: String? {
        return self["key.typename"] as? String
    }
    /// Column where the token's declaration begins.
    var docColumn: Int? {
        return (self["key.doc.column"] as? Int64).flatMap({ Int($0) })
    }
    /// Line where the token's declaration begins.
    var docLine: Int? {
        return (self["key.doc.line"] as? Int64).flatMap({ Int($0) })
    }
    /// Parsed scope start.
    var docType: Int? {
        return (self["key.doc.type"] as? Int64).flatMap({ Int($0) })
    }
    /// Parsed scope start end.
    var usr: Int? {
        return (self["key.usr"] as? Int64).flatMap({ Int($0) })
    }
    /// Documentation length.
    var docLength: Int? {
        return (self["key.doclength"] as? Int64).flatMap({ Int($0) })
    }

    var attribute: String? {
        return self["key.attribute"] as? String
    }

    var enclosedSwiftAttributes: [SwiftDeclarationAttributeKind] {
        return swiftAttributes.compactMap { $0.attribute }
            .compactMap(SwiftDeclarationAttributeKind.init(rawValue:))
    }

    var swiftAttributes: [[String: SourceKitRepresentable]] {
        let array = self["key.attributes"] as? [SourceKitRepresentable] ?? []
        let dictionaries = array.compactMap { ($0 as? [String: SourceKitRepresentable]) }
        return dictionaries
    }

    var substructure: [[String: SourceKitRepresentable]] {
        let substructure = self["key.substructure"] as? [SourceKitRepresentable] ?? []
        return substructure.compactMap { $0 as? [String: SourceKitRepresentable] }
    }

    var elements: [[String: SourceKitRepresentable]] {
        let elements = self["key.elements"] as? [SourceKitRepresentable] ?? []
        return elements.compactMap { $0 as? [String: SourceKitRepresentable] }
    }


    var inheritedTypes: [String] {
        let array = self["key.inheritedtypes"] as? [SourceKitRepresentable] ?? []
        return array.compactMap { ($0 as? [String: String])?.name }
    }

}

extension Dictionary where Key == String {
    /// Returns a dictionary with SwiftLint violation markers (↓) removed from keys.
    func removingViolationMarkers() -> [Key: Value] {
        return Dictionary(uniqueKeysWithValues: map { ($0.replacingOccurrences(of: "↓", with: ""), $1) })
    }
}


func findIBOutlets(in dictionary: [String : SourceKitRepresentable]) -> [(String, String)] {
    if dictionary.enclosedSwiftAttributes.contains(.iboutlet) {
        return [(dictionary.name!, dictionary.typeName!)]
    } else {
        return dictionary.substructure.flatMap(findIBOutlets(in:))
    }
}

guard CommandLine.arguments.count == 2 else {
    print("Usage: selfish xcodebuild-log-path")
    abort()
}

if CommandLine.arguments[1] == "-v" {
    print("0.0.11")
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

private func stripXCBuildExec(from arguments: [String]) throws -> [String] {
    if let dashIndex = arguments.index(of: "--") {
        let index = arguments.index(after: dashIndex)
        return Array(arguments[index...])
    }

    throw ParsingError.invalidArguments(arguments: arguments)
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

        let filteredArgs = filter(arguments: try stripXCBuildExec(from: arguments))
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
    let structure = try! Structure(file: file)

    print(findIBOutlets(in: structure.dictionary))
}

exit(didFindViolations ? 1 : 0)
