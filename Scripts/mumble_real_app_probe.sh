#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PYTHON_BIN="${PYTHON:-python3}"
PROJECT_PATH="${MUMBLE_XCODE_PROJECT:-Mumble.xcodeproj}"
SCHEME="${MUMBLE_XCODE_SCHEME:-Mumble}"
CONFIGURATION="${MUMBLE_XCODE_CONFIGURATION:-Debug}"
PLATFORM="${MUMBLE_REAL_APP_PLATFORM:-ios-simulator}"
SIMULATOR_NAME="${MUMBLE_SIMULATOR_NAME:-auto}"
SIMULATOR_ID="${MUMBLE_SIMULATOR_ID:-}"
SIMULATOR_RUNTIME=""
BUNDLE_ID="${MUMBLE_BUNDLE_ID:-cn.hotxiang.Mumble}"
PRODUCT_NAME="${MUMBLE_PRODUCT_NAME:-Mumble}"
URL="${MUMBLE_TEST_URL:-ws://localhost:54296}"
SCENARIO="${MUMBLE_PROBE_SCENARIO:-all}"
REPEAT="${MUMBLE_PROBE_REPEAT:-1}"
WAIT_SECONDS="${MUMBLE_TEST_SERVER_WAIT_SECONDS:-45}"
DERIVED_DATA="${MUMBLE_DERIVED_DATA:-Tests/Artifacts/real-app/DerivedData}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="${MUMBLE_REAL_APP_ARTIFACT_DIR:-Tests/Artifacts/real-app/$TIMESTAMP}"
DEPLOYMENT_TARGET="${MUMBLE_SIM_DEPLOYMENT_TARGET:-17.0}"
VERBOSE_BUILD_LOGS="${MUMBLE_REAL_APP_VERBOSE_BUILD:-0}"
SKIP_BUILD=0
SKIP_LAUNCH=0
KEEP_APP_RUNNING=0
DRY_RUN=0
PREFLIGHT_ONLY=0
APP_PID=""
APP_PATH=""
MICROPHONE_PRIVACY_STATUS="not-applicable"
MICROPHONE_PRIVACY_SUMMARY=""
EXTRA_XCODEBUILD_ARGS=()

usage() {
  cat <<'EOF'
Usage: Scripts/mumble_real_app_probe.sh [options]

Build, install, launch a Debug app, then run MUTestServer probes and
write traceable JSONL/Markdown evidence under Tests/Artifacts/real-app.

Options:
  --platform NAME        ios-simulator, ipados-simulator, or macos (default: ios-simulator)
  --simulator NAME       Simulator name, or auto (default: auto)
  --simulator-id UUID    Simulator UDID; bypasses name-based selection
  --scheme NAME          Xcode scheme (default: Mumble)
  --configuration NAME   Xcode configuration (default: Debug)
  --derived-data PATH    DerivedData path (default: Tests/Artifacts/real-app/DerivedData)
  --artifacts PATH       Evidence directory (default: Tests/Artifacts/real-app/<timestamp>)
  --bundle-id ID         App bundle id (default: cn.hotxiang.Mumble)
  --url URL              MUTestServer WebSocket URL (default: ws://localhost:54296)
  --scenario NAME        Probe scenario or all (default: all)
  --repeat N             Repeat count for --scenario all (default: 1)
  --wait-seconds N       Seconds to wait for MUTestServer (default: 45)
  --xcodebuild-arg ARG   Extra xcodebuild argument or build setting (repeatable)
  --skip-build           Reuse an existing build
  --skip-launch          Assume the app is already running
  --keep-running         Do not terminate the app when the script exits
  --preflight-only       Resolve environment and write preflight.json, then exit
  --dry-run              Print the planned commands without executing them
  --help                 Show this help

Environment overrides use the MUMBLE_* names matching the defaults above.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform) PLATFORM="$2"; shift 2 ;;
    --simulator) SIMULATOR_NAME="$2"; shift 2 ;;
    --simulator-id) SIMULATOR_ID="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --derived-data) DERIVED_DATA="$2"; shift 2 ;;
    --artifacts) ARTIFACT_DIR="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --scenario) SCENARIO="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --xcodebuild-arg) EXTRA_XCODEBUILD_ARGS+=("$2"); shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-launch) SKIP_LAUNCH=1; shift ;;
    --keep-running) KEEP_APP_RUNNING=1; shift ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$PLATFORM" in
  ios-simulator|ipados-simulator|macos) ;;
  *) echo "unsupported platform: $PLATFORM" >&2; usage >&2; exit 2 ;;
esac

log() {
  printf '[mumble-real-app-probe] %s\n' "$*"
}

run_cmd() {
  log "$*"
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  "$@"
}

