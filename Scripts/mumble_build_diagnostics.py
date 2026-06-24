#!/usr/bin/env python3
"""Extract a concise build-failure diagnosis from xcodebuild logs."""

from __future__ import annotations

import argparse
import json
import re
import tempfile
from pathlib import Path
from typing import Any


PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        "actool_asset_catalog",
        re.compile(r"(couldn.t be opened|com\.apple\.actool\.errors|Exception while running actool)", re.I),
    ),
    (
        "swift_macro_plugin_environment",
        re.compile(r"(swift-plugin-server produced malformed response|external macro implementation type .* could not be found|sandbox-exec: sandbox_apply: Operation not permitted)", re.I),
    ),
    ("compiler_error", re.compile(r"(^|\s)error:", re.I)),
    ("linker_error", re.compile(r"((^|\s)ld:|linker command failed|Undefined symbols)", re.I)),
    ("signing_error", re.compile(r"(codesign|CodeSign|Provisioning profile|requires a provisioning profile|entitlements?)", re.I)),
    ("coresimulator_environment", re.compile(r"(CoreSimulatorService|simdiskimaged|Simulator services)", re.I)),
    ("failed_command", re.compile(r"(The following build commands failed|BUILD FAILED|\(\d+ failures?\))", re.I)),
]

CLASSIFICATION_PRIORITY = [
    "actool_asset_catalog",
    "swift_macro_plugin_environment",
    "compiler_error",
    "linker_error",
    "signing_error",
    "coresimulator_environment",
]

HIGHLIGHT_ORDER = [
    "actool_asset_catalog",
    "swift_macro_plugin_environment",
    "compiler_error",
    "linker_error",
    "signing_error",
    "failed_command",
    "coresimulator_environment",
]


DIAGNOSTIC_GUIDANCE: dict[str, dict[str, Any]] = {
    "actool_asset_catalog": {
        "summary": "Asset catalog compilation failed before the app binary was produced.",
        "environmentLimited": False,
        "nextActions": [
            "Open the highlighted asset path and verify the file or directory exists in the repository.",
            "Prefer a standard .appiconset inside Assets.xcassets for app icons instead of placing .icon bundles in Copy Bundle Resources.",
            "Rerun the same real-app probe after fixing the asset catalog to prove the build advances past actool.",
        ],
    },
    "swift_macro_plugin_environment": {
        "summary": "Swift macro/plugin execution failed in the local build environment.",
        "environmentLimited": True,
        "nextActions": [
            "Rerun the same command outside the sandboxed automation environment or with a stable Xcode toolchain.",
            "Keep this classified as an environment/toolchain blocker unless the same source errors reproduce in a normal Xcode build.",
            "Do not treat the real-app probe as product-verified until the app launches and MUTestServer evidence is collected.",
        ],
    },
    "compiler_error": {
        "summary": "The compiler reported source-level errors.",
        "environmentLimited": False,
        "nextActions": [
            "Fix the first source error in the highlights before investigating later cascading errors.",
            "Rerun the probe or xcodebuild command with the same scheme/configuration to confirm the compile phase is clear.",
        ],
    },
    "linker_error": {
        "summary": "The linker failed after compilation.",
        "environmentLimited": False,
        "nextActions": [
            "Check the highlighted undefined symbols or duplicate symbols and map them to target membership or linked library settings.",
            "Rerun with the same DerivedData path after fixing target membership or dependency linkage.",
        ],
    },
    "signing_error": {
        "summary": "Code signing, provisioning, or entitlement validation failed.",
        "environmentLimited": True,
        "nextActions": [
            "Confirm the probe is using CODE_SIGNING_ALLOWED=NO for simulator/local debug paths when signing is not needed.",
            "For macOS/device builds, inspect entitlements and provisioning state separately from product runtime behavior.",
        ],
    },
    "coresimulator_environment": {
        "summary": "The simulator service or simulator disk environment failed before app runtime evidence could be collected.",
        "environmentLimited": True,
        "nextActions": [
            "Retry after CoreSimulator services recover or use a fresh simulator runtime.",
            "Record this as environment-limited and avoid treating missing probe evidence as an app regression.",
        ],
    },
    "unknown": {
        "summary": "The build log did not match a known failure classifier.",
        "environmentLimited": False,
        "nextActions": [
            "Inspect the first failing xcodebuild command and add a classifier if this failure is expected to recur.",
            "Attach the full xcodebuild.log with the generated diagnostics when filing the issue.",
        ],
    },
}


def parse_context(items: list[str] | None) -> dict[str, str]:
    context: dict[str, str] = {}
    for item in items or []:
        if "=" not in item:
            raise ValueError(f"context entries must use key=value syntax: {item}")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"context key cannot be empty: {item}")
        context[key] = value
    return context


def parse_log(log_path: Path, context: dict[str, str] | None = None) -> dict[str, Any]:
    text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
    lines = text.splitlines()
    matches: dict[str, list[dict[str, object]]] = {name: [] for name, _ in PATTERNS}
    for index, line in enumerate(lines, start=1):
        for name, pattern in PATTERNS:
            if pattern.search(line):
                matches[name].append({"line": index, "text": line[:600]})

    classification = "unknown"
    for candidate in CLASSIFICATION_PRIORITY:
        if matches[candidate]:
            classification = candidate
            break

    highlights: list[dict[str, object]] = []
    seen = set()
    for name in HIGHLIGHT_ORDER:
        selected = matches[name][-8:] if name == "actool_asset_catalog" else matches[name][:8]
        for item in selected:
            key = (item["line"], item["text"])
            if key in seen:
                continue
            seen.add(key)
            highlights.append({"kind": name, **item})

    guidance = DIAGNOSTIC_GUIDANCE.get(classification, DIAGNOSTIC_GUIDANCE["unknown"])
    return {
        "classification": classification,
        "rootCauseSummary": guidance["summary"],
        "environmentLimited": guidance["environmentLimited"],
        "nextActions": guidance["nextActions"],
        "context": context or {},
        "log": str(log_path),
        "lineCount": len(lines),
        "highlights": highlights,
        "counts": {name: len(items) for name, items in matches.items()},
    }


