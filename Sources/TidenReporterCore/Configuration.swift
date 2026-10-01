import Foundation

public enum ReporterMode: String, Sendable { case off, report, tiden }
public struct Configuration: Sendable {
    public var mode: ReporterMode = .off
    public var fallbackToReport = false
    public var rootDir: URL
    public var output: URL
    public var rootSuite: String?
    public var baseURL = URL(string: "https://api.tiden.ai")!
    public var token: String?
    public var product: String?
    public var runID: Int?
    public var complete = true
    public var title: String?
    public var runDescription: String?
    public var branch: String?
    public var buildSha: String?
    public var environment: String?
    public var batchSize = 200
    public var uploadAttachments = true
    public var sourceMap: [String: String] = [:]
    public init(rootDir: URL, output: URL) { self.rootDir = rootDir; self.output = output }
    public func redact(_ message: String) -> String {
        guard let token, !token.isEmpty else { return message }
        return message.replacingOccurrences(of: token, with: "[REDACTED]")
    }

    public static let optionKeys: [String: String] = [
        "mode": "mode", "fallback": "fallback", "root-dir": "rootDir", "output": "report.connections.local.path",
        "root-suite": "rootSuite", "base-url": "tiden.api.baseUrl", "token": "tiden.api.token", "product-id": "tiden.product",
        "run-id": "tiden.run.id", "run-title": "tiden.run.title", "run-description": "tiden.run.description",
        "complete": "tiden.run.complete", "branch": "tiden.run.branch", "build-sha": "tiden.run.buildSha",
        "environment": "environment", "batch-size": "tiden.batch.size", "upload-attachments": "tiden.uploadAttachments"
    ]
    public static let environmentKeys: [String: String] = [
        "TIDEN_MODE": "mode", "TIDEN_FALLBACK": "fallback", "TIDEN_ROOT_DIR": "rootDir", "TIDEN_ROOT_SUITE": "rootSuite",
        "TIDEN_REPORT_CONNECTION_PATH": "report.connections.local.path", "TIDEN_API_TOKEN": "tiden.api.token",
        "TIDEN_BASE_URL": "tiden.api.baseUrl", "TIDEN_PRODUCT_ID": "tiden.product", "TIDEN_RUN_ID": "tiden.run.id",
        "TIDEN_RUN_TITLE": "tiden.run.title", "TIDEN_RUN_DESCRIPTION": "tiden.run.description", "TIDEN_RUN_COMPLETE": "tiden.run.complete",
        "TIDEN_BRANCH": "tiden.run.branch", "TIDEN_BUILD_SHA": "tiden.run.buildSha", "TIDEN_ENVIRONMENT": "environment",
        "TIDEN_BATCH_SIZE": "tiden.batch.size", "TIDEN_UPLOAD_ATTACHMENTS": "tiden.uploadAttachments"
    ]
    public static func resolve(file: Data? = nil, environment env: [String: String], cli: [String: String], cwd: URL,
                               defaultOutput: URL) throws -> Configuration {
        var values: [String: JSONValue] = [:]
        if let file {
            let decoded = try JSONValue.decode(file)
            guard case .object = decoded else { throw ReporterError("tiden.config.json must be an object") }
            func flatten(_ object: [String: JSONValue], prefix: String = "") throws {
                for (key, value) in object {
                    let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                    if path == "sourceMap" { values[path] = value }
                    else if case .object(let nested) = value { try flatten(nested, prefix: path) }
                    else { values[path] = value }
                }
            }
            try flatten(decoded.object)
            for key in ["tiden", "tiden.api", "tiden.run", "tiden.batch", "report", "report.connections", "report.connections.local"] {
                if values[key] != nil { throw ReporterError("\(key) must be an object") }
            }
        }
        for (key, path) in environmentKeys { if let v = env[key] { values[path] = .string(v) } }
        for (key, value) in cli {
            guard let path = optionKeys[key] else { continue }
            values[path] = .string(value)
        }
        func string(_ key: String) throws -> String? {
            guard let v = values[key] else { return nil }
            guard let text = v.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReporterError("\(key) must be a nonempty string")
            }
            return text
        }
        func boolean(_ key: String, default fallback: Bool) throws -> Bool {
            guard let v = values[key] else { return fallback }
            if let b = v.bool { return b }
            if v.string == "true" { return true }
            if v.string == "false" { return false }
            throw ReporterError("\(key) must be true or false")
        }
        func integer(_ key: String, range: ClosedRange<Int>) throws -> Int? {
            guard let v = values[key] else { return nil }
            guard let n = v.integer, range.contains(n), v.bool == nil else { throw ReporterError("\(key) must be an integer in \(range)") }
            return n
        }
        func path(_ text: String) -> URL {
            (text.hasPrefix("/") ? URL(fileURLWithPath: text) : cwd.appendingPathComponent(text)).standardizedFileURL
        }
        var config = Configuration(rootDir: cwd, output: defaultOutput)
        if let s = try string("mode") {
            guard let mode = ReporterMode(rawValue: s) else { throw ReporterError("mode must be off, report, or tiden") }
            config.mode = mode
        }
        if let s = try string("fallback") {
            guard s == "off" || s == "report" else { throw ReporterError("fallback must be off or report") }
            config.fallbackToReport = s == "report"
        }
        if let s = try string("rootDir") { config.rootDir = path(s) }
        if let s = try string("report.connections.local.path") { config.output = path(s) }
        config.rootSuite = try string("rootSuite")
        if let s = try string("tiden.api.baseUrl") {
            guard let url = URL(string: s), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  ["https", "http"].contains(parts.scheme), parts.host != nil, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil else { throw ReporterError("tiden.api.baseUrl must be an http(s) URL without credentials, query, or fragment") }
            config.baseURL = url
        }
        config.token = try string("tiden.api.token")
        if let token = config.token, token.contains(where: { $0.isNewline || $0 == "\r" }) { throw ReporterError("Token contains invalid header characters") }
        config.product = try string("tiden.product")
        if let product = config.product, UUID(uuidString: product) == nil { throw ReporterError("tiden.product must be a UUID") }
        config.runID = try integer("tiden.run.id", range: 1...Int(Int32.max))
        config.complete = try boolean("tiden.run.complete", default: true)
        config.title = try string("tiden.run.title"); config.runDescription = try string("tiden.run.description")
        config.branch = try string("tiden.run.branch"); config.buildSha = try string("tiden.run.buildSha")
        config.environment = try string("environment")
        config.batchSize = try integer("tiden.batch.size", range: 1...2000) ?? 200
        config.uploadAttachments = try boolean("tiden.uploadAttachments", default: true)
        if let map = values["sourceMap"] {
            guard case .object(let entries) = map, entries.values.allSatisfy({ $0.string != nil }) else { throw ReporterError("sourceMap must map signatures to repository relative paths") }
            config.sourceMap = entries.mapValues { $0.string! }
        }
        if config.mode == .tiden {
            guard config.token != nil, config.product != nil else { throw ReporterError("tiden mode requires TIDEN_API_TOKEN and TIDEN_PRODUCT_ID") }
        } else if values["mode"] == nil && (config.token != nil || config.product != nil || config.runID != nil) {
            throw ReporterError("Tiden settings were supplied without mode; set TIDEN_MODE=tiden, report, or off explicitly")
        }
        return config
    }
}