run_logged() {
  local log_path="$1"
  shift
  log "$* > $log_path"
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if [ "$VERBOSE_BUILD_LOGS" = "1" ]; then
    "$@" 2>&1 | tee "$log_path"
  else
    "$@" > "$log_path" 2>&1
  fi
}

json_bool() {
  if [ "$1" = "1" ]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

url_host_port() {
  "$PYTHON_BIN" - "$URL" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
host = parsed.hostname or "localhost"
port = parsed.port or 80
print(f"{host} {port}")
PY
}

wait_for_test_server() {
  local host="$1"
  local port="$2"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$PYTHON_BIN" - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
with socket.create_connection((host, port), timeout=1):
    pass
PY
    then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting ${WAIT_SECONDS}s for MUTestServer at ${host}:${port}" >&2
  return 1
}

summarize_build_failure() {
  local log_path="$1"
  local markdown_path="$2"
  local json_path="$3"
  local developer_dir="${DEVELOPER_DIR:-}"
  local selected_developer_dir=""
  selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
  "$PYTHON_BIN" Scripts/mumble_build_diagnostics.py "$log_path" \
    --context "platform=$PLATFORM" \
    --context "simulator=$SIMULATOR_NAME" \
    --context "simulatorId=$SIMULATOR_ID" \
    --context "simulatorRuntime=$SIMULATOR_RUNTIME" \
    --context "scheme=$SCHEME" \
    --context "configuration=$CONFIGURATION" \
    --context "project=$PROJECT_PATH" \
    --context "derivedData=$DERIVED_DATA" \
    --context "destination=$(destination_for_platform)" \
    --context "developerDir=$developer_dir" \
    --context "selectedDeveloperDir=$selected_developer_dir" \
    --context "deploymentTarget=$DEPLOYMENT_TARGET" \
    --markdown "$markdown_path" \
    --json "$json_path"
  log "build diagnostics: $markdown_path"
}

summarize_preflight_failure() {
  local log_path="$1"
  local markdown_path="$2"
  local json_path="$3"
  local developer_dir="${DEVELOPER_DIR:-}"
  local selected_developer_dir=""
  selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
  "$PYTHON_BIN" Scripts/mumble_build_diagnostics.py "$log_path" \
    --context "phase=simulator-preflight" \
    --context "platform=$PLATFORM" \
    --context "simulator=$SIMULATOR_NAME" \
    --context "simulatorId=$SIMULATOR_ID" \
    --context "simulatorRuntime=$SIMULATOR_RUNTIME" \
    --context "scheme=$SCHEME" \
    --context "configuration=$CONFIGURATION" \
    --context "project=$PROJECT_PATH" \
    --context "derivedData=$DERIVED_DATA" \
    --context "destination=$(destination_for_platform)" \
    --context "developerDir=$developer_dir" \
    --context "selectedDeveloperDir=$selected_developer_dir" \
    --context "deploymentTarget=$DEPLOYMENT_TARGET" \
    --markdown "$markdown_path" \
    --json "$json_path"
  log "preflight diagnostics: $markdown_path"
}

write_manifest() {
  local status="$1"
  local phase="$2"
  local summary="$3"
  local diagnostics_json="${4:-}"
  local diagnostics_markdown="${5:-}"
  local destination
  destination="$(destination_for_platform)"

  MUMBLE_MANIFEST_STATUS="$status" \
  MUMBLE_MANIFEST_PHASE="$phase" \
  MUMBLE_MANIFEST_SUMMARY="$summary" \
  MUMBLE_MANIFEST_DIAGNOSTICS_JSON="$diagnostics_json" \
  MUMBLE_MANIFEST_DIAGNOSTICS_MARKDOWN="$diagnostics_markdown" \
  MUMBLE_MANIFEST_DRY_RUN="$(json_bool "$DRY_RUN")" \
  MUMBLE_MANIFEST_PREFLIGHT_ONLY="$(json_bool "$PREFLIGHT_ONLY")" \
  MUMBLE_MANIFEST_PLATFORM="$PLATFORM" \
  MUMBLE_MANIFEST_SIMULATOR_NAME="$SIMULATOR_NAME" \
  MUMBLE_MANIFEST_SIMULATOR_ID="$SIMULATOR_ID" \
  MUMBLE_MANIFEST_SIMULATOR_RUNTIME="$SIMULATOR_RUNTIME" \
  MUMBLE_MANIFEST_SCHEME="$SCHEME" \
  MUMBLE_MANIFEST_CONFIGURATION="$CONFIGURATION" \
  MUMBLE_MANIFEST_PROJECT="$PROJECT_PATH" \
  MUMBLE_MANIFEST_DERIVED_DATA="$DERIVED_DATA" \
  MUMBLE_MANIFEST_DESTINATION="$destination" \
  MUMBLE_MANIFEST_BUNDLE_ID="$BUNDLE_ID" \
  MUMBLE_MANIFEST_PRODUCT_NAME="$PRODUCT_NAME" \
  MUMBLE_MANIFEST_URL="$URL" \
  MUMBLE_MANIFEST_SCENARIO="$SCENARIO" \
  MUMBLE_MANIFEST_REPEAT="$REPEAT" \
  MUMBLE_MANIFEST_WAIT_SECONDS="$WAIT_SECONDS" \
  MUMBLE_MANIFEST_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  MUMBLE_MANIFEST_ARTIFACT_DIR="$ARTIFACT_DIR" \
  MUMBLE_MANIFEST_APP_PATH="$APP_PATH" \
  MUMBLE_MANIFEST_EVIDENCE_PATH="$EVIDENCE_PATH" \
  MUMBLE_MANIFEST_PREFLIGHT_JSON="$PREFLIGHT_JSON" \
  MUMBLE_MANIFEST_PREFLIGHT_DIAGNOSTICS_JSON="$PREFLIGHT_DIAGNOSTICS_JSON" \
  MUMBLE_MANIFEST_PREFLIGHT_DIAGNOSTICS_MD="$PREFLIGHT_DIAGNOSTICS_MD" \
  MUMBLE_MANIFEST_SIMCTL_LIST_LOG="$SIMCTL_LIST_LOG" \
  MUMBLE_MANIFEST_BUILD_LOG="$BUILD_LOG" \
  MUMBLE_MANIFEST_BUILD_DIAGNOSTICS_JSON="$BUILD_DIAGNOSTICS_JSON" \
  MUMBLE_MANIFEST_BUILD_DIAGNOSTICS_MD="$BUILD_DIAGNOSTICS_MD" \
  MUMBLE_MANIFEST_LAUNCH_LOG="$LAUNCH_LOG" \
  MUMBLE_MANIFEST_REPORT_PATH="$REPORT_PATH" \
  MUMBLE_MANIFEST_PRIVACY_LOG="$PRIVACY_LOG" \
  MUMBLE_MANIFEST_PRIVACY_JSON="$PRIVACY_JSON" \
  MUMBLE_MANIFEST_MICROPHONE_PRIVACY_STATUS="$MICROPHONE_PRIVACY_STATUS" \
  MUMBLE_MANIFEST_MICROPHONE_PRIVACY_SUMMARY="$MICROPHONE_PRIVACY_SUMMARY" \
    "$PYTHON_BIN" - "$RUN_MANIFEST_JSON" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])

