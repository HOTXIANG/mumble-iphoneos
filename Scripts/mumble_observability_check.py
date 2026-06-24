#!/usr/bin/env python3
"""Static observability policy checks for first-party Mumble sources."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SOURCE_ROOTS = ["Source", "MumbleKit/src", "MumbleWidget"]
SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".h"}
IGNORED_PATH_PARTS = {".git", "DerivedData", "build", "__pycache__"}
BARE_NSLOG_RE = re.compile(r"\bNSLog\s*\(")
PRINT_RE = re.compile(r"\bprint\s*\(")
PERF_RE = re.compile(r"\bPERF\s+([A-Za-z0-9_.:-]+)")
KV_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


@dataclass(frozen=True)
class Violation:
    rule: str
    path: str
    line: int
    excerpt: str
    fingerprint: str

    def to_json(self) -> dict[str, Any]:
        return {
            "rule": self.rule,
            "path": self.path,
            "line": self.line,
            "excerpt": self.excerpt,
            "fingerprint": self.fingerprint,
        }


def repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def source_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for source_root in SOURCE_ROOTS:
        base = root / source_root
        if not base.exists():
            continue
        for path in base.rglob("*"):
            if path.suffix not in SOURCE_SUFFIXES:
                continue
            if any(part in IGNORED_PATH_PARTS for part in path.parts):
                continue
            files.append(path)
    return sorted(files)


def scan(root: Path) -> list[Violation]:
    violations: list[Violation] = []
    for path in source_files(root):
        relative = path.relative_to(root).as_posix()
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for index, line in enumerate(lines, start=1):
            stripped = line.strip()
            if not stripped or stripped.startswith("//"):
                continue
            if PRINT_RE.search(line):
                violations.append(make_violation("no_print", relative, index, stripped))
            if BARE_NSLOG_RE.search(line):
                violations.append(make_violation("no_bare_nslog", relative, index, stripped))
            if "PERF " in line and not is_valid_perf_line(line):
                violations.append(make_violation("perf_log_format", relative, index, stripped))
    return violations


def collect_perf_markers(root: Path) -> dict[str, int]:
    markers: dict[str, int] = {}
    for path in source_files(root):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for line in lines:
            if "PERF " not in line or not is_valid_perf_line(line):
                continue
            match = PERF_RE.search(line)
            if not match:
                continue
            marker = match.group(1)
            markers[marker] = markers.get(marker, 0) + 1
    return dict(sorted(markers.items()))


def missing_perf_markers(markers: dict[str, int], required: list[str]) -> list[str]:
    return sorted({marker for marker in required if marker not in markers})


def is_valid_perf_line(line: str) -> bool:
    return bool(PERF_RE.search(line) and KV_RE.search(line))


def make_violation(rule: str, path: str, line: int, excerpt: str) -> Violation:
    normalized = re.sub(r"\s+", " ", excerpt.strip())
    identity = f"{rule}\0{path}\0{normalized}"
    fingerprint = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:16]
    return Violation(rule=rule, path=path, line=line, excerpt=normalized[:220], fingerprint=fingerprint)


def load_baseline(path: Path | None) -> dict[str, dict[str, Any]]:
    if path is None:
        return {}
    if not path.exists():
        raise FileNotFoundError(f"Baseline does not exist: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    entries = data.get("violations", [])
    if not isinstance(entries, list):
        raise ValueError("Baseline field 'violations' must be an array")
    return {
        str(entry["fingerprint"]): entry
        for entry in entries
        if isinstance(entry, dict) and "fingerprint" in entry
    }


def write_baseline(path: Path, violations: list[Violation]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": 1,
        "description": "Known observability-policy violations. Do not add entries unless accepting existing debt intentionally.",
        "violations": [violation.to_json() for violation in sorted_violations(violations)],
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sorted_violations(violations: list[Violation]) -> list[Violation]:
    return sorted(violations, key=lambda item: (item.rule, item.path, item.line, item.fingerprint))


def compare_to_baseline(
    violations: list[Violation], baseline: dict[str, dict[str, Any]]
) -> tuple[list[Violation], list[dict[str, Any]]]:
    current = {violation.fingerprint: violation for violation in violations}
    new = [violation for violation in violations if violation.fingerprint not in baseline]
    resolved = [entry for fingerprint, entry in baseline.items() if fingerprint not in current]
    return sorted_violations(new), sorted(resolved, key=lambda item: (item.get("rule", ""), item.get("path", "")))


def print_text(
    violations: list[Violation],
    new: list[Violation],
    resolved: list[dict[str, Any]],
    baseline: Path | None,
    markers: dict[str, int],
    missing_markers: list[str],
) -> None:
    print(f"observability violations: {len(violations)}")
    if baseline:
        print(f"baseline: {baseline}")
        print(f"new violations: {len(new)}")
        print(f"resolved baseline entries: {len(resolved)}")
    by_rule: dict[str, int] = {}
    for violation in violations:
        by_rule[violation.rule] = by_rule.get(violation.rule, 0) + 1
    for rule, count in sorted(by_rule.items()):
        print(f"  {rule}: {count}")
    print(f"PERF markers: {len(markers)}")
    for marker, count in markers.items():
        print(f"  {marker}: {count}")
    if missing_markers:
        print("")
        print("missing required PERF markers:")
        for marker in missing_markers:
            print(f"  {marker}")

    if new:
        print("")
        print("new violations:")
        for violation in sorted_violations(new):
            print(f"  {violation.rule} {violation.path}:{violation.line} {violation.excerpt}")

    if resolved:
        print("")
        print("resolved baseline entries:")
        for entry in resolved:
            print(f"  {entry.get('rule')} {entry.get('path')} {entry.get('excerpt')}")


def to_json(
    violations: list[Violation],
    new: list[Violation],
    resolved: list[dict[str, Any]],
    baseline: Path | None,
    markers: dict[str, int],
    missing_markers: list[str],
) -> dict[str, Any]:
    return {
        "baseline": str(baseline) if baseline else None,
        "violationCount": len(violations),
        "newViolationCount": len(new),
        "resolvedBaselineCount": len(resolved),
        "violationsByRule": count_by_rule(violations),
        "perfMarkers": markers,
        "missingPerfMarkers": missing_markers,
        "newViolations": [violation.to_json() for violation in sorted_violations(new)],
        "resolvedBaselineEntries": resolved,
    }


def count_by_rule(violations: list[Violation]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for violation in violations:
        counts[violation.rule] = counts.get(violation.rule, 0) + 1
    return dict(sorted(counts.items()))


def run_self_test() -> int:
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        source = root / "Source" / "Example.swift"
        source.parent.mkdir(parents=True)
        source.write_text(
            "\n".join(
                [
                    "import Foundation",
                    "print(\"debug\")",
                    "NSLog(\"debug\")",
                    "MumbleLogger.ui.debug(\"PERF render elapsed_ms=12.3\")",
                    "MumbleLogger.ui.debug(\"PERF broken\")",
                ]
            ),
            encoding="utf-8",
        )
        violations = scan(root)
        markers = collect_perf_markers(root)
        if len(violations) != 3:
            print(f"expected 3 violations, found {len(violations)}", file=sys.stderr)
            return 1
        if markers != {"render": 1}:
            print(f"expected render marker only, found {markers}", file=sys.stderr)
            return 1
        baseline = root / "Tests" / "Baselines" / "observability_allowlist.json"
        write_baseline(baseline, violations[:2])
        known = load_baseline(baseline)
        new, resolved = compare_to_baseline(violations, known)
        missing_markers = missing_perf_markers(markers, ["render", "connect_ready"])
        if len(new) != 1 or resolved or missing_markers != ["connect_ready"]:
            print(json.dumps(to_json(violations, new, resolved, baseline, markers, missing_markers), indent=2), file=sys.stderr)
            return 1
    print("passed: observability check self-test")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check first-party source observability policy.")
    parser.add_argument("--baseline", type=Path, help="JSON allowlist for existing violations")
    parser.add_argument("--update-baseline", type=Path, help="Write the current violation set to this baseline path")
    parser.add_argument(
        "--require-perf-marker",
        action="append",
        default=[],
        help="Fail unless this valid PERF marker is present in first-party source. Repeat as needed.",
    )
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    parser.add_argument("--self-test", action="store_true", help="Validate scanner and baseline comparison")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()

    root = repository_root()
    violations = scan(root)
    markers = collect_perf_markers(root)
    missing_markers = missing_perf_markers(markers, args.require_perf_marker)

    if args.update_baseline:
        write_baseline(args.update_baseline, violations)

    baseline = load_baseline(args.baseline) if args.baseline else {}
    new, resolved = compare_to_baseline(violations, baseline)

    if args.json:
        print(
            json.dumps(
                to_json(violations, new, resolved, args.baseline, markers, missing_markers),
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
        )
    else:
        print_text(violations, new, resolved, args.baseline, markers, missing_markers)

    return 1 if new or resolved or missing_markers else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
