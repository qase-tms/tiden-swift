import Foundation
import Testing
import TidenReporterCore
import TidenXCResult

struct CoordinatorTests {
    private func extraction(_ input: XCResultInput, exportStatus: Int32? = nil) throws -> MockProcess {
        var outputs = try [input.summary, input.tests, input.details["Tests::Suite/pass()"]!, .object([:])].map {
            ProcessResult(exitCode: 0, stdout: try Wire.encode($0))
        }
        if let exportStatus { outputs.append(ProcessResult(exitCode: exportStatus, stderr: Data("export failed".utf8))) }
        return MockProcess(outputs)
    }
    @Test func actualFailedAssertionCompletesFailedRunAndKeepsEvidence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixtureSources(root: root)
        var config = onlineConfig(output: root.appendingPathComponent("output"))
        config.rootDir = root; config.uploadAttachments = false
        let transport = MockTransport([http(#"{"run":{"seqNum":9}}"#), http(#"{"accepted":"1","duplicates":"0","errors":[]}"#), http("{}")])
        let api = APIClient(config: config, transport: transport)
        let process = try extraction(fixtureInput(outcome: "Failed"))
        let coordinator = ReportCoordinator(config: config, reader: XCResultReader(process: process), api: api)
        try await coordinator.begin()
        let summary = try await coordinator.report(bundle: root.appendingPathComponent("input.xcresult"), exitCode: 65, cancelled: false)
        #expect(summary.trustworthy)
        #expect(summary.exitCode == 65)
        let requests = await transport.requests
        #expect(requests.last?.url.path.hasSuffix("/runs/9:complete") == true)
        let persisted = try JSONValue.decode(Data(contentsOf: config.output.appendingPathComponent("results.json")))
        #expect(persisted.array.first?["execution"]["status"].string == "failed")
        #expect(FileManager.default.fileExists(atPath: config.output.appendingPathComponent("batch-1.json").path))
    }
    @Test func enabledAttachmentExportFailureAbortsOwnedRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixtureSources(root: root)
        var config = onlineConfig(output: root.appendingPathComponent("output")); config.rootDir = root
        let transport = MockTransport([http(#"{"run":{"seqNum":9}}"#), http(#"{"accepted":1,"duplicates":0}"#), http("{}")])
        let coordinator = ReportCoordinator(config: config, reader: XCResultReader(process: try extraction(fixtureInput(), exportStatus: 1)), api: APIClient(config: config, transport: transport))
        try await coordinator.begin()
        let summary = try await coordinator.report(bundle: root.appendingPathComponent("input.xcresult"), exitCode: 0, cancelled: false)
        #expect(!summary.trustworthy)
        #expect(summary.errors.contains { $0.contains("attachment export failed") })
        #expect(await transport.requests.last?.url.path.hasSuffix("/runs/9:abort") == true)
        #expect(FileManager.default.fileExists(atPath: config.output.appendingPathComponent("results.json").path))
    }
    @Test func failedAcknowledgmentAndCancellationNeverFinalizeJoinedRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixtureSources(root: root)
        var config = onlineConfig(output: root.appendingPathComponent("output")); config.rootDir = root
        config.runID = 7; config.complete = false; config.uploadAttachments = false
        let transport = MockTransport([http(#"{"accepted":0,"duplicates":0,"errors":[{"index":0,"resultId":"id","code":"INVALID","message":"rejected"}]}"#)])
        let coordinator = ReportCoordinator(config: config, reader: XCResultReader(process: try extraction(fixtureInput())), api: APIClient(config: config, transport: transport), isCancelled: { true })
        try await coordinator.begin()
        let summary = try await coordinator.report(bundle: root.appendingPathComponent("input.xcresult"), exitCode: 0, cancelled: false)
        #expect(!summary.trustworthy)
        #expect(summary.cancelled)
        #expect(summary.errors.contains { $0.contains("INVALID") })
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url.path.hasSuffix("/runs/7/results:report"))
    }
    @Test func attachmentOptOutDoesNotInvokeExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixtureSources(root: root)
        var config = Configuration(rootDir: root, output: root.appendingPathComponent("output"))
        config.mode = .report; config.uploadAttachments = false
        let process = try extraction(fixtureInput())
        let coordinator = ReportCoordinator(config: config, reader: XCResultReader(process: process))
        let summary = try await coordinator.report(bundle: root.appendingPathComponent("input.xcresult"), exitCode: 0, cancelled: false)
        #expect(summary.trustworthy)
        #expect(await process.commands.count == 4)
    }
    @Test func rejectedAttachmentUploadRetainsBytesAndAbortsRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixtureSources(root: root)
        var config = onlineConfig(output: root.appendingPathComponent("output")); config.rootDir = root
        let export = config.output.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: export.appendingPathComponent("capture.png"))
        try Data(#"[{"testIdentifier":"Suite/pass()","attachments":[{"exportedFileName":"capture.png","suggestedHumanReadableName":"Screenshot"}]}]"#.utf8).write(to: export.appendingPathComponent("manifest.json"))
        let transport = MockTransport([http(#"{"run":{"seqNum":9}}"#), http(400, #"{"message":"attachment refused test-secret"}"#), http(#"{"accepted":1,"duplicates":0}"#), http("{}")])
        let coordinator = ReportCoordinator(config: config, reader: XCResultReader(process: try extraction(fixtureInput(), exportStatus: 0)), api: APIClient(config: config, transport: transport))
        try await coordinator.begin()
        let summary = try await coordinator.report(bundle: root.appendingPathComponent("input.xcresult"), exitCode: 0, cancelled: false)
        #expect(!summary.trustworthy)
        #expect(summary.errors.contains { $0.contains("attachment refused [REDACTED]") })
        let requests = await transport.requests
        #expect(requests[1].url.path.hasSuffix("/attachments:upload"))
        #expect(requests.last?.url.path.hasSuffix("/runs/9:abort") == true)
        #expect(try Data(contentsOf: export.appendingPathComponent("capture.png")) == Data([7, 8, 9]))
        let rows = try JSONValue.decode(Data(contentsOf: config.output.appendingPathComponent("results.json")))
        #expect(rows.array.first?["attachments"].array.isEmpty == true)
    }
}
