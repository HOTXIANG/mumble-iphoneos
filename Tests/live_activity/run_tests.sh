#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "$script_dir/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mumble-live-activity.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Compile the production activity methods against controlled framework doubles.
# Keep their implementation in one place; only the unrelated Handoff methods,
# iOS guards, and ActivityKit type names need adapting for a macOS command line.
python3 - "$project_root" "$test_dir" <<'PY'
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
source = (root / "Source/Classes/SwiftUI/ServerModelManager/ServerModelManager+HandoffLiveActivity.swift").read_text()
source = (
    source[:source.index("    // MARK: - Handoff User Preferences Restore")]
    + source[source.index("    func startLiveActivity()"):]
)
start = source.index("    /// 收集当前用户音频设置并更新 Handoff Activity")
end = source.index("    func endLiveActivity()", start)
source = source[:start] + source[end:]
source = source.replace("import ActivityKit\n", "")
source = source.replace("#if os(iOS)\n", "").replace("#endif\n", "")
source = source.replace("Activity<MumbleActivityAttributes>", "TestActivity")
source = source.replace("Activity.request(", "TestActivity.request(")
(output / "ActivityUpdates.swift").write_text(source)
PY

xcrun swiftc -swift-version 6 \
    -module-cache-path "$test_dir/module-cache" \
    "$script_dir/Harness.swift" "$test_dir/ActivityUpdates.swift" \
    -o "$test_dir/checks"
"$test_dir/checks"
