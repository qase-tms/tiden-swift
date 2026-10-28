import Foundation
import Testing
import TidenReporterCore

struct BuildShaTests {
    private static let sha = "0123456789abcdef0123456789abcdef01234567"
    private func resolve(_ env: [String: String] = [:], cli: [String: String] = [:], file: String? = nil, root: URL) throws -> Configuration {
        var environment = ["TIDEN_MODE": "tiden", "TIDEN_API_TOKEN": "test-secret", "TIDEN_PRODUCT_ID": "11111111-1111-4111-8111-111111111111", "TIDEN_ROOT_DIR": root.path]
        environment.merge(env) { $1 }
        return try Configuration.resolve(file: file.map { Data($0.utf8) }, environment: environment, cli: cli, cwd: root, defaultOutput: root.appendingPathComponent("out"))
    }
    private func head(_ text: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: Data(text.utf8)) }
    private func git(_ arguments: [String]) async throws -> ProcessResult { try await ProcessRunner().execute(["git"] + arguments, passthrough: false) }

    @Test func aSettingWinsOverTheCheckoutAndGitDoesNotRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = #"{"tiden":{"run":{"buildSha":"from-file"}}}"#
        let cases = [
            (try resolve(file: file, root: root), "from-file"),
            (try resolve(["TIDEN_BUILD_SHA": "from-env"], file: file, root: root), "from-env"),
            (try resolve(["TIDEN_BUILD_SHA": "from-env"], cli: ["build-sha": "from-flag"], file: file, root: root), "from-flag")
        ]
        for (resolved, expected) in cases {
            var config = resolved
            let process = MockProcess([head(Self.sha)])
            await config.resolveBuildSha(process: process)
            #expect(config.buildSha == expected)
            #expect(await process.commands.isEmpty)
        }
    }
    @Test func withoutASettingTheRunCarriesTheTrimmedCheckoutHead() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = try resolve(root: root)
        let process = MockProcess([head(" \(Self.sha)\n")])
        await config.resolveBuildSha(process: process)
        #expect(config.buildSha == Self.sha)
        #expect(CreateRun(config: config, now: Date()).buildSha == Self.sha)
        #expect(await process.commands == [["git", "-C", root.path, "rev-parse", "HEAD"]])
    }
    @Test(arguments: [
        ProcessResult(exitCode: 127, stderr: Data("env: git: No such file or directory\n".utf8)),
        ProcessResult(exitCode: 128, stderr: Data("fatal: not a git repository (or any of the parent directories): .git\n".utf8)),
        ProcessResult(exitCode: 128, stdout: Data("HEAD\n".utf8), stderr: Data("fatal: ambiguous argument 'HEAD'\n".utf8)),
        ProcessResult(exitCode: 0, stdout: Data("\n".utf8)),
        ProcessResult(exitCode: 0, stdout: Data("not a sha\n".utf8)),
        ProcessResult(exitCode: 143, stdout: Data("0123456789abcdef0123456789abcdef01234567\n".utf8), interrupted: true)
    ])
    func aFailedLookupLeavesTheShaOut(result: ProcessResult) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = try resolve(root: root)
        await config.resolveBuildSha(process: MockProcess([result]))
        #expect(config.buildSha == nil)
        let body = try JSONValue.decode(Wire.encode(CreateRun(config: config, now: Date())))
        #expect(body.object["buildSha"] == nil)
    }
    /// The runner cannot start git at all.
    @Test func aRunnerErrorLeavesTheShaOut() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = try resolve(root: root)
        await config.resolveBuildSha(process: MockProcess([]))
        #expect(config.buildSha == nil)
    }
    @Test func onlyARunThisReporterCreatesLooksForTheHead() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for env in [["TIDEN_MODE": "report"], ["TIDEN_MODE": "off"], ["TIDEN_RUN_ID": "42"]] {
            var config = try resolve(env, root: root)
            let process = MockProcess([head(Self.sha)])
            await config.resolveBuildSha(process: process)
            #expect(config.buildSha == nil)
            #expect(await process.commands.isEmpty)
        }
    }
    @Test func aDirectoryOutsideAnyCheckoutHasNoHead() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await BuildShaResolver.resolve(explicit: nil, directory: root, process: ProcessRunner()) == nil)
    }
    @Test func theHeadOfARealCheckoutIsFoundFromASubdirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(try await git(["init", "-q", root.path]).exitCode == 0)
        let commit = try await git(["-C", root.path, "-c", "user.name=Tiden", "-c", "user.email=tiden@example.com", "-c", "commit.gpgsign=false",
                                    "commit", "-q", "--no-verify", "--allow-empty", "-m", "init"])
        try #require(commit.exitCode == 0)
        let expected = String(decoding: try await git(["-C", root.path, "rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let tests = root.appendingPathComponent("Tests/Unit")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        let found = await BuildShaResolver.resolve(explicit: nil, directory: tests, process: ProcessRunner())
        #expect(found == expected)
        #expect(found?.count == 40 || found?.count == 64)
    }
    /// End to end: the CLI asks a `git` found on PATH, and that child never sees the API token.
    @Test func theCLIRunsGitInTheRootDirWithoutTheToken() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = package.appendingPathComponent(".build/debug/tiden-swift")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            Issue.record("Build the CLI with swift build before the Xcode validation suite")
            return
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin"), seen = root.appendingPathComponent("git-seen")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = "#!/bin/sh\nprintf '%s\\n' \"${TIDEN_API_TOKEN-unset}\" \"$@\" > '\(seen.path)'\nprintf '\(Self.sha)\\n'\n"
        try script.write(to: bin.appendingPathComponent("git"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("git").path)
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = root
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path, "TIDEN_API_TOKEN": "test-secret"]
        process.arguments = ["report", "--xcresult", root.appendingPathComponent("missing.xcresult").path, "--mode", "tiden",
                             "--base-url", "http://127.0.0.1:1", "--product-id", "11111111-1111-4111-8111-111111111111",
                             "--root-dir", root.path, "--output", root.appendingPathComponent("evidence").path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { process.waitUntilExit(); continuation.resume() }
        }
        let lines = try String(contentsOf: seen, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == ["unset", "-C", root.path, "rev-parse", "HEAD"])
    }
}
