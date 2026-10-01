#!/usr/bin/env bash
# Line coverage of the SightlineIOS.app target from a test run's result bundle, checked against a
# minimum.
#
#   SightlineIOS/scripts/coverage_check.sh RESULT.xcresult [MIN_PERCENT]
#
# The scheme gathers coverage (TestAction codeCoverageEnabled), so any `xcodebuild test
# -resultBundlePath RESULT.xcresult` run has it. The unit-test bundle compiles the app sources it
# tests itself; xccov merges a source file's counts from every target that compiled it, so the app
# target's figure covers the unit and the UI tests. Prints one line per file, then the total.
# Exits 1 below MIN_PERCENT (default 0: report only), 2 on bad arguments.
set -euo pipefail

[ $# -ge 1 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
bundle="$1"
min="${2:-0}"
[ -d "${bundle}" ] || { echo "coverage_check: no result bundle at ${bundle}" >&2; exit 2; }
# The pinned local Xcode when it's installed; elsewhere (CI) the selected Xcode.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.0.0.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer
fi

report="$(mktemp "${TMPDIR:-/tmp}/coverage.XXXXXX")"
trap 'rm -f "${report}"' EXIT
xcrun xccov view --report --json "${bundle}" > "${report}"
python3 - "${report}" "${min}" <<'EOF'
import json, sys

with open(sys.argv[1]) as f:
    report = json.load(f)
minimum = float(sys.argv[2])
app = next((t for t in report.get("targets", []) if t["name"] == "SightlineIOS.app"), None)
if app is None:
    sys.exit("coverage_check: no SightlineIOS.app target in the coverage report")
for f in sorted(app["files"], key=lambda f: f["name"]):
    print(f"{100 * f['lineCoverage']:6.1f}%  {f['coveredLines']:5d}/{f['executableLines']:<5d} {f['name']}")
percent = 100 * app["lineCoverage"]
print(f"SightlineIOS.app line coverage: {percent:.1f}% "
      f"({app['coveredLines']}/{app['executableLines']} lines); minimum {minimum:g}%")
sys.exit(0 if percent + 1e-9 >= minimum else 1)
EOF
