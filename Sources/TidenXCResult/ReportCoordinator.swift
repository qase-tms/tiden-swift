import Foundation
import TidenReporterCore

/// Persists evidence before network writes and owns only the terminal action explicitly assigned to it.
public actor ReportCoordinator {
    private let config: Configuration
    private let reader: XCResultReader
    private let api: APIClient?
    private let isCancelled: @Sendable () async -> Bool
    private var run: RunHandle?
    public init(config: Configuration, reader: XCResultReader, api: APIClient? = nil, isCancelled: @escaping @Sendable () async -> Bool = { false }) {
        self.config = config; self.reader = reader; self.api = api
        self.isCancelled = isCancelled
    }
    public func begin() async throws {
        guard config.mode == .tiden, let api else { return }
        run = try await api.begin()
        try persist(run, name: "run.json")
    }
    public func abort() async throws {
        guard let run, let api else { return }
        try await api.finish(run, trustworthy: false)
    }
    private func persist<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: config.output, withIntermediateDirectories: true)
        try Wire.encode(value).write(to: config.output.appendingPathComponent(name), options: .atomic)
    }
    public func report(bundle: URL, exitCode: Int32, cancelled: Bool) async throws -> ReportSummary {
        if config.mode == .off {
            var summary = ReportSummary(); summary.exitCode = exitCode; summary.cancelled = cancelled
            return summary
        }
        var converted: ConvertedReport
        do {
            let input = try await reader.read(bundle)
            try persist(input.summary, name: "xcode-summary.json")
            try persist(input.tests, name: "xcode-tests.json")
            try persist(input.details, name: "xcode-details.json")
            try persist(input.activities, name: "xcode-activities.json")
            let sources = try SourceResolver(root: config.rootDir, overrides: config.sourceMap)
            converted = Converter().convert(input, sources: sources, rootSuite: config.rootSuite, exitCode: exitCode, cancelled: cancelled)
        } catch {
            var summary = ReportSummary(); summary.exitCode = exitCode; summary.cancelled = cancelled
            summary.errors = [config.redact(String(describing: error))]
            try persist(summary, name: "summary.json")
            try await abort()
            return summary
        }
        // The bare array is immediately available even when attachment association or upload later fails.
        try persist(converted.rows, name: "results.json")
        try persist(converted.contexts, name: "execution-contexts.json")
        if config.uploadAttachments {
            do {
                let export = config.output.appendingPathComponent("attachments", isDirectory: true)
                let manifest = try await reader.exportAttachments(bundle, output: export)
                let resolution = AttachmentMatcher.resolve(manifest: manifest, root: export, contexts: converted.contexts)
                converted.summary.diagnostics += resolution.diagnostics
                converted.summary.errors += resolution.errors
                try persist(resolution.matches, name: "attachment-associations.json")
                if config.mode == .tiden, let api {
                    for attachment in resolution.matches where !attachment.skippedForSize {
                        do {
                            let hash = try await api.upload(file: attachment.file, name: attachment.name, mime: attachment.mime)
                            converted.rows[attachment.rowIndex].attachments.append(hash)
                            try persist(converted.rows, name: "results.json")
                        } catch {
                            converted.summary.errors.append(config.redact(String(describing: error)))
                            break
                        }
                    }
                }
            } catch { converted.summary.errors.append(config.redact(String(describing: error))) }
        }
        if config.mode == .tiden, let api, let run {
            do {
                let batches = try APIClient.batches(converted.rows, size: config.batchSize)
                for (index, batch) in batches.enumerated() { try batch.write(to: config.output.appendingPathComponent("batch-\(index + 1).json"), options: .atomic) }
                try await api.report(batches, run: run)
            } catch { converted.summary.errors.append(config.redact(String(describing: error))) }
            if await isCancelled() {
                converted.summary.cancelled = true
                converted.summary.errors.append("Cancelled during reporting; refusing completion")
            }
            do { try await api.finish(run, trustworthy: converted.summary.trustworthy) }
            catch { converted.summary.errors.append(config.redact("Run finalization failed: \(error)")) }
        }
        try persist(converted.summary, name: "summary.json")
        return converted.summary
    }
}
