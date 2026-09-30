import Foundation
import Testing
import TidenReporterCore

struct ProcessAndCLITests {
    @Test func wrapperPassThroughEmitsShortLineBeforeChildTerminates() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = package.appendingPathComponent(".build/debug/tiden-swift")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            Issue.record("Build the CLI with swift build before the Xcode validation suite")
            return
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("xcodebuild"), release = root.appendingPathComponent("release")
        try "#!/bin/sh\nprintf 'short line\\n'\nwhile [ ! -f '\(release.path)' ]; do sleep 0.05; done\n".write(to: child, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)
        let log = root.appendingPathComponent("stdout.log")
        #expect(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", "--config", package.appendingPathComponent("Tests/TidenReporterTests/Fixtures/local-config.json").path, "--mode", "off", "--output", root.appendingPathComponent("output").path, "--", child.path, "test"]
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        var streamed = false
        for _ in 0..<200 {
            if String(decoding: try Data(contentsOf: log), as: UTF8.self).contains("short line\n") { streamed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(process.isRunning)
        // Release even on assertion failure, so the regression never leaves a child.
        try Data().write(to: release)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); continuation.resume() }
        }
        #expect(streamed)
        #expect(process.terminationStatus == 0)
    }
    @Test func drainsBothPipesAndPreservesChildFailure() async throws {
        let result = try await ProcessRunner().execute(["/bin/sh", "-c", "i=0; while [ $i -lt 3000 ]; do printf 'stdout-line\\n'; printf 'stderr-line\\n' >&2; i=$((i + 1)); done; exit 65"], passthrough: false)
        #expect(result.exitCode == 65)
        #expect(String(decoding: result.stdout, as: UTF8.self).components(separatedBy: "stdout-line").count == 3001)
        #expect(String(decoding: result.stderr, as: UTF8.self).components(separatedBy: "stderr-line").count == 3001)
    }
    @Test func interruptionTerminatesRunningChildAndKeepsCapturedOutput() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let runner = ProcessRunner()
        let task = Task { try await runner.execute(["/bin/sh", "-c", "printf started; touch \"$1\"; while :; do :; done", "fixture", ready.path], passthrough: false) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = FileManager.default.fileExists(atPath: ready.path)
        await runner.interrupt()
        let result = try await task.value
        #expect(started)
        #expect(result.interrupted)
        #expect(result.exitCode != 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "started")
        await #expect(throws: CancellationError.self) { try await runner.execute(["/usr/bin/true"], passthrough: false) }
    }
    @Test func wrapperFallbackRunsChildAndPreservesFailureAndLocalSummary() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = package.appendingPathComponent(".build/debug/tiden-swift")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            Issue.record("Build the CLI with swift build before the Xcode validation suite")
            return
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("xcodebuild")
        let marker = root.appendingPathComponent("child-ran")
        // No fake result bundle: the absent bundle is a deliberate extraction failure.
        let script = "#!/bin/sh\nprintf ran > '\(marker.path)'\nexit 65\n"
        try script.write(to: child, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)
        let output = root.appendingPathComponent("evidence")
        let result = try await ProcessRunner().execute([
            executable.path, "run", "--config", package.appendingPathComponent("Tests/TidenReporterTests/Fixtures/local-config.json").path,
            "--mode", "tiden", "--fallback", "report", "--base-url", "http://127.0.0.1:1", "--token", "test-secret",
            "--product-id", "11111111-1111-4111-8111-111111111111", "--root-dir", root.path, "--output", output.path,
            "--", child.path, "test"
        ], passthrough: false)
        #expect(result.exitCode == 65)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let summary = try JSONValue.decode(Data(contentsOf: output.appendingPathComponent("summary.json")))
        #expect(summary["exitCode"].integer == 65)
        #expect(summary["errors"].array.contains { $0.string?.contains("API begin failed") == true })
        #expect(!String(decoding: result.stderr, as: UTF8.self).contains("test-secret"))
    }
}
