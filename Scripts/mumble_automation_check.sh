#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

PYTHON_BIN="${PYTHON:-python3}"
REPORT_PATH="Tests/Artifacts/self-test-suite/report.md"
KEEP_ARTIFACTS="${MUMBLE_KEEP_ARTIFACTS:-}"

if [ -z "$KEEP_ARTIFACTS" ]; then
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    KEEP_ARTIFACTS=1
  else
    KEEP_ARTIFACTS=0
  fi
fi

"$PYTHON_BIN" -m py_compile \
  Scripts/mumble_automation_consistency.py \
  Scripts/mumble_agent_probe.py \
  Scripts/mumble_build_diagnostics.py \
  Scripts/mumble_manifest_summarize.py \
  Scripts/mumble_trace_analyze.py \
  Scripts/mumble_trace_compare.py \
  Scripts/mumble_observability_check.py
bash -n Scripts/mumble_real_app_probe.sh

"$PYTHON_BIN" Scripts/mumble_build_diagnostics.py --self-test
"$PYTHON_BIN" Scripts/mumble_manifest_summarize.py --self-test
"$PYTHON_BIN" Scripts/mumble_automation_consistency.py
Scripts/mumble_real_app_probe.sh --dry-run --platform ios-simulator --scenario baseline \
  --artifacts Tests/Artifacts/real-app-dry-run \
  --derived-data Tests/Artifacts/real-app-dry-run/DerivedData \
  >/dev/null
Scripts/mumble_real_app_probe.sh --dry-run --platform macos --scenario baseline \
  --artifacts Tests/Artifacts/real-app-macos-dry-run \
  --derived-data Tests/Artifacts/real-app-macos-dry-run/DerivedData \
  >/dev/null
"$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path

manifest_path = Path("Tests/Artifacts/real-app-dry-run/run-manifest.json")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
assert manifest["schemaVersion"] == 1
assert manifest["status"] == "passed"
assert manifest["phase"] == "dry-run"
assert manifest["dryRun"] is True
assert manifest["configuration"]["scenario"] == "baseline"
assert manifest["privacy"]["microphone"]["status"] == "planned"
assert "Would grant microphone permission" in manifest["privacy"]["microphone"]["summary"]

macos_manifest_path = Path("Tests/Artifacts/real-app-macos-dry-run/run-manifest.json")
macos_manifest = json.loads(macos_manifest_path.read_text(encoding="utf-8"))
assert macos_manifest["schemaVersion"] == 1
assert macos_manifest["status"] == "passed"
assert macos_manifest["phase"] == "dry-run"
assert macos_manifest["dryRun"] is True
assert macos_manifest["configuration"]["platform"] == "macos"
assert macos_manifest["privacy"]["microphone"]["status"] == "not-applicable"
assert macos_manifest["privacy"]["microphone"]["summary"] == "Not a simulator platform."
PY
"$PYTHON_BIN" Scripts/mumble_manifest_summarize.py Tests/Artifacts/real-app-dry-run --markdown \
  > Tests/Artifacts/real-app-manifest-summary.md
"$PYTHON_BIN" - <<'PY'
from pathlib import Path

summary = Path("Tests/Artifacts/real-app-manifest-summary.md").read_text(encoding="utf-8")
assert "Mumble Real-App Manifest Summary" in summary
assert "`dry-run`" in summary
assert "`passed`" in summary
assert "Microphone Privacy" in summary
assert "`planned`" in summary
PY
"$PYTHON_BIN" Scripts/mumble_agent_probe.py --self-test
"$PYTHON_BIN" Scripts/mumble_trace_analyze.py --self-test \
  --budget-file Tests/Baselines/performance_budgets.json
"$PYTHON_BIN" Scripts/mumble_trace_compare.py --self-test
"$PYTHON_BIN" Scripts/mumble_trace_analyze.py Tests/Artifacts/self-test.jsonl \
  --budget-file Tests/Baselines/performance_budgets.json \
  --require-provenance \
  --require-event log.entry \
  --require-command log.stream \
  --require-command log.marker \
  --require-command log.recent \
  --require-command network.status \
  --require-command network.injectUDPStatus \
  --require-command app.refreshModel \
  --require-command app.simulateLifecycle \
  --require-network-snapshot \
  --require-command performance.reset \
  --require-command performance.status \
  --require-perf-marker agent_probe.marker \
  --require-perf-marker ui_performance_sampling.samples \
  --max-performance-stalls 0 \
  --max-performance-lag-ms 0
