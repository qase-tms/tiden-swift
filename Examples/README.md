# Native Xcode fixture

`ReporterFixture` is a small host app with Swift Testing, XCTest unit, and XCTest UI targets. The same shared scheme runs on macOS or an iOS simulator. Its tests cover passing assertions, expected failures, deliberate skips, a parameterized Swift test, and a screenshot attachment. The macOS UI test captures the fixture window; the iOS UI test captures the fixture app.

Build the reporter from the repository root, then run the fixture:

```sh
swift build --disable-sandbox
TIDEN_MODE=report .build/debug/tiden-swift run --root-dir "$PWD" -- \
  xcodebuild test \
  -project Examples/ReporterFixture/ReporterFixture.xcodeproj \
  -scheme ReporterFixture -destination 'platform=macOS'
```

For iOS, select a simulator available in your Xcode installation:

```sh
xcrun simctl list devices available
TIDEN_MODE=report .build/debug/tiden-swift run --root-dir "$PWD" -- \
  xcodebuild test \
  -project Examples/ReporterFixture/ReporterFixture.xcodeproj \
  -scheme ReporterFixture -destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID'
```

The wrapper selects a fresh result bundle beneath its evidence directory and preserves the `xcodebuild` status. Consult the main README for Tiden credentials, upload opt-out, and joined runs. Signing and simulator availability follow your local Xcode setup. Use a fresh DerivedData path when validating with different destinations or signing settings.

To exercise real assertion failures, pass `TEST_RUNNER_TIDEN_FIXTURE_FAILURES=1` to the wrapper environment. Xcode forwards the variable to the test runner as `TIDEN_FIXTURE_FAILURES`; both unit frameworks then fail their opt-in assertion. The remaining tests still run and the reporter retains their results.

```sh
TEST_RUNNER_TIDEN_FIXTURE_FAILURES=1 TIDEN_MODE=report \
  .build/debug/tiden-swift run --root-dir "$PWD" -- \
  xcodebuild test -project Examples/ReporterFixture/ReporterFixture.xcodeproj \
  -scheme ReporterFixture -destination 'platform=macOS'
```

The fixture is validation material, not an application dependency. It does not change reporter identity rules or require test annotations beyond the frameworks' own APIs.
