import Foundation
import Testing
import TidenReporterCore
import TidenXCResult

struct ConverterTests {
    @Test func repeatedFailuresRetainNestedOptionalAssertionValuesAsDiagnostics() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Sanitized native optInFailure shape: Optional values contain nested Test Values.
        let diagnostic = try json(#"""
        {"nodeType":"Test Case Run","result":"Failed","name":"Expectation failed: optionalValue != expected","sourceLocation":{"filePath":"Tests.swift","lineNumber":23},"children":[
          {"nodeType":"Expression","name":"Results","children":[
            {"nodeType":"Test Value","name":"optionalValue : \"1\"","details":"Swift.Optional<Swift.String>","children":[
              {"nodeType":"Test Value","name":"some : \"1\"","details":"Swift.String"}
            ]},
            {"nodeType":"Test Value","name":"some : \"1\"","details":"Swift.String"},
            {"nodeType":"Test Value","name":"_ : \"1\"","details":"Swift.Optional<Swift.String>","children":[
              {"nodeType":"Test Value","name":"some : \"1\"","details":"Swift.String"}
            ]}
          ]},
          {"nodeType":"Source Code Reference","name":"","sourceLocation":{"filePath":"Tests.swift","lineNumber":23}}
        ]}
        """#)
        let durations = [0.0015130043029785156, 0.0002262592315673828]
        let runs = JSONValue.array(durations.enumerated().map { index, duration in
            .object(["nodeType": .string("Repetition"), "name": .string("Repetition \(index + 1)"),
                     "nodeIdentifier": .string(String(index + 1)), "result": .string("Failed"),
                     "durationInSeconds": .number(duration), "children": .array([diagnostic])])
        })
        let report = Converter().convert(try fixtureInput(outcome: "Failed", runs: runs, count: 2), sources: try fixtureSources(root: root), exitCode: 65)
        #expect(report.summary.trustworthy)
        #expect(report.rows.count == 2)
        #expect(report.rows.map(\.execution.status) == ["failed", "failed"])
        #expect(report.rows.map(\.execution.duration) == ["2", "0"])
        #expect(report.contexts.map(\.repetition) == [1, 2])
        #expect(report.rows.allSatisfy { $0.message == "Expectation failed: optionalValue != expected" })
        #expect(report.contexts.allSatisfy { $0.arguments.isEmpty })
        #expect(report.rows.allSatisfy { Set($0.params.keys) == ["tiden.xcode.device", "tiden.xcode.configuration"] })
    }
    @Test func failedParameterizedAssertionsDoNotOverwriteOriginalRepeatedInputs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = try json(#"""
        [{"nodeType":"Repetition","name":"Repetition 1","children":[
          {"nodeType":"Arguments","name":"2","result":"Failed","durationInSeconds":0.1,"children":[
            {"nodeType":"Arguments","name":"Arguments","children":[{"nodeType":"Test Value","name":"value : 2"}]},
            {"nodeType":"Test Case Run","name":"Expectation failed: value == expected","result":"Failed","children":[
              {"nodeType":"Expression","name":"Results","children":[
                {"nodeType":"Test Value","name":"value : 999"},
                {"nodeType":"Test Value","name":"assertionOnly : false"}
              ]},
              {"nodeType":"Source Code Reference","name":"","sourceLocation":{"filePath":"Tests.swift","lineNumber":1}}
            ]}
          ]}
        ]},{"nodeType":"Repetition","name":"Repetition 2","children":[
          {"nodeType":"Arguments","name":"2","result":"Passed","durationInSeconds":0.2,"children":[{"nodeType":"Test Value","name":"value : 2"}]}
        ]}]
        """#)
        var input = try fixtureInput(outcome: "Failed", runs: runs, count: 2)
        input.summary = try json(#"{"result":"Failed","totalTestCount":1,"failedTests":1,"devicesAndConfigurations":[{"passedTests":1,"failedTests":1,"skippedTests":0,"expectedFailures":0}]}"#)
        let report = Converter().convert(input, sources: try fixtureSources(root: root), exitCode: 65)
        #expect(report.summary.trustworthy)
        #expect(report.rows.map(\.execution.status) == ["failed", "passed"])
        #expect(report.contexts.map(\.repetition) == [1, 2])
        #expect(report.contexts.allSatisfy { $0.arguments == ["2"] })
        #expect(report.rows.allSatisfy { $0.params["value"] == "2" && $0.params["assertionOnly"] == nil })
        #expect(report.rows.first?.message == "Expectation failed: value == expected")
        #expect(report.rows[0].signature == report.rows[1].signature)
        #expect(report.rows[0].id != report.rows[1].id)
    }
    @Test func failedSwiftExpectationExpressionRemainsOneFailedExecution() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Sanitized native Swift Testing assertion shape from validation.3Tg4tw.
        let runs = try json(#"""
        [{"nodeType":"Device","name":"MacBook Pro","nodeIdentifier":"device-1","durationInSeconds":0.004,"result":"Failed","children":[
          {"nodeType":"Test Plan Configuration","name":"Default","nodeIdentifier":"1","durationInSeconds":0.004,"result":"Failed","children":[
            {"nodeType":"Test Case Run","name":"Expectation failed: output.path == expected","result":"Failed","sourceLocation":{"filePath":"Tests.swift","lineNumber":26},"children":[
              {"nodeType":"Expression","name":"Results","children":[
                {"nodeType":"Test Value","name":"output.path : \"/env-output\"","details":"Swift.String"},
                {"nodeType":"Test Value","name":"_ : \"/tmp/env-output\"","details":"Swift.String"}
              ]},
              {"nodeType":"Source Code Reference","name":"","sourceLocation":{"filePath":"Tests.swift","lineNumber":26}}
            ]}
          ]}
        ]}]
        """#)
        let report = Converter().convert(try fixtureInput(outcome: "Failed", runs: runs), sources: try fixtureSources(root: root), exitCode: 65)
        #expect(report.summary.trustworthy)
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.execution.status == "failed")
        #expect(report.rows.first?.execution.duration == "4")
        #expect(report.rows.first?.message == "Expectation failed: output.path == expected")
        #expect(report.rows.first?.fields["xcode_result"] == "Failed")
        #expect(report.rows.first?.params["output.path"] == nil)
    }
    @Test func relativeSourceMetadataAndOverridesTreatRootAsDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Nested/Actual.swift")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// File intentionally has no discoverable declaration".write(to: source, atomically: true, encoding: .utf8)
        let noSlash = URL(fileURLWithPath: root.path, isDirectory: false)
        #expect(!noSlash.hasDirectoryPath)
        let resolver = try SourceResolver(root: noSlash)
        #expect(resolver.resolve(signature: "s", identifier: "Missing/function()", location: "Nested/Actual.swift").path == "Nested/Actual.swift")
        #expect(resolver.resolve(signature: "s", identifier: "Missing/function()", location: source.path).path == "Nested/Actual.swift")
        let overridden = try SourceResolver(root: noSlash, overrides: ["s": "Nested/Actual.swift"])
        #expect(overridden.resolve(signature: "s", identifier: "Missing/function()", location: nil).path == "Nested/Actual.swift")
    }
    @Test func activityEventsDoNotFabricateExecutionTimes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var input = try fixtureInput()
        input.activities["Tests::Suite/pass()"] = try json(#"{"testRuns":[{"device":{"deviceId":"device-1"},"testPlanConfiguration":{"configurationId":"1"},"activities":[{"startTime":1050,"childActivities":[{"startTime":1055}]}]}]}"#)
        let sources = try fixtureSources(root: root)
        let eventsOnly = Converter().convert(input, sources: sources)
        #expect(eventsOnly.summary.trustworthy)
        #expect(eventsOnly.rows.first?.execution.startTime == nil)
        #expect(eventsOnly.rows.first?.execution.endTime == nil)
        #expect(eventsOnly.contexts.first?.startTime == nil)
        input.activities["Tests::Suite/pass()"] = try json(#"{"testRuns":[{"startTime":1000,"endTime":1060,"device":{"deviceId":"device-1"},"testPlanConfiguration":{"configurationId":"1"},"activities":[{"startTime":1050}]}]}"#)
        let explicit = Converter().convert(input, sources: sources)
        #expect(explicit.rows.first?.execution.startTime == 1000)
        #expect(explicit.rows.first?.execution.endTime == 1060)
        #expect(explicit.contexts.first?.endTime == 1060)
    }
    @Test(arguments: ["Expected Failure", "Failed", "Skipped"])
    func untimedAssertionDiagnosticsPreserveTheEnclosingExecution(outcome: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Sanitized Xcode 27 shape: assertion diagnostics are named Test Case Run
        // nodes with source references, under one timed configuration execution.
        let runs = try json("""
        [{"nodeType":"Device","name":"MacBook Pro","nodeIdentifier":"device-1","result":"\(outcome)","durationInSeconds":0.25,"children":[
          {"nodeType":"Test Plan Configuration","name":"Default","nodeIdentifier":"1","result":"\(outcome)","durationInSeconds":0.25,"children":[
            {"nodeType":"Test Case Run","name":"Expected fixture assertion","result":"\(outcome)","children":[{"nodeType":"Source Code Reference","name":"","sourceLocation":{"filePath":"Tests.swift","lineNumber":16}}]},
            {"nodeType":"Test Case Run","name":"Second assertion diagnostic","result":"\(outcome)","children":[]}
          ]}
        ]}]
        """)
        let report = Converter().convert(try fixtureInput(outcome: outcome, runs: runs), sources: try fixtureSources(root: root))
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.execution.duration == "250")
        #expect(report.rows.first?.message == "Expected fixture assertion\nSecond assertion diagnostic")
        #expect(report.rows.first?.fields["xcode_result"] == outcome)
        #expect(report.summary.trustworthy == (outcome != "Skipped"))
    }
    @Test func deviceWrapperUsesIdentifierWhenModelsHaveTheSameName() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = try json(#"[{"nodeType":"Device","name":"MacBook Pro","nodeIdentifier":"device-2","children":[{"nodeType":"Test Plan Configuration","name":"Default","nodeIdentifier":"1","result":"Passed","durationInSeconds":0.1}]}]"#)
        var input = try fixtureInput(runs: runs)
        var details = input.details["Tests::Suite/pass()"]!.object
        details["devices"] = try json(#"[{"deviceId":"device-1","deviceName":"First Mac","modelName":"MacBook Pro"},{"deviceId":"device-2","deviceName":"Second Mac","modelName":"MacBook Pro"}]"#)
        input.details["Tests::Suite/pass()"] = .object(details)
        let report = Converter().convert(input, sources: try fixtureSources(root: root))
        #expect(report.summary.trustworthy)
        #expect(report.rows.first?.params["tiden.xcode.device"] == "device-2")
        #expect(report.contexts.first?.deviceName == "Second Mac")
    }
    @Test func realParameterDetailsPreserveOneIdentityAndNamedInputs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "struct SampleExportTests { func unsafeSheetStatesNeverEmitScaledNumbers(_ state: Int) {} }".write(to: root.appendingPathComponent("Tests.swift"), atomically: true, encoding: .utf8)
        let details = try JSONValue.decode(Data(contentsOf: Bundle.module.url(forResource: "parameter-details", withExtension: "json", subdirectory: "Fixtures")!))
        let identifier = details["testIdentifier"].string!
        var input = try fixtureInput(definition: identifier, count: 3)
        input.details["Tests::\(identifier)"] = details
        let report = Converter().convert(input, sources: try SourceResolver(root: root))
        #expect(report.summary.trustworthy)
        #expect(report.rows.count == 3)
        #expect(Set(report.rows.map(\.signature)) == ["swift/v1::Tests::SampleExportTests/unsafeSheetStatesNeverEmitScaledNumbers(_:)"])
        #expect(Set(report.rows.compactMap { $0.params["state"] }).count == 3)
        #expect(report.rows.allSatisfy { !$0.signature.contains("args=") })
        #expect(Set(report.rows.map(\.id)).count == 3)
    }
    @Test func devicesRepetitionsAndArgumentOrderAreSeparateExecutions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = try json("""
        [{"nodeType":"Device","name":"Mac","children":[{"nodeType":"Test Plan Configuration","name":"Default","children":[
          {"nodeType":"Repetition","name":"Repetition 2","children":[{"nodeType":"Arguments","name":"2,1","result":"Passed","durationInSeconds":0.2,"children":[{"nodeType":"Test Value","name":"z : 2"},{"nodeType":"Test Value","name":"a : 1"}]}]},
          {"nodeType":"Repetition","name":"Repetition 1","children":[{"nodeType":"Arguments","name":"2,1","result":"Passed","durationInSeconds":0.1,"children":[{"nodeType":"Test Value","name":"z : 2"},{"nodeType":"Test Value","name":"a : 1"}]}]}
        ]}]}]
        """)
        let input = try fixtureInput(runs: runs, count: 2)
        let report = Converter().convert(input, sources: try fixtureSources(root: root))
        #expect(report.summary.trustworthy)
        #expect(report.rows.count == 2)
        #expect(report.contexts.map(\.repetition) == [1, 2])
        #expect(report.contexts.allSatisfy { $0.arguments == ["2", "1"] })
        #expect(report.rows[0].params["tiden.xcode.device"] == "device-1")
        #expect(report.rows[0].params["tiden.xcode.configuration"] == "1")
        #expect(report.rows[0].signature == report.rows[1].signature)
        #expect(report.rows[0].id != report.rows[1].id)
    }
    @Test func partialOutcomesRemainAvailableButNeverComplete() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = try json(#"[{"nodeType":"Test Case Run","name":"First","result":"Passed","durationInSeconds":0.1},{"nodeType":"Test Case Run","name":"Second","result":"unknown","durationInSeconds":0.1}]"#)
        let report = Converter().convert(try fixtureInput(runs: runs, count: 2), sources: try fixtureSources(root: root))
        #expect(report.rows.count == 1)
        #expect(!report.summary.trustworthy)
        #expect(report.summary.errors.contains { $0.contains("Unknown/incomplete") })
        #expect(report.summary.errors.contains { $0.contains("Execution count") })
    }
    @Test(arguments: ["Passed", "Failed", "Skipped", "Expected Failure"])
    func explicitOutcomesAreMappedWithoutHidingUnexpectedFailures(outcome: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = Converter().convert(try fixtureInput(outcome: outcome), sources: try fixtureSources(root: root))
        #expect(report.rows.first?.fields["xcode_result"] == outcome)
        let expected = outcome == "Expected Failure" ? "passed" : outcome.lowercased()
        #expect(report.rows.first?.execution.status == expected)
        #expect(report.summary.trustworthy == (outcome != "Skipped"))
    }
    @Test func infrastructureFailureAndCancellationCannotCompleteGreen() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixtureInput()
        let source = try fixtureSources(root: root)
        #expect(!Converter().convert(input, sources: source, exitCode: 65).summary.trustworthy)
        #expect(!Converter().convert(input, sources: source, cancelled: true).summary.trustworthy)
        var truncated = input
        truncated.summary = try json(#"{"result":"Passed","totalTestCount":2,"failedTests":0,"devicesAndConfigurations":[{"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0}]}"#)
        #expect(!Converter().convert(truncated, sources: source).summary.trustworthy)
        var empty = input
        empty.tests = try json(#"{"testNodes":[]}"#)
        #expect(!Converter().convert(empty, sources: source).summary.trustworthy)
    }
    @Test(arguments: [
        ("Tests-Runner (1) encountered an error", "The test runner exited with code -1 before finishing running tests."),
        ("Tests-Runner (1) encountered an error", "Early unexpected exit, operation never finished bootstrapping - no restart will be attempted. (Underlying Error: Test crashed with signal kill before establishing connection.)"),
        ("FixtureHost (50534) encountered an error", "Early unexpected exit, operation never finished bootstrapping - no restart will be attempted. (Underlying Error: The test runner crashed before establishing connection: FixtureHost)")
    ])
    func runnerDiagnosticNeverBecomesFakeCase(identifier: String, text: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var input = try fixtureInput()
        let diagnostic = try json("""
        {"nodeType":"Test Case","name":"\(identifier)","nodeIdentifier":"\(identifier)","result":"Failed","children":[{"nodeType":"Failure Message","name":"\(text)"}]}
        """)
        var bundle = input.tests["testNodes"].array[0].object
        bundle["children"] = .array(input.tests["testNodes"].array[0]["children"].array + [diagnostic])
        input.tests = .object(["testNodes": .array([.object(bundle)])])
        input.summary = try json("""
        {"result":"Failed","totalTestCount":2,"failedTests":1,"testFailures":[{"targetName":"Tests","testIdentifierString":"\(identifier)","failureText":"\(text)"}],"devicesAndConfigurations":[{"passedTests":1,"failedTests":1,"skippedTests":0,"expectedFailures":0}]}
        """)
        let report = Converter().convert(input, sources: try fixtureSources(root: root), exitCode: 65)
        #expect(report.rows.count == 1)
        #expect(report.rows.first?.signature == "swift/v1::Tests::Suite/pass")
        #expect(!report.summary.trustworthy)
        #expect(report.summary.errors.contains { $0.contains("runner exited") })
    }
    @Test func sourceResolutionUsesRealOwnersAndRejectsAmbiguousOverloads() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Nested/Layout/Suite.swift")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = #"""
        // struct Suite { func pass() {} }
        let string = "struct Suite { func pass() {} }"
        struct Other { func pass() {} }
        struct Suite { func pass() {} }
        """#
        try text.write(to: path, atomically: true, encoding: .utf8)
        let resolver = try SourceResolver(root: root)
        let result = resolver.resolve(signature: "swift/v1::Tests::Suite/pass", identifier: "Suite/pass()", location: nil)
        #expect(result.path == "Nested/Layout/Suite.swift")
        #expect(resolver.resolve(signature: "s", identifier: "Unknown/pass()", location: nil).path == nil)
        try "extension Suite { func pass(_ x: Int) {} }".write(to: root.appendingPathComponent("Overload.swift"), atomically: true, encoding: .utf8)
        let ambiguous = try SourceResolver(root: root)
        #expect(ambiguous.resolve(signature: "s", identifier: "Suite/pass()", location: nil).path == nil)
        #expect(ambiguous.resolve(signature: "s", identifier: "Suite/pass()", location: path.absoluteString).path == "Nested/Layout/Suite.swift")
        #expect(try SourceResolver(root: root, overrides: ["s": "../escape.swift"]).resolve(signature: "s", identifier: "Suite/pass()", location: nil).path == nil)
    }
    @Test func readerCommandsDoNotParseHumanLogsAndKeepProcessStatus() async throws {
        let process = MockProcess([ProcessResult(exitCode: 65, stderr: Data("human text with 777".utf8))])
        await #expect(throws: ReporterError.self) { try await XCResultReader(process: process).read(URL(fileURLWithPath: "/tmp/result with spaces.xcresult")) }
        let commands = await process.commands
        #expect(commands.count == 1)
        #expect(commands[0].contains("/tmp/result with spaces.xcresult"))
        #expect(commands[0].prefix(5) == ["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary"])
    }
}
