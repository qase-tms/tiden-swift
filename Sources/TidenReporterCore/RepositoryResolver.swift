import Foundation

/// Which repository the tests belong to, as the raw remote the server normalizes
/// (`https://github.com/acme/shop`, `git@github.com:acme/shop.git`).
///
/// Order, first hit wins:
/// 1. the explicit setting (`--repository`, `TIDEN_REPOSITORY`, `repository` in the config file);
/// 2. the CI's own variables: `GITHUB_SERVER_URL` + `GITHUB_REPOSITORY`, `CI_SERVER_URL` + `CI_PROJECT_PATH`
///    (GitLab), `BITBUCKET_GIT_HTTP_ORIGIN`, `BUILD_REPOSITORY_URI` (Azure Pipelines);
/// 3. the `origin` remote in `.git/config` of the nearest ancestor directory that has a `.git`
///    (a directory, or the file a linked worktree or a submodule has).
///
/// The value is raw. The only change is removing `user:password@` from an http(s) URL: a clone made with a
/// token keeps it in `.git/config`, and it must not travel to the API. No process is spawned; the file is read.
public enum RepositoryResolver {
    public static let ciVariables = [
        "GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "CI_SERVER_URL", "CI_PROJECT_PATH",
        "BITBUCKET_GIT_HTTP_ORIGIN", "BUILD_REPOSITORY_URI"
    ]

    public static func resolve(explicit: String?, environment: [String: String], startDirectory: URL) -> String? {
        let found = clean(explicit) ?? fromCI(environment) ?? originURL(startingAt: startDirectory)
        return found.map(withoutCredentials)
    }

    private static func fromCI(_ env: [String: String]) -> String? {
        join(env["GITHUB_SERVER_URL"], env["GITHUB_REPOSITORY"])
            ?? join(env["CI_SERVER_URL"], env["CI_PROJECT_PATH"])
            ?? clean(env["BITBUCKET_GIT_HTTP_ORIGIN"])
            ?? clean(env["BUILD_REPOSITORY_URI"])
    }

    private static func join(_ server: String?, _ path: String?) -> String? {
        guard var server = clean(server), var path = clean(path) else { return nil }
        while server.hasSuffix("/") { server.removeLast() }
        while path.hasPrefix("/") { path.removeFirst() }
        return "\(server)/\(path)"
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func withoutCredentials(_ remote: String) -> String {
        remote.replacingOccurrences(of: #"^(https?://)[^/@]*@"#, with: "$1", options: [.regularExpression, .caseInsensitive])
    }

    private static func originURL(startingAt start: URL) -> String? {
        guard let gitDirectory = findGitDirectory(from: start) else { return nil }
        // A linked worktree has its own gitdir but shares the repository's config through `commondir`. A
        // submodule's gitdir (under .git/modules) has no commondir and holds its own config.
        var configDirectory = gitDirectory
        let commonDir = gitDirectory.appendingPathComponent("commondir")
        if let text = try? String(contentsOf: commonDir, encoding: .utf8), let relative = clean(text) {
            configDirectory = resolve(relative, against: gitDirectory)
        }
        guard let config = try? String(contentsOf: configDirectory.appendingPathComponent("config"), encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = isOriginHeader(line)
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
            if let url = clean(value) { return url }
        }
        return nil
    }

    /// `[remote "origin"]`, in any spacing; every other section header ends the origin section.
    private static func isOriginHeader(_ line: String) -> Bool {
        guard let close = line.firstIndex(of: "]") else { return false }
        let inner = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        guard let space = inner.firstIndex(where: \.isWhitespace) else { return false }
        let section = inner[..<space].lowercased()
        let subsection = inner[space...].trimmingCharacters(in: .whitespaces)
        return section == "remote" && subsection == "\"origin\""
    }

    private static func findGitDirectory(from start: URL) -> URL? {
        var directory = start.resolvingSymlinksInPath().standardizedFileURL
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dotGit }
                // A worktree or a submodule: `.git` is a file holding `gitdir: <path>`.
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                      let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }),
                      let path = clean(String(line.dropFirst("gitdir:".count))) else { return nil }
                return resolve(path, against: directory)
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    private static func resolve(_ path: String, against base: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL
    }
}
