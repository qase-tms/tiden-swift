import Foundation
import TidenReporterCore

public struct SourceResolution: Sendable { public let path: String?; public let diagnostic: String? }
public struct SourceResolver: Sendable {
    public let root: URL
    public let overrides: [String: String]
    private let index: [Declaration]
    private struct Declaration: Sendable { let owner: [String]; let name: String; let file: String }
    public init(root: URL, overrides: [String: String] = [:]) throws {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL; self.overrides = overrides
        guard FileManager.default.fileExists(atPath: root.path) else { throw ReporterError("Source root does not exist") }
        var declarations: [Declaration] = []
        if let files = FileManager.default.enumerator(at: self.root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let file as URL in files {
                if [".build", "DerivedData"].contains(file.lastPathComponent) { files.skipDescendants(); continue }
                guard file.pathExtension == "swift", let relative = Self.relative(file, to: self.root),
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                declarations += Self.declarations(text, file: relative)
            }
        }
        index = declarations
    }
    public static func relative(_ url: URL, to root: URL) -> String? {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard canonical.path.hasPrefix(base), FileManager.default.fileExists(atPath: canonical.path) else { return nil }
        return String(canonical.path.dropFirst(base.count))
    }
    public func resolve(signature: String, identifier: String, location: String?) -> SourceResolution {
        if let override = overrides[signature] {
            let url = root.appendingPathComponent(override)
            guard !override.hasPrefix("/"), !override.split(separator: "/").contains(".."), let path = Self.relative(url, to: root) else {
                return SourceResolution(path: nil, diagnostic: "Invalid sourceMap path for \(signature)")
            }
            return SourceResolution(path: path, diagnostic: nil)
        }
        if let location {
            let url = location.hasPrefix("file:") ? URL(string: location) :
                (location.hasPrefix("/") ? URL(fileURLWithPath: location) : root.appendingPathComponent(location))
            if let url, let path = Self.relative(url, to: root) { return SourceResolution(path: path, diagnostic: nil) }
        }
        guard let declaration = try? Identity.declaration(identifier) else { return SourceResolution(path: nil, diagnostic: "Invalid declaration source identity") }
        var parts = declaration.split(separator: "/").map(String.init)
        guard let function = parts.popLast()?.components(separatedBy: "(").first else { return SourceResolution(path: nil, diagnostic: "Missing source declaration") }
        let candidates = index.filter { $0.name == function && $0.owner == parts }
        guard candidates.count == 1 else {
            return SourceResolution(path: nil, diagnostic: "Source \(signature) has \(candidates.count) matching declarations; file_path omitted (use sourceMap for ambiguity)")
        }
        return SourceResolution(path: candidates[0].file, diagnostic: nil)
    }
    /// A small lexer avoids declarations appearing inside comments, string literals, and other owners.
    /// Overloads are intentionally ambiguous: a guessed source anchor is worse than a missing one.
    private static func declarations(_ text: String, file: String) -> [Declaration] {
        let chars = Array(text)
        var tokens: [String] = [], i = 0
        while i < chars.count {
            if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "/" {
                i += 2; while i < chars.count, chars[i] != "\n" { i += 1 }; continue
            }
            if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" {
                i += 2; var depth = 1
                while i < chars.count, depth > 0 {
                    if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" { depth += 1; i += 2 }
                    else if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "/" { depth -= 1; i += 2 }
                    else { i += 1 }
                }; continue
            }
            var quote = i, hashes = 0
            while quote < chars.count, chars[quote] == "#" { hashes += 1; quote += 1 }
            if quote < chars.count, chars[quote] == "\"" {
                let triple = quote + 2 < chars.count && chars[quote + 1] == "\"" && chars[quote + 2] == "\""
                let terminator = Array((triple ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes))
                i = quote + (triple ? 3 : 1)
                while i < chars.count {
                    if hashes == 0, chars[i] == "\\" { i = min(i + 2, chars.count); continue }
                    if i + terminator.count <= chars.count, Array(chars[i..<i + terminator.count]) == terminator { i += terminator.count; break }
                    i += 1
                }; continue
            }
            if chars[i].isLetter || chars[i] == "_" || chars[i] == "`" {
                let begin = i; i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "`" { i += 1 }
                tokens.append(String(chars[begin..<i]).replacingOccurrences(of: "`", with: ""))
            } else { if !chars[i].isWhitespace { tokens.append(String(chars[i])) }; i += 1 }
        }
        var stack: [[String]?] = [], owners: [String] = [], pendingOwner: [String]?, result: [Declaration] = []
        var previous = "", index = 0
        while index < tokens.count {
            let token = tokens[index]
            if ["struct", "class", "enum", "actor", "extension"].contains(token), index + 1 < tokens.count,
               previous != ":", tokens[index + 1] != "func", tokens[index + 1] != "{" {
                var name = [tokens[index + 1]], cursor = index + 2
                while cursor + 1 < tokens.count, tokens[cursor] == "." { name.append(tokens[cursor + 1]); cursor += 2 }
                pendingOwner = name
            }
            if token == "func", index + 2 < tokens.count, tokens[index + 2] == "(" || tokens[index + 2] == "<" {
                result.append(Declaration(owner: owners, name: tokens[index + 1], file: file))
            }
            if token == "{" { stack.append(pendingOwner); if let pendingOwner { owners += pendingOwner }; pendingOwner = nil }
            if token == "}", !stack.isEmpty { if let popped = stack.removeLast() { owners.removeLast(popped.count) } }
            previous = token; index += 1
        }
        return result
    }
}