def env(name: str) -> str:
    return os.environ.get(name, "")

def env_bool(name: str) -> bool:
    return env(name).lower() == "true"

def artifact(path_value: str) -> dict[str, object]:
    if not path_value:
        return {"path": "", "exists": False}
    path = Path(path_value)
    return {"path": path_value, "exists": path.exists()}

diagnostics = {}
diagnostics_path = env("MUMBLE_MANIFEST_DIAGNOSTICS_JSON")
if diagnostics_path:
    try:
        diagnostics = json.loads(Path(diagnostics_path).read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 - manifest should survive malformed diagnostics.
        diagnostics = {"readError": str(exc), "path": diagnostics_path}

manifest = {
    "schemaVersion": 1,
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "status": env("MUMBLE_MANIFEST_STATUS"),
    "phase": env("MUMBLE_MANIFEST_PHASE"),
    "summary": env("MUMBLE_MANIFEST_SUMMARY"),
    "dryRun": env_bool("MUMBLE_MANIFEST_DRY_RUN"),
    "preflightOnly": env_bool("MUMBLE_MANIFEST_PREFLIGHT_ONLY"),
    "configuration": {
        "platform": env("MUMBLE_MANIFEST_PLATFORM"),
        "scheme": env("MUMBLE_MANIFEST_SCHEME"),
        "configuration": env("MUMBLE_MANIFEST_CONFIGURATION"),
        "project": env("MUMBLE_MANIFEST_PROJECT"),
        "derivedData": env("MUMBLE_MANIFEST_DERIVED_DATA"),
        "destination": env("MUMBLE_MANIFEST_DESTINATION"),
        "deploymentTarget": env("MUMBLE_MANIFEST_DEPLOYMENT_TARGET"),
        "bundleId": env("MUMBLE_MANIFEST_BUNDLE_ID"),
        "productName": env("MUMBLE_MANIFEST_PRODUCT_NAME"),
        "url": env("MUMBLE_MANIFEST_URL"),
        "scenario": env("MUMBLE_MANIFEST_SCENARIO"),
        "repeat": int(env("MUMBLE_MANIFEST_REPEAT") or "0"),
        "waitSeconds": int(env("MUMBLE_MANIFEST_WAIT_SECONDS") or "0"),
    },
    "simulator": {
        "name": env("MUMBLE_MANIFEST_SIMULATOR_NAME"),
        "id": env("MUMBLE_MANIFEST_SIMULATOR_ID"),
        "runtime": env("MUMBLE_MANIFEST_SIMULATOR_RUNTIME"),
    },
    "appPath": env("MUMBLE_MANIFEST_APP_PATH"),
    "privacy": {
        "microphone": {
            "status": env("MUMBLE_MANIFEST_MICROPHONE_PRIVACY_STATUS"),
            "summary": env("MUMBLE_MANIFEST_MICROPHONE_PRIVACY_SUMMARY"),
        }
    },
    "diagnostics": diagnostics,
    "artifacts": {
        "artifactDir": artifact(env("MUMBLE_MANIFEST_ARTIFACT_DIR")),
        "preflight": artifact(env("MUMBLE_MANIFEST_PREFLIGHT_JSON")),
        "preflightDiagnosticsJson": artifact(env("MUMBLE_MANIFEST_PREFLIGHT_DIAGNOSTICS_JSON")),
        "preflightDiagnosticsMarkdown": artifact(env("MUMBLE_MANIFEST_PREFLIGHT_DIAGNOSTICS_MD")),
        "simctlListLog": artifact(env("MUMBLE_MANIFEST_SIMCTL_LIST_LOG")),
        "buildLog": artifact(env("MUMBLE_MANIFEST_BUILD_LOG")),
        "buildDiagnosticsJson": artifact(env("MUMBLE_MANIFEST_BUILD_DIAGNOSTICS_JSON")),
        "buildDiagnosticsMarkdown": artifact(env("MUMBLE_MANIFEST_BUILD_DIAGNOSTICS_MD")),
        "launchLog": artifact(env("MUMBLE_MANIFEST_LAUNCH_LOG")),
        "evidence": artifact(env("MUMBLE_MANIFEST_EVIDENCE_PATH")),
        "report": artifact(env("MUMBLE_MANIFEST_REPORT_PATH")),
        "privacyLog": artifact(env("MUMBLE_MANIFEST_PRIVACY_LOG")),
        "privacyJson": artifact(env("MUMBLE_MANIFEST_PRIVACY_JSON")),
        "activeDiagnosticsJson": artifact(env("MUMBLE_MANIFEST_DIAGNOSTICS_JSON")),
        "activeDiagnosticsMarkdown": artifact(env("MUMBLE_MANIFEST_DIAGNOSTICS_MARKDOWN")),
    },
}

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  log "manifest: $RUN_MANIFEST_JSON"
}

