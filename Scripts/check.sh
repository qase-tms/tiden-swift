#!/bin/bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$package_root"
mkdir -p artifacts
evidence="$(mktemp -d "$package_root/artifacts/validation.XXXXXX")"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/tiden-swift-validation.XXXXXX")"
workspace="$temporary/ReporterValidation.xcworkspace"
mkdir -p "$workspace"
xml_root="${package_root//&/&amp;}"
xml_root="${xml_root//</&lt;}"
xml_root="${xml_root//>/&gt;}"
xml_root="${xml_root//\"/&quot;}"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="absolute:%s"/></Workspace>\n' "$xml_root" > "$workspace/contents.xcworkspacedata"
printf 'Validation evidence: %s\nWorkspace: %s\n' "$evidence" "$workspace"

set +e
swift build --disable-sandbox 2>&1 | tee "$evidence/build.log"
build_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$build_status" > "$evidence/build.exitstatus"
if [ "$build_status" -ne 0 ]; then exit "$build_status"; fi

set +e
xcodebuild test -workspace "$workspace" -scheme TidenReporterTests \
  -destination 'platform=macOS' -derivedDataPath "$temporary/DerivedData" \
  -resultBundlePath "$evidence/Tests.xcresult" 2>&1 | tee "$evidence/xcodebuild.log"
test_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$test_status" > "$evidence/xcodebuild.exitstatus"

set +e
"$package_root/.build/debug/tiden-swift" report --xcresult "$evidence/Tests.xcresult" \
  --root-dir "$package_root" --exit-code "$test_status" --mode "${TIDEN_MODE:-report}" \
  --output "$evidence/report" 2>&1 | tee "$evidence/reporter.log"
report_status=${PIPESTATUS[0]}
set -e
printf '%s\n' "$report_status" > "$evidence/reporter.exitstatus"
printf 'xcodebuild: %s; reporter: %s; evidence retained at %s\n' "$test_status" "$report_status" "$evidence"
if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
exit "$report_status"
