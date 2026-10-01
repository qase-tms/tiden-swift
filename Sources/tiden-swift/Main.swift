import Foundation
import Darwin
import TidenReporterCore
import TidenXCResult

@main struct TidenSwift {
    static let help = """
    tiden-swift — report Xcode Swift Testing and XCTest results to Tiden

    tiden-swift report --xcresult PATH --root-dir ROOT [options]
    tiden-swift run --root-dir ROOT [options] -- xcodebuild test ...

    Options (CLI > environment > tiden.config.json > defaults):
      --mode off|report|tiden        Default: off
      --output DIR                  Fresh evidence directory (default: artifacts/<UUID>)
      --config FILE                 Config file (default: ./tiden.config.json)
      --exit-code N                 Importer's original xcodebuild status
      --product-id UUID --token TOKEN --base-url URL
      --run-id N --complete true|false --run-title TITLE --run-description TEXT
      --branch NAME --build-sha SHA --environment NAME --root-suite TITLE
      --batch-size 1..2000           Default: 200; requests capped at 8 MiB
      --upload-attachments true|false  Default: true
      --fallback off|report          Persist local evidence on API failure; exit stays nonzero

    run accepts test or test-without-building and supplies its own -resultBundlePath.
    Secrets can be supplied with TIDEN_API_TOKEN; see README for the config contract.
    Exit: 0 successful reporting; 1 test failures on import; 2 reporting/infrastructure
    error. Wrapper preserves nonzero xcodebuild status; otherwise reporting errors use 2.
    """
    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--help") || CommandLine.arguments.dropFirst().contains("-h") {
            print(help); return
        }
        var status: Int32 = 2
        var coordinator: ReportCoordinator?
        var config: Configuration?
        do {
            let invocation = try Invocation.parse(Array(CommandLine.arguments.dropFirst()))
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let configFile = URL(fileURLWithPath: invocation.options["config"] ?? "tiden.config.json", relativeTo: cwd)
            let file = FileManager.default.fileExists(atPath: configFile.path) ? try Data(contentsOf: configFile) : nil
            if invocation.options["config"] != nil, file == nil { throw ReporterError("Explicit config file does not exist") }
            let resolved = try Configuration.resolve(file: file, environment: ProcessInfo.processInfo.environment, cli: invocation.options,
                                                     cwd: cwd, defaultOutput: cwd.appendingPathComponent("artifacts/\(UUID().uuidString)"))
            config = resolved
            guard !FileManager.default.fileExists(atPath: resolved.output.path) else { throw ReporterError("Output directory already exists; use a fresh --output directory to preserve evidence") }
            try FileManager.default.createDirectory(at: resolved.output, withIntermediateDirectories: true)
            let process = ProcessRunner()
            await process.installSignalHandlers()
            let api = resolved.mode == .tiden ? APIClient(config: resolved) : nil
            let extraction = ProcessRunner()
            var session = ReportCoordinator(config: resolved, reader: XCResultReader(process: extraction), api: api, isCancelled: { await process.wasInterrupted() })
            coordinator = session
            var fallbackFailure: String?
            do { try await session.begin() }
            catch {
                guard resolved.fallbackToReport else { throw error }
                fallbackFailure = resolved.redact("API begin failed: \(error)")
                writeError(fallbackFailure!)
                var local = resolved
                local.mode = .report
                session = ReportCoordinator(config: local, reader: XCResultReader(process: extraction))
                coordinator = session
            }
            let bundle: URL
            var childStatus = Int32(invocation.options["exit-code"] ?? "0") ?? 0
            if invocation.command == "run" {
                bundle = resolved.output.appendingPathComponent("Tests.xcresult")
                let result = try await process.execute(invocation.child + ["-resultBundlePath", bundle.path], passthrough: true)
                childStatus = result.exitCode
                status = childStatus == 0 ? 2 : childStatus
            } else { bundle = URL(fileURLWithPath: invocation.options["xcresult"]!, relativeTo: cwd) }
            let interrupted = await process.wasInterrupted()
            // Use a new reader after interruption: cancelled xcodebuild cannot prevent evidence extraction/abort.
            var summary = try await session.report(bundle: bundle, exitCode: childStatus, cancelled: interrupted)
            if let fallbackFailure {
                summary.errors.append(fallbackFailure)
                try Wire.encode(summary).write(to: resolved.output.appendingPathComponent("summary.json"), options: .atomic)
            }
            for message in summary.diagnostics { writeError("warning: \(resolved.redact(message))") }
            for message in summary.errors { writeError(resolved.redact(message)) }
            print("\(summary.executionCount) executions; evidence: \(resolved.output.path)")
            if invocation.command == "run", childStatus != 0 { status = childStatus }
            else if !summary.trustworthy { status = 2 }
            else if invocation.command == "report", childStatus != 0 { status = childStatus }
            else if invocation.command == "report", resolved.mode != .off {
                let rows = try JSONDecoder().decode([ResultCreate].self, from: Data(contentsOf: resolved.output.appendingPathComponent("results.json")))
                status = rows.contains { $0.execution.status == "failed" } ? 1 : 0
            } else { status = 0 }
        } catch {
            writeError(config?.redact(String(describing: error)) ?? String(describing: error))
            if let coordinator {
                do { try await coordinator.abort() }
                catch { writeError(config?.redact("Run abort failed: \(error)") ?? "Run abort failed") }
            }
        }
        exit(status)
    }
    static func writeError(_ message: String) { try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8)) }
}
