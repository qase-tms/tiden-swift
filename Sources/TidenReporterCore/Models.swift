import Foundation

public struct ReporterError: Error, CustomStringConvertible, Sendable {
    public let description: String
    /// Set when the server answered with a refusal: the HTTP status and the raw body, for the few callers that
    /// answer one specific refusal differently. Never printed; `description` is the redacted text.
    public let httpStatus: Int?
    public let responseBody: Data?
    public init(_ description: String) { self.description = description; httpStatus = nil; responseBody = nil }
    public init(_ description: String, httpStatus: Int, responseBody: Data) {
        self.description = description; self.httpStatus = httpStatus; self.responseBody = responseBody
    }
}

/// Schema-tolerant Xcode input, with strict accessors at the trust boundaries.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { object[key] ?? .null }
    public var object: [String: JSONValue] { if case .object(let v) = self { v } else { [:] } }
    public var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var integer: Int? {
        if let s = string { return Int(s) }
        guard let n = number, n.isFinite, n.rounded() == n, n >= Double(Int.min), n < Double(Int.max) else { return nil }
        return Int(n)
    }
    public static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: data) }
}

public enum Wire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public struct ResultExecution: Codable, Sendable, Equatable {
    public var status: String
    public var duration: String
    public var startTime: Double?
    public var endTime: Double?
    public init(status: String, durationMilliseconds: Int64, startTime: Double? = nil) {
        self.status = status; duration = String(durationMilliseconds); self.startTime = startTime
        endTime = startTime.map { $0 + Double(durationMilliseconds) / 1000 }
    }
}
public struct SuiteSegment: Codable, Sendable, Equatable {
    public var title: String
    public init(_ title: String) { self.title = title }
}
/// The parts of a test's identity, from which the server builds its case key. `scope` and `name` are as Xcode
/// names them; the server does any normalizing. The legacy `signature` is sent next to this, unchanged.
public struct IdentityParts: Codable, Sendable, Equatable {
    public var language: String
    public var repository: String
    public var scope: [String]
    public var name: [String]
    public init(language: String, repository: String, scope: [String], name: [String]) {
        self.language = language; self.repository = repository; self.scope = scope; self.name = name
    }
}
public struct ResultCreate: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var signature: String
    /// Absent without a repository (or after a server that does not know the field refused it).
    public var identity: IdentityParts?
    public var execution: ResultExecution
    public var suitePath: [SuiteSegment]
    public var fields: [String: String]
    public var params: [String: String]
    public var attachments: [String]
    public var message: String?
    public init(id: String, title: String, signature: String, execution: ResultExecution,
                suitePath: [SuiteSegment] = [], fields: [String: String] = [:], params: [String: String] = [:],
                identity: IdentityParts? = nil) {
        self.id = id; self.title = title; self.signature = signature; self.identity = identity; self.execution = execution
        self.suitePath = suitePath; self.fields = fields; self.params = params; attachments = []
    }
}
public struct CreateRun: Codable, Sendable {
    public var title: String?
    public var description: String?
    public var environment: String?
    public var branch: String?
    public var buildSha: String?
    public var startedAt: String
    public var clientMeta: [String: String] = ["framework": "xcode", "reporter": "tiden-swift", "identity": "swift/v1"]
    public init(config: Configuration, now: Date) {
        title = config.title; description = config.runDescription; environment = config.environment
        branch = config.branch; buildSha = config.buildSha
        if let repository = config.repository { clientMeta["gitRepository"] = repository }
        startedAt = ISO8601DateFormatter().string(from: now)
    }
}
public struct RunHandle: Codable, Sendable, Equatable {
    public let sequence: Int
    public let ownsCompletion: Bool
    public init(sequence: Int, ownsCompletion: Bool) { self.sequence = sequence; self.ownsCompletion = ownsCompletion }
}
public struct ReportSummary: Codable, Sendable {
    public var definitionCount: Int = 0
    public var executionCount: Int = 0
    public var diagnostics: [String] = []
    public var errors: [String] = []
    public var exitCode: Int32 = 0
    public var cancelled: Bool = false
    public var trustworthy: Bool { errors.isEmpty && !cancelled }
    public init() {}
}

public enum Identity {
    public static func declaration(_ identifier: String) throws -> String {
        var value = identifier
        if identifier.hasPrefix("test://") {
            guard let url = URLComponents(string: identifier), url.scheme == "test" else { throw ReporterError("Invalid test identifier URL") }
            let components = url.path.split(separator: "/").map(String.init)
            guard components.count >= 3 else { throw ReporterError("Test URL lacks module/declaration: \(identifier)") }
            // Xcode's path is project/module/declaration. Declaration can be nested.
            value = components.dropFirst(2).joined(separator: "/")
        } else { value = value.components(separatedBy: "?")[0] }
        value = value.removingPercentEncoding ?? value
        if value.hasSuffix("()") { value.removeLast(2) }
        guard !value.isEmpty, !value.contains("::"), !value.contains("\n") else {
            throw ReporterError("Missing containing declaration/function identity: \(identifier)")
        }
        return value
    }
    public static let language = "swift"
    /// `scope` = the module, then the enclosing types; `name` = the declaration itself, by the same rule as the
    /// signature (argument labels kept, a terminal `()` removed). Case and spelling are as Xcode gives them.
    public static func parts(module: String, identifier: String, repository: String) throws -> IdentityParts {
        guard !module.isEmpty, !module.contains("::") else { throw ReporterError("Invalid test module") }
        let path = try declaration(identifier).split(separator: "/").map(String.init)
        guard let name = path.last else { throw ReporterError("Missing containing declaration/function identity: \(identifier)") }
        return IdentityParts(language: language, repository: repository, scope: [module] + path.dropLast(), name: [name])
    }
    public static func signature(module: String, identifier: String) throws -> String {
        guard !module.isEmpty, !module.contains("::") else { throw ReporterError("Invalid test module") }
        return "swift/v1::\(module)::\(try declaration(identifier))"
    }
}