def markdown_escape(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def write_markdown(summary: dict[str, Any], path: Path) -> None:
    highlights = summary.get("highlights", [])
    counts = summary.get("counts", {})
    context = summary.get("context", {})
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        handle.write("# Mumble Real-App Build Diagnostics\n\n")
        handle.write(f"- Classification: `{summary.get('classification', 'unknown')}`\n")
        handle.write(f"- Root cause summary: {summary.get('rootCauseSummary', '')}\n")
        handle.write(f"- Environment limited: `{str(summary.get('environmentLimited', False)).lower()}`\n")
        handle.write(f"- Log: `{summary.get('log', '')}`\n")
        handle.write(f"- Lines: `{summary.get('lineCount', 0)}`\n\n")

        if context:
            handle.write("## Context\n\n")
            handle.write("| Key | Value |\n")
            handle.write("|-----|-------|\n")
            for key in sorted(context):
                handle.write(f"| `{markdown_escape(key)}` | `{markdown_escape(context[key])}` |\n")
            handle.write("\n")

        handle.write("## Next Actions\n\n")
        actions = summary.get("nextActions", [])
        if actions:
            for action in actions:
                handle.write(f"- {action}\n")
        else:
            handle.write("- Inspect the full xcodebuild log for the first failing command.\n")
        handle.write("\n")

        handle.write("## Highlights\n\n")
        handle.write("| Kind | Line | Text |\n")
        handle.write("|------|------|------|\n")
        if highlights:
            for item in highlights:
                handle.write(
                    f"| `{markdown_escape(item.get('kind', 'unknown'))}` | "
                    f"{item.get('line', '')} | {markdown_escape(item.get('text', ''))} |\n"
                )
        else:
            handle.write("| `none` |  | No matching failure highlights found. |\n")

        if counts:
            handle.write("\n## Match Counts\n\n")
            handle.write("| Kind | Count |\n")
            handle.write("|------|-------|\n")
            for key in sorted(counts):
                handle.write(f"| `{markdown_escape(key)}` | {counts[key]} |\n")


def write_json(summary: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_self_test() -> int:
    sample = "\n".join(
        [
            "CompileAssetCatalogVariant thinned /tmp/Mumble.app/Contents/Resources Resources/NeoMumble.icon Assets.xcassets",
            "The file “NeoMumble.icon” couldn’t be opened.",
            "/* com.apple.actool.errors */",
            "error: Exception while running actool: synthetic failure",
            "** BUILD FAILED **",
        ]
    )
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        log_path = root / "xcodebuild.log"
        markdown_path = root / "diagnostics.md"
        json_path = root / "diagnostics.json"
        log_path.write_text(sample, encoding="utf-8")
        summary = parse_log(log_path, {"platform": "macos", "scheme": "Mumble"})
        write_markdown(summary, markdown_path)
        write_json(summary, json_path)
        loaded = json.loads(json_path.read_text(encoding="utf-8"))
        assert loaded["classification"] == "actool_asset_catalog"
        assert loaded["environmentLimited"] is False
        assert loaded["context"]["platform"] == "macos"
        assert loaded["counts"]["actool_asset_catalog"] >= 3
        assert loaded["nextActions"]
        assert "NeoMumble.icon" in markdown_path.read_text(encoding="utf-8")

        macro_path = root / "macro.log"
        macro_path.write_text(
            "\n".join(
                [
                    "sandbox-exec: sandbox_apply: Operation not permitted",
                    "swift-plugin-server produced malformed response",
                    "external macro implementation type 'SwiftUI.StateMacro' could not be found",
                ]
            ),
            encoding="utf-8",
        )
        macro_summary = parse_log(macro_path)
        assert macro_summary["classification"] == "swift_macro_plugin_environment"
        assert macro_summary["environmentLimited"] is True

        simulator_path = root / "simulator.log"
        simulator_path.write_text(
            "\n".join(
                [
                    "CoreSimulatorService connection became invalid. Simulator services will no longer be available.",
                    "simdiskimaged crashed or is not responding",
                    "Unable to locate device set: Failed to initialize simulator device set.",
                ]
            ),
            encoding="utf-8",
        )
        simulator_summary = parse_log(simulator_path)
        assert simulator_summary["classification"] == "coresimulator_environment"
        assert simulator_summary["environmentLimited"] is True
    print("passed: build diagnostics self-test")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", nargs="?", help="xcodebuild log path")
    parser.add_argument("--markdown", required=False, help="Markdown output path")
    parser.add_argument("--json", required=False, help="JSON output path")
    parser.add_argument(
        "--context",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Add build context to diagnostics output (repeatable)",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()
    if not args.log:
        parser.error("log path is required unless --self-test is used")

    summary = parse_log(Path(args.log), parse_context(args.context))
    if args.markdown:
        write_markdown(summary, Path(args.markdown))
    if args.json:
        write_json(summary, Path(args.json))
    if not args.markdown and not args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
