#!/usr/bin/env python3
"""Check that probe scenarios, gates, docs, and budgets stay in sync."""

from __future__ import annotations

import ast
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "Scripts" / "mumble_agent_probe.py"
AUTOMATION_CHECK = ROOT / "Scripts" / "mumble_automation_check.sh"
REAL_APP_PROBE = ROOT / "Scripts" / "mumble_real_app_probe.sh"
TESTING_DOC = ROOT / "docs" / "TESTING.md"
PERFORMANCE_BUDGETS = ROOT / "Tests" / "Baselines" / "performance_budgets.json"
PROJECT_FILE = ROOT / "Mumble.xcodeproj" / "project.pbxproj"

REQUIRED_SUITE_COMMANDS = {
    "log.stream",
    "log.marker",
    "log.recent",
    "network.status",
    "network.injectUDPStatus",
    "app.refreshModel",
    "app.simulateLifecycle",
    "performance.reset",
    "performance.status",
}

REQUIRED_SUITE_MARKERS = {
    "agent_probe.marker",
    "ui_performance_sampling.samples",
}

REQUIRED_UI_PERFORMANCE_BUDGETS = {
    "scenarioBudgets": {"ui-performance-sampling", "network-udp-degraded", "network-udp-toast-throttle", "lifecycle-idle-audio"},
    "commandBudgets": {"app.refreshModel", "performance.status", "state.get", "ui.get", "app.get"},
}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def probe_scenarios() -> list[str]:
    tree = ast.parse(read(PROBE), filename=str(PROBE))
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == "SCENARIOS":
                    value = ast.literal_eval(node.value)
                    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                        raise AssertionError("SCENARIOS must be a list[str]")
                    return value
    raise AssertionError("SCENARIOS assignment not found")


def required_scenarios(text: str) -> set[str]:
    scenarios: set[str] = set()
    for line in text.splitlines():
        stripped = line.strip()
        prefix = "--require-scenario "
        if stripped.startswith(prefix):
            scenarios.add(stripped.removeprefix(prefix).split()[0])
    return scenarios


def required_commands(text: str) -> set[str]:
    commands: set[str] = set()
    for line in text.splitlines():
        stripped = line.strip()
        prefix = "--require-command "
        if stripped.startswith(prefix):
            commands.add(stripped.removeprefix(prefix).split()[0])
    return commands


def required_markers(text: str) -> set[str]:
    markers: set[str] = set()
    for line in text.splitlines():
        stripped = line.strip()
        prefix = "--require-perf-marker "
        if stripped.startswith(prefix):
            markers.add(stripped.removeprefix(prefix).split()[0])
    return markers


def doc_scenarios(text: str) -> set[str]:
    scenarios: set[str] = set()
    for line in text.splitlines():
        if line.startswith("| `"):
            parts = line.split("|")
            if len(parts) > 2:
                name = parts[1].strip().strip("`")
                if name and name != "场景":
                    scenarios.add(name)
    return scenarios


def budget_selectors(data: dict[str, Any], key: str, selector: str) -> set[str]:
    values = data.get(key, [])
    if not isinstance(values, list):
        raise AssertionError(f"{PERFORMANCE_BUDGETS}: {key} must be a list")
    selectors: set[str] = set()
    for item in values:
        if not isinstance(item, dict):
            raise AssertionError(f"{PERFORMANCE_BUDGETS}: {key} entries must be objects")
        value = item.get(selector)
        if isinstance(value, str):
            selectors.add(value)
    return selectors


def assert_contains(label: str, observed: set[str], expected: set[str]) -> None:
    missing = sorted(expected - observed)
    if missing:
        present = ", ".join(sorted(observed)) or "none"
        raise AssertionError(f"{label} missing {missing}; present={present}")


def assert_no_legacy_icon_resources(project_text: str) -> None:
    legacy_entries = [
        line.strip()
        for line in project_text.splitlines()
        if "NeoMumble.icon in Resources" in line
    ]
    if legacy_entries:
        raise AssertionError(
            "project file still compiles legacy NeoMumble.icon as a target resource; "
            f"entries={legacy_entries}"
        )


def main() -> int:
    scenarios = set(probe_scenarios())
    automation_text = read(AUTOMATION_CHECK)
    real_app_text = read(REAL_APP_PROBE)
    doc_text = read(TESTING_DOC)
    budgets = json.loads(read(PERFORMANCE_BUDGETS))
    project_text = read(PROJECT_FILE)

    assert_contains("automation_check required scenarios", required_scenarios(automation_text), scenarios)
    assert_contains("real_app_probe required scenarios", required_scenarios(real_app_text), scenarios)
    assert_contains("docs TESTING scenario table", doc_scenarios(doc_text), scenarios)

    for label, text in [
        ("automation_check", automation_text),
        ("real_app_probe", real_app_text),
    ]:
        assert_contains(f"{label} required commands", required_commands(text), REQUIRED_SUITE_COMMANDS)
        assert_contains(f"{label} required PERF markers", required_markers(text), REQUIRED_SUITE_MARKERS)

    assert_contains(
        "performance_budgets scenarioBudgets",
        budget_selectors(budgets, "scenarioBudgets", "scenario"),
        REQUIRED_UI_PERFORMANCE_BUDGETS["scenarioBudgets"],
    )
    assert_contains(
        "performance_budgets commandBudgets",
        budget_selectors(budgets, "commandBudgets", "action"),
        REQUIRED_UI_PERFORMANCE_BUDGETS["commandBudgets"],
    )
    assert_no_legacy_icon_resources(project_text)

    print(
        "passed: automation consistency "
        f"scenarios={len(scenarios)} commands={len(REQUIRED_SUITE_COMMANDS)} markers={len(REQUIRED_SUITE_MARKERS)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
