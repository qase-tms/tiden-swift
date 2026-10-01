# tiden-swift

Native Swift reporter for Xcode Swift Testing and XCTest results, including XCTest UI tests and attachments. The `tiden-swift` command imports an existing `.xcresult` bundle or wraps `xcodebuild test` / `test-without-building`, then writes local evidence or reports it to Tiden's public Test Runs API.

The package has no third-party dependencies, Python bridge, or Tiden CLI runtime dependency. The executable and its libraries run on a Mac: Xcode's `xcresulttool` reads results produced by macOS and iOS test targets. They are not linked into the app under test. Xcode 27 and Swift 6.4 are the development toolchain; the reporter's deployment target is macOS 13. Native test validation uses `.xcresult`, so test reporting does not depend on parsing console logs.

## Build and install from source

Select the intended Xcode installation before building. `xcode-select -p`, `xcodebuild -version`, and `swift --version` identify the active toolchain.

```sh
git clone https://github.com/qase-tms/tiden-swift.git
cd tiden-swift
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/tiden-swift "$HOME/.local/bin/tiden-swift"
export PATH="$HOME/.local/bin:$PATH"
tiden-swift --help
```

You can use `.build/release/tiden-swift` directly. There is no package-registry or Homebrew installation step documented here. The SwiftPM products are the `tiden-swift` executable, `TidenReporterCore`, and `TidenXCResult` libraries.

## Quick start

Upload an existing result bundle:

```sh
export TIDEN_MODE=tiden
export TIDEN_API_TOKEN='your-api-token'
export TIDEN_PRODUCT_ID='your-product-uuid'
tiden-swift report --xcresult artifacts/Tests.xcresult --root-dir "$PWD"
```

`--root-dir` is the repository root containing the test sources. Supply the original `xcodebuild` status with `--exit-code` if the bundle came from a failed or interrupted command. The importer also examines Xcode's outcomes and counts; a supplied zero status cannot turn an incomplete bundle into a successful report.

Run tests and report in one command:

```sh
tiden-swift run --root-dir "$PWD" -- \
  xcodebuild test -workspace MyApp.xcworkspace -scheme MyApp \
  -destination 'platform=macOS'
```

Use your actual workspace/project, scheme, and destination. The wrapper passes arguments directly to the process, drains stdout and stderr independently, and streams test output. It adds its own `-resultBundlePath` inside a fresh evidence directory, so do not supply that option yourself. `test-without-building` follows the same reporting path.

For local conversion without API calls:

```sh
TIDEN_MODE=report tiden-swift report --xcresult artifacts/Tests.xcresult --root-dir "$PWD"
```

Modes are explicit: `off` disables extraction/reporting, `report` writes local JSON and exports attachments, and `tiden` additionally uploads results and enabled attachments. The default is `off`. Supplying credentials or a run ID without an explicit mode is an error. In `off` mode the wrapper still runs `xcodebuild` and retains its bundle; it does not inspect test outcomes. Importing a bundle is an explicit action after Xcode produces it; installing this package does not automatically report a Command-U run.

## CI and joined runs

Keep API tokens in CI secrets. Record branch and build metadata explicitly using `TIDEN_BRANCH` and `TIDEN_BUILD_SHA`.

```sh
export TIDEN_MODE=tiden
export TIDEN_BRANCH="$CI_BRANCH"
export TIDEN_BUILD_SHA="$CI_COMMIT_SHA"
tiden-swift run --root-dir "$PWD" -- \
  xcodebuild test -project MyApp.xcodeproj -scheme MyApp \
  -destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID'
```

Preserve the complete evidence directory as a CI artifact, including failed runs. Set `--output` to a new directory for every invocation. Existing output directories are rejected to prevent overwriting prior evidence. The reporter returns a nonzero status for test failures or reporting problems; a successful HTTP request alone does not establish successful reporting.

An orchestrator can create one Tiden run and assign its positive sequence number to multiple shards:

```sh
export TIDEN_RUN_ID=42
export TIDEN_RUN_COMPLETE=false
tiden-swift report --xcresult shard-1/Tests.xcresult --root-dir "$PWD" \
  --output artifacts/shard-1-report
```

With `complete=false`, the reporter sends results but neither completes nor aborts the shared run, including when a shard fails. The orchestrator owns the terminal action after evaluating every shard. By default a newly created or joined run has `complete=true`, so that invocation owns completion or abort. For joined runs, the run's existing lifecycle must permit reporting; server refusals are retained as errors.

## Configuration

Precedence is **CLI options > environment variables > nested `tiden.config.json` > defaults**. The default config file is in the current working directory; `--config FILE` selects another. An explicitly selected missing file is an error. Paths are interpreted relative to the current working directory. Unknown CLI options, malformed known values, invalid product UUIDs, and invalid run IDs are rejected.

