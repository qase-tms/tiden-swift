import Foundation

/// The commit a created run was built from, sent as its `buildSha`.
///
/// Order, first hit wins:
/// 1. the explicit setting (`--build-sha`, `TIDEN_BUILD_SHA`, `tiden.run.buildSha` in the config file);
/// 2. `git rev-parse HEAD` in the root directory, trimmed.
///
/// Git runs through the process runner, so the child gets the same environment as every other child: without
/// `TIDEN_API_TOKEN`. A missing git, a directory that is not a checkout, or any other failure leaves the SHA out;
/// the run never fails over it.
public enum BuildShaResolver {
    public static func resolve(explicit: String?, directory: URL, process: any ProcessExecuting) async -> String? {
        if let explicit { return explicit }
        guard let result = try? await process.execute(["git", "-C", directory.path, "rev-parse", "HEAD"], passthrough: false),
              result.exitCode == 0, !result.interrupted else { return nil }
        let sha = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sha.isEmpty, sha.allSatisfy(\.isHexDigit) else { return nil }
        return sha
    }
}