public struct Invocation: Sendable {
    public let command: String
    public let options: [String: String]
    public let child: [String]
    public static func parse(_ arguments: [String]) throws -> Invocation {
        guard let command = arguments.first, ["report", "run"].contains(command) else { throw ReporterError("Expected report or run; use --help") }
        var options: [String: String] = [:], child: [String] = []
        var i = 1
        while i < arguments.count {
            let argument = arguments[i]
            if argument == "--" { child = Array(arguments.dropFirst(i + 1)); break }
            guard argument.hasPrefix("--") else { throw ReporterError("Unexpected argument: \(argument)") }
            let key = String(argument.dropFirst(2))
            guard Configuration.optionKeys[key] != nil || ["xcresult", "exit-code", "config"].contains(key) else { throw ReporterError("Unknown option: --\(key)") }
            guard options[key] == nil, i + 1 < arguments.count else { throw ReporterError("--\(key) requires one value and cannot be repeated") }
            options[key] = arguments[i + 1]; i += 2
        }
        if command == "report" {
            guard options["xcresult"] != nil, child.isEmpty else { throw ReporterError("report requires --xcresult PATH and no child command") }
        } else {
            guard options["xcresult"] == nil, let executable = child.first,
                  URL(fileURLWithPath: executable).lastPathComponent == "xcodebuild",
                  child.dropFirst().contains(where: { ["test", "test-without-building"].contains($0) }),
                  !child.contains(where: { $0 == "-resultBundlePath" || $0.hasPrefix("-resultBundlePath=") }) else {
                throw ReporterError("run requires -- xcodebuild test (or test-without-building), without -resultBundlePath")
            }
        }
        if let s = options["exit-code"], Int32(s) == nil { throw ReporterError("--exit-code must be an int32") }
        return Invocation(command: command, options: options, child: child)
    }
}