write_privacy_result() {
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  MUMBLE_PRIVACY_STATUS="$MICROPHONE_PRIVACY_STATUS" \
  MUMBLE_PRIVACY_SUMMARY="$MICROPHONE_PRIVACY_SUMMARY" \
  MUMBLE_PRIVACY_PLATFORM="$PLATFORM" \
  MUMBLE_PRIVACY_SIMULATOR_ID="$SIMULATOR_ID" \
  MUMBLE_PRIVACY_SIMULATOR_NAME="$SIMULATOR_NAME" \
  MUMBLE_PRIVACY_BUNDLE_ID="$BUNDLE_ID" \
    "$PYTHON_BIN" - "$PRIVACY_JSON" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path = sys.argv[1]
payload = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "status": os.environ.get("MUMBLE_PRIVACY_STATUS", ""),
    "summary": os.environ.get("MUMBLE_PRIVACY_SUMMARY", ""),
    "platform": os.environ.get("MUMBLE_PRIVACY_PLATFORM", ""),
    "bundleId": os.environ.get("MUMBLE_PRIVACY_BUNDLE_ID", ""),
    "simulator": {
        "id": os.environ.get("MUMBLE_PRIVACY_SIMULATOR_ID", ""),
        "name": os.environ.get("MUMBLE_PRIVACY_SIMULATOR_NAME", ""),
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

initialize_privacy_status() {
  if is_simulator_platform; then
    MICROPHONE_PRIVACY_STATUS="not-attempted"
    MICROPHONE_PRIVACY_SUMMARY="Microphone permission grant has not run yet; the simulator app must be installed first."
  else
    MICROPHONE_PRIVACY_STATUS="not-applicable"
    MICROPHONE_PRIVACY_SUMMARY="Not a simulator platform."
  fi
}

grant_simulator_microphone_permission() {
  if ! is_simulator_platform; then
    MICROPHONE_PRIVACY_STATUS="not-applicable"
    MICROPHONE_PRIVACY_SUMMARY="Not a simulator platform."
    write_privacy_result
    return 0
  fi

  local simulator_target="${SIMULATOR_ID:-$SIMULATOR_NAME}"
  if [ "$DRY_RUN" = "1" ]; then
    MICROPHONE_PRIVACY_STATUS="planned"
    MICROPHONE_PRIVACY_SUMMARY="Would grant microphone permission for $BUNDLE_ID on $simulator_target."
    log "xcrun simctl privacy $simulator_target grant microphone $BUNDLE_ID > $PRIVACY_LOG"
    return 0
  fi

  log "granting microphone permission for $BUNDLE_ID on $simulator_target"
  if xcrun simctl privacy "$simulator_target" grant microphone "$BUNDLE_ID" > "$PRIVACY_LOG" 2>&1; then
    MICROPHONE_PRIVACY_STATUS="granted"
    MICROPHONE_PRIVACY_SUMMARY="Microphone permission granted with simctl privacy."
  else
    MICROPHONE_PRIVACY_STATUS="failed"
    MICROPHONE_PRIVACY_SUMMARY="$(head -n 1 "$PRIVACY_LOG" 2>/dev/null || printf 'simctl privacy grant microphone failed')"
    log "warning: microphone permission grant failed; see $PRIVACY_LOG"
  fi
  write_privacy_result
}

is_simulator_platform() {
  case "$PLATFORM" in
    ios-simulator|ipados-simulator) return 0 ;;
    *) return 1 ;;
  esac
}

