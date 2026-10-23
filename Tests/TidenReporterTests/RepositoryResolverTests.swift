import Foundation
import Testing
import TidenReporterCore

struct RepositoryResolverTests {
    private func directory() throws -> URL { try temporaryDirectory().resolvingSymlinksInPath() }
    private func checkout(_ root: URL, origin: String, other: String? = nil) throws {
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        var config = "[core]\n\trepositoryformatversion = 0\n"
        if let other { config += "[remote \"fork\"]\n\turl = \(other)\n" }
        config += "[remote \"origin\"]\n\turl = \(origin)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n[branch \"main\"]\n\tremote = origin\n"
        try config.write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }
    private func resolve(explicit: String? = nil, environment: [String: String] = [:], in directory: URL) -> String? {
        RepositoryResolver.resolve(explicit: explicit, environment: environment, startDirectory: directory)
    }

    @Test(arguments: [
        (["GITHUB_SERVER_URL": "https://github.com", "GITHUB_REPOSITORY": "acme/shop"], "https://github.com/acme/shop"),
        (["GITHUB_SERVER_URL": "https://git.acme.dev/", "GITHUB_REPOSITORY": "acme/shop"], "https://git.acme.dev/acme/shop"),
        (["CI_SERVER_URL": "https://gitlab.com", "CI_PROJECT_PATH": "acme/team/shop"], "https://gitlab.com/acme/team/shop"),
        (["BITBUCKET_GIT_HTTP_ORIGIN": "http://bitbucket.org/acme/shop"], "http://bitbucket.org/acme/shop"),
        (["BUILD_REPOSITORY_URI": "https://dev.azure.com/acme/proj/_git/shop"], "https://dev.azure.com/acme/proj/_git/shop")
    ] as [([String: String], String)])
    func eachCIProviderIsRead(environment: [String: String], expected: String) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(resolve(environment: environment, in: root) == expected)
    }
    @Test func halfACIPairIsNotEnough() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(resolve(environment: ["GITHUB_SERVER_URL": "https://github.com"], in: root) == nil)
        #expect(resolve(environment: ["CI_PROJECT_PATH": "acme/shop"], in: root) == nil)
    }
    @Test func explicitBeatsCIAndCIBeatsTheCheckout() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try checkout(root, origin: "git@github.com:from/config.git")
        let ci = ["GITHUB_SERVER_URL": "https://github.com", "GITHUB_REPOSITORY": "from/ci"]
        #expect(resolve(explicit: "https://github.com/explicit/repo", environment: ci, in: root) == "https://github.com/explicit/repo")
        #expect(resolve(environment: ci, in: root) == "https://github.com/from/ci")
        #expect(resolve(in: root) == "git@github.com:from/config.git")
    }
    @Test func originIsReadFromTheNearestAncestorAndOnlyOriginCounts() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try checkout(root, origin: "git@github.com:acme/shop.git", other: "https://example.com/fork/shop.git")
        let deep = root.appendingPathComponent("Tests/Unit")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        #expect(resolve(in: deep) == "git@github.com:acme/shop.git")
    }
    @Test func aCheckoutWithoutOriginHasNoRepository() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "[core]\n\tbare = false\n[remote \"upstream\"]\n\turl = https://example.com/a/b\n".write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        #expect(resolve(in: root) == nil)
    }
    /// A linked worktree: `.git` is a file, and the config lives in the main repository.
    @Test func aWorktreeGitFileIsFollowedToTheSharedConfig() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        try checkout(main, origin: "https://github.com/acme/shop.git")
        let worktreeGit = main.appendingPathComponent(".git/worktrees/feature")
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try "../..\n".write(to: worktreeGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let feature = root.appendingPathComponent("feature/src")
        try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGit.path)\n".write(to: root.appendingPathComponent("feature/.git"), atomically: true, encoding: .utf8)
        #expect(resolve(in: feature) == "https://github.com/acme/shop.git")
    }
    @Test func aRelativeGitdirIsResolvedAgainstTheDirectoryHoldingTheFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        try checkout(main, origin: "https://github.com/acme/shop.git")
        let worktreeGit = main.appendingPathComponent(".git/worktrees/wt")
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try "../..\n".write(to: worktreeGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        let wt = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: ../main/.git/worktrees/wt\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(resolve(in: wt) == "https://github.com/acme/shop.git")
    }
    /// A submodule's gitdir has no commondir: its own config is the one.
    @Test func aSubmoduleGitFileIsFollowedToItsOwnConfig() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modules = root.appendingPathComponent("super/.git/modules/lib")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = git@github.com:acme/lib.git\n".write(to: modules.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let lib = root.appendingPathComponent("super/lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/lib\n".write(to: lib.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(resolve(in: lib) == "git@github.com:acme/lib.git")
    }
    @Test func noSourceMeansNoRepository() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(resolve(in: root) == nil)
        #expect(resolve(explicit: "  ", environment: ["GITHUB_REPOSITORY": " "], in: root) == nil)
    }
    /// A clone made with a token keeps it in `.git/config`; it must not reach the API.
    @Test(arguments: [
        ("https://ghs_secret@github.com/acme/shop.git", "https://github.com/acme/shop.git"),
        ("https://x-access-token:ghs_secret@github.com/acme/shop", "https://github.com/acme/shop"),
        ("git@github.com:acme/shop.git", "git@github.com:acme/shop.git"),
        ("ssh://git@github.com/acme/shop.git", "ssh://git@github.com/acme/shop.git")
    ])
    func credentialsInAURLAreNotSent(raw: String, expected: String) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try checkout(root, origin: raw)
        #expect(resolve(in: root) == expected)
        #expect(resolve(explicit: raw, in: root) == expected)
    }
}