"$PYTHON_BIN" Scripts/mumble_trace_analyze.py Tests/Artifacts/self-test-suite/*.jsonl \
  --budget-file Tests/Baselines/performance_budgets.json \
  --require-suite-index \
  --require-provenance \
  --require-scenario baseline \
  --require-scenario idle-welcome \
  --require-scenario lifecycle-idle-audio \
  --require-scenario mixer-lifecycle \
  --require-scenario vad-onboarding \
  --require-scenario network-settings \
  --require-scenario network-connect-failure \
  --require-scenario network-auto-reconnect \
  --require-scenario network-udp-degraded \
  --require-scenario network-udp-toast-throttle \
  --require-scenario ui-performance-sampling \
  --require-event log.entry \
  --require-command log.stream \
  --require-command log.marker \
  --require-command log.recent \
  --require-command network.status \
  --require-command network.injectUDPStatus \
  --require-network-snapshot \
  --require-command app.simulateLifecycle \
  --require-command performance.reset \
  --require-command performance.status \
  --require-perf-marker agent_probe.marker \
  --max-performance-stalls 0 \
  --max-performance-lag-ms 0
"$PYTHON_BIN" Scripts/mumble_trace_analyze.py Tests/Artifacts/self-test-suite/*.jsonl \
  --markdown \
  --budget-file Tests/Baselines/performance_budgets.json \
  --require-suite-index \
  --require-provenance \
  --require-scenario baseline \
  --require-scenario idle-welcome \
  --require-scenario lifecycle-idle-audio \
  --require-scenario mixer-lifecycle \
  --require-scenario vad-onboarding \
  --require-scenario network-settings \
  --require-scenario network-connect-failure \
  --require-scenario network-auto-reconnect \
  --require-scenario network-udp-degraded \
  --require-scenario network-udp-toast-throttle \
  --require-scenario ui-performance-sampling \
  --require-event log.entry \
  --require-command log.stream \
  --require-command log.marker \
  --require-command log.recent \
  --require-command network.status \
  --require-command network.injectUDPStatus \
  --require-command app.refreshModel \
  --require-command app.simulateLifecycle \
  --require-network-snapshot \
  --require-command performance.reset \
  --require-command performance.status \
  --require-perf-marker agent_probe.marker \
  --require-perf-marker ui_performance_sampling.samples \
  --max-performance-stalls 0 \
  --max-performance-lag-ms 0 \
  > "$REPORT_PATH"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$REPORT_PATH" ]; then
  {
    echo "## Mumble Automation Evidence"
    echo
    cat "$REPORT_PATH"
  } >> "$GITHUB_STEP_SUMMARY"
fi

"$PYTHON_BIN" Scripts/mumble_observability_check.py --self-test
"$PYTHON_BIN" Scripts/mumble_observability_check.py \
  --baseline Tests/Baselines/observability_allowlist.json \
  --require-perf-marker connect_begin \
  --require-perf-marker connect_opened \
  --require-perf-marker connect_ready \
  --require-perf-marker connect_failed \
  --require-perf-marker rebuild_model_array \
  --require-perf-marker message_render_blocks \
  --require-perf-marker audio_callback \
  --require-perf-marker main_thread_stall

if [ "$KEEP_ARTIFACTS" != "1" ]; then
  rm -rf Tests/Artifacts
  rm -f \
    Scripts/__pycache__/mumble_automation_consistency.*.pyc \
    Scripts/__pycache__/mumble_agent_probe.*.pyc \
    Scripts/__pycache__/mumble_build_diagnostics.*.pyc \
    Scripts/__pycache__/mumble_manifest_summarize.*.pyc \
    Scripts/__pycache__/mumble_trace_analyze.*.pyc \
    Scripts/__pycache__/mumble_trace_compare.*.pyc \
    Scripts/__pycache__/mumble_observability_check.*.pyc
fi