| CLI option | Environment variable | JSON path | Default |
| --- | --- | --- | --- |
| `--mode` | `TIDEN_MODE` | `mode` | `off` |
| `--fallback` | `TIDEN_FALLBACK` | `fallback` | `off` |
| `--root-dir` | `TIDEN_ROOT_DIR` | `rootDir` | current directory |
| `--output` | `TIDEN_REPORT_CONNECTION_PATH` | `report.connections.local.path` | `artifacts/<UUID>` |
| `--root-suite` | `TIDEN_ROOT_SUITE` | `rootSuite` | none |
| `--token` | `TIDEN_API_TOKEN` | `tiden.api.token` | none |
| `--base-url` | `TIDEN_BASE_URL` | `tiden.api.baseUrl` | `https://api.tiden.ai` |
| `--product-id` | `TIDEN_PRODUCT_ID` | `tiden.product` | none |
| `--run-id` | `TIDEN_RUN_ID` | `tiden.run.id` | create a run |
| `--complete` | `TIDEN_RUN_COMPLETE` | `tiden.run.complete` | `true` |
| `--run-title` | `TIDEN_RUN_TITLE` | `tiden.run.title` | none |
| `--run-description` | `TIDEN_RUN_DESCRIPTION` | `tiden.run.description` | none |
| `--branch` | `TIDEN_BRANCH` | `tiden.run.branch` | none |
| `--build-sha` | `TIDEN_BUILD_SHA` | `tiden.run.buildSha` | none |
| `--environment` | `TIDEN_ENVIRONMENT` | `environment` | none |
| `--batch-size` | `TIDEN_BATCH_SIZE` | `tiden.batch.size` | `200` |
| `--upload-attachments` | `TIDEN_UPLOAD_ATTACHMENTS` | `tiden.uploadAttachments` | `true` |

Booleans accept `true` or `false`. Batch size must be 1–2000; requests are also capped at 8 MiB. Run IDs are positive int32 sequence numbers, distinct from product UUIDs. `sourceMap` is a file-only mapping from permanent signatures to existing repository-relative source paths.

```json
{
  "mode": "tiden",
  "rootDir": ".",
  "rootSuite": "MyApp",
  "tiden": {
    "api": { "baseUrl": "https://api.tiden.ai" },
    "product": "11111111-1111-4111-8111-111111111111",
    "uploadAttachments": true,
    "batch": { "size": 200 },
    "run": { "title": "Xcode tests", "complete": true }
  },
  "sourceMap": {
    "swift/v1::MyAppTests::ExampleTests/testExample": "Tests/ExampleTests.swift"
  }
}
```

Supply the token through `TIDEN_API_TOKEN`; keep secret-bearing config files out of version control. The reporter redacts its configured token from error messages and does not forward that environment variable to child processes. It preserves original Xcode evidence and attachment bytes, which may contain application data; choose artifacts and attachment policy accordingly.

## Identity, executions, and source anchors

The permanent case identity is case-sensitive and parameter-free:

```text
swift/v1::<test-module>::<declaration>
swift/v1::MyAppTests::ExampleTests/testExample
swift/v1::MyAppTests::Outer/Nested/parameterized(value:)
swift/v1::MyAppTests::topLevelTest
```

Module names and declaration paths come from Xcode identifiers. A no-argument declaration's terminal `()` is normalized away so Swift Testing and XCTest URL variants stay stable. Readable test titles, actual argument values, destinations, configurations, repetitions, and source line numbers do not change the signature.

Every actual execution receives a distinct UUID; transport retries reuse the same UUID and exact batch bytes. Parameterized inputs are reported as string-valued `params` using Xcode's named `Test Value` entries. Their argument association preserves declaration traversal order. Device and configuration IDs use the reserved keys `tiden.xcode.device` and `tiden.xcode.configuration`; collisions with user parameter names are errors. Repetitions remain separate execution rows with `fields.xcode_attempt`; `fields.xcode_result` retains the original Xcode outcome. Explicit run timestamps are epoch seconds. Activity event timestamps are not used as execution start times.

Expected failures map to `passed` while retaining `Expected Failure` and assertion messages. Actual failed assertions map to `failed`. Skips remain `skipped`. Untimed assertion diagnostics nested under a timed execution are retained as messages on that execution, rather than counted as attempts. Xcode definition and execution counts must reconcile, including known runner diagnostics; unknown outcomes and missing durations block completion.

