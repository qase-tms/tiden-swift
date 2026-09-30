import Foundation
import Dispatch
import Darwin

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let interrupted: Bool
    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), interrupted: Bool = false) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr; self.interrupted = interrupted
    }
}
public protocol ProcessExecuting: Sendable {
    func execute(_ arguments: [String], passthrough: Bool) async throws -> ProcessResult
}

/// One child at a time. Both pipes are drained independently, including while waiting for termination.
public actor ProcessRunner: ProcessExecuting {
    private var child: Process?
    private var interrupted = false
    private var signalSources: [DispatchSourceSignal] = []
    public init() {}
    public func installSignalHandlers() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in Task { await self?.interrupt() } }
            source.resume(); signalSources.append(source)
        }
    }
    public func wasInterrupted() -> Bool { interrupted }
    public func interrupt() {
        interrupted = true
        guard let child, child.isRunning else { return }
        child.terminate()
        let pid = child.processIdentifier
        Task {
            try? await Task.sleep(for: .seconds(3))
            self.forceStop(pid)
        }
    }
    private func forceStop(_ pid: Int32) {
        if let child, child.processIdentifier == pid, child.isRunning { kill(pid, SIGKILL) }
    }
    public func execute(_ arguments: [String], passthrough: Bool = false) async throws -> ProcessResult {
        guard !arguments.isEmpty else { throw ReporterError("Empty process command") }
        guard child == nil else { throw ReporterError("A child process is already running") }
        if interrupted || Task.isCancelled { throw CancellationError() }
        let process = Process(), out = Pipe(), err = Pipe()
        if arguments[0].hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: arguments[0]); process.arguments = Array(arguments.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = arguments
        }
        process.standardOutput = out; process.standardError = err
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TIDEN_API_TOKEN")
        process.environment = environment
        child = process
        defer { child = nil }
        let outTask = Task.detached { await Self.drain(out.fileHandleForReading, to: passthrough ? .standardOutput : nil) }
        let errTask = Task.detached { await Self.drain(err.fileHandleForReading, to: passthrough ? .standardError : nil) }
        let status = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus)
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
                // Closing our write ends ensures EOF when the child exits.
                try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
            }
        } onCancel: { Task { await self.interrupt() } }
        return await ProcessResult(exitCode: status, stdout: outTask.value, stderr: errTask.value, interrupted: interrupted)
    }
    private static func drain(_ handle: FileHandle, to destination: FileHandle?) async -> Data {
        await withCheckedContinuation { continuation in
            // POSIX read returns available pipe bytes instead of waiting to fill a
            // Foundation buffer. A dispatch queue keeps blocking I/O off the Swift
            // cooperative executor; stdout and stderr always drain independently.
            DispatchQueue.global(qos: .utility).async {
                var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    let data = Data(buffer.prefix(count))
                    if let destination { try? destination.write(contentsOf: data) }
                    else { result.append(data) }
                }
                try? handle.close()
                continuation.resume(returning: result)
            }
        }
    }
}
