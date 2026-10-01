import Foundation
import TidenReporterCore
import TidenXCResult

func json(_ text: String) throws -> JSONValue { try JSONValue.decode(Data(text.utf8)) }
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiden-swift-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func sampleRow(id: String = "11111111-1111-4111-8111-111111111111", status: String = "passed") -> ResultCreate {
    ResultCreate(id: id, title: "Example", signature: "swift/v1::Tests::Suite/pass", execution: ResultExecution(status: status, durationMilliseconds: 125, startTime: 1000), fields: ["file_path": "Tests/Suite.swift"])
}
func onlineConfig(output: URL = URL(fileURLWithPath: "/tmp/unused")) -> Configuration {
    var config = Configuration(rootDir: URL(fileURLWithPath: "/tmp"), output: output)
    config.mode = .tiden
    config.token = "test-secret"
    config.product = "11111111-1111-4111-8111-111111111111"
    return config
}
actor MockTransport: HTTPTransport {
    enum Step: Sendable { case response(HTTPResponse), connectionError }
    struct Request: Sendable { let url: URL; let headers: [String: String]; let body: Data }
    var steps: [Step]
    var requests: [Request] = []
    init(_ steps: [Step]) { self.steps = steps }
    func post(url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        requests.append(Request(url: url, headers: headers, body: body))
        guard !steps.isEmpty else { throw ReporterError("No scripted request response") }
        switch steps.removeFirst() {
        case .response(let response): return response
        case .connectionError: throw URLError(.networkConnectionLost)
        }
    }
}
actor RecordingSleeper: Sleeping {
    var delays: [Double] = []
    func sleep(seconds: Double) async throws { delays.append(seconds) }
}
func http(_ status: Int = 200, _ text: String, headers: [String: String] = [:]) -> MockTransport.Step {
    .response(HTTPResponse(status: status, headers: headers, body: Data(text.utf8)))
}
func http(_ text: String, headers: [String: String] = [:]) -> MockTransport.Step { http(200, text, headers: headers) }
actor MockProcess: ProcessExecuting {
    var outputs: [ProcessResult]
    var commands: [[String]] = []
    init(_ outputs: [ProcessResult]) { self.outputs = outputs }
    func execute(_ arguments: [String], passthrough: Bool) async throws -> ProcessResult {
        commands.append(arguments)
        guard !outputs.isEmpty else { throw ReporterError("No scripted process output") }
        return outputs.removeFirst()
    }
}
func fixtureInput(outcome: String = "Passed", runs: JSONValue? = nil, definition: String = "Suite/pass()", count: Int = 1) throws -> XCResultInput {
    let tests = try json("""
    {"testNodes":[{"nodeType":"Unit test bundle","name":"Tests","children":[{"nodeType":"Test Suite","name":"Suite","children":[{"nodeType":"Test Case","name":"Readable title","nodeIdentifier":"\(definition)","result":"\(outcome)","durationInSeconds":0.1}]}]}]}
    """)
    let failed = outcome == "Failed" ? count : 0
    let skipped = outcome == "Skipped" ? count : 0
    let expected = outcome == "Expected Failure" ? count : 0
    let summary = try json("""
    {"result":"\(outcome)","totalTestCount":1,"failedTests":\(failed),"devicesAndConfigurations":[{"passedTests":\(count - failed - skipped - expected),"failedTests":\(failed),"skippedTests":\(skipped),"expectedFailures":\(expected)}]}
    """)
    let run = try runs ?? json("""
    [{"nodeType":"Test Case Run","name":"Run","result":"\(outcome)","durationInSeconds":0.1}]
    """)
    let details = JSONValue.object([
        "testIdentifier": .string(definition), "devices": .array([.object(["deviceId": .string("device-1"), "deviceName": .string("Mac")])]),
        "testPlanConfigurations": .array([.object(["configurationId": .string("1"), "configurationName": .string("Default")])]), "testRuns": run
    ])
    return XCResultInput(summary: summary, tests: tests, details: ["Tests::\(definition)": details])
}
func fixtureSources(root: URL) throws -> SourceResolver {
    let source = root.appendingPathComponent("Unusual/Layout/Tests.swift")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "struct Suite { func pass() {} }".write(to: source, atomically: true, encoding: .utf8)
    return try SourceResolver(root: root)
}
