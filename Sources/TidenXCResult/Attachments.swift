import Foundation
import TidenReporterCore

public struct MatchedAttachment: Codable, Sendable {
    public let rowIndex: Int
    public let file: URL
    public let name: String
    public let mime: String
    public let skippedForSize: Bool
}
public struct AttachmentResolution: Sendable {
    public var matches: [MatchedAttachment] = []
    public var diagnostics: [String] = []
    public var errors: [String] = []
}
public enum AttachmentMatcher {
    public static let fileLimit = 32 * 1024 * 1024
    public static func resolve(manifest: JSONValue, root: URL, contexts: [ExecutionContext]) -> AttachmentResolution {
        var resolution = AttachmentResolution()
        guard case .array = manifest else { resolution.errors.append("Attachment manifest must be an array"); return resolution }
        for test in manifest.array {
            do {
                guard let raw = test["testIdentifierURL"].string ?? test["testIdentifier"].string else { throw ReporterError("Attachment has no test identifier") }
                let declaration = try Identity.declaration(raw)
                let urlParts = raw.hasPrefix("test://") ? URLComponents(string: raw)?.path.split(separator: "/").map(String.init) : nil
                let module = urlParts.flatMap { $0.count >= 2 ? $0[1] : nil }
                guard case .array = test["attachments"] else { throw ReporterError("Manifest attachments must be an array") }
                for attachment in test["attachments"].array {
                    do {
                        guard let filename = attachment["exportedFileName"].string,
                              let name = attachment["suggestedHumanReadableName"].string else { throw ReporterError("Attachment lacks filename/name") }
                        let file = try secureFile(filename, root: root)
                        var matches = contexts.indices.filter { contexts[$0].declaration == declaration && (module == nil || contexts[$0].module == module) }
                        if let deviceID = attachment["deviceId"].string { matches = matches.filter { contexts[$0].deviceID == deviceID } }
                        else if let device = attachment["deviceName"].string { matches = matches.filter { contexts[$0].deviceName == device } }
                        if let configuration = attachment["configurationId"].string { matches = matches.filter { contexts[$0].configurationID == configuration } }
                        else if let configuration = attachment["configurationName"].string { matches = matches.filter { contexts[$0].configurationName == configuration } }
                        if let repetition = attachment["repetitionNumber"].integer { matches = matches.filter { contexts[$0].repetition == repetition } }
                        if case .array(let arguments) = attachment["arguments"] {
                            guard arguments.allSatisfy({ $0.string != nil }) else { throw ReporterError("Attachment arguments must be strings") }
                            matches = matches.filter { contexts[$0].arguments == arguments.compactMap(\.string) }
                        }
                        if matches.count > 1, let timestamp = attachment["timestamp"].number, timestamp.isFinite {
                            matches = matches.filter { index in
                                guard let start = contexts[index].startTime, let end = contexts[index].endTime else { return false }
                                return timestamp >= start - 0.01 && timestamp <= end + 0.01
                            }
                        }
                        guard matches.count == 1 else { throw ReporterError("Attachment \(filename) matches \(matches.count) executions; refusing ambiguous association") }
                        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
                        guard let size else { throw ReporterError("Cannot determine attachment size") }
                        let oversized = size.int64Value > fileLimit
                        if oversized { resolution.diagnostics.append("Attachment \(filename) exceeds 32 MiB; preserved locally and omitted from upload") }
                        resolution.matches.append(MatchedAttachment(rowIndex: matches[0], file: file, name: name, mime: mime(file.pathExtension), skippedForSize: oversized))
                    } catch { resolution.errors.append(String(describing: error)) }
                }
            } catch { resolution.errors.append(String(describing: error)) }
        }
        return resolution
    }
    public static func secureFile(_ filename: String, root: URL) throws -> URL {
        guard !filename.isEmpty, !filename.hasPrefix("/"), !filename.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw ReporterError("Unsafe exported attachment path") }
        var component = root
        for part in filename.split(separator: "/") {
            component.appendPathComponent(String(part))
            if try component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw ReporterError("Symbolic links are not accepted for exported attachments")
            }
        }
        let file = root.appendingPathComponent(filename).resolvingSymlinksInPath().standardizedFileURL
        guard SourceResolver.relative(file, to: root) != nil,
              (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw ReporterError("Attachment escapes export root or is not a regular file") }
        return file
    }
    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "txt", "log": "text/plain"
        case "json": "application/json"
        case "pdf": "application/pdf"
        case "mp4": "video/mp4"
        default: "application/octet-stream"
        }
    }
}
