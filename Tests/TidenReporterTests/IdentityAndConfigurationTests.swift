import Foundation
import Testing
import TidenReporterCore

struct IdentityAndConfigurationTests {
    @Test func goldenIdentityIgnoresDisplayAndExecutionContext() throws {
        let expected = "swift/v1::UnitTests::Outer/Nested/function(_:)"
        #expect(try Identity.signature(module: "UnitTests", identifier: "Outer/Nested/function(_:)") == expected)
        #expect(try Identity.signature(module: "UnitTests", identifier: "test://com.apple.xcode/Project/UnitTests/Outer/Nested/function(_:)?args=abcdef&repetition=3") == expected)
        #expect(try Identity.signature(module: "UnitTests", identifier: "Suite/testPass()") == "swift/v1::UnitTests::Suite/testPass")
        #expect(try Identity.signature(module: "UnitTests", identifier: "test://com.apple.xcode/Project/UnitTests/Suite/testPass") == "swift/v1::UnitTests::Suite/testPass")
        #expect(try Identity.signature(module: "UnitTests", identifier: "topLevel()") == "swift/v1::UnitTests::topLevel")
        #expect(try Identity.signature(module: "UnitTests", identifier: "suite/testPass()") != "swift/v1::UnitTests::Suite/testPass")
    }
    @Test func invalidIdentityIsRejected() {
        #expect(throws: ReporterError.self) { try Identity.signature(module: "", identifier: "Suite/a()") }
        #expect(throws: ReporterError.self) { try Identity.signature(module: "Tests", identifier: "") }
        #expect(throws: ReporterError.self) { try Identity.signature(module: "Tests", identifier: "test://com.apple.xcode/OnlyProject") }
    }
    @Test func configurationPrecedenceAndCanonicalEnvironment() throws {
        let file = Data(#"{"mode":"report","rootSuite":"file","tiden":{"product":"11111111-1111-4111-8111-111111111111","uploadAttachments":false,"batch":{"size":10},"run":{"branch":"file"}},"report":{"connections":{"local":{"path":"reports"}}}}"#.utf8)
        let config = try Configuration.resolve(file: file, environment: ["TIDEN_ROOT_SUITE": "env", "TIDEN_BRANCH": "ci", "TIDEN_BUILD_SHA": "abc", "TIDEN_REPORT_CONNECTION_PATH": "env-output", "TIDEN_BATCH_SIZE": "20"], cli: ["root-suite": "cli"], cwd: URL(fileURLWithPath: "/tmp"), defaultOutput: URL(fileURLWithPath: "/tmp/default"))
        #expect(config.rootSuite == "cli")
        #expect(config.branch == "ci")
        #expect(config.buildSha == "abc")
        #expect(config.output.path == "/tmp/env-output")
        #expect(config.batchSize == 20)
        #expect(!config.uploadAttachments)
    }
    @Test func relativeConfigPathsTreatCWDAsDirectoryWithoutTrailingSlash() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let cwd = URL(fileURLWithPath: root.path, isDirectory: false)
        #expect(!cwd.hasDirectoryPath)
        let config = try Configuration.resolve(environment: ["TIDEN_MODE": "report", "TIDEN_ROOT_DIR": "Sources", "TIDEN_REPORT_CONNECTION_PATH": "evidence"], cli: [:], cwd: cwd, defaultOutput: root.appendingPathComponent("unused"))
        #expect(config.rootDir.path == source.path)
        #expect(config.output.path == root.appendingPathComponent("evidence").path)
        let absolute = try Configuration.resolve(environment: ["TIDEN_MODE": "report", "TIDEN_ROOT_DIR": source.path, "TIDEN_REPORT_CONNECTION_PATH": "/tmp/absolute-evidence"], cli: [:], cwd: cwd, defaultOutput: root.appendingPathComponent("unused"))
        #expect(absolute.rootDir.path == source.path)
        #expect(absolute.output.path == "/tmp/absolute-evidence")
    }
    @Test(arguments: [#"{"mode":true}"#, #"{"mode":"tiden"}"#, #"{"tiden":{"product":"bad"}}"#, #"{"tiden":{"batch":{"size":0}}}"#, #"{"tiden":{"batch":{"size":2001}}}"#, #"{"tiden":{"run":{"complete":"yes"}}}"#, #"{"tiden":{"run":{"id":2147483648}}}"#, #"{"tiden":{"api":{"baseUrl":"https://user:secret@host"}}}"#, #"{"tiden":{"api":[]}}"#])
    func invalidConfigCannotSilentlyDisableReporting(text: String) {
        #expect(throws: (any Error).self) { try Configuration.resolve(file: Data(text.utf8), environment: [:], cli: [:], cwd: URL(fileURLWithPath: "/tmp"), defaultOutput: URL(fileURLWithPath: "/tmp/output")) }
    }
    @Test func partialConfigAndRedaction() throws {
        #expect(throws: ReporterError.self) { try Configuration.resolve(environment: ["TIDEN_API_TOKEN": "secret"], cli: [:], cwd: URL(fileURLWithPath: "/tmp"), defaultOutput: URL(fileURLWithPath: "/tmp/output")) }
        let config = try Configuration.resolve(environment: ["TIDEN_MODE": "off", "TIDEN_API_TOKEN": "secret"], cli: [:], cwd: URL(fileURLWithPath: "/tmp"), defaultOutput: URL(fileURLWithPath: "/tmp/output"))
        #expect(config.mode == .off)
        #expect(config.redact("reason secret headers") == "reason [REDACTED] headers")
    }
    @Test func invocationPreservesChildArgumentsWithoutShellInterpretation() throws {
        let invocation = try Invocation.parse(["run", "--mode", "report", "--", "xcodebuild", "test-without-building", "-scheme", "Name with spaces;$(echo x)"])
        #expect(invocation.child == ["xcodebuild", "test-without-building", "-scheme", "Name with spaces;$(echo x)"])
        #expect(throws: ReporterError.self) { try Invocation.parse(["run", "--", "xcodebuild", "test", "-resultBundlePath", "owned.xcresult"]) }
        #expect(throws: ReporterError.self) { try Invocation.parse(["report", "--xcresult", "x", "--exit-code", "not-a-number"]) }
    }
    @Test func resultWireShapeMatchesPublicAPI() throws {
        let value = try JSONValue.decode(Wire.encode(sampleRow()))
        #expect(value["execution"]["duration"].string == "125")
        #expect(value["execution"]["startTime"].number == 1000)
        #expect(value["execution"]["endTime"].number == 1000.125)
        #expect(value["fields"]["file_path"].string == "Tests/Suite.swift")
        #expect(value["id"].string.flatMap(UUID.init(uuidString:)) != nil)
        #expect(value["attachments"].array.isEmpty)
    }
}