simulator_family_for_platform() {
  case "$PLATFORM" in
    ios-simulator) printf 'iPhone\n' ;;
    ipados-simulator) printf 'iPad\n' ;;
    *) printf '\n' ;;
  esac
}

products_dir_for_platform() {
  case "$PLATFORM" in
    ios-simulator|ipados-simulator)
      printf '%s\n' "$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphonesimulator"
      ;;
    macos)
      printf '%s\n' "$DERIVED_DATA/Build/Products/${CONFIGURATION}"
      ;;
  esac
}

destination_for_platform() {
  case "$PLATFORM" in
    ios-simulator|ipados-simulator)
      if [ -n "$SIMULATOR_ID" ]; then
        printf 'platform=iOS Simulator,id=%s\n' "$SIMULATOR_ID"
      else
        printf 'platform=iOS Simulator,name=%s\n' "$SIMULATOR_NAME"
      fi
      ;;
    macos)
      printf 'platform=macOS\n'
      ;;
  esac
}

resolve_simulator() {
  if ! is_simulator_platform || [ "$DRY_RUN" = "1" ]; then
    return 0
  fi

  local simctl_json
  simctl_json="$ARTIFACT_DIR/simulators.json"
  if ! xcrun simctl list devices available -j > "$simctl_json" 2> "$SIMCTL_LIST_LOG"; then
    summarize_preflight_failure "$SIMCTL_LIST_LOG" "$PREFLIGHT_DIAGNOSTICS_MD" "$PREFLIGHT_DIAGNOSTICS_JSON"
    return 1
  fi

  local family
  family="$(simulator_family_for_platform)"

  local selected
  if ! selected="$("$PYTHON_BIN" - "$simctl_json" "$family" "$SIMULATOR_NAME" "$SIMULATOR_ID" 2>> "$SIMCTL_LIST_LOG" <<'PY'
import json
import re
import sys

path, family, requested_name, requested_id = sys.argv[1:5]
data = json.load(open(path, encoding="utf-8"))

def runtime_version(runtime_key: str) -> tuple[int, ...]:
    match = re.search(r"iOS-([0-9-]+)$", runtime_key)
    if not match:
        return ()
    return tuple(int(part) for part in match.group(1).split("-") if part.isdigit())

devices = []
for runtime_key, runtime_devices in data.get("devices", {}).items():
    for device in runtime_devices:
        if not device.get("isAvailable", True):
            continue
        name = device.get("name", "")
        udid = device.get("udid", "")
        if family and not name.startswith(family):
            continue
        devices.append(
            {
                "name": name,
                "udid": udid,
                "runtime": runtime_key,
                "version": runtime_version(runtime_key),
            }
        )

if requested_id:
    matches = [device for device in devices if device["udid"] == requested_id]
elif requested_name and requested_name != "auto":
    matches = [device for device in devices if device["name"] == requested_name]
else:
    matches = devices

if not matches:
    requested = requested_id or requested_name or "auto"
    available = ", ".join(f'{device["name"]} ({device["runtime"].split(".")[-1]}, {device["udid"]})' for device in devices[:20])
    print(f"No available {family or 'iOS'} simulator matched {requested!r}. Available: {available}", file=sys.stderr)
    raise SystemExit(2)

matches.sort(key=lambda item: (item["version"], item["name"], item["udid"]), reverse=True)
chosen = matches[0]
print(f'{chosen["udid"]}\t{chosen["name"]}\t{chosen["runtime"]}')
PY
  )"; then
    summarize_preflight_failure "$SIMCTL_LIST_LOG" "$PREFLIGHT_DIAGNOSTICS_MD" "$PREFLIGHT_DIAGNOSTICS_JSON"
    return 1
  fi

  IFS="$(printf '\t')" read -r SIMULATOR_ID SIMULATOR_NAME SIMULATOR_RUNTIME <<EOF
