#!/usr/bin/env python3
"""Compare before/after MUTestServer probe evidence."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import sys
import tempfile
from pathlib import Path
from typing import Any

import mumble_trace_analyze as analyze


def summarize(paths: list[Path]) -> dict[str, Any]:
    summary = analyze.parse_jsonl(paths)
    return {
        "files": [str(path) for path in paths],
        "failed": summary.failed,
        "records": summary.records,
        "scenarios": dict(summary.scenarios),
        "suiteScenarios": dict(summary.suite_scenarios),
        "perfStats": analyze.perf_stats(summary),
        "scenarioDuration": analyze.scenario_duration_stats(summary),
        "commandLatency": analyze.command_latency_stats(summary),
        "performance": analyze.performance_stats(summary),
        "network": analyze.network_stats(summary),
        "provenance": analyze.provenance_summary(summary),
        "failures": {
            "run": summary.run_failures,
            "command": summary.command_failures,
            "assertion": summary.assertion_failures,
            "coverage": summary.coverage_failures,
            "threshold": summary.threshold_failures,
            "malformed": summary.malformed_lines,
        },
    }


def compare(before: dict[str, Any], after: dict[str, Any], selectors: list[str]) -> dict[str, Any]:
    selected = selectors or common_selectors(before["perfStats"], after["perfStats"])
    metrics = [compare_selector(before, after, selector) for selector in selected]
    return {
        "before": before,
        "after": after,
        "metrics": metrics,
        "scenarioDuration": compare_scenario_duration(before["scenarioDuration"], after["scenarioDuration"]),
        "commandLatency": compare_command_latency(before["commandLatency"], after["commandLatency"]),
        "performance": compare_performance(before["performance"], after["performance"]),
        "network": compare_network(before["network"], after["network"]),
    }


def common_selectors(before_stats: dict[str, Any], after_stats: dict[str, Any]) -> list[str]:
    selectors: set[str] = set()
    for marker, metrics in before_stats.items():
        after_metrics = after_stats.get(marker, {})
        for metric in metrics:
            if metric in after_metrics:
                selectors.add(f"{marker}.{metric}")
    return sorted(selectors)


def compare_selector(before: dict[str, Any], after: dict[str, Any], selector: str) -> dict[str, Any]:
    marker, metric = split_selector(selector)
    before_value = metric_value(before["perfStats"], marker, metric)
    after_value = metric_value(after["perfStats"], marker, metric)
    delta = None if before_value is None or after_value is None else after_value - before_value
    percent = None
    if delta is not None and before_value not in (None, 0):
        percent = (delta / before_value) * 100.0
    return {
        "selector": selector,
        "beforeMax": before_value,
        "afterMax": after_value,
        "delta": delta,
        "deltaPercent": percent,
        "direction": classify_delta(delta),
    }


def compare_performance(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    stall_delta = int(after.get("maxStallCount", 0)) - int(before.get("maxStallCount", 0))
    lag_delta = float(after.get("maxLagMs", 0.0)) - float(before.get("maxLagMs", 0.0))
    return {
        "beforeMaxStallCount": before.get("maxStallCount", 0),
        "afterMaxStallCount": after.get("maxStallCount", 0),
        "stallCountDelta": stall_delta,
        "beforeMaxLagMs": before.get("maxLagMs", 0.0),
        "afterMaxLagMs": after.get("maxLagMs", 0.0),
        "lagMsDelta": lag_delta,
        "beforeMaxContext": before.get("maxContext", {}),
        "afterMaxContext": after.get("maxContext", {}),
        "beforeLatestContext": before.get("latestContext", {}),
        "afterLatestContext": after.get("latestContext", {}),
        "direction": classify_delta(lag_delta if lag_delta else float(stall_delta)),
    }


def compare_command_latency(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    before_max = numeric_value(before.get("maxMs"))
    after_max = numeric_value(after.get("maxMs"))
    max_delta = None if before_max is None or after_max is None else after_max - before_max
    actions = sorted(set(before.get("actions", {})) | set(after.get("actions", {})))
    action_deltas = []
    for action in actions:
        before_action = before.get("actions", {}).get(action, {})
        after_action = after.get("actions", {}).get(action, {})
        before_action_max = numeric_value(before_action.get("max"))
        after_action_max = numeric_value(after_action.get("max"))
        delta = None if before_action_max is None or after_action_max is None else after_action_max - before_action_max
        action_deltas.append(
            {
                "action": action,
                "beforeMaxMs": before_action_max,
                "afterMaxMs": after_action_max,
                "deltaMs": delta,
                "direction": classify_delta(delta),
            }
        )
    return {
        "beforeCount": before.get("count", 0),
        "afterCount": after.get("count", 0),
        "beforeMaxMs": before_max,
        "afterMaxMs": after_max,
        "maxMsDelta": max_delta,
        "direction": classify_delta(max_delta),
        "beforeSlowest": before.get("slowest", {}),
        "afterSlowest": after.get("slowest", {}),
        "actions": action_deltas,
    }


def compare_scenario_duration(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    before_max = float(before.get("maxMs", 0.0))
    after_max = float(after.get("maxMs", 0.0))
    max_delta = after_max - before_max
    scenario_deltas: list[dict[str, Any]] = []
    scenario_names = sorted(set(before.get("scenarios", {})) | set(after.get("scenarios", {})))
    for scenario in scenario_names:
        before_stats = before.get("scenarios", {}).get(scenario, {})
        after_stats = after.get("scenarios", {}).get(scenario, {})
        before_scenario_max = before_stats.get("max")
        after_scenario_max = after_stats.get("max")
        if before_scenario_max is None or after_scenario_max is None:
            delta = None
        else:
            delta = float(after_scenario_max) - float(before_scenario_max)
        scenario_deltas.append(
            {
                "scenario": scenario,
                "beforeMaxMs": before_scenario_max,
                "afterMaxMs": after_scenario_max,
                "deltaMs": delta,
                "direction": classify_delta(delta),
            }
        )
    return {
        "beforeCount": before.get("count", 0),
        "afterCount": after.get("count", 0),
        "beforeMaxMs": before_max,
        "afterMaxMs": after_max,
        "maxMsDelta": max_delta,
        "direction": classify_delta(max_delta),
        "beforeSlowest": before.get("slowest", {}),
        "afterSlowest": after.get("slowest", {}),
        "scenarios": scenario_deltas,
    }


def compare_network(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    ping_delta = float(after.get("maxUdpPingMeanMs", 0.0)) - float(before.get("maxUdpPingMeanMs", 0.0))
    loss_delta = float(after.get("maxPacketLossPercent", 0.0)) - float(before.get("maxPacketLossPercent", 0.0))
    warning_delta = int(after.get("timelineWarningCount", 0)) - int(before.get("timelineWarningCount", 0))
    error_delta = int(after.get("timelineErrorCount", 0)) - int(before.get("timelineErrorCount", 0))
    issue_delta = int(after.get("networkIssueCount", 0)) - int(before.get("networkIssueCount", 0))
    direction_delta = issue_delta or error_delta or warning_delta or loss_delta or ping_delta
    return {
        "beforeCount": before.get("count", 0),
        "afterCount": after.get("count", 0),
        "beforeUdpStates": before.get("udpStates", {}),
        "afterUdpStates": after.get("udpStates", {}),
        "beforeTimelineKinds": before.get("timelineKinds", {}),
        "afterTimelineKinds": after.get("timelineKinds", {}),
        "beforeTimelineWarnings": before.get("timelineWarningCount", 0),
        "afterTimelineWarnings": after.get("timelineWarningCount", 0),
        "timelineWarningDelta": warning_delta,
        "beforeTimelineErrors": before.get("timelineErrorCount", 0),
        "afterTimelineErrors": after.get("timelineErrorCount", 0),
        "timelineErrorDelta": error_delta,
        "beforeNetworkHealth": before.get("networkHealth", {}),
        "afterNetworkHealth": after.get("networkHealth", {}),
        "beforeNetworkIssueCount": before.get("networkIssueCount", 0),
        "afterNetworkIssueCount": after.get("networkIssueCount", 0),
        "networkIssueDelta": issue_delta,
        "beforeNetworkIssueKinds": before.get("networkIssueKinds", {}),
        "afterNetworkIssueKinds": after.get("networkIssueKinds", {}),
        "beforeMaxUdpPingMeanMs": before.get("maxUdpPingMeanMs", 0.0),
        "afterMaxUdpPingMeanMs": after.get("maxUdpPingMeanMs", 0.0),
        "udpPingMeanMsDelta": ping_delta,
        "beforeMaxPacketLossPercent": before.get("maxPacketLossPercent", 0.0),
        "afterMaxPacketLossPercent": after.get("maxPacketLossPercent", 0.0),
        "packetLossPercentDelta": loss_delta,
        "direction": classify_delta(float(direction_delta)),
    }


def split_selector(selector: str) -> tuple[str, str]:
    if "." not in selector:
        raise ValueError(f"Invalid metric selector {selector!r}; expected marker.metric")
    return selector.split(".", 1)


def metric_value(stats: dict[str, Any], marker: str, metric: str) -> float | None:
    value = stats.get(marker, {}).get(metric, {}).get("max")
    return numeric_value(value)


def numeric_value(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def classify_delta(delta: float | None) -> str:
    if delta is None:
        return "missing"
    if delta < 0:
        return "improved"
    if delta > 0:
        return "regressed"
    return "unchanged"


def print_text(result: dict[str, Any]) -> None:
    print("metric comparisons:")
    if not result["metrics"]:
        print("  none")
    for metric in result["metrics"]:
        print(
            "  "
            f"{metric['selector']}: before={format_number(metric['beforeMax'])} "
            f"after={format_number(metric['afterMax'])} "
            f"delta={format_number(metric['delta'])} "
            f"delta_pct={format_percent(metric['deltaPercent'])} "
            f"{metric['direction']}"
        )
    perf = result["performance"]
    print("")
    print("performance:")
    print(
        "  "
        f"maxStallCount {perf['beforeMaxStallCount']} -> {perf['afterMaxStallCount']} "
        f"(delta {perf['stallCountDelta']})"
    )
    print(
        "  "
        f"maxLagMs {format_number(perf['beforeMaxLagMs'])} -> {format_number(perf['afterMaxLagMs'])} "
        f"(delta {format_number(perf['lagMsDelta'])}) {perf['direction']}"
    )
    if perf["beforeMaxContext"] or perf["afterMaxContext"]:
        print(f"  beforeMaxContext={json.dumps(perf['beforeMaxContext'], ensure_ascii=False, sort_keys=True)}")
        print(f"  afterMaxContext={json.dumps(perf['afterMaxContext'], ensure_ascii=False, sort_keys=True)}")
    scenario_duration = result["scenarioDuration"]
    print("")
    print("scenario duration:")
    print(
        "  "
        f"maxMs {format_number(scenario_duration['beforeMaxMs'])} -> "
        f"{format_number(scenario_duration['afterMaxMs'])} "
        f"(delta {format_number(scenario_duration['maxMsDelta'])}) {scenario_duration['direction']}"
    )
    print(
        "  "
        f"slowest before={scenario_duration['beforeSlowest'].get('scenario', 'unknown')} "
        f"after={scenario_duration['afterSlowest'].get('scenario', 'unknown')}"
    )
    for scenario in scenario_duration["scenarios"]:
        print(
            "  "
            f"{scenario['scenario']}: before={format_number(scenario['beforeMaxMs'])} "
            f"after={format_number(scenario['afterMaxMs'])} "
            f"delta={format_number(scenario['deltaMs'])} {scenario['direction']}"
        )
    command_latency = result["commandLatency"]
    print("")
    print("command latency:")
    print(
        "  "
        f"maxMs {format_number(command_latency['beforeMaxMs'])} -> {format_number(command_latency['afterMaxMs'])} "
        f"(delta {format_number(command_latency['maxMsDelta'])}) {command_latency['direction']}"
    )
    print(
        "  "
        f"slowest before={command_latency['beforeSlowest'].get('action', 'unknown')} "
        f"after={command_latency['afterSlowest'].get('action', 'unknown')}"
    )
    for action in command_latency["actions"]:
        print(
            "  "
            f"{action['action']}: before={format_number(action['beforeMaxMs'])} "
            f"after={format_number(action['afterMaxMs'])} "
            f"delta={format_number(action['deltaMs'])} {action['direction']}"
        )
    net = result["network"]
    print("")
    print("network:")
    print(
        "  "
        f"maxUdpPingMeanMs {format_number(net['beforeMaxUdpPingMeanMs'])} -> "
        f"{format_number(net['afterMaxUdpPingMeanMs'])} "
        f"(delta {format_number(net['udpPingMeanMsDelta'])})"
    )
    print(
        "  "
        f"maxPacketLossPercent {format_number(net['beforeMaxPacketLossPercent'])} -> "
        f"{format_number(net['afterMaxPacketLossPercent'])} "
        f"(delta {format_number(net['packetLossPercentDelta'])}) {net['direction']}"
    )
    print(
        "  "
        f"timelineWarnings {net['beforeTimelineWarnings']} -> {net['afterTimelineWarnings']} "
        f"(delta {net['timelineWarningDelta']})"
    )
    print(
        "  "
        f"timelineErrors {net['beforeTimelineErrors']} -> {net['afterTimelineErrors']} "
        f"(delta {net['timelineErrorDelta']})"
    )
    print(
        "  "
        f"networkIssues {net['beforeNetworkIssueCount']} -> {net['afterNetworkIssueCount']} "
        f"(delta {net['networkIssueDelta']}) "
        f"health {net['beforeNetworkHealth'].get('status', 'unknown')} -> "
        f"{net['afterNetworkHealth'].get('status', 'unknown')} "
        f"rootCause {net['beforeNetworkHealth'].get('rootCauseHint', 'unknown')} -> "
        f"{net['afterNetworkHealth'].get('rootCauseHint', 'unknown')}"
    )
    print(f"  udpStates before={json.dumps(net['beforeUdpStates'], sort_keys=True)} after={json.dumps(net['afterUdpStates'], sort_keys=True)}")
    print(f"  timelineKinds before={json.dumps(net['beforeTimelineKinds'], sort_keys=True)} after={json.dumps(net['afterTimelineKinds'], sort_keys=True)}")
    print(f"  networkIssueKinds before={json.dumps(net['beforeNetworkIssueKinds'], sort_keys=True)} after={json.dumps(net['afterNetworkIssueKinds'], sort_keys=True)}")


def print_markdown(result: dict[str, Any]) -> None:
    print("# Mumble Probe Comparison")
    print("")
    print("## PERF Metric Deltas")
    print("")
    if not result["metrics"]:
        print("No common PERF metrics.")
    else:
        print("| Metric | Before max | After max | Delta | Delta % | Direction |")
        print("|---|---:|---:|---:|---:|---|")
        for metric in result["metrics"]:
            print(
                f"| {md(metric['selector'])} | {format_number(metric['beforeMax'])} | "
                f"{format_number(metric['afterMax'])} | {format_number(metric['delta'])} | "
                f"{format_percent(metric['deltaPercent'])} | {metric['direction']} |"
            )
    perf = result["performance"]
    print("")
    print("## Main Thread Responsiveness")
    print("")
    print("| Metric | Before | After | Delta | Direction |")
    print("|---|---:|---:|---:|---|")
    print(
        f"| maxStallCount | {perf['beforeMaxStallCount']} | {perf['afterMaxStallCount']} | "
        f"{perf['stallCountDelta']} | {classify_delta(float(perf['stallCountDelta']))} |"
    )
    print(
        f"| maxLagMs | {format_number(perf['beforeMaxLagMs'])} | {format_number(perf['afterMaxLagMs'])} | "
        f"{format_number(perf['lagMsDelta'])} | {classify_delta(perf['lagMsDelta'])} |"
    )
    print("")
    print("### Max Stall Context")
    print("")
    print("| Side | Context |")
    print("|---|---|")
    print(f"| Before | `{md(json.dumps(perf['beforeMaxContext'], ensure_ascii=False, sort_keys=True))}` |")
    print(f"| After | `{md(json.dumps(perf['afterMaxContext'], ensure_ascii=False, sort_keys=True))}` |")
    scenario_duration = result["scenarioDuration"]
    print("")
    print("## Scenario Duration")
    print("")
    print("| Scenario | Before max ms | After max ms | Delta ms | Direction |")
    print("|---|---:|---:|---:|---|")
    for scenario in scenario_duration["scenarios"]:
        print(
            f"| {md(scenario['scenario'])} | {format_number(scenario['beforeMaxMs'])} | "
            f"{format_number(scenario['afterMaxMs'])} | {format_number(scenario['deltaMs'])} | "
            f"{scenario['direction']} |"
        )
    print("")
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Before slowest | {md(scenario_duration['beforeSlowest'].get('scenario', 'unknown'))} |")
    print(f"| After slowest | {md(scenario_duration['afterSlowest'].get('scenario', 'unknown'))} |")
    print(f"| Overall direction | {scenario_duration['direction']} |")
    command_latency = result["commandLatency"]
    print("")
    print("## Command Latency")
    print("")
    print("| Metric | Before | After | Delta | Direction |")
    print("|---|---:|---:|---:|---|")
    print(
        f"| maxMs | {format_number(command_latency['beforeMaxMs'])} | "
        f"{format_number(command_latency['afterMaxMs'])} | {format_number(command_latency['maxMsDelta'])} | "
        f"{command_latency['direction']} |"
    )
    print("")
    print("| Side | Slowest action | Slowest id |")
    print("|---|---|---|")
    print(
        f"| Before | {md(command_latency['beforeSlowest'].get('action', 'unknown'))} | "
        f"{md(command_latency['beforeSlowest'].get('id', 'unknown'))} |"
    )
    print(
        f"| After | {md(command_latency['afterSlowest'].get('action', 'unknown'))} | "
        f"{md(command_latency['afterSlowest'].get('id', 'unknown'))} |"
    )
    if command_latency["actions"]:
        print("")
        print("| Action | Before max ms | After max ms | Delta ms | Direction |")
        print("|---|---:|---:|---:|---|")
        for action in command_latency["actions"]:
            print(
                f"| {md(action['action'])} | {format_number(action['beforeMaxMs'])} | "
                f"{format_number(action['afterMaxMs'])} | {format_number(action['deltaMs'])} | "
                f"{action['direction']} |"
            )
    net = result["network"]
    print("")
    print("## Network Health")
    print("")
    print("| Metric | Before | After | Delta | Direction |")
    print("|---|---:|---:|---:|---|")
    print(
        f"| maxUdpPingMeanMs | {format_number(net['beforeMaxUdpPingMeanMs'])} | "
        f"{format_number(net['afterMaxUdpPingMeanMs'])} | {format_number(net['udpPingMeanMsDelta'])} | "
        f"{classify_delta(net['udpPingMeanMsDelta'])} |"
    )
    print(
        f"| maxPacketLossPercent | {format_number(net['beforeMaxPacketLossPercent'])} | "
        f"{format_number(net['afterMaxPacketLossPercent'])} | {format_number(net['packetLossPercentDelta'])} | "
        f"{classify_delta(net['packetLossPercentDelta'])} |"
    )
    print(
        f"| timelineWarningCount | {net['beforeTimelineWarnings']} | "
        f"{net['afterTimelineWarnings']} | {net['timelineWarningDelta']} | "
        f"{classify_delta(float(net['timelineWarningDelta']))} |"
    )
    print(
        f"| timelineErrorCount | {net['beforeTimelineErrors']} | "
        f"{net['afterTimelineErrors']} | {net['timelineErrorDelta']} | "
        f"{classify_delta(float(net['timelineErrorDelta']))} |"
    )
    print(
        f"| networkIssueCount | {net['beforeNetworkIssueCount']} | "
        f"{net['afterNetworkIssueCount']} | {net['networkIssueDelta']} | "
        f"{classify_delta(float(net['networkIssueDelta']))} |"
    )
    print("")
    print("| Field | Before | After |")
    print("|---|---|---|")
    print(
        f"| Health status | {md(net['beforeNetworkHealth'].get('status', 'unknown'))} | "
        f"{md(net['afterNetworkHealth'].get('status', 'unknown'))} |"
    )
    print(
        f"| Root cause hint | {md(net['beforeNetworkHealth'].get('rootCauseHint', 'unknown'))} | "
        f"{md(net['afterNetworkHealth'].get('rootCauseHint', 'unknown'))} |"
    )
    print("")
    print("| Side | UDP states | Timeline kinds | Network issue kinds |")
    print("|---|---|---|---|")
    print(
        f"| Before | `{md(json.dumps(net['beforeUdpStates'], ensure_ascii=False, sort_keys=True))}` "
        f"| `{md(json.dumps(net['beforeTimelineKinds'], ensure_ascii=False, sort_keys=True))}` "
        f"| `{md(json.dumps(net['beforeNetworkIssueKinds'], ensure_ascii=False, sort_keys=True))}` |"
    )
    print(
        f"| After | `{md(json.dumps(net['afterUdpStates'], ensure_ascii=False, sort_keys=True))}` "
        f"| `{md(json.dumps(net['afterTimelineKinds'], ensure_ascii=False, sort_keys=True))}` "
        f"| `{md(json.dumps(net['afterNetworkIssueKinds'], ensure_ascii=False, sort_keys=True))}` |"
    )
    print_provenance("Before Provenance", result["before"]["provenance"])
    print_provenance("After Provenance", result["after"]["provenance"])


def print_provenance(title: str, provenance: dict[str, Any]) -> None:
    print("")
    print(f"## {title}")
    print("")
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Repository HEADs | {md_list(provenance.get('repositoryHeads', []))} |")
    print(f"| MumbleKit HEADs | {md_list(provenance.get('mumbleKitHeads', []))} |")
    print(f"| Repository dirty | {provenance.get('repositoryDirty', False)} |")
    print(f"| MumbleKit dirty | {provenance.get('mumbleKitDirty', False)} |")


def format_number(value: Any) -> str:
    if value is None:
        return "missing"
    if isinstance(value, (int, float)):
        return f"{float(value):.2f}"
    return str(value)


def format_percent(value: Any) -> str:
    if value is None:
        return "missing"
    return f"{float(value):.2f}%"


def md(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def md_list(values: list[Any]) -> str:
    return ", ".join(md(value) for value in values) if values else "none"


def markdown_text(result: dict[str, Any]) -> str:
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        print_markdown(result)
    return buffer.getvalue()


def run_self_test() -> int:
    before_provenance = {
        "probe": {"version": 1, "script": "probe"},
        "runtime": {"python": "3.13.0", "platform": "self-test"},
        "git": {
            "repository": {"head": "beforehead", "dirty": False},
            "mumbleKit": {"head": "beforekit", "dirty": False},
        },
    }
    after_provenance = {
        "probe": {"version": 1, "script": "probe"},
        "runtime": {"python": "3.13.0", "platform": "self-test"},
        "git": {
            "repository": {"head": "afterhead", "dirty": True},
            "mumbleKit": {"head": "afterkit", "dirty": False},
        },
    }
    with tempfile.TemporaryDirectory() as tmpdir:
        before_path = Path(tmpdir) / "before.jsonl"
        after_path = Path(tmpdir) / "after.jsonl"
        write_records(
            before_path,
            before_provenance,
            "PERF rebuild_model_array elapsed_ms=80",
            220,
            1500,
            {
                "stallCount": 1,
                "maxLagMs": 140.0,
                "lastStallContext": {"screen": "channelList", "lagMs": 140.0},
                "maxStallContext": {"screen": "channelList", "lagMs": 140.0},
            },
            {
                "connection": {"connected": True, "isReconnecting": False},
                "transport": {
                    "udpState": "stalled",
                    "udpPingMeanMs": 120.0,
                    "packetLossPercent": 8.0,
                },
                "timeline": [
                    {
                        "timestamp": "2026-01-01 00:00:00.200",
                        "category": "Connection",
                        "level": "warning",
                        "kind": "reconnect",
                        "message": "Reconnection scheduled",
                    },
                    {
                        "timestamp": "2026-01-01 00:00:00.300",
                        "category": "Connection",
                        "level": "error",
                        "kind": "connect_failed",
                        "message": "PERF connect_failed reconnect=true attempt=1 total_ms=1200",
                    },
                ],
            },
        )
        write_records(
            after_path,
            after_provenance,
            "PERF rebuild_model_array elapsed_ms=40",
            80,
            700,
            {"stallCount": 0, "maxLagMs": 0.0, "lastStallContext": {}, "maxStallContext": {}},
            {
                "connection": {"connected": True, "isReconnecting": False},
                "transport": {
                    "udpState": "available",
                    "udpPingMeanMs": 45.0,
                    "packetLossPercent": 1.0,
                },
                "timeline": [
                    {
                        "timestamp": "2026-01-01 00:00:00.200",
                        "category": "Connection",
                        "level": "info",
                        "kind": "connect_ready",
                        "message": "PERF connect_ready reconnect=false attempt=0 total_ms=320",
                    }
                ],
            },
        )
        result = compare(summarize([before_path]), summarize([after_path]), ["rebuild_model_array.elapsed_ms"])
        checks = [
            result["metrics"][0]["direction"] == "improved",
            result["metrics"][0]["beforeMax"] == 80.0,
            result["metrics"][0]["afterMax"] == 40.0,
            result["performance"]["direction"] == "improved",
            result["performance"]["beforeMaxContext"]["screen"] == "channelList",
            result["scenarioDuration"]["direction"] == "improved",
            result["scenarioDuration"]["beforeMaxMs"] == 1500.0,
            result["scenarioDuration"]["afterMaxMs"] == 700.0,
            result["scenarioDuration"]["scenarios"][0]["scenario"] == "baseline",
            result["commandLatency"]["direction"] == "improved",
            result["commandLatency"]["beforeMaxMs"] == 220.0,
            result["commandLatency"]["afterMaxMs"] == 80.0,
            result["commandLatency"]["actions"][0]["action"] == "network.status",
            result["network"]["direction"] == "improved",
            result["network"]["beforeUdpStates"] == {"stalled": 1},
            result["network"]["afterUdpStates"] == {"available": 1},
            result["network"]["beforeTimelineWarnings"] == 1,
            result["network"]["beforeTimelineErrors"] == 1,
            result["network"]["afterTimelineErrors"] == 0,
            result["network"]["timelineErrorDelta"] == -1,
            result["network"]["beforeNetworkHealth"]["status"] == "failing",
            result["network"]["afterNetworkHealth"]["status"] == "degraded",
            result["network"]["beforeNetworkHealth"]["rootCauseHint"] == "reconnect_loop",
            result["network"]["afterNetworkHealth"]["rootCauseHint"] == "packet_loss",
            result["network"]["beforeNetworkIssueCount"] == 4,
            result["network"]["afterNetworkIssueCount"] == 1,
            result["network"]["networkIssueDelta"] == -3,
            result["network"]["beforeNetworkIssueKinds"] == {
                "packet_loss_observed": 1,
                "timeline_connect_failed": 1,
                "timeline_reconnect": 1,
                "udp_stalled": 1,
            },
            result["network"]["afterNetworkIssueKinds"] == {"packet_loss_observed": 1},
            result["before"]["provenance"]["repositoryHeads"] == ["beforehead"],
            result["after"]["provenance"]["repositoryHeads"] == ["afterhead"],
            "# Mumble Probe Comparison" in markdown_text(result),
            "## Scenario Duration" in markdown_text(result),
            "## Command Latency" in markdown_text(result),
            "## Network Health" in markdown_text(result),
            "timelineErrorCount" in markdown_text(result),
            "networkIssueCount" in markdown_text(result),
            "reconnect_loop" in markdown_text(result),
        ]
        if not all(checks):
            print(json.dumps(result, indent=2, sort_keys=True), file=sys.stderr)
            return 1
    print("passed: trace compare self-test")
    return 0


def write_records(
    path: Path,
    provenance: dict[str, Any],
    message: str,
    command_duration_ms: int,
    scenario_duration_ms: int,
    performance: dict[str, Any],
    network: dict[str, Any],
) -> None:
    response_ms = command_duration_ms % 1000
    records = [
        {"type": "run.start", "timestamp": "2026-01-01T00:00:00Z", "scenario": "baseline", "provenance": provenance},
        {"type": "event", "message": {"event": "log.entry", "data": {"message": message}}},
        {
            "type": "command.send",
            "timestamp": "2026-01-01T00:00:00.100Z",
            "id": "selftest:network.status",
            "action": "network.status",
        },
        {
            "type": "command.response",
            "timestamp": f"2026-01-01T00:00:00.{100 + response_ms:03d}Z",
            "message": {"id": "selftest:network.status", "success": True, "data": network},
        },
        {"type": "performance.snapshot", "scenario": "baseline", "data": performance},
        {"type": "run.end", "timestamp": timestamp_after_ms(scenario_duration_ms), "scenario": "baseline", "status": "passed", "failures": []},
    ]
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")


def timestamp_after_ms(milliseconds: int) -> str:
    seconds = milliseconds // 1000
    remainder = milliseconds % 1000
    return f"2026-01-01T00:00:{seconds:02d}.{remainder:03d}Z"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare before/after MUTestServer probe evidence.")
    parser.add_argument("--before", nargs="+", type=Path, required=True, help="Before JSONL evidence files")
    parser.add_argument("--after", nargs="+", type=Path, required=True, help="After JSONL evidence files")
    parser.add_argument("--metric", action="append", default=[], help="Metric selector marker.metric. Repeat as needed.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON")
    parser.add_argument("--markdown", action="store_true", help="Print Markdown comparison report")
    parser.add_argument("--self-test", action="store_true", help="Validate comparison logic")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return run_self_test()
    args = parse_args(argv)
    missing = [str(path) for path in [*args.before, *args.after] if not path.exists()]
    if missing:
        print(f"error: missing evidence file(s): {', '.join(missing)}", file=sys.stderr)
        return 2
    result = compare(summarize(args.before), summarize(args.after), args.metric)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    elif args.markdown:
        print_markdown(result)
    else:
        print_text(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
