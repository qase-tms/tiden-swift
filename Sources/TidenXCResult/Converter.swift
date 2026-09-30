import Foundation
import TidenReporterCore

public struct ExecutionContext: Codable, Sendable, Equatable {
    public var module: String
    public var declaration: String
    public var arguments: [String] = []
    public var deviceID: String?
    public var deviceName: String?
    public var configurationID: String?
    public var configurationName: String?
    public var repetition: Int?
    public var startTime: Double?
    public var endTime: Double?
}
public struct ConvertedReport: Sendable {
    public var rows: [ResultCreate]
    public var contexts: [ExecutionContext]
    public var summary: ReportSummary
    public init(rows: [ResultCreate], contexts: [ExecutionContext], summary: ReportSummary) { self.rows = rows; self.contexts = contexts; self.summary = summary }
}
public struct Converter: Sendable {
    private let uuid: @Sendable () -> UUID
    public init(uuid: @escaping @Sendable () -> UUID = { UUID() }) { self.uuid = uuid }
    private static let executionKinds: Set<String> = ["Test Case Run", "Arguments", "Repetition", "Device", "Test Plan Configuration"]
    private struct Candidate { var node: JSONValue; var context: ExecutionContext; var params: [String: String] }
    public func convert(_ input: XCResultInput, sources: SourceResolver, rootSuite: String? = nil, exitCode: Int32 = 0,
                        cancelled: Bool = false) -> ConvertedReport {
        var summary = ReportSummary(); summary.exitCode = exitCode; summary.cancelled = cancelled
        summary.errors += input.diagnostics
        var rows: [ResultCreate] = [], contexts: [ExecutionContext] = [], infrastructure = 0
        let definitions = TestTree.definitions(input.tests)
        summary.definitionCount = definitions.count
        var keys: Set<String> = []
        for test in definitions {
            if !keys.insert(test.key).inserted { summary.errors.append("Duplicate definition \(test.key)"); continue }
            if isRunnerDiagnostic(test, summary: input.summary) {
                infrastructure += 1; summary.errors.append("Xcode test runner exited before finishing: \(test.identifier)"); continue
            }
            do {
                let signature = try Identity.signature(module: test.module, identifier: test.identifier)
                let declaration = try Identity.declaration(test.identifier)
                guard let details = input.details[test.key] else { throw ReporterError("Missing test-details for \(test.key)") }
                if let identifier = details["testIdentifier"].string,
                   try Identity.declaration(identifier) != declaration { throw ReporterError("test-details identifier mismatch") }
                let base = context(module: test.module, declaration: declaration, details: details)
                var candidates: [Candidate] = []
                func walk(_ node: JSONValue, context: ExecutionContext, params: [String: String]) throws {
                    var context = context, params = params
                    let kind = node["nodeType"].string ?? ""
                    let name = node["name"].string ?? ""
                    if kind == "Device" {
                        let id = node["nodeIdentifier"].string
                        let exact = details["devices"].array.filter { id != nil && $0["deviceId"].string == id }
                        let devices = exact.isEmpty ? details["devices"].array.filter {
                            $0["deviceName"].string == name || $0["deviceId"].string == name || $0["modelName"].string == name
                        } : exact
                        guard devices.count == 1 else { throw ReporterError("Cannot resolve device wrapper \(name)") }
                        context.deviceID = devices[0]["deviceId"].string; context.deviceName = devices[0]["deviceName"].string
                    }
                    if kind == "Test Plan Configuration" {
                        let id = node["nodeIdentifier"].string
                        let exact = details["testPlanConfigurations"].array.filter { id != nil && $0["configurationId"].string == id }
                        let configs = exact.isEmpty ? details["testPlanConfigurations"].array.filter { $0["configurationName"].string == name || $0["configurationId"].string == name } : exact
                        guard configs.count == 1 else { throw ReporterError("Cannot resolve configuration wrapper \(name)") }
                        context.configurationID = configs[0]["configurationId"].string; context.configurationName = configs[0]["configurationName"].string
                    }
                    if kind == "Repetition" {
                        let numbers = name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                        guard numbers.count == 1 else { throw ReporterError("Cannot resolve repetition number \(name)") }
                        context.repetition = numbers[0]
                    }
                    if kind == "Arguments", node["result"].string != nil {
                        let values = parameterValues(node)
                        guard !values.isEmpty else { throw ReporterError("Parameterized execution lacks named Test Value inputs: \(test.key)") }
                        params = values
                        context.arguments = parameterArguments(node)
                    }
                    let children = node["children"].array.filter { child in
                        Self.executionKinds.contains(child["nodeType"].string ?? "") &&
                        !(node["durationInSeconds"].number != nil && isAssertionDiagnostic(child, outcome: node["result"].string)) &&
                        (child["result"].string != nil || containsExecution(child))
                    }
                    if !children.isEmpty {
                        for child in children { try walk(child, context: context, params: params) }
                    } else {
                        let duration = node["durationInSeconds"].number
                        if node["result"].string != nil || kind == "Test Case Run" || duration != nil {
                            candidates.append(Candidate(node: node, context: context, params: params))
                        } else { throw ReporterError("Incomplete execution wrapper for \(test.key)") }
                    }
                }
                let testRuns = details["testRuns"].array
                if testRuns.isEmpty {
                    // Skipped declarations may have no run tree; use only their explicit terminal outcome.
                    if test.node["result"].string == "Skipped" { candidates = [Candidate(node: test.node, context: base, params: [:])] }
                    else { throw ReporterError("No actual executions in test-details for \(test.key)") }
                } else { for node in testRuns { try walk(node, context: base, params: [:]) } }
                enrichTimes(&candidates, activities: input.activities[test.key], details: details)
                candidates = candidates.enumerated().sorted { left, right in
                    if let a = left.element.context.startTime, let b = right.element.context.startTime, a != b { return a < b }
                    if let a = left.element.context.repetition, let b = right.element.context.repetition, a != b { return a < b }
                    return left.offset < right.offset
                }.map(\.element)
                let location = test.node["sourceLocation"]["filePath"].string ?? firstLocation(test.node)
                let source = sources.resolve(signature: signature, identifier: test.identifier, location: location)
                if let diagnostic = source.diagnostic { summary.diagnostics.append(diagnostic) }
                for (attempt, candidate) in candidates.enumerated() {
                    do {
                        let outcome = candidate.node["result"].string ?? "unknown"
                        let status: String
                        switch outcome {
                        case "Passed", "Expected Failure": status = "passed"
                        case "Failed": status = "failed"
                        case "Skipped": status = "skipped"
                        default: throw ReporterError("Unknown/incomplete outcome \(outcome): \(test.key)")
                        }
                        let seconds = candidate.node["durationInSeconds"].number ?? (status == "skipped" ? 0 : nil)
                        guard let seconds, seconds.isFinite, seconds >= 0, seconds * 1000 < Double(Int64.max) else { throw ReporterError("Invalid/missing execution duration: \(test.key)") }
                        var params = candidate.params
                        for reserved in ["tiden.xcode.device", "tiden.xcode.configuration"] {
                            if params[reserved] != nil { throw ReporterError("Test parameter collides with reserved \(reserved)") }
                        }
                        if let id = candidate.context.deviceID { params["tiden.xcode.device"] = id }
                        if let id = candidate.context.configurationID { params["tiden.xcode.configuration"] = id }
                        if details["devices"].array.count > 1 && candidate.context.deviceID == nil { throw ReporterError("Multi-destination execution lacks device context") }
                        if details["testPlanConfigurations"].array.count > 1 && candidate.context.configurationID == nil { throw ReporterError("Multi-configuration execution lacks context") }
                        var fields = ["xcode_result": outcome, "xcode_attempt": String(attempt + 1)]
                        if let path = source.path { fields["file_path"] = path }
                        var row = ResultCreate(id: uuid().uuidString.lowercased(), title: test.node["name"].string ?? declaration, signature: signature,
                                               execution: ResultExecution(status: status, durationMilliseconds: Int64((seconds * 1000).rounded()), startTime: candidate.context.startTime),
                                               suitePath: ([rootSuite].compactMap { $0 } + [test.module] + test.suites).map(SuiteSegment.init), fields: fields, params: params)
                        let messages = failureMessages(candidate.node)
                        if !messages.isEmpty { row.message = messages.joined(separator: "\n") }
                        if let end = candidate.context.endTime { row.execution.endTime = end }
                        let context = candidate.context
                        rows.append(row); contexts.append(context)
                    } catch { summary.errors.append(String(describing: error)) }
                }
            } catch { summary.errors.append(String(describing: error)) }
        }
        summary.executionCount = rows.count
        if summary.definitionCount != input.summary["totalTestCount"].integer { summary.errors.append("Definition count \(summary.definitionCount) disagrees with summary totalTestCount") }
        let configs = input.summary["devicesAndConfigurations"].array
        if !configs.isEmpty {
            var expected = 0
            for config in configs {
                for key in ["passedTests", "failedTests", "skippedTests", "expectedFailures"] {
                    guard let count = config[key].integer, count >= 0 else { summary.errors.append("Invalid summary execution count \(key)"); continue }
                    expected += count
                }
            }
            if expected != rows.count + infrastructure { summary.errors.append("Execution count \(rows.count) plus \(infrastructure) runner diagnostics disagrees with summary \(expected)") }
        } else { summary.errors.append("Missing devicesAndConfigurations execution counts") }
        if rows.isEmpty || rows.allSatisfy({ $0.execution.status == "skipped" }) { summary.errors.append("No executed tests; refusing empty or all-skipped completion") }
        if !rows.contains(where: { $0.fields["file_path"] != nil }) { summary.errors.append("No source file anchors resolved; refusing completion") }
        let hasFailure = rows.contains { $0.execution.status == "failed" }
        if !["Passed", "Failed", "Expected Failure"].contains(input.summary["result"].string ?? "") { summary.errors.append("Unknown/incomplete summary outcome") }
        if (input.summary["failedTests"].integer ?? -1 > 0) != hasFailure, infrastructure == 0 { summary.errors.append("Summary failedTests disagrees with actual outcomes") }
        if exitCode != 0 && !hasFailure { summary.errors.append("Xcode exited \(exitCode) without a failed assertion; infrastructure failure") }
        if input.summary["result"].string == "Failed" && !hasFailure { summary.errors.append("Failed summary without actual failed tests") }
        if cancelled { summary.errors.append("Cancelled run; refusing completion") }
        return ConvertedReport(rows: rows, contexts: contexts, summary: summary)
    }
    private func containsExecution(_ node: JSONValue) -> Bool {
        node["children"].array.contains { Self.executionKinds.contains($0["nodeType"].string ?? "") && ($0["result"].string != nil || containsExecution($0)) }
    }
    private func parameterValues(_ node: JSONValue) -> [String: String] {
        var values: [String: String] = [:]
        for (name, value) in parameterInputs(node) { values[name] = value }
        return values
    }
    private func parameterArguments(_ node: JSONValue) -> [String] {
        parameterInputs(node).map { $0.1 }
    }
    private func parameterInputs(_ node: JSONValue) -> [(String, String)] {
        var values: [(String, String)] = []
        func visit(_ current: JSONValue) {
            if current["nodeType"].string == "Test Value", let name = current["name"].string, let split = name.range(of: " : ") {
                values.append((String(name[..<split.lowerBound]), String(name[split.upperBound...]))); return
            }
            // Only input wrappers belong to the argument list. Assertion Expression
            // values and timed child executions describe something else entirely.
            if current["nodeType"].string == "Arguments", current["result"] == .null, current["durationInSeconds"] == .null {
                for child in current["children"].array { visit(child) }
            }
        }
        for child in node["children"].array { visit(child) }
        return values
    }
    private func context(module: String, declaration: String, details: JSONValue) -> ExecutionContext {
        var value = ExecutionContext(module: module, declaration: declaration)
        if details["devices"].array.count == 1 { value.deviceID = details["devices"].array[0]["deviceId"].string; value.deviceName = details["devices"].array[0]["deviceName"].string }
        if details["testPlanConfigurations"].array.count == 1 { value.configurationID = details["testPlanConfigurations"].array[0]["configurationId"].string; value.configurationName = details["testPlanConfigurations"].array[0]["configurationName"].string }
        return value
    }
    private func firstLocation(_ node: JSONValue) -> String? {
        if let file = node["sourceLocation"]["filePath"].string { return file }
        for child in node["children"].array { if let file = firstLocation(child) { return file } }
        return nil
    }
    private func failureMessages(_ node: JSONValue) -> [String] {
        var result: [String] = []
        if ["Failure Message", "Expected Failure", "Skip Message"].contains(node["nodeType"].string ?? "") ||
            isAssertionDiagnostic(node, outcome: node["result"].string), let message = node["name"].string {
            result.append(message)
        }
        for child in node["children"].array { result += failureMessages(child) }
        return result
    }
    // Xcode 27 places assertion/skip text in untimed Test Case Run children of the
    // timed configuration or argument execution. These are diagnostics, not retries.
    private func isAssertionDiagnostic(_ node: JSONValue, outcome: String?) -> Bool {
        node["nodeType"].string == "Test Case Run" && node["durationInSeconds"] == .null &&
        node["nodeIdentifier"] == .null && node["nodeIdentifierURL"] == .null &&
        ["Failed", "Expected Failure", "Skipped"].contains(outcome ?? "") &&
        node["result"].string == outcome && node["name"].string != nil &&
        node["children"].array.allSatisfy { child in
            if child["nodeType"].string == "Expression" {
                return child["children"].array.allSatisfy(isDiagnosticValue)
            }
            return ["Source Code Reference", "Failure Message", "Expected Failure", "Skip Message"].contains(child["nodeType"].string ?? "")
        }
    }
    private func isDiagnosticValue(_ node: JSONValue) -> Bool {
        node["nodeType"].string == "Test Value" && node["result"] == .null && node["durationInSeconds"] == .null &&
        node["nodeIdentifier"] == .null && node["nodeIdentifierURL"] == .null &&
        node["children"].array.allSatisfy(isDiagnosticValue)
    }
    private func isRunnerDiagnostic(_ test: TestDefinition, summary: JSONValue) -> Bool {
        guard test.node["nodeIdentifierURL"] == .null, test.node["sourceLocation"] == .null,
              test.identifier.range(of: #"^[A-Za-z0-9_.-]+ \([0-9]+\) encountered an error$"#, options: .regularExpression) != nil,
              test.node["result"].string == "Failed", test.node["children"].array.count == 1,
              test.node["children"].array[0]["nodeType"].string == "Failure Message",
              let text = test.node["children"].array[0]["name"].string else { return false }
        let exited = text.hasPrefix("The test runner exited with code ") && text.contains(" before finishing running tests.")
        let bootstrap = text.hasPrefix("Early unexpected exit, operation never finished bootstrapping - no restart will be attempted.") &&
            (text.contains("before establishing connection.") || text.contains("The test runner crashed before establishing connection: "))
        guard (exited && test.identifier.hasPrefix(test.module + "-Runner (")) || bootstrap else { return false }
        return summary["testFailures"].array.contains {
            $0["targetName"].string == test.module && $0["testIdentifierString"].string == test.identifier && $0["failureText"].string == text && $0["testIdentifierURL"] == .null && $0["sourceLocation"] == .null
        }
    }
    private func enrichTimes(_ candidates: inout [Candidate], activities: JSONValue?, details: JSONValue) {
        let testRuns = activities?["testRuns"] ?? .null
        let runs = testRuns.array.isEmpty ? (testRuns.object.isEmpty ? [] : [testRuns]) : testRuns.array
        for i in candidates.indices {
            let candidate = candidates[i]
            let matches = runs.filter { run in
                (candidate.context.deviceID == nil || run["device"]["deviceId"].string == candidate.context.deviceID) &&
                (candidate.context.configurationID == nil || run["testPlanConfiguration"]["configurationId"].string == candidate.context.configurationID) &&
                (candidate.context.arguments.isEmpty || run["arguments"].array.compactMap { $0["value"].string } == candidate.context.arguments)
            }
            if matches.count == 1,
               candidates.filter({ $0.context.deviceID == candidate.context.deviceID && $0.context.configurationID == candidate.context.configurationID && $0.context.arguments == candidate.context.arguments }).count == 1 {
                // Activity timestamps describe events within a test, not its start.
                // Only explicit run timestamps may become wire execution timestamps.
                candidates[i].context.startTime = matches[0]["startTime"].number.flatMap { $0.isFinite ? $0 : nil }
                candidates[i].context.endTime = matches[0]["endTime"].number.flatMap { $0.isFinite ? $0 : nil }
            } else if candidates.count == 1 {
                candidates[i].context.startTime = details["startTime"].number.flatMap { $0.isFinite ? $0 : nil }
                candidates[i].context.endTime = details["endTime"].number.flatMap { $0.isFinite ? $0 : nil }
            }
            if let start = candidates[i].context.startTime, let end = candidates[i].context.endTime, end < start {
                candidates[i].context.startTime = nil; candidates[i].context.endTime = nil
            }
        }
    }
}