`fields.file_path` is relative to `--root-dir`, never a guessed absolute path. Source metadata is preferred. When it is absent, a conservative Swift lexer searches actual declaration owners, ignoring comments and string literals. Overloads or multiple matching declarations are ambiguous: the path is omitted with a diagnostic. Use `sourceMap` to resolve known ambiguity. Invalid or outside-root override paths are omitted with a diagnostic. A report with no resolved source anchors cannot complete.

## Attachments and local evidence

Enabled attachments are exported by `xcresulttool`. Association uses the test module/declaration, actual arguments, device/configuration, repetition, and explicit execution intervals when available. An attachment must resolve to exactly one execution; missing or ambiguous association blocks successful completion. Export paths must be regular files within the export root; traversal and symbolic links are rejected.

Each file up to **32 MiB** uploads as multipart `file[]`. Upload acknowledgments must contain exactly one valid 64-character hexadecimal content hash before that hash is added to a result. Oversized files are preserved locally and explicitly omitted with a diagnostic. Export or upload failure blocks completion. Disable export and upload together with `--upload-attachments false` or `TIDEN_UPLOAD_ATTACHMENTS=false`.

The evidence directory contains available Xcode summary/tree/details/activities JSON, `results.json`, execution contexts, `summary.json`, and, in Tiden mode, the run handle and exact request batches. Exported attachments, their manifest, and association records remain local. The wrapper also retains `Tests.xcresult`. Evidence is written before result submission so transport errors leave recoverable artifacts.

## Errors, retries, and exit codes

Result and attachment requests retry connection failures and HTTP 408, 429, 500, 502, 503, and 504 up to five times after the initial attempt, using bounded exponential delays and bounded `Retry-After`. Other HTTP errors are terminal. Redirects are rejected so authorization is not forwarded to another endpoint. A run-creation request is never blindly retried after an ambiguous failure, because it may already have created a run.

Results require an acknowledgment whose accepted plus duplicate count equals the batch count, with no per-entry errors. Rejection diagnostics retain sanitized result index, ID, code, and message. An owned run completes only after trustworthy conversion and successful enabled uploads and result acknowledgments. Unknown, crashed, incomplete, empty, all-skipped, or unanchored reports abort an owned run. A complete set of actual failed assertions completes the run with failed results and returns failure to the caller.

| Status | Importer | Wrapper |
| --- | --- | --- |
| `0` | Successful report with no failed assertions | Tests and reporting succeeded |
| `1` | Actual failed assertions in a trustworthy imported bundle | Preserves the child's `1` if returned |
| `2` | Reporting, extraction, configuration, or infrastructure error | Reporting error after child status `0` |
| Other nonzero | Preserves an explicitly supplied original nonzero status after trustworthy import | Preserves `xcodebuild`'s nonzero status |

SIGINT/SIGTERM interrupt the wrapper's child; it escalates to SIGKILL if necessary. Extraction uses a separate process runner so cancellation still allows local evidence and an owned-run abort. Cancellation during API reporting also prevents completion. Joined `complete=false` runs retain orchestrator ownership throughout.

`--fallback report` allows local reporting when API begin fails: the wrapper still runs tests and preserves their bundle and local extraction evidence, while its final status remains nonzero. Reporting-stage failures already retain local evidence. Fallback does not turn an upload or acknowledgment failure into a successful run.

## Development

```sh
swift build --disable-sandbox
swift build --build-tests --disable-sandbox
swift run --disable-sandbox tiden-swift --help
bash Scripts/check.sh
git diff --check
```

`Scripts/check.sh` creates a fresh temporary workspace pointing at the current package root, runs the `TidenReporterTests` scheme with native `xcodebuild test`, then imports its `.xcresult` with the built reporter and original test status. It defaults to local `report` mode and honors an explicit `TIDEN_MODE`; use `tiden` with credentials when validation should reach Tiden. Build/test/reporter logs and exit statuses remain under `artifacts/validation.*`. Its exit status preserves a failed Xcode test command, or otherwise the importer status. A plain SwiftPM test event stream is not the reporting adapter.

Tests cover permanent identity, configuration/wire contracts, conversion/count fidelity, conservative source resolution, retry/acknowledgment handling, attachment safety and association, run ownership, process streaming/cancellation, and wrapper fallback. [The native fixture](Examples/README.md) adds Swift Testing, XCTest unit/UI, and screenshot validation on macOS and iOS. The CI workflow uses GitHub's standard Apple silicon `xcode-27` hosted runner, currently in public preview and free for public repositories, and selects Xcode 27.0 through `DEVELOPER_DIR`. CI stores evidence in local report mode and uploads validation artifacts.

This package does not provide a direct SwiftPM test-stream adapter, custom traits/macros, or automatic Xcode test-action installation. Contributions follow the [organization Code of Conduct](CODE_OF_CONDUCT.md). The project is licensed under [Apache 2.0](LICENSE).
