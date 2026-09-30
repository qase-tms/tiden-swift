import Foundation
import TidenReporterCore

public struct XCResultInput: Sendable {
    public var summary: JSONValue
    public var tests: JSONValue
    public var details: [String: JSONValue]
    public var activities: [String: JSONValue]
    public var diagnostics: [String]
    public init(summary: JSONValue, tests: JSONValue, details: [String: JSONValue] = [:], activities: [String: JSONValue] = [:], diagnostics: [String] = []) {
        self.summary = summary; self.tests = tests; self.details = details; self.activities = activities; self.diagnostics = diagnostics
    }
}
public struct TestDefinition: Sendable {
    public let module: String
    public let suites: [String]
    public let node: JSONValue
    public var identifier: String { node["nodeIdentifier"].string ?? node["nodeIdentifierURL"].string ?? "" }
    public var key: String { module + "::" + identifier }
}
public enum TestTree {
    public static func definitions(_ tree: JSONValue) -> [TestDefinition] {
        var result: [TestDefinition] = []
        func visit(_ node: JSONValue, module: String?, suites: [String]) {
            let kind = node["nodeType"].string
            var module = module, suites = suites
            if kind == "Unit test bundle" || kind == "UI test bundle" { module = node["name"].string }
            if kind == "Test Suite", let name = node["name"].string { suites.append(name) }
            if kind == "Test Case" { result.append(TestDefinition(module: module ?? "", suites: suites, node: node)); return }
            for child in node["children"].array { visit(child, module: module, suites: suites) }
        }
        for node in tree["testNodes"].array { visit(node, module: nil, suites: []) }
        return result
    }
}
public struct XCResultReader: Sendable {
    private let process: any ProcessExecuting
    public init(process: any ProcessExecuting) { self.process = process }
    private func get(_ section: String, bundle: URL, identifier: String? = nil) async throws -> JSONValue {
        var args = ["/usr/bin/xcrun", "xcresulttool", "get", "test-results", section, "--path", bundle.path, "--compact"]
        if let identifier { args += ["--test-id", identifier] }
        let response = try await process.execute(args, passthrough: false)
        guard response.exitCode == 0, !response.interrupted else {
            throw ReporterError("xcresulttool \(section) failed (\(response.exitCode)): \(String(decoding: response.stderr.prefix(2000), as: UTF8.self))")
        }
        return try JSONValue.decode(response.stdout)
    }
    public func read(_ bundle: URL) async throws -> XCResultInput {
        let summary = try await get("summary", bundle: bundle)
        let tests = try await get("tests", bundle: bundle)
        var details: [String: JSONValue] = [:], activities: [String: JSONValue] = [:], diagnostics: [String] = []
        for test in TestTree.definitions(tests) {
            // Runner diagnostics are not real test identifiers and cannot be queried.
            if test.identifier.contains("-Runner (") { continue }
            do {
                details[test.key] = try await get("test-details", bundle: bundle, identifier: test.node["nodeIdentifierURL"].string ?? test.identifier)
                activities[test.key] = try await get("activities", bundle: bundle, identifier: test.node["nodeIdentifierURL"].string ?? test.identifier)
            } catch { diagnostics.append("Details/activities unavailable for \(test.key): \(error)") }
        }
        return XCResultInput(summary: summary, tests: tests, details: details, activities: activities, diagnostics: diagnostics)
    }
    public func exportAttachments(_ bundle: URL, output: URL) async throws -> JSONValue {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let response = try await process.execute(["/usr/bin/xcrun", "xcresulttool", "export", "attachments", "--path", bundle.path, "--output-path", output.path], passthrough: false)
        guard response.exitCode == 0, !response.interrupted else {
            throw ReporterError("xcresulttool attachment export failed (\(response.exitCode)): \(String(decoding: response.stderr.prefix(2000), as: UTF8.self))")
        }
        return try JSONValue.decode(Data(contentsOf: output.appendingPathComponent("manifest.json")))
    }
}
