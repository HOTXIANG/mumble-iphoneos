#!/usr/bin/env python3
"""Summarize real-app probe run manifests."""

from __future__ import annotations

import argparse
import json
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any


def load_manifest(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schemaVersion") != 1:
        raise ValueError(f"{path}: unsupported manifest schemaVersion={data.get('schemaVersion')!r}")
    data["_manifestPath"] = str(path)
    return data


def discover_manifests(paths: list[Path]) -> list[Path]:
    if not paths:
        paths = [Path("Tests/Artifacts")]

    manifests: list[Path] = []
    for path in paths:
        if path.is_file():
            manifests.append(path)
        elif path.is_dir():
            manifests.extend(path.rglob("run-manifest.json"))
        else:
            raise FileNotFoundError(path)

    return sorted(set(manifests))


def summarize(manifests: list[dict[str, Any]]) -> dict[str, Any]:
    statuses = Counter(str(item.get("status", "unknown")) for item in manifests)
    phases = Counter(str(item.get("phase", "unknown")) for item in manifests)
    classifications: Counter[str] = Counter()
    microphone_privacy_statuses: Counter[str] = Counter()
    environment_limited = 0

    rows: list[dict[str, Any]] = []
    for item in manifests:
        diagnostics = item.get("diagnostics") or {}
        classification = str(diagnostics.get("classification") or "none")
        classifications[classification] += 1
        env_limited = bool(diagnostics.get("environmentLimited"))
        if env_limited:
            environment_limited += 1

        configuration = item.get("configuration") or {}
        simulator = item.get("simulator") or {}
        privacy = item.get("privacy") or {}
        microphone_privacy = privacy.get("microphone") or {}
        microphone_privacy_status = str(microphone_privacy.get("status") or "unknown")
        microphone_privacy_statuses[microphone_privacy_status] += 1
        rows.append(
            {
                "status": item.get("status", "unknown"),
                "phase": item.get("phase", "unknown"),
                "platform": configuration.get("platform", ""),
                "scenario": configuration.get("scenario", ""),
                "repeat": configuration.get("repeat", 0),
                "simulator": simulator.get("name") or simulator.get("id") or "",
                "classification": classification,
                "environmentLimited": env_limited,
                "microphonePrivacyStatus": microphone_privacy_status,
                "microphonePrivacySummary": microphone_privacy.get("summary", ""),
                "summary": item.get("summary", ""),
                "manifest": item.get("_manifestPath", ""),
            }
        )

    return {
        "manifestCount": len(manifests),
        "passed": statuses.get("passed", 0),
        "failed": statuses.get("failed", 0),
        "environmentLimited": environment_limited,
        "statuses": dict(sorted(statuses.items())),
        "phases": dict(sorted(phases.items())),
        "classifications": dict(sorted(classifications.items())),
        "microphonePrivacyStatuses": dict(sorted(microphone_privacy_statuses.items())),
        "runs": sorted(rows, key=lambda row: (row["status"] != "failed", row["phase"], row["manifest"])),
    }


def markdown_escape(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def write_markdown(summary: dict[str, Any]) -> str:
    lines = [
        "# Mumble Real-App Manifest Summary",
        "",
        f"- Manifests: `{summary['manifestCount']}`",
        f"- Passed: `{summary['passed']}`",
        f"- Failed: `{summary['failed']}`",
        f"- Environment-limited: `{summary['environmentLimited']}`",
        "",
        "## Counts",
        "",
        "| Kind | Values |",
        "|------|--------|",
        f"| Status | {markdown_escape(summary['statuses'])} |",
        f"| Phase | {markdown_escape(summary['phases'])} |",
        f"| Classification | {markdown_escape(summary['classifications'])} |",
        f"| Microphone Privacy | {markdown_escape(summary['microphonePrivacyStatuses'])} |",
        "",
        "## Runs",
        "",
        "| Status | Phase | Platform | Scenario | Classification | Env Limited | Mic Privacy | Summary | Manifest |",
        "|--------|-------|----------|----------|----------------|-------------|-------------|---------|----------|",
    ]
    for row in summary["runs"]:
        lines.append(
            "| "
            + " | ".join(
                [
                    f"`{markdown_escape(row['status'])}`",
                    f"`{markdown_escape(row['phase'])}`",
                    markdown_escape(row["platform"]),
                    markdown_escape(row["scenario"]),
                    f"`{markdown_escape(row['classification'])}`",
                    f"`{str(row['environmentLimited']).lower()}`",
                    f"`{markdown_escape(row['microphonePrivacyStatus'])}`",
                    markdown_escape(row["summary"]),
                    f"`{markdown_escape(row['manifest'])}`",
                ]
            )
            + " |"
        )
    return "\n".join(lines) + "\n"


def run_self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        samples = [
            {
                "schemaVersion": 1,
                "status": "passed",
                "phase": "dry-run",
                "summary": "Dry run completed.",
                "configuration": {"platform": "ios-simulator", "scenario": "baseline", "repeat": 1},
                "simulator": {"name": "auto"},
                "privacy": {"microphone": {"status": "planned", "summary": "Would grant microphone permission."}},
                "diagnostics": {},
            },
            {
                "schemaVersion": 1,
                "status": "failed",
                "phase": "simulator-preflight",
                "summary": "Simulator preflight failed.",
                "configuration": {"platform": "ios-simulator", "scenario": "all", "repeat": 2},
                "simulator": {"name": "auto"},
                "privacy": {"microphone": {"status": "not-applicable", "summary": "Preflight failed before install."}},
                "diagnostics": {"classification": "coresimulator_environment", "environmentLimited": True},
            },
            {
                "schemaVersion": 1,
                "status": "failed",
                "phase": "build",
                "summary": "xcodebuild failed.",
                "configuration": {"platform": "macos", "scenario": "baseline", "repeat": 1},
                "simulator": {},
                "privacy": {"microphone": {"status": "not-applicable", "summary": "Not a simulator platform."}},
                "diagnostics": {"classification": "actool_asset_catalog", "environmentLimited": False},
            },
        ]
        for index, sample in enumerate(samples, start=1):
            run_dir = root / f"run-{index}"
            run_dir.mkdir()
            (run_dir / "run-manifest.json").write_text(
                json.dumps(sample, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

        manifest_paths = discover_manifests([root])
        summary = summarize([load_manifest(path) for path in manifest_paths])
        assert summary["manifestCount"] == 3
        assert summary["passed"] == 1
        assert summary["failed"] == 2
        assert summary["environmentLimited"] == 1
        assert summary["classifications"]["coresimulator_environment"] == 1
        assert summary["microphonePrivacyStatuses"]["planned"] == 1
        assert summary["microphonePrivacyStatuses"]["not-applicable"] == 2
        markdown = write_markdown(summary)
        assert "simulator-preflight" in markdown
        assert "actool_asset_catalog" in markdown
        assert "Microphone Privacy" in markdown
        assert "`planned`" in markdown
    print("passed: manifest summarize self-test")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path, help="Manifest files or directories to scan")
    parser.add_argument("--markdown", action="store_true", help="Write Markdown instead of JSON")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    manifest_paths = discover_manifests(args.paths)
    summary = summarize([load_manifest(path) for path in manifest_paths])
    if args.markdown:
        print(write_markdown(summary), end="")
    else:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