$selected
EOF
}

write_preflight() {
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi

  local selected_developer_dir
  selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
  local xcode_version
  xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  local destination
  destination="$(destination_for_platform)"

  MUMBLE_PREFLIGHT_PLATFORM="$PLATFORM" \
  MUMBLE_PREFLIGHT_SCHEME="$SCHEME" \
  MUMBLE_PREFLIGHT_CONFIGURATION="$CONFIGURATION" \
  MUMBLE_PREFLIGHT_PROJECT="$PROJECT_PATH" \
  MUMBLE_PREFLIGHT_DERIVED_DATA="$DERIVED_DATA" \
  MUMBLE_PREFLIGHT_DESTINATION="$destination" \
  MUMBLE_PREFLIGHT_SIMULATOR_NAME="$SIMULATOR_NAME" \
  MUMBLE_PREFLIGHT_SIMULATOR_ID="$SIMULATOR_ID" \
  MUMBLE_PREFLIGHT_SIMULATOR_RUNTIME="$SIMULATOR_RUNTIME" \
  MUMBLE_PREFLIGHT_DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
  MUMBLE_PREFLIGHT_SELECTED_DEVELOPER_DIR="$selected_developer_dir" \
  MUMBLE_PREFLIGHT_XCODE_VERSION="$xcode_version" \
  MUMBLE_PREFLIGHT_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    "$PYTHON_BIN" - "$PREFLIGHT_JSON" <<PY
import json
import os
import sys
from datetime import datetime, timezone

path = sys.argv[1]
preflight = {
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "platform": os.environ.get("MUMBLE_PREFLIGHT_PLATFORM", ""),
    "scheme": os.environ.get("MUMBLE_PREFLIGHT_SCHEME", ""),
    "configuration": os.environ.get("MUMBLE_PREFLIGHT_CONFIGURATION", ""),
    "project": os.environ.get("MUMBLE_PREFLIGHT_PROJECT", ""),
    "derivedData": os.environ.get("MUMBLE_PREFLIGHT_DERIVED_DATA", ""),
    "destination": os.environ.get("MUMBLE_PREFLIGHT_DESTINATION", ""),
    "simulator": {
        "name": os.environ.get("MUMBLE_PREFLIGHT_SIMULATOR_NAME", ""),
        "id": os.environ.get("MUMBLE_PREFLIGHT_SIMULATOR_ID", ""),
        "runtime": os.environ.get("MUMBLE_PREFLIGHT_SIMULATOR_RUNTIME", ""),
    },
    "xcode": {
        "developerDir": os.environ.get("MUMBLE_PREFLIGHT_DEVELOPER_DIR", ""),
        "selectedDeveloperDir": os.environ.get("MUMBLE_PREFLIGHT_SELECTED_DEVELOPER_DIR", ""),
        "version": os.environ.get("MUMBLE_PREFLIGHT_XCODE_VERSION", ""),
    },
    "deploymentTarget": os.environ.get("MUMBLE_PREFLIGHT_DEPLOYMENT_TARGET", ""),
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(preflight, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

find_app_path() {
  local products_dir
  products_dir="$(products_dir_for_platform)"
  local app_path="$products_dir/${PRODUCT_NAME}.app"
  if [ ! -d "$products_dir" ]; then
    return 0
  fi
  if [ -d "$app_path" ]; then
    printf '%s\n' "$app_path"
    return 0
  fi
  find "$products_dir" -maxdepth 3 -type d -name "${PRODUCT_NAME}.app" -print -quit
}

build_app() {
  local destination
  destination="$(destination_for_platform)"
  if is_simulator_platform; then
    if [ "${#EXTRA_XCODEBUILD_ARGS[@]}" -gt 0 ]; then
      run_logged "$BUILD_LOG" \
        xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -sdk iphonesimulator \
        -destination "$destination" \
        -derivedDataPath "$DERIVED_DATA" \
        IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        "${EXTRA_XCODEBUILD_ARGS[@]}" \
        build
    else
      run_logged "$BUILD_LOG" \
        xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -sdk iphonesimulator \
        -destination "$destination" \
        -derivedDataPath "$DERIVED_DATA" \
        IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        build
    fi
  else
    if [ "${#EXTRA_XCODEBUILD_ARGS[@]}" -gt 0 ]; then
      run_logged "$BUILD_LOG" \
        xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$destination" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        "${EXTRA_XCODEBUILD_ARGS[@]}" \
        build
    else
      run_logged "$BUILD_LOG" \
        xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$destination" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        build
    fi
  fi
}

analyze_evidence() {
  local evidence_path="$1"
  local report_path="$2"
  if [ "$SCENARIO" = "all" ]; then
    "$PYTHON_BIN" Scripts/mumble_trace_analyze.py "$evidence_path"/*.jsonl \
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
      --require-command app.refreshModel \
      --require-network-snapshot \
      --require-command performance.reset \
      --require-command performance.status \
      --require-perf-marker agent_probe.marker \
      --require-perf-marker ui_performance_sampling.samples \
      > "$report_path"
  else
    "$PYTHON_BIN" Scripts/mumble_trace_analyze.py "$evidence_path" \
      --markdown \
      --budget-file Tests/Baselines/performance_budgets.json \
      --require-provenance \
      --require-event log.entry \
      --require-command log.stream \
      --require-command log.marker \
      --require-command log.recent \
      --require-command network.status \
      --require-command network.injectUDPStatus \
      --require-command app.simulateLifecycle \
      --require-network-snapshot \
      --require-command performance.reset \
      --require-command performance.status \
      --require-perf-marker agent_probe.marker \
      > "$report_path"
  fi
}

stop_app() {
  if [ "$KEEP_APP_RUNNING" = "1" ] || [ "$SKIP_LAUNCH" = "1" ] || [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if is_simulator_platform; then
    xcrun simctl terminate "${SIMULATOR_ID:-$SIMULATOR_NAME}" "$BUNDLE_ID" >/dev/null 2>&1 || true
  elif [ -n "$APP_PID" ]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}

launch_simulator_app() {
  local simulator_target="${SIMULATOR_ID:-$SIMULATOR_NAME}"
  run_cmd xcrun simctl boot "$simulator_target" || true
  run_cmd xcrun simctl bootstatus "$simulator_target" -b
  run_cmd xcrun simctl install "$simulator_target" "$APP_PATH"
  grant_simulator_microphone_permission
  log "launching $BUNDLE_ID"
  if [ "$DRY_RUN" != "1" ]; then
    {
      SIMCTL_CHILD_MUMBLE_LOG_LEVEL=debug \
      SIMCTL_CHILD_MUMBLE_LOG_VERBOSE=Connection,Network,Audio,Plugin,UI,Model \
      SIMCTL_CHILD_MUMBLE_LOG_FILE=1 \
      xcrun simctl launch --terminate-running-process "$simulator_target" "$BUNDLE_ID"
    } 2>&1 | tee "$LAUNCH_LOG"
  else
    log "SIMCTL_CHILD_MUMBLE_LOG_LEVEL=debug SIMCTL_CHILD_MUMBLE_LOG_VERBOSE=Connection,Network,Audio,Plugin,UI,Model SIMCTL_CHILD_MUMBLE_LOG_FILE=1 xcrun simctl launch --terminate-running-process $simulator_target $BUNDLE_ID | tee $LAUNCH_LOG"
  fi
}

launch_macos_app() {
  local executable_name="$PRODUCT_NAME"
  if [ -f "$APP_PATH/Contents/Info.plist" ]; then
    executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null || printf '%s' "$PRODUCT_NAME")"
  fi
  local executable="$APP_PATH/Contents/MacOS/$executable_name"
  log "launching macOS app $executable"
  if [ "$DRY_RUN" = "1" ]; then
    log "env MUMBLE_LOG_LEVEL=debug MUMBLE_LOG_VERBOSE=Connection,Network,Audio,Plugin,UI,Model MUMBLE_LOG_FILE=1 $executable > $LAUNCH_LOG 2>&1 &"
    return 0
  fi
  if [ ! -x "$executable" ]; then
    echo "Unable to execute macOS app binary at $executable" >&2
    return 1
  fi
  (
    export MUMBLE_LOG_LEVEL=debug
    export MUMBLE_LOG_VERBOSE=Connection,Network,Audio,Plugin,UI,Model
    export MUMBLE_LOG_FILE=1
    "$executable"
  ) > "$LAUNCH_LOG" 2>&1 &
  APP_PID=$!
  log "macOS app pid: $APP_PID"
}

mkdir -p "$ARTIFACT_DIR"
trap stop_app EXIT

BUILD_LOG="$ARTIFACT_DIR/xcodebuild.log"
BUILD_DIAGNOSTICS_MD="$ARTIFACT_DIR/build-diagnostics.md"
BUILD_DIAGNOSTICS_JSON="$ARTIFACT_DIR/build-diagnostics.json"
PREFLIGHT_JSON="$ARTIFACT_DIR/preflight.json"
PREFLIGHT_DIAGNOSTICS_MD="$ARTIFACT_DIR/preflight-diagnostics.md"
PREFLIGHT_DIAGNOSTICS_JSON="$ARTIFACT_DIR/preflight-diagnostics.json"
SIMCTL_LIST_LOG="$ARTIFACT_DIR/simctl-list.log"
LAUNCH_LOG="$ARTIFACT_DIR/app-launch.log"
PRIVACY_LOG="$ARTIFACT_DIR/simctl-privacy.log"
PRIVACY_JSON="$ARTIFACT_DIR/simctl-privacy.json"
REPORT_PATH="$ARTIFACT_DIR/report.md"
RUN_MANIFEST_JSON="$ARTIFACT_DIR/run-manifest.json"
initialize_privacy_status

if [ "$SCENARIO" = "all" ]; then
  EVIDENCE_PATH="$ARTIFACT_DIR/suite"
else
  EVIDENCE_PATH="$ARTIFACT_DIR/${SCENARIO}.jsonl"
fi

log "artifacts: $ARTIFACT_DIR"
log "platform: $PLATFORM"
if is_simulator_platform; then
  if ! resolve_simulator; then
    write_manifest "failed" "simulator-preflight" "Simulator preflight failed before app build or launch." "$PREFLIGHT_DIAGNOSTICS_JSON" "$PREFLIGHT_DIAGNOSTICS_MD"
    exit 1
  fi
  write_preflight
  log "simulator: $SIMULATOR_NAME"
  if [ -n "$SIMULATOR_ID" ]; then
    log "simulator id: $SIMULATOR_ID"
  fi
  if [ -n "$SIMULATOR_RUNTIME" ]; then
    log "simulator runtime: $SIMULATOR_RUNTIME"
  fi
else
  write_preflight
fi
log "scenario: $SCENARIO repeat=$REPEAT"

if [ "$PREFLIGHT_ONLY" = "1" ]; then
  log "preflight: $PREFLIGHT_JSON"
  write_manifest "passed" "preflight" "Preflight completed without building or launching the app."
  exit 0
fi

if [ "$SKIP_BUILD" != "1" ]; then
  if ! build_app; then
    summarize_build_failure "$BUILD_LOG" "$BUILD_DIAGNOSTICS_MD" "$BUILD_DIAGNOSTICS_JSON"
    write_manifest "failed" "build" "xcodebuild failed before app launch." "$BUILD_DIAGNOSTICS_JSON" "$BUILD_DIAGNOSTICS_MD"
    exit 1
  fi
fi

APP_PATH="$(find_app_path || true)"
if [ -z "$APP_PATH" ] && [ "$DRY_RUN" = "1" ]; then
  APP_PATH="$(products_dir_for_platform)/${PRODUCT_NAME}.app"
fi
if [ -z "$APP_PATH" ] && [ "$DRY_RUN" != "1" ]; then
  echo "Unable to find ${PRODUCT_NAME}.app under $DERIVED_DATA" >&2
  write_manifest "failed" "app-lookup" "Built app bundle could not be found under DerivedData."
  exit 1
fi

if [ "$SKIP_LAUNCH" != "1" ]; then
  if is_simulator_platform; then
    if ! launch_simulator_app; then
      write_manifest "failed" "launch" "Simulator app launch failed."
      exit 1
    fi
  else
    if ! launch_macos_app; then
      write_manifest "failed" "launch" "macOS app launch failed."
      exit 1
    fi
  fi
fi

read -r HOST PORT <<EOF
$(url_host_port)
EOF

if [ "$DRY_RUN" != "1" ]; then
  if ! wait_for_test_server "$HOST" "$PORT"; then
    write_manifest "failed" "test-server-wait" "Timed out waiting for MUTestServer."
    exit 1
  fi
fi

if ! run_cmd "$PYTHON_BIN" Scripts/mumble_agent_probe.py \
    --url "$URL" \
    --scenario "$SCENARIO" \
    --repeat "$REPEAT" \
    --output "$EVIDENCE_PATH"; then
  write_manifest "failed" "probe" "MUTestServer probe failed."
  exit 1
fi

if [ "$DRY_RUN" != "1" ]; then
  if ! analyze_evidence "$EVIDENCE_PATH" "$REPORT_PATH"; then
    write_manifest "failed" "analyze" "Probe evidence analysis failed."
    exit 1
  fi
  log "report: $REPORT_PATH"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$REPORT_PATH" ]; then
    {
      echo "## Mumble Real-App Probe"
      echo
      cat "$REPORT_PATH"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  write_manifest "passed" "dry-run" "Dry run completed command planning without executing build, launch, or probe commands."
else
  write_manifest "passed" "complete" "Real-app probe completed and evidence report was generated."
fi
