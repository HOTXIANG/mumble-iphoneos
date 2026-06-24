#!/usr/bin/env python3
"""Summarize MUTestServer probe evidence and PERF log markers."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import re
import statistics
import sys
import tempfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


PERF_RE = re.compile(r"\bPERF\s+(?P<name>[A-Za-z0-9_.:-]+)\s*(?P<body>.*)")
KV_RE = re.compile(r"(?P<key>[A-Za-z_][A-Za-z0-9_]*)=(?P<value>\"[^\"]*\"|'[^']*'|[^\s]+)")
INCIDENT_SLOW_COMMAND_MS = 100.0
INCIDENT_SLOW_WAIT_MS = 1000.0
NETWORK_HIGH_UDP_PING_MS = 150.0
NETWORK_UDP_PROBLEM_STATES = {"stalled", "recovering", "unavailable"}
EXPECTED_NETWORK_ROOT_CAUSES_BY_SCENARIO = {
    "network-connect-failure": {"connection_failure"},
    "network-auto-reconnect": {"connection_failure", "reconnect_loop"},
    "network-udp-degraded": {"udp_transport", "packet_loss", "network_latency"},
}


@dataclass
class EvidenceSummary:
    files: list[str] = field(default_factory=list)
    records: int = 0
    malformed_lines: list[str] = field(default_factory=list)
    record_types: Counter[str] = field(default_factory=Counter)
    scenarios: Counter[str] = field(default_factory=Counter)
    suite_ids: Counter[str] = field(default_factory=Counter)
    suite_scenarios: Counter[str] = field(default_factory=Counter)
    events: Counter[str] = field(default_factory=Counter)
    commands: Counter[str] = field(default_factory=Counter)
    run_failures: list[str] = field(default_factory=list)
    command_failures: list[str] = field(default_factory=list)
    assertion_failures: list[str] = field(default_factory=list)
    coverage_failures: list[str] = field(default_factory=list)
    log_entries: int = 0
    perf_markers: dict[str, list[dict[str, Any]]] = field(default_factory=lambda: defaultdict(list))
    performance_snapshots: list[dict[str, Any]] = field(default_factory=list)
    network_snapshots: list[dict[str, Any]] = field(default_factory=list)
    diagnostic_snapshots: list[dict[str, Any]] = field(default_factory=list)
    command_sends: dict[str, dict[str, Any]] = field(default_factory=dict)
    command_latencies: list[dict[str, Any]] = field(default_factory=list)
    pending_run_starts: list[dict[str, Any]] = field(default_factory=list)
    run_durations: list[dict[str, Any]] = field(default_factory=list)
    waits: list[dict[str, Any]] = field(default_factory=list)
    suite_scenario_outcomes: list[dict[str, Any]] = field(default_factory=list)
    current_scenarios_by_file: dict[str, str] = field(default_factory=dict)
    provenance_expected: int = 0
    provenance_records: list[dict[str, Any]] = field(default_factory=list)
    provenance_missing: list[str] = field(default_factory=list)
    threshold_failures: list[str] = field(default_factory=list)

    @property
    def failed(self) -> bool:
        return bool(
            self.malformed_lines
            or self.run_failures
            or self.command_failures
            or self.assertion_failures
            or self.coverage_failures
            or self.threshold_failures
        )


@dataclass(frozen=True)
class Threshold:
    marker: str
    metric: str
    limit: float
    source: str
    required: bool = True

    @property
    def selector(self) -> str:
        return f"{self.marker}.{self.metric}"


@dataclass(frozen=True)
class NetworkThreshold:
    metric: str
    limit: float
    source: str
    required: bool = False


@dataclass(frozen=True)
class CommandThreshold:
    action: str
    limit_ms: float
    source: str
    required: bool = False


@dataclass(frozen=True)
class ScenarioThreshold:
    scenario: str
    limit_ms: float
    source: str
    required: bool = False


@dataclass(frozen=True)
class WaitThreshold:
    description: str
    limit_ms: float
    source: str
    required: bool = False


def parse_jsonl(paths: list[Path]) -> EvidenceSummary:
    summary = EvidenceSummary(files=[str(path) for path in paths])
    for path in paths:
        with path.open("r", encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError as exc:
                    summary.malformed_lines.append(f"{path}:{line_number}: {exc.msg}")
                    continue
                if not isinstance(record, dict):
                    summary.malformed_lines.append(f"{path}:{line_number}: expected JSON object")
                    continue
                consume_record(summary, record, path, line_number)
    return summary


def consume_record(summary: EvidenceSummary, record: dict[str, Any], path: Path, line_number: int) -> None:
    summary.records += 1
    record_type = str(record.get("type", "unknown"))
    summary.record_types[record_type] += 1

    if record_type == "assertion" and not bool(record.get("passed")):
        summary.assertion_failures.append(f"{path}:{line_number}: {record.get('description', 'assertion failed')}")
    elif record_type == "run.start":
        count_scenario(summary, record.get("scenario"))
        consume_run_start(summary, record, path, line_number)
        consume_provenance_record(summary, record, path, line_number)
    elif record_type == "error":
        error_type = record.get("error_type", "Error")
        error = record.get("error", "unknown error")
        summary.run_failures.append(f"{path}:{line_number}: {error_type}: {error}")
    elif record_type == "run.end":
        consume_run_end(summary, record, path, line_number)
        failures = string_list(record.get("failures"))
        status = str(record.get("status", "unknown"))
        if status != "passed" or failures:
            details = "; ".join(failures) if failures else f"status={status}"
            summary.run_failures.append(f"{path}:{line_number}: run failed: {details}")
    elif record_type == "suite.start":
        count_suite(summary, record.get("suite_id"))
        consume_provenance_record(summary, record, path, line_number)
    elif record_type == "suite.scenario":
        count_suite(summary, record.get("suite_id"))
        count_scenario(summary, record.get("scenario"))
        count_suite_scenario(summary, record.get("scenario"))
        consume_suite_scenario_outcome(summary, record, path, line_number)
        status = str(record.get("status", "unknown"))
        exit_code = record.get("exit_code", 0)
        if status != "passed" or exit_code not in (0, "0"):
            scenario = record.get("scenario", "unknown")
            summary.run_failures.append(
                f"{path}:{line_number}: suite scenario {scenario} failed with exit_code={exit_code}"
            )
    elif record_type == "suite.end":
        count_suite(summary, record.get("suite_id"))
        failures = string_list(record.get("failures"))
        status = str(record.get("status", "unknown"))
        if status != "passed" or failures:
            details = "; ".join(failures) if failures else f"status={status}"
            summary.run_failures.append(f"{path}:{line_number}: suite failed: {details}")
    elif record_type == "performance.snapshot":
        error = record.get("error")
        if error:
            summary.coverage_failures.append(f"{path}:{line_number}: performance snapshot failed: {error}")
        data = record.get("data")
        if isinstance(data, dict):
            consume_performance_snapshot(summary, data, timestamp=record.get("timestamp"))
    elif record_type == "diagnostic.snapshot":
        consume_diagnostic_snapshot(summary, record)
    elif record_type == "command.send":
        consume_command_send(summary, record)
    elif record_type == "wait":
        consume_wait(summary, record, path, line_number)

    message = record.get("message")
    if isinstance(message, dict):
        if "event" in message:
            event_name = str(message.get("event"))
            summary.events[event_name] += 1
            if event_name == "log.entry":
                consume_log_entry(summary, message.get("data"))
        elif "id" in message:
            consume_response(summary, message, path, line_number, record.get("timestamp"))


def string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item) for item in value]


def count_scenario(summary: EvidenceSummary, value: Any) -> None:
    if isinstance(value, str) and value:
        summary.scenarios[value] += 1


def count_suite(summary: EvidenceSummary, value: Any) -> None:
    if isinstance(value, str) and value:
        summary.suite_ids[value] += 1


def count_suite_scenario(summary: EvidenceSummary, value: Any) -> None:
    if isinstance(value, str) and value:
        summary.suite_scenarios[value] += 1


def action_from_request_id(request_id: str) -> str:
    return request_id.split(":", 2)[-1] if ":" in request_id else request_id


def consume_command_send(summary: EvidenceSummary, record: dict[str, Any]) -> None:
    request_id = record.get("id")
    if not isinstance(request_id, str) or not request_id:
        return
    action = record.get("action")
    summary.command_sends[request_id] = {
        "id": request_id,
        "action": str(action) if isinstance(action, str) and action else action_from_request_id(request_id),
        "timestamp": record.get("timestamp"),
    }


def consume_response(
    summary: EvidenceSummary,
    response: dict[str, Any],
    path: Path,
    line_number: int,
    timestamp: Any,
) -> None:
    response_id = str(response.get("id", ""))
    action = action_from_request_id(response_id)
    if action:
        summary.commands[action] += 1
    if not response.get("success", True):
        summary.command_failures.append(f"{path}:{line_number}: {action or response_id} failed: {response.get('error')}")
    consume_command_latency(summary, response_id, action, timestamp)

    data = response.get("data")
    if action == "log.recent" and isinstance(data, dict):
        entries = data.get("entries", [])
        if isinstance(entries, list):
            for entry in entries:
                consume_log_entry(summary, entry)
    if action in {"performance.status", "performance.reset"} and isinstance(data, dict):
            consume_performance_snapshot(summary, data, timestamp=timestamp)
    if action == "network.status" and isinstance(data, dict):
        enriched = dict(data)
        scenario = summary.current_scenarios_by_file.get(str(path))
        if scenario and "_scenario" not in enriched:
            enriched["_scenario"] = scenario
        consume_network_snapshot(summary, enriched)


def consume_command_latency(summary: EvidenceSummary, response_id: str, action: str, response_timestamp: Any) -> None:
    sent = summary.command_sends.get(response_id)
    if not sent:
        return
    sent_at = parse_timestamp(sent.get("timestamp"))
    responded_at = parse_timestamp(response_timestamp)
    if sent_at is None or responded_at is None:
        return
    duration_ms = max(0.0, (responded_at - sent_at).total_seconds() * 1000.0)
    summary.command_latencies.append(
        {
            "id": response_id,
            "action": action or sent.get("action", response_id),
            "durationMs": duration_ms,
            "sentAt": sent.get("timestamp"),
            "respondedAt": response_timestamp,
        }
    )


def consume_run_start(summary: EvidenceSummary, record: dict[str, Any], path: Path, line_number: int) -> None:
    started_at = parse_timestamp(record.get("timestamp"))
    if started_at is None:
        return
    run_id = record.get("run_id")
    scenario = str(record.get("scenario") or "unknown")
    summary.current_scenarios_by_file[str(path)] = scenario
    summary.pending_run_starts.append(
        {
            "runId": str(run_id) if isinstance(run_id, str) and run_id else "",
            "scenario": scenario,
            "timestamp": record.get("timestamp"),
            "startedAt": started_at,
            "path": str(path),
            "line": line_number,
        }
    )


def consume_run_end(summary: EvidenceSummary, record: dict[str, Any], path: Path, line_number: int) -> None:
    ended_at = parse_timestamp(record.get("timestamp"))
    if ended_at is None or not summary.pending_run_starts:
        return
    run_id = record.get("run_id")
    start_index: int | None = None
    if isinstance(run_id, str) and run_id:
        for index in range(len(summary.pending_run_starts) - 1, -1, -1):
            if summary.pending_run_starts[index].get("runId") == run_id:
                start_index = index
                break
    if start_index is None:
        start_index = len(summary.pending_run_starts) - 1
    start = summary.pending_run_starts.pop(start_index)
    started_at = start.get("startedAt")
    if not isinstance(started_at, datetime):
        return
    duration_ms = max(0.0, (ended_at - started_at).total_seconds() * 1000.0)
    scenario = str(record.get("scenario") or start.get("scenario") or "unknown")
    summary.run_durations.append(
        {
            "runId": str(run_id) if isinstance(run_id, str) and run_id else str(start.get("runId") or ""),
            "scenario": scenario,
            "durationMs": duration_ms,
            "startedAt": start.get("timestamp"),
            "endedAt": record.get("timestamp"),
            "startSource": f"{start.get('path')}:{start.get('line')}",
            "endSource": f"{path}:{line_number}",
        }
    )


def consume_wait(summary: EvidenceSummary, record: dict[str, Any], path: Path, line_number: int) -> None:
    summary.waits.append(
        {
            "timestamp": record.get("timestamp"),
            "passed": bool(record.get("passed")),
            "description": str(record.get("description") or "unknown"),
            "action": str(record.get("action") or ""),
            "attempts": int_value(record.get("attempts")),
            "elapsedMs": float_value(record.get("elapsedMs")),
            "timeoutMs": float_value(record.get("timeoutMs")),
            "intervalMs": float_value(record.get("intervalMs")),
            "source": f"{path}:{line_number}",
        }
    )


def consume_suite_scenario_outcome(summary: EvidenceSummary, record: dict[str, Any], path: Path, line_number: int) -> None:
    status = str(record.get("status", "unknown"))
    scenario = str(record.get("scenario") or "unknown")
    summary.suite_scenario_outcomes.append(
        {
            "suiteId": str(record.get("suite_id") or ""),
            "scenario": scenario,
            "iteration": int_value(record.get("iteration")) or 1,
            "repeat": int_value(record.get("repeat")) or 1,
            "status": status,
            "passed": status == "passed" and record.get("exit_code", 0) in (0, "0"),
            "exitCode": record.get("exit_code", 0),
            "elapsedMs": float_value(record.get("elapsed_ms")),
            "output": str(record.get("output") or ""),
            "source": f"{path}:{line_number}",
        }
    )


def parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def consume_log_entry(summary: EvidenceSummary, entry: Any) -> None:
    if not isinstance(entry, dict):
        return
    summary.log_entries += 1
    message = entry.get("message")
    if not isinstance(message, str):
        return
    perf = parse_perf_message(message)
    if perf is not None:
        name, fields = perf
        summary.perf_markers[name].append(fields)


def consume_performance_snapshot(summary: EvidenceSummary, snapshot: dict[str, Any], timestamp: Any = None) -> None:
    enriched = dict(snapshot)
    if timestamp is not None and "_timestamp" not in enriched:
        enriched["_timestamp"] = timestamp
    summary.performance_snapshots.append(enriched)


def consume_network_snapshot(summary: EvidenceSummary, snapshot: dict[str, Any]) -> None:
    summary.network_snapshots.append(snapshot)


def consume_diagnostic_snapshot(summary: EvidenceSummary, snapshot: dict[str, Any]) -> None:
    summary.diagnostic_snapshots.append(snapshot)


def consume_provenance_record(summary: EvidenceSummary, record: dict[str, Any], path: Path, line_number: int) -> None:
    summary.provenance_expected += 1
    provenance = record.get("provenance")
    if not isinstance(provenance, dict):
        summary.provenance_missing.append(f"{path}:{line_number}: missing provenance on {record.get('type')}")
        return
    summary.provenance_records.append(provenance)


def parse_perf_message(message: str) -> tuple[str, dict[str, Any]] | None:
    match = PERF_RE.search(message)
    if not match:
        return None
    fields: dict[str, Any] = {"message": message}
    for kv in KV_RE.finditer(match.group("body")):
        fields[kv.group("key")] = parse_value(kv.group("value"))
    return match.group("name"), fields


def parse_value(raw: str) -> Any:
    stripped = raw.strip().strip("\"'")
    lowered = stripped.lower()
    if lowered in {"true", "yes"}:
        return True
    if lowered in {"false", "no"}:
        return False
    try:
        if "." in stripped:
            return float(stripped)
        return int(stripped)
    except ValueError:
        return stripped


def parse_inline_threshold(raw: str) -> Threshold | str:
    try:
        selector, limit_text = raw.split("=", 1)
        marker, metric = selector.split(".", 1)
        limit = float(limit_text)
    except ValueError:
        return f"Invalid threshold {raw!r}; expected marker.metric=value"
    return Threshold(marker=marker, metric=metric, limit=limit, source=f"--max {raw}", required=True)


def load_budget_file(path: Path) -> list[Threshold]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return parse_perf_budgets(data, path)


def parse_perf_budgets(data: dict[str, Any], path: Path) -> list[Threshold]:
    budgets = data.get("budgets", [])
    if not isinstance(budgets, list):
        raise ValueError(f"{path}: field 'budgets' must be an array")
    thresholds: list[Threshold] = []
    for index, item in enumerate(budgets, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"{path}: budgets[{index}] must be an object")
        try:
            marker = str(item["marker"])
            metric = str(item["metric"])
            limit = float(item["max"])
        except KeyError as exc:
            raise ValueError(f"{path}: budgets[{index}] missing field {exc.args[0]!r}") from exc
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{path}: budgets[{index}] field 'max' must be numeric") from exc
        if not marker or not metric:
            raise ValueError(f"{path}: budgets[{index}] marker and metric must be non-empty")
        thresholds.append(
            Threshold(
                marker=marker,
                metric=metric,
                limit=limit,
                source=f"{path}:{index}",
                required=bool(item.get("required", False)),
            )
        )
    return thresholds


def load_network_budget_file(path: Path) -> list[NetworkThreshold]:
    data = json.loads(path.read_text(encoding="utf-8"))
    budgets = data.get("networkBudgets", [])
    if not isinstance(budgets, list):
        raise ValueError(f"{path}: field 'networkBudgets' must be an array")
    thresholds: list[NetworkThreshold] = []
    allowed_metrics = {
        "maxUdpPingMeanMs",
        "maxPacketLossPercent",
        "networkIssueCount",
        "packetLossObservedCount",
        "reconnectingCount",
        "timelineWarningCount",
        "timelineErrorCount",
        "udpProblemStateCount",
    }
    for index, item in enumerate(budgets, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"{path}: networkBudgets[{index}] must be an object")
        try:
            metric = str(item["metric"])
            limit = float(item["max"])
        except KeyError as exc:
            raise ValueError(f"{path}: networkBudgets[{index}] missing field {exc.args[0]!r}") from exc
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{path}: networkBudgets[{index}] field 'max' must be numeric") from exc
        if metric not in allowed_metrics:
            raise ValueError(
                f"{path}: networkBudgets[{index}] metric must be one of {', '.join(sorted(allowed_metrics))}"
            )
        thresholds.append(
            NetworkThreshold(
                metric=metric,
                limit=limit,
                source=f"{path}:networkBudgets[{index}]",
                required=bool(item.get("required", False)),
            )
        )
    return thresholds


def load_command_budget_file(path: Path) -> list[CommandThreshold]:
    data = json.loads(path.read_text(encoding="utf-8"))
    budgets = data.get("commandBudgets", [])
    if not isinstance(budgets, list):
        raise ValueError(f"{path}: field 'commandBudgets' must be an array")
    thresholds: list[CommandThreshold] = []
    for index, item in enumerate(budgets, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"{path}: commandBudgets[{index}] must be an object")
        try:
            action = str(item["action"])
            limit = float(item["maxMs"])
        except KeyError as exc:
            raise ValueError(f"{path}: commandBudgets[{index}] missing field {exc.args[0]!r}") from exc
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{path}: commandBudgets[{index}] field 'maxMs' must be numeric") from exc
        if not action:
            raise ValueError(f"{path}: commandBudgets[{index}] action must be non-empty")
        thresholds.append(
            CommandThreshold(
                action=action,
                limit_ms=limit,
                source=f"{path}:commandBudgets[{index}]",
                required=bool(item.get("required", False)),
            )
        )
    return thresholds


def load_scenario_budget_file(path: Path) -> list[ScenarioThreshold]:
    data = json.loads(path.read_text(encoding="utf-8"))
    budgets = data.get("scenarioBudgets", [])
    if not isinstance(budgets, list):
        raise ValueError(f"{path}: field 'scenarioBudgets' must be an array")
    thresholds: list[ScenarioThreshold] = []
    for index, item in enumerate(budgets, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"{path}: scenarioBudgets[{index}] must be an object")
        try:
            scenario = str(item["scenario"])
            limit = float(item["maxMs"])
        except KeyError as exc:
            raise ValueError(f"{path}: scenarioBudgets[{index}] missing field {exc.args[0]!r}") from exc
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{path}: scenarioBudgets[{index}] field 'maxMs' must be numeric") from exc
        if not scenario:
            raise ValueError(f"{path}: scenarioBudgets[{index}] scenario must be non-empty")
        thresholds.append(
            ScenarioThreshold(
                scenario=scenario,
                limit_ms=limit,
                source=f"{path}:scenarioBudgets[{index}]",
                required=bool(item.get("required", False)),
            )
        )
    return thresholds


def load_wait_budget_file(path: Path) -> list[WaitThreshold]:
    data = json.loads(path.read_text(encoding="utf-8"))
    budgets = data.get("waitBudgets", [])
    if not isinstance(budgets, list):
        raise ValueError(f"{path}: field 'waitBudgets' must be an array")
    thresholds: list[WaitThreshold] = []
    for index, item in enumerate(budgets, start=1):
        if not isinstance(item, dict):
            raise ValueError(f"{path}: waitBudgets[{index}] must be an object")
        try:
            description = str(item["description"])
            limit = float(item["maxMs"])
        except KeyError as exc:
            raise ValueError(f"{path}: waitBudgets[{index}] missing field {exc.args[0]!r}") from exc
        except (TypeError, ValueError) as exc:
            raise ValueError(f"{path}: waitBudgets[{index}] field 'maxMs' must be numeric") from exc
        if not description:
            raise ValueError(f"{path}: waitBudgets[{index}] description must be non-empty")
        thresholds.append(
            WaitThreshold(
                description=description,
                limit_ms=limit,
                source=f"{path}:waitBudgets[{index}]",
                required=bool(item.get("required", False)),
            )
        )
    return thresholds


def collect_thresholds(inline: list[str], budget_files: list[Path]) -> tuple[list[Threshold], list[str]]:
    thresholds: list[Threshold] = []
    errors: list[str] = []
    for raw in inline:
        parsed = parse_inline_threshold(raw)
        if isinstance(parsed, str):
            errors.append(parsed)
        else:
            thresholds.append(parsed)
    for path in budget_files:
        try:
            thresholds.extend(load_budget_file(path))
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            errors.append(str(exc))
    return thresholds, errors


def collect_network_thresholds(budget_files: list[Path]) -> tuple[list[NetworkThreshold], list[str]]:
    thresholds: list[NetworkThreshold] = []
    errors: list[str] = []
    for path in budget_files:
        try:
            thresholds.extend(load_network_budget_file(path))
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            errors.append(str(exc))
    return thresholds, errors


def parse_command_threshold(raw: str) -> CommandThreshold | str:
    try:
        action, limit_text = raw.split("=", 1)
        limit = float(limit_text)
    except ValueError:
        return f"Invalid command threshold {raw!r}; expected action=max_ms"
    if not action:
        return f"Invalid command threshold {raw!r}; action must be non-empty"
    return CommandThreshold(action=action, limit_ms=limit, source=f"--max-command-ms {raw}", required=True)


def collect_command_thresholds(
    inline: list[str],
    budget_files: list[Path],
) -> tuple[list[CommandThreshold], list[str]]:
    thresholds: list[CommandThreshold] = []
    errors: list[str] = []
    for raw in inline:
        parsed = parse_command_threshold(raw)
        if isinstance(parsed, str):
            errors.append(parsed)
        else:
            thresholds.append(parsed)
    for path in budget_files:
        try:
            thresholds.extend(load_command_budget_file(path))
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            errors.append(str(exc))
    return thresholds, errors


def parse_scenario_threshold(raw: str) -> ScenarioThreshold | str:
    try:
        scenario, limit_text = raw.split("=", 1)
        limit = float(limit_text)
    except ValueError:
        return f"Invalid scenario duration threshold {raw!r}; expected scenario=max_ms"
    if not scenario:
        return f"Invalid scenario duration threshold {raw!r}; scenario must be non-empty"
    return ScenarioThreshold(scenario=scenario, limit_ms=limit, source=f"--max-scenario-ms {raw}", required=True)


def collect_scenario_thresholds(
    inline: list[str],
    budget_files: list[Path],
) -> tuple[list[ScenarioThreshold], list[str]]:
    thresholds: list[ScenarioThreshold] = []
    errors: list[str] = []
    for raw in inline:
        parsed = parse_scenario_threshold(raw)
        if isinstance(parsed, str):
            errors.append(parsed)
        else:
            thresholds.append(parsed)
    for path in budget_files:
        try:
            thresholds.extend(load_scenario_budget_file(path))
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            errors.append(str(exc))
    return thresholds, errors


def parse_wait_threshold(raw: str) -> WaitThreshold | str:
    try:
        description, limit_text = raw.split("=", 1)
        limit = float(limit_text)
    except ValueError:
        return f"Invalid wait threshold {raw!r}; expected description=max_ms"
    if not description:
        return f"Invalid wait threshold {raw!r}; description must be non-empty"
    return WaitThreshold(description=description, limit_ms=limit, source=f"--max-wait-ms {raw}", required=True)


def collect_wait_thresholds(
    inline: list[str],
    budget_files: list[Path],
) -> tuple[list[WaitThreshold], list[str]]:
    thresholds: list[WaitThreshold] = []
    errors: list[str] = []
    for raw in inline:
        parsed = parse_wait_threshold(raw)
        if isinstance(parsed, str):
            errors.append(parsed)
        else:
            thresholds.append(parsed)
    for path in budget_files:
        try:
            thresholds.extend(load_wait_budget_file(path))
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            errors.append(str(exc))
    return thresholds, errors


def evaluate_thresholds(summary: EvidenceSummary, thresholds: list[Threshold]) -> None:
    for threshold in thresholds:
        values = numeric_values(summary.perf_markers.get(threshold.marker, []), threshold.metric)
        if not values:
            if threshold.required:
                summary.threshold_failures.append(
                    f"{threshold.source}: {threshold.selector} had no matching numeric values"
                )
            continue
        observed = max(values)
        if observed > threshold.limit:
            summary.threshold_failures.append(
                f"{threshold.source}: {threshold.selector} max {observed:g} exceeded threshold {threshold.limit:g}"
            )


def evaluate_required_scenarios(summary: EvidenceSummary, required: list[str]) -> None:
    missing = sorted({scenario for scenario in required if scenario not in summary.scenarios})
    if missing:
        present = ", ".join(sorted(summary.scenarios)) or "none"
        summary.coverage_failures.append(
            f"Missing required scenario(s): {', '.join(missing)}; present={present}"
        )


def evaluate_suite_index(summary: EvidenceSummary, required: list[str]) -> None:
    suite_start_count = summary.record_types.get("suite.start", 0)
    suite_end_count = summary.record_types.get("suite.end", 0)
    suite_scenario_count = summary.record_types.get("suite.scenario", 0)
    if suite_start_count == 0:
        summary.coverage_failures.append("Missing suite.start record; include suite-index.jsonl in the analysis")
    if suite_end_count == 0:
        summary.coverage_failures.append("Missing suite.end record; include suite-index.jsonl in the analysis")
    if suite_scenario_count == 0:
        summary.coverage_failures.append("Missing suite.scenario records; include suite-index.jsonl in the analysis")
    if len(summary.suite_ids) > 1:
        summary.coverage_failures.append(
            f"Multiple suite ids present: {', '.join(sorted(summary.suite_ids))}"
        )
    missing = sorted({scenario for scenario in required if scenario not in summary.suite_scenarios})
    if missing:
        present = ", ".join(sorted(summary.suite_scenarios)) or "none"
        summary.coverage_failures.append(
            f"Missing required suite scenario(s): {', '.join(missing)}; suite_index_present={present}"
        )


def evaluate_required_events(summary: EvidenceSummary, required: list[str]) -> None:
    missing = sorted({event for event in required if event not in summary.events})
    if missing:
        present = ", ".join(sorted(summary.events)) or "none"
        summary.coverage_failures.append(
            f"Missing required event(s): {', '.join(missing)}; present={present}"
        )


def evaluate_required_commands(summary: EvidenceSummary, required: list[str]) -> None:
    missing = sorted({command for command in required if command not in summary.commands})
    if missing:
        present = ", ".join(sorted(summary.commands)) or "none"
        summary.coverage_failures.append(
            f"Missing required command(s): {', '.join(missing)}; present={present}"
        )


def evaluate_required_perf_markers(summary: EvidenceSummary, required: list[str]) -> None:
    for selector in required:
        if "." in selector:
            marker, metric = selector.split(".", 1)
            values = numeric_values(summary.perf_markers.get(marker, []), metric)
            if not values:
                present = ", ".join(sorted(summary.perf_markers)) or "none"
                summary.coverage_failures.append(
                    f"Missing required PERF metric {selector}; markers={present}"
                )
            continue
        if selector not in summary.perf_markers:
            present = ", ".join(sorted(summary.perf_markers)) or "none"
            summary.coverage_failures.append(
                f"Missing required PERF marker {selector}; present={present}"
            )


def evaluate_performance_limits(
    summary: EvidenceSummary,
    max_stall_count: int | None,
    max_lag_ms: float | None,
) -> None:
    stats = performance_stats(summary)
    if max_stall_count is not None and stats["maxStallCount"] > max_stall_count:
        summary.threshold_failures.append(
            f"--max-performance-stalls {max_stall_count}: observed maxStallCount={stats['maxStallCount']}"
        )
    if max_lag_ms is not None and stats["maxLagMs"] > max_lag_ms:
        summary.threshold_failures.append(
            f"--max-performance-lag-ms {max_lag_ms:g}: observed maxLagMs={stats['maxLagMs']:g}"
        )


def evaluate_required_network_snapshot(summary: EvidenceSummary, required: bool) -> None:
    if required and not summary.network_snapshots:
        summary.coverage_failures.append("Missing network.status snapshot evidence")


def evaluate_network_limits(
    summary: EvidenceSummary,
    max_udp_ping_ms: float | None,
    max_packet_loss_percent: float | None,
    max_timeline_warning_count: int | None,
    max_timeline_error_count: int | None,
    max_network_issue_count: int | None,
) -> None:
    stats = network_stats(summary)
    if max_udp_ping_ms is not None and stats["maxUdpPingMeanMs"] > max_udp_ping_ms:
        summary.threshold_failures.append(
            f"--max-network-udp-ping-ms {max_udp_ping_ms:g}: "
            f"observed maxUdpPingMeanMs={stats['maxUdpPingMeanMs']:g}"
        )
    if max_packet_loss_percent is not None and stats["maxPacketLossPercent"] > max_packet_loss_percent:
        summary.threshold_failures.append(
            f"--max-network-packet-loss-percent {max_packet_loss_percent:g}: "
            f"observed maxPacketLossPercent={stats['maxPacketLossPercent']:g}"
        )
    if max_timeline_warning_count is not None and stats["timelineWarningCount"] > max_timeline_warning_count:
        summary.threshold_failures.append(
            f"--max-network-timeline-warnings {max_timeline_warning_count:g}: "
            f"observed timelineWarningCount={stats['timelineWarningCount']:g}"
        )
    if max_timeline_error_count is not None and stats["timelineErrorCount"] > max_timeline_error_count:
        summary.threshold_failures.append(
            f"--max-network-timeline-errors {max_timeline_error_count:g}: "
            f"observed timelineErrorCount={stats['timelineErrorCount']:g}"
        )
    if max_network_issue_count is not None and stats["networkIssueCount"] > max_network_issue_count:
        summary.threshold_failures.append(
            f"--max-network-issues {max_network_issue_count:g}: "
            f"observed networkIssueCount={stats['networkIssueCount']:g}"
        )


def evaluate_network_thresholds(summary: EvidenceSummary, thresholds: list[NetworkThreshold]) -> None:
    if not thresholds:
        return
    stats = network_stats(summary)
    if stats["count"] == 0:
        for threshold in thresholds:
            if threshold.required:
                summary.threshold_failures.append(
                    f"{threshold.source}: network.status had no matching snapshot values"
                )
        return
    for threshold in thresholds:
        observed = float_value(stats.get(threshold.metric))
        if observed > threshold.limit:
            summary.threshold_failures.append(
                f"{threshold.source}: {threshold.metric} max {observed:g} exceeded threshold {threshold.limit:g}"
            )


def evaluate_command_thresholds(summary: EvidenceSummary, thresholds: list[CommandThreshold]) -> None:
    if not thresholds:
        return
    stats = command_latency_stats(summary)
    actions = stats["actions"]
    for threshold in thresholds:
        if threshold.action == "*":
            observed = float_value(stats["maxMs"])
            if stats["count"] == 0:
                if threshold.required:
                    summary.threshold_failures.append(
                        f"{threshold.source}: command latency had no matching values"
                    )
                continue
        else:
            action_stats = actions.get(threshold.action)
            if not action_stats:
                if threshold.required:
                    present = ", ".join(sorted(actions)) or "none"
                    summary.threshold_failures.append(
                        f"{threshold.source}: command {threshold.action} had no matching latency values; present={present}"
                    )
                continue
            observed = float_value(action_stats["max"])
        if observed > threshold.limit_ms:
            summary.threshold_failures.append(
                f"{threshold.source}: command {threshold.action} max {observed:g}ms exceeded threshold {threshold.limit_ms:g}ms"
            )


def evaluate_scenario_thresholds(summary: EvidenceSummary, thresholds: list[ScenarioThreshold]) -> None:
    if not thresholds:
        return
    stats = scenario_duration_stats(summary)
    scenarios = stats["scenarios"]
    for threshold in thresholds:
        if threshold.scenario == "*":
            observed = float_value(stats["maxMs"])
            if stats["count"] == 0:
                if threshold.required:
                    summary.threshold_failures.append(
                        f"{threshold.source}: scenario duration had no matching values"
                    )
                continue
        else:
            scenario_stats = scenarios.get(threshold.scenario)
            if not scenario_stats:
                if threshold.required:
                    present = ", ".join(sorted(scenarios)) or "none"
                    summary.threshold_failures.append(
                        f"{threshold.source}: scenario {threshold.scenario} had no matching duration values; present={present}"
                    )
                continue
            observed = float_value(scenario_stats["max"])
        if observed > threshold.limit_ms:
            summary.threshold_failures.append(
                f"{threshold.source}: scenario {threshold.scenario} max {observed:g}ms exceeded threshold {threshold.limit_ms:g}ms"
            )


def evaluate_wait_thresholds(summary: EvidenceSummary, thresholds: list[WaitThreshold]) -> None:
    if not thresholds:
        return
    stats = wait_stats(summary)
    waits = stats["waits"]
    for threshold in thresholds:
        if threshold.description == "*":
            observed = float_value(stats["maxMs"])
            if stats["count"] == 0:
                if threshold.required:
                    summary.threshold_failures.append(
                        f"{threshold.source}: wait latency had no matching values"
                    )
                continue
        else:
            wait_values = waits.get(threshold.description)
            if not wait_values:
                if threshold.required:
                    present = ", ".join(sorted(waits)) or "none"
                    summary.threshold_failures.append(
                        f"{threshold.source}: wait {threshold.description} had no matching latency values; present={present}"
                    )
                continue
            observed = float_value(wait_values["max"])
        if observed > threshold.limit_ms:
            summary.threshold_failures.append(
                f"{threshold.source}: wait {threshold.description} max {observed:g}ms exceeded threshold {threshold.limit_ms:g}ms"
            )


def evaluate_required_provenance(summary: EvidenceSummary) -> None:
    for failure in summary.provenance_missing:
        summary.coverage_failures.append(failure)
    if summary.provenance_expected == 0:
        summary.coverage_failures.append("Missing run.start/suite.start records for provenance validation")
    if len(summary.provenance_records) != summary.provenance_expected:
        summary.coverage_failures.append(
            f"Expected provenance on {summary.provenance_expected} start record(s), found {len(summary.provenance_records)}"
        )
    for index, provenance in enumerate(summary.provenance_records, start=1):
        missing = missing_provenance_fields(provenance)
        if missing:
            summary.coverage_failures.append(
                f"Provenance record {index} missing field(s): {', '.join(missing)}"
            )


def missing_provenance_fields(provenance: dict[str, Any]) -> list[str]:
    required_paths = [
        ("probe", "version"),
        ("probe", "script"),
        ("runtime", "python"),
        ("runtime", "platform"),
        ("git", "repository", "head"),
        ("git", "repository", "dirty"),
        ("git", "mumbleKit", "head"),
        ("git", "mumbleKit", "dirty"),
    ]
    missing: list[str] = []
    for path in required_paths:
        value: Any = provenance
        for part in path:
            if not isinstance(value, dict) or part not in value:
                missing.append(".".join(path))
                break
            value = value[part]
        else:
            if value is None or value == "":
                missing.append(".".join(path))
    return missing


def numeric_values(entries: list[dict[str, Any]], metric: str) -> list[float]:
    values: list[float] = []
    for entry in entries:
        value = entry.get(metric)
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)):
            values.append(float(value))
    return values


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]
    sorted_values = sorted(values)
    index = (len(sorted_values) - 1) * pct
    lower = int(index)
    upper = min(lower + 1, len(sorted_values) - 1)
    weight = index - lower
    return sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight


def perf_stats(summary: EvidenceSummary) -> dict[str, dict[str, dict[str, float]]]:
    result: dict[str, dict[str, dict[str, float]]] = {}
    for marker, entries in sorted(summary.perf_markers.items()):
        metric_stats: dict[str, dict[str, float]] = {}
        metric_names = sorted({key for entry in entries for key in entry if key != "message"})
        for metric in metric_names:
            values = numeric_values(entries, metric)
            if not values:
                continue
            metric_stats[metric] = {
                "count": float(len(values)),
                "min": min(values),
                "mean": statistics.fmean(values),
                "p50": percentile(values, 0.50),
                "p95": percentile(values, 0.95),
                "max": max(values),
            }
        result[marker] = metric_stats
    return result


def performance_stats(summary: EvidenceSummary) -> dict[str, Any]:
    if not summary.performance_snapshots:
        return {
            "count": 0,
            "maxStallCount": 0,
            "maxLagMs": 0.0,
            "latestContext": {},
            "maxContext": {},
            "recentContexts": [],
        }
    max_stall_count = max(int_value(snapshot.get("stallCount")) for snapshot in summary.performance_snapshots)
    max_lag_ms = max(float_value(snapshot.get("maxLagMs")) for snapshot in summary.performance_snapshots)
    latest_context: dict[str, Any] = {}
    max_context: dict[str, Any] = {}
    for snapshot in reversed(summary.performance_snapshots):
        context = snapshot.get("lastStallContext")
        if isinstance(context, dict) and context:
            latest_context = context
            break
    for snapshot in summary.performance_snapshots:
        context = snapshot.get("maxStallContext")
        if isinstance(context, dict) and context:
            max_context = context
    if not max_context:
        max_context = context_with_largest_lag(summary.performance_snapshots)
    return {
        "count": len(summary.performance_snapshots),
        "maxStallCount": max_stall_count,
        "maxLagMs": max_lag_ms,
        "latestContext": latest_context,
        "maxContext": max_context,
        "recentContexts": recent_stall_contexts(summary.performance_snapshots, limit=5),
    }


def context_with_largest_lag(snapshots: list[dict[str, Any]]) -> dict[str, Any]:
    best_context: dict[str, Any] = {}
    best_lag = -1.0
    for snapshot in snapshots:
        context = snapshot.get("lastStallContext")
        if not isinstance(context, dict) or not context:
            continue
        lag = float_value(context.get("lagMs"))
        if lag >= best_lag:
            best_lag = lag
            best_context = context
    return best_context


def recent_stall_contexts(snapshots: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    contexts: list[dict[str, Any]] = []
    seen: set[str] = set()
    for snapshot in reversed(snapshots):
        context = snapshot.get("lastStallContext")
        if not isinstance(context, dict) or not context:
            continue
        key = json.dumps(context, ensure_ascii=False, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        contexts.append(context)
        if len(contexts) >= limit:
            break
    return contexts


def network_stats(summary: EvidenceSummary) -> dict[str, Any]:
    if not summary.network_snapshots:
        return {
            "count": 0,
            "connectedCount": 0,
            "reconnectingCount": 0,
            "udpStates": {},
            "udpProblemStateCount": 0,
            "maxUdpPingMeanMs": 0.0,
            "maxPacketLossPercent": 0.0,
            "packetLossObservedCount": 0,
            "timelineCount": 0,
            "timelineKinds": {},
            "timelineWarningCount": 0,
            "timelineErrorCount": 0,
            "networkIssueCount": 0,
            "networkIssueKinds": {},
            "networkHealth": {
                "status": "unknown",
                "rootCauseHint": "no_network_snapshots",
                "latestIssue": {},
                "recommendations": ["Collect network.status evidence with --require-network-snapshot."],
            },
            "recentTimeline": [],
            "latest": {},
        }

    udp_states: Counter[str] = Counter()
    timeline_kinds: Counter[str] = Counter()
    issue_kinds: Counter[str] = Counter()
    issues: list[dict[str, Any]] = []
    connected_count = 0
    reconnecting_count = 0
    udp_problem_state_count = 0
    max_udp_ping_mean_ms = 0.0
    max_packet_loss_percent = 0.0
    packet_loss_observed_count = 0
    timeline_warning_count = 0
    timeline_error_count = 0
    recent_timeline: list[dict[str, Any]] = []
    for snapshot_index, snapshot in enumerate(summary.network_snapshots, start=1):
        connection = snapshot.get("connection")
        if isinstance(connection, dict):
            if bool(connection.get("connected")):
                connected_count += 1
            if bool(connection.get("isReconnecting")):
                reconnecting_count += 1
                add_network_issue(
                    issues,
                    issue_kinds,
                    "warning",
                    "reconnecting_snapshot",
                    "network.status reported reconnecting=true",
                    snapshot_index=snapshot_index,
                )
        transport = snapshot.get("transport")
        if isinstance(transport, dict):
            state = str(transport.get("udpState", "unknown"))
            udp_states[state] += 1
            if state in NETWORK_UDP_PROBLEM_STATES:
                udp_problem_state_count += 1
                add_network_issue(
                    issues,
                    issue_kinds,
                    "warning",
                    f"udp_{state}",
                    f"UDP transport state is {state}",
                    snapshot_index=snapshot_index,
                    details={"udpState": state},
                )
            udp_ping_mean_ms = float_value(transport.get("udpPingMeanMs"))
            packet_loss_percent = float_value(transport.get("packetLossPercent"))
            max_udp_ping_mean_ms = max(max_udp_ping_mean_ms, udp_ping_mean_ms)
            max_packet_loss_percent = max(max_packet_loss_percent, packet_loss_percent)
            if udp_ping_mean_ms > NETWORK_HIGH_UDP_PING_MS:
                add_network_issue(
                    issues,
                    issue_kinds,
                    "warning",
                    "high_udp_ping",
                    f"UDP ping mean is {udp_ping_mean_ms:.2f}ms",
                    snapshot_index=snapshot_index,
                    details={"udpPingMeanMs": udp_ping_mean_ms},
                )
            if packet_loss_percent > 0.0:
                packet_loss_observed_count += 1
                add_network_issue(
                    issues,
                    issue_kinds,
                    "warning",
                    "packet_loss_observed",
                    f"Packet loss is {packet_loss_percent:.2f}%",
                    snapshot_index=snapshot_index,
                    details={"packetLossPercent": packet_loss_percent},
                )
        timeline = snapshot.get("timeline")
        if isinstance(timeline, list):
            for item in timeline:
                if not isinstance(item, dict):
                    continue
                kind = str(item.get("kind", "unknown"))
                level = str(item.get("level", "")).lower()
                timeline_kinds[kind] += 1
                if level == "warning":
                    timeline_warning_count += 1
                    add_network_issue(
                        issues,
                        issue_kinds,
                        "warning",
                        f"timeline_{kind}",
                        str(item.get("message", "")),
                        timestamp=item.get("timestamp"),
                        snapshot_index=snapshot_index,
                        details=item,
                    )
                elif level == "error":
                    timeline_error_count += 1
                    add_network_issue(
                        issues,
                        issue_kinds,
                        "error",
                        f"timeline_{kind}",
                        str(item.get("message", "")),
                        timestamp=item.get("timestamp"),
                        snapshot_index=snapshot_index,
                        details=item,
                    )
                recent_timeline.append(item)
    health = network_health_summary(issues, issue_kinds, timeline_kinds)

    return {
        "count": len(summary.network_snapshots),
        "connectedCount": connected_count,
        "reconnectingCount": reconnecting_count,
        "udpStates": dict(sorted(udp_states.items())),
        "udpProblemStateCount": udp_problem_state_count,
        "maxUdpPingMeanMs": max_udp_ping_mean_ms,
        "maxPacketLossPercent": max_packet_loss_percent,
        "packetLossObservedCount": packet_loss_observed_count,
        "timelineCount": sum(timeline_kinds.values()),
        "timelineKinds": dict(sorted(timeline_kinds.items())),
        "timelineWarningCount": timeline_warning_count,
        "timelineErrorCount": timeline_error_count,
        "networkIssueCount": len(issues),
        "networkIssueKinds": dict(sorted(issue_kinds.items())),
        "networkHealth": health,
        "recentTimeline": recent_timeline[-5:],
        "latest": summary.network_snapshots[-1],
    }


def network_stats_by_scenario(summary: EvidenceSummary) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for snapshot in summary.network_snapshots:
        scenario = str(snapshot.get("_scenario") or "unknown")
        grouped[scenario].append(snapshot)
    scenarios: dict[str, dict[str, Any]] = {}
    for scenario, snapshots in sorted(grouped.items()):
        scenario_summary = EvidenceSummary(network_snapshots=snapshots)
        stats = network_stats(scenario_summary)
        health = stats["networkHealth"]
        root_cause = str(health.get("rootCauseHint", "unknown"))
        expected_root_causes = EXPECTED_NETWORK_ROOT_CAUSES_BY_SCENARIO.get(scenario, set())
        stats["expectedRootCause"] = root_cause in expected_root_causes
        stats["expectedRootCauses"] = sorted(expected_root_causes)
        scenarios[scenario] = stats
    return {
        "count": len(scenarios),
        "scenarios": scenarios,
    }


def add_network_issue(
    issues: list[dict[str, Any]],
    issue_kinds: Counter[str],
    severity: str,
    kind: str,
    summary: str,
    snapshot_index: int,
    timestamp: Any = None,
    details: dict[str, Any] | None = None,
) -> None:
    issue = {
        "severity": severity,
        "kind": kind,
        "summary": summary,
        "snapshotIndex": snapshot_index,
        "timestamp": str(timestamp) if timestamp else "",
        "details": details or {},
    }
    issues.append(issue)
    issue_kinds[kind] += 1


def network_health_summary(
    issues: list[dict[str, Any]],
    issue_kinds: Counter[str],
    timeline_kinds: Counter[str],
) -> dict[str, Any]:
    has_error = any(str(issue.get("severity")) == "error" for issue in issues)
    has_connect_failure = timeline_kinds.get("connect_failed", 0) > 0
    if not issues and not has_connect_failure:
        return {
            "status": "ok",
            "rootCauseHint": "none",
            "latestIssue": {},
            "recommendations": [],
        }
    status = "failing" if has_error or has_connect_failure else "degraded"
    root_cause_hint = network_root_cause_hint(issue_kinds, timeline_kinds)
    return {
        "status": status,
        "rootCauseHint": root_cause_hint,
        "latestIssue": issues[-1] if issues else {},
        "recommendations": network_recommendations(root_cause_hint),
    }


def network_root_cause_hint(issue_kinds: Counter[str], timeline_kinds: Counter[str]) -> str:
    keys = set(issue_kinds) | set(timeline_kinds)
    if any(key.startswith("timeline_certificate") for key in keys) or "certificate" in keys:
        return "certificate_or_tls"
    if "reconnecting_snapshot" in keys or "reconnect" in keys or any(key.startswith("timeline_reconnect") for key in keys):
        return "reconnect_loop"
    if "connect_failed" in keys or any(key.startswith("timeline_connect_failed") for key in keys):
        return "connection_failure"
    if any(key.startswith("udp_") or key.startswith("timeline_udp") for key in keys):
        return "udp_transport"
    if "packet_loss_observed" in keys:
        return "packet_loss"
    if "high_udp_ping" in keys:
        return "network_latency"
    if any(key.startswith("timeline_") for key in keys):
        return "network_timeline"
    return "unknown"


def network_recommendations(root_cause_hint: str) -> list[str]:
    recommendations = {
        "certificate_or_tls": [
            "Inspect Certificate and Connection timeline entries around the first failure.",
            "Compare with PERF connect_begin/connect_failed/connect_ready markers.",
        ],
        "connection_failure": [
            "Check connection.status and recent Connection logs for the first failed open or close.",
            "Run the same scenario with artifacts kept and compare against a passing trace.",
        ],
        "reconnect_loop": [
            "Inspect reconnectAttempt, reconnectReason, and NetworkAutoReconnect settings.",
            "Verify the run did not enter generic reconnect handling after a TLS or transport-specific failure.",
        ],
        "udp_transport": [
            "Inspect udpState, UDP ping samples, packet loss, and recent Network logs.",
            "Compare Force TCP and UDP runs to separate control-channel stability from voice transport instability.",
        ],
        "packet_loss": [
            "Inspect packet accounting totals and confirm whether loss grows during voice activity.",
            "Compare before/after traces with mumble_trace_compare.py.",
        ],
        "network_latency": [
            "Check whether high UDP ping aligns with command latency or main-thread stall events.",
            "Use the incident timeline to separate app-side stalls from network path latency.",
        ],
        "network_timeline": [
            "Open the Network Timeline section and inspect the earliest warning or error entry.",
        ],
    }
    return recommendations.get(root_cause_hint, ["Inspect the Network Timeline and diagnostic snapshot for first failure evidence."])


def diagnostic_stats(summary: EvidenceSummary) -> dict[str, Any]:
    if not summary.diagnostic_snapshots:
        return {
            "count": 0,
            "latest": {},
            "commands": {},
        }
    latest = summary.diagnostic_snapshots[-1]
    commands: Counter[str] = Counter()
    data = latest.get("data")
    if isinstance(data, dict):
        for command in data:
            commands[str(command)] += 1
    return {
        "count": len(summary.diagnostic_snapshots),
        "latest": latest,
        "commands": dict(sorted(commands.items())),
    }


def command_latency_stats(summary: EvidenceSummary) -> dict[str, Any]:
    if not summary.command_latencies:
        return {
            "count": 0,
            "maxMs": 0.0,
            "slowest": {},
            "actions": {},
        }
    slowest = max(summary.command_latencies, key=lambda item: float_value(item.get("durationMs")))
    actions: dict[str, dict[str, float]] = {}
    action_names = sorted({str(item.get("action", "unknown")) for item in summary.command_latencies})
    for action in action_names:
        values = [
            float_value(item.get("durationMs"))
            for item in summary.command_latencies
            if str(item.get("action", "unknown")) == action
        ]
        actions[action] = {
            "count": float(len(values)),
            "min": min(values),
            "mean": statistics.fmean(values),
            "p50": percentile(values, 0.50),
            "p95": percentile(values, 0.95),
            "max": max(values),
        }
    return {
        "count": len(summary.command_latencies),
        "maxMs": float_value(slowest.get("durationMs")),
        "slowest": slowest,
        "actions": actions,
    }


def scenario_duration_stats(summary: EvidenceSummary) -> dict[str, Any]:
    if not summary.run_durations:
        return {
            "count": 0,
            "maxMs": 0.0,
            "slowest": {},
            "scenarios": {},
        }
    slowest = max(summary.run_durations, key=lambda item: float_value(item.get("durationMs")))
    scenarios: dict[str, dict[str, float]] = {}
    scenario_names = sorted({str(item.get("scenario", "unknown")) for item in summary.run_durations})
    for scenario in scenario_names:
        values = [
            float_value(item.get("durationMs"))
            for item in summary.run_durations
            if str(item.get("scenario", "unknown")) == scenario
        ]
        scenarios[scenario] = {
            "count": float(len(values)),
            "min": min(values),
            "mean": statistics.fmean(values),
            "p50": percentile(values, 0.50),
            "p95": percentile(values, 0.95),
            "max": max(values),
        }
    return {
        "count": len(summary.run_durations),
        "maxMs": float_value(slowest.get("durationMs")),
        "slowest": slowest,
        "scenarios": scenarios,
    }


def scenario_outcome_stats(summary: EvidenceSummary) -> dict[str, Any]:
    if not summary.suite_scenario_outcomes:
        return {
            "count": 0,
            "passed": 0,
            "failed": 0,
            "passRate": 0.0,
            "maxRepeat": 0,
            "scenarios": {},
            "failures": [],
        }
    scenarios: dict[str, dict[str, Any]] = {}
    failures: list[dict[str, Any]] = []
    for outcome in summary.suite_scenario_outcomes:
        scenario = str(outcome.get("scenario", "unknown"))
        entry = scenarios.setdefault(
            scenario,
            {
                "count": 0,
                "passed": 0,
                "failed": 0,
                "passRate": 0.0,
                "maxRepeat": 0,
                "maxElapsedMs": 0.0,
                "failedIterations": [],
            },
        )
        entry["count"] += 1
        entry["maxRepeat"] = max(int_value(entry["maxRepeat"]), int_value(outcome.get("repeat")))
        entry["maxElapsedMs"] = max(float_value(entry["maxElapsedMs"]), float_value(outcome.get("elapsedMs")))
        if bool(outcome.get("passed")):
            entry["passed"] += 1
        else:
            entry["failed"] += 1
            failure = {
                "scenario": scenario,
                "iteration": outcome.get("iteration", 1),
                "exitCode": outcome.get("exitCode", 0),
                "output": outcome.get("output", ""),
                "source": outcome.get("source", ""),
            }
            entry["failedIterations"].append(failure)
            failures.append(failure)
    total = len(summary.suite_scenario_outcomes)
    passed = sum(1 for outcome in summary.suite_scenario_outcomes if bool(outcome.get("passed")))
    failed = total - passed
    for entry in scenarios.values():
        count = int_value(entry["count"])
        entry["passRate"] = (float_value(entry["passed"]) / float(count)) if count else 0.0
    return {
        "count": total,
        "passed": passed,
        "failed": failed,
        "passRate": float(passed) / float(total) if total else 0.0,
        "maxRepeat": max(int_value(outcome.get("repeat")) for outcome in summary.suite_scenario_outcomes),
        "scenarios": dict(sorted(scenarios.items())),
        "failures": failures,
    }


def wait_stats(summary: EvidenceSummary) -> dict[str, Any]:
    if not summary.waits:
        return {
            "count": 0,
            "failedCount": 0,
            "maxMs": 0.0,
            "slowest": {},
            "waits": {},
        }
    slowest = max(summary.waits, key=lambda item: float_value(item.get("elapsedMs")))
    failed_count = sum(1 for item in summary.waits if not bool(item.get("passed")))
    waits: dict[str, dict[str, float]] = {}
    descriptions = sorted({str(item.get("description", "unknown")) for item in summary.waits})
    for description in descriptions:
        matching = [item for item in summary.waits if str(item.get("description", "unknown")) == description]
        values = [float_value(item.get("elapsedMs")) for item in matching]
        attempts = [float_value(item.get("attempts")) for item in matching]
        waits[description] = {
            "count": float(len(values)),
            "failedCount": float(sum(1 for item in matching if not bool(item.get("passed")))),
            "min": min(values),
            "mean": statistics.fmean(values),
            "p50": percentile(values, 0.50),
            "p95": percentile(values, 0.95),
            "max": max(values),
            "maxAttempts": max(attempts) if attempts else 0.0,
        }
    return {
        "count": len(summary.waits),
        "failedCount": failed_count,
        "maxMs": float_value(slowest.get("elapsedMs")),
        "slowest": slowest,
        "waits": waits,
    }


def incident_timeline(summary: EvidenceSummary, limit: int = 20) -> dict[str, Any]:
    items: list[dict[str, Any]] = []
    for item in summary.waits:
        elapsed_ms = float_value(item.get("elapsedMs"))
        passed = bool(item.get("passed"))
        if passed and elapsed_ms < INCIDENT_SLOW_WAIT_MS:
            continue
        severity = "error" if not passed else "warning"
        kind = "failed_wait" if not passed else "slow_wait"
        items.append(
            incident_item(
                timestamp=item.get("timestamp"),
                severity=severity,
                kind=kind,
                summary=f"{item.get('description', 'unknown')} waited {elapsed_ms:.2f}ms attempts={item.get('attempts', 0)}",
                details=item,
            )
        )

    for item in summary.command_latencies:
        duration_ms = float_value(item.get("durationMs"))
        if duration_ms < INCIDENT_SLOW_COMMAND_MS:
            continue
        items.append(
            incident_item(
                timestamp=item.get("respondedAt"),
                severity="warning",
                kind="slow_command",
                summary=f"{item.get('action', 'unknown')} took {duration_ms:.2f}ms",
                details={
                    "id": item.get("id", ""),
                    "action": item.get("action", "unknown"),
                    "durationMs": duration_ms,
                },
            )
        )

    seen_stalls: set[str] = set()
    for snapshot in summary.performance_snapshots:
        stall_count = int_value(snapshot.get("stallCount"))
        max_lag_ms = float_value(snapshot.get("maxLagMs"))
        context = snapshot.get("lastStallContext")
        if stall_count <= 0 and max_lag_ms <= 0:
            continue
        if not isinstance(context, dict) or not context:
            context = snapshot.get("maxStallContext")
        details = {
            "stallCount": stall_count,
            "maxLagMs": max_lag_ms,
            "context": context if isinstance(context, dict) else {},
        }
        key = json.dumps(details, ensure_ascii=False, sort_keys=True)
        if key in seen_stalls:
            continue
        seen_stalls.add(key)
        items.append(
            incident_item(
                timestamp=snapshot.get("_timestamp"),
                severity="warning",
                kind="main_thread_stall",
                summary=f"main thread stall maxLagMs={max_lag_ms:.2f} stallCount={stall_count}",
                details=details,
            )
        )

    for snapshot in summary.network_snapshots:
        timeline = snapshot.get("timeline")
        if not isinstance(timeline, list):
            continue
        for event in timeline:
            if not isinstance(event, dict):
                continue
            level = str(event.get("level", "")).lower()
            if level not in {"warning", "error"}:
                continue
            kind = str(event.get("kind", "network"))
            items.append(
                incident_item(
                    timestamp=event.get("timestamp"),
                    severity=level,
                    kind=f"network_{kind}",
                    summary=str(event.get("message", "")),
                    details=event,
                )
            )

    for snapshot in summary.diagnostic_snapshots:
        failures = snapshot.get("failures")
        items.append(
            incident_item(
                timestamp=snapshot.get("timestamp"),
                severity="error",
                kind="diagnostic_snapshot",
                summary=f"diagnostic snapshot reason={snapshot.get('reason', 'unknown')}",
                details={
                    "scenario": snapshot.get("scenario", "unknown"),
                    "reason": snapshot.get("reason", "unknown"),
                    "failures": failures if isinstance(failures, list) else [],
                },
            )
        )

    for outcome in summary.suite_scenario_outcomes:
        if bool(outcome.get("passed")):
            continue
        items.append(
            incident_item(
                timestamp="",
                severity="error",
                kind="suite_scenario_failure",
                summary=f"{outcome.get('scenario', 'unknown')} iteration {outcome.get('iteration', 1)} exited {outcome.get('exitCode', 0)}",
                details=outcome,
            )
        )

    failure_groups = [
        ("run_failure", summary.run_failures),
        ("command_failure", summary.command_failures),
        ("assertion_failure", summary.assertion_failures),
        ("coverage_failure", summary.coverage_failures),
        ("threshold_failure", summary.threshold_failures),
    ]
    for kind, failures in failure_groups:
        for failure in failures:
            items.append(
                incident_item(
                    timestamp="",
                    severity="error",
                    kind=kind,
                    summary=failure,
                    details={},
                )
            )

    sorted_items = sorted(items, key=incident_sort_key)
    severities = Counter(str(item.get("severity", "unknown")) for item in sorted_items)
    kinds = Counter(str(item.get("kind", "unknown")) for item in sorted_items)
    return {
        "count": len(sorted_items),
        "severities": dict(sorted(severities.items())),
        "kinds": dict(sorted(kinds.items())),
        "items": sorted_items[:limit],
    }


def incident_item(timestamp: Any, severity: str, kind: str, summary: str, details: dict[str, Any]) -> dict[str, Any]:
    return {
        "timestamp": str(timestamp) if timestamp else "",
        "severity": severity,
        "kind": kind,
        "summary": summary,
        "details": details,
    }


def incident_sort_key(item: dict[str, Any]) -> tuple[int, str, str]:
    timestamp = str(item.get("timestamp") or "")
    if not timestamp:
        return (1, "", str(item.get("kind", "")))
    return (0, timestamp.replace(" ", "T"), str(item.get("kind", "")))


def provenance_summary(summary: EvidenceSummary) -> dict[str, Any]:
    probe_versions = sorted({
        value
        for provenance in summary.provenance_records
        if (value := nested_value(provenance, ("probe", "version"))) is not None
    })
    repository_heads = sorted({
        str(value)
        for provenance in summary.provenance_records
        if (value := nested_value(provenance, ("git", "repository", "head")))
    })
    mumblekit_heads = sorted({
        str(value)
        for provenance in summary.provenance_records
        if (value := nested_value(provenance, ("git", "mumbleKit", "head")))
    })
    repository_dirty = any(
        bool(nested_value(provenance, ("git", "repository", "dirty")))
        for provenance in summary.provenance_records
    )
    mumblekit_dirty = any(
        bool(nested_value(provenance, ("git", "mumbleKit", "dirty")))
        for provenance in summary.provenance_records
    )
    return {
        "expected": summary.provenance_expected,
        "count": len(summary.provenance_records),
        "missing": summary.provenance_missing,
        "probeVersions": probe_versions,
        "repositoryHeads": repository_heads,
        "mumbleKitHeads": mumblekit_heads,
        "repositoryDirty": repository_dirty,
        "mumbleKitDirty": mumblekit_dirty,
    }


def nested_value(data: dict[str, Any], path: tuple[str, ...]) -> Any:
    value: Any = data
    for part in path:
        if not isinstance(value, dict):
            return None
        value = value.get(part)
    return value


def int_value(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    return 0


def float_value(value: Any) -> float:
    if isinstance(value, bool):
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    return 0.0


def to_json(summary: EvidenceSummary) -> dict[str, Any]:
    return {
        "files": summary.files,
        "failed": summary.failed,
        "records": summary.records,
        "recordTypes": dict(summary.record_types),
        "scenarios": dict(summary.scenarios),
        "suiteIds": dict(summary.suite_ids),
        "suiteScenarios": dict(summary.suite_scenarios),
        "scenarioOutcomes": scenario_outcome_stats(summary),
        "events": dict(summary.events),
        "commands": dict(summary.commands),
        "logEntries": summary.log_entries,
        "perfMarkers": {key: len(value) for key, value in sorted(summary.perf_markers.items())},
        "perfStats": perf_stats(summary),
        "scenarioDuration": scenario_duration_stats(summary),
        "waitLatency": wait_stats(summary),
        "commandLatency": command_latency_stats(summary),
        "performance": performance_stats(summary),
        "network": network_stats(summary),
        "networkByScenario": network_stats_by_scenario(summary),
        "diagnostics": diagnostic_stats(summary),
        "incidentTimeline": incident_timeline(summary),
        "provenance": provenance_summary(summary),
        "malformedLines": summary.malformed_lines,
        "runFailures": summary.run_failures,
        "commandFailures": summary.command_failures,
        "assertionFailures": summary.assertion_failures,
        "coverageFailures": summary.coverage_failures,
        "thresholdFailures": summary.threshold_failures,
    }


def print_text(summary: EvidenceSummary) -> None:
    print(f"files: {len(summary.files)}")
    print(f"records: {summary.records}")
    print(f"status: {'failed' if summary.failed else 'passed'}")
    print("")
    print("record types:")
    for name, count in sorted(summary.record_types.items()):
        print(f"  {name}: {count}")
    print("")
    print("scenarios:")
    if not summary.scenarios:
        print("  none")
    for name, count in sorted(summary.scenarios.items()):
        print(f"  {name}: {count}")
    print("")
    print("suite ids:")
    if not summary.suite_ids:
        print("  none")
    for name, count in sorted(summary.suite_ids.items()):
        print(f"  {name}: {count}")
    print("")
    print("suite scenarios:")
    if not summary.suite_scenarios:
        print("  none")
    for name, count in sorted(summary.suite_scenarios.items()):
        print(f"  {name}: {count}")
    print("")
    print("scenario outcomes:")
    outcomes = scenario_outcome_stats(summary)
    if outcomes["count"] == 0:
        print("  none")
    else:
        print(
            "  "
            f"count={outcomes['count']} passed={outcomes['passed']} failed={outcomes['failed']} "
            f"passRate={float(outcomes['passRate']) * 100.0:.1f}% maxRepeat={outcomes['maxRepeat']}"
        )
        for scenario, values in outcomes["scenarios"].items():
            print(
                "    "
                f"{scenario}: count={values['count']} passed={values['passed']} failed={values['failed']} "
                f"passRate={float(values['passRate']) * 100.0:.1f}% maxElapsedMs={float(values['maxElapsedMs']):.2f}"
            )
    print("")
    print("scenario duration:")
    scenario_duration = scenario_duration_stats(summary)
    if scenario_duration["count"] == 0:
        print("  none")
    else:
        slowest = scenario_duration["slowest"]
        print(
            "  "
            f"count={scenario_duration['count']} "
            f"maxMs={scenario_duration['maxMs']:.2f} "
            f"slowest={slowest.get('scenario', 'unknown')}"
        )
        for scenario, values in scenario_duration["scenarios"].items():
            print(
                "    "
                f"{scenario}: count={values['count']:.0f} "
                f"min={values['min']:.2f} p50={values['p50']:.2f} "
                f"p95={values['p95']:.2f} max={values['max']:.2f}"
            )
    print("")
    print("events:")
    for name, count in sorted(summary.events.items()):
        print(f"  {name}: {count}")
    print("")
    print("commands:")
    for name, count in sorted(summary.commands.items()):
        print(f"  {name}: {count}")
    print("")
    print("wait latency:")
    wait_latency = wait_stats(summary)
    if wait_latency["count"] == 0:
        print("  none")
    else:
        slowest = wait_latency["slowest"]
        print(
            "  "
            f"count={wait_latency['count']} "
            f"failed={wait_latency['failedCount']} "
            f"maxMs={wait_latency['maxMs']:.2f} "
            f"slowest={slowest.get('description', 'unknown')}"
        )
        for description, values in wait_latency["waits"].items():
            print(
                "    "
                f"{description}: count={values['count']:.0f} failed={values['failedCount']:.0f} "
                f"min={values['min']:.2f} p50={values['p50']:.2f} "
                f"p95={values['p95']:.2f} max={values['max']:.2f} attempts={values['maxAttempts']:.0f}"
            )
    print("")
    print("command latency:")
    command_latency = command_latency_stats(summary)
    if command_latency["count"] == 0:
        print("  none")
    else:
        slowest = command_latency["slowest"]
        print(
            "  "
            f"count={command_latency['count']} "
            f"maxMs={command_latency['maxMs']:.2f} "
            f"slowest={slowest.get('action', 'unknown')}"
        )
        for action, values in command_latency["actions"].items():
            print(
                "    "
                f"{action}: count={values['count']:.0f} "
                f"min={values['min']:.2f} p50={values['p50']:.2f} "
                f"p95={values['p95']:.2f} max={values['max']:.2f}"
            )
    print("")
    print("PERF markers:")
    stats = perf_stats(summary)
    if not stats:
        print("  none")
    for marker, metrics in stats.items():
        print(f"  {marker}:")
        for metric, values in metrics.items():
            print(
                "    "
                f"{metric}: count={values['count']:.0f} "
                f"min={values['min']:.2f} p50={values['p50']:.2f} "
                f"p95={values['p95']:.2f} max={values['max']:.2f}"
            )
    print("")
    print("performance snapshots:")
    perf = performance_stats(summary)
    if perf["count"] == 0:
        print("  none")
    else:
        print(
            "  "
            f"count={perf['count']} "
            f"maxStallCount={perf['maxStallCount']} "
            f"maxLagMs={perf['maxLagMs']:.2f}"
        )
        if perf["maxContext"]:
            print(f"  maxContext={json.dumps(perf['maxContext'], ensure_ascii=False, sort_keys=True)}")
        if perf["latestContext"]:
            print(f"  latestContext={json.dumps(perf['latestContext'], ensure_ascii=False, sort_keys=True)}")
    print("")
    print("network snapshots:")
    network = network_stats(summary)
    if network["count"] == 0:
        print("  none")
    else:
        print(
            "  "
            f"count={network['count']} "
            f"connected={network['connectedCount']} "
            f"reconnecting={network['reconnectingCount']} "
            f"udpStates={network['udpStates']} "
            f"timeline={network['timelineCount']} "
            f"timelineWarnings={network['timelineWarningCount']} "
            f"timelineErrors={network['timelineErrorCount']} "
            f"health={network['networkHealth']['status']} "
            f"rootCause={network['networkHealth']['rootCauseHint']}"
        )
        if network["networkIssueKinds"]:
            print(f"  networkIssueKinds={network['networkIssueKinds']}")
        if network["timelineKinds"]:
            print(f"  timelineKinds={network['timelineKinds']}")
        if network["latest"]:
            print(f"  latest={json.dumps(network['latest'], ensure_ascii=False, sort_keys=True)}")
    network_by_scenario = network_stats_by_scenario(summary)
    if network_by_scenario["count"]:
        print("  by scenario:")
        for scenario, values in network_by_scenario["scenarios"].items():
            health = values["networkHealth"]
            expected = " expected" if values.get("expectedRootCause") else ""
            print(
                "    "
                f"{scenario}: snapshots={values['count']} "
                f"health={health.get('status', 'unknown')} "
                f"rootCause={health.get('rootCauseHint', 'unknown')}{expected} "
                f"timelineKinds={values['timelineKinds']}"
            )
    print("")
    print("diagnostic snapshots:")
    diagnostics = diagnostic_stats(summary)
    if diagnostics["count"] == 0:
        print("  none")
    else:
        latest = diagnostics["latest"]
        print(
            "  "
            f"count={diagnostics['count']} "
            f"latestReason={latest.get('reason', 'unknown')} "
            f"commands={list(diagnostics['commands'])}"
        )
    print("")
    print("incident timeline:")
    incidents = incident_timeline(summary)
    if incidents["count"] == 0:
        print("  none")
    else:
        print(
            "  "
            f"count={incidents['count']} "
            f"severities={incidents['severities']} "
            f"kinds={incidents['kinds']}"
        )
        for item in incidents["items"][:5]:
            print(
                "    "
                f"{item.get('timestamp') or 'no-time'} "
                f"{item.get('severity')} "
                f"{item.get('kind')}: {item.get('summary')}"
            )
    print("")
    print("provenance:")
    provenance = provenance_summary(summary)
    if provenance["count"] == 0:
        print("  none")
    else:
        print(
            "  "
            f"count={provenance['count']}/{provenance['expected']} "
            f"probeVersions={provenance['probeVersions']} "
            f"repositoryHeads={provenance['repositoryHeads']} "
            f"mumbleKitHeads={provenance['mumbleKitHeads']} "
            f"repositoryDirty={provenance['repositoryDirty']} "
            f"mumbleKitDirty={provenance['mumbleKitDirty']}"
        )
    print_failures(summary)


def print_markdown(summary: EvidenceSummary) -> None:
    data = to_json(summary)
    perf = data["performance"]
    scenario_duration = data["scenarioDuration"]
    scenario_outcomes = data["scenarioOutcomes"]
    wait_latency = data["waitLatency"]
    command_latency = data["commandLatency"]
    provenance = data["provenance"]
    print("# Mumble Probe Evidence Report")
    print("")
    print("## Summary")
    print("")
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Status | {md('failed' if data['failed'] else 'passed')} |")
    print(f"| Files | {len(data['files'])} |")
    print(f"| Records | {data['records']} |")
    print(f"| Log entries | {data['logEntries']} |")
    print(f"| Performance snapshots | {perf['count']} |")
    print(f"| Network snapshots | {data['network']['count']} |")
    print(f"| Diagnostic snapshots | {data['diagnostics']['count']} |")
    print(f"| Incident timeline items | {data['incidentTimeline']['count']} |")
    print(f"| Scenario pass rate | {float(scenario_outcomes['passRate']) * 100.0:.1f}% |")
    print(f"| Scenario duration max ms | {float(scenario_duration['maxMs']):.2f} |")
    print(f"| Wait latency max ms | {float(wait_latency['maxMs']):.2f} |")
    print(f"| Command latency max ms | {float(command_latency['maxMs']):.2f} |")
    print(f"| Max stall count | {perf['maxStallCount']} |")
    print(f"| Max lag ms | {float(perf['maxLagMs']):.2f} |")
    print("")
    print_counter_table("Scenarios", data["scenarios"])
    print_counter_table("Suite Scenarios", data["suiteScenarios"])
    print_counter_table("Events", data["events"])
    print_counter_table("Commands", data["commands"])
    print_scenario_outcomes_markdown(scenario_outcomes)
    print_scenario_duration_markdown(scenario_duration)
    print_wait_latency_markdown(wait_latency)
    print_command_latency_markdown(command_latency)
    print_perf_markdown(data["perfStats"])
    print_network_markdown(data["network"])
    print_network_by_scenario_markdown(data["networkByScenario"])
    print_diagnostics_markdown(data["diagnostics"])
    print_incident_timeline_markdown(data["incidentTimeline"])
    print("")
    print("## Provenance")
    print("")
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Records | {provenance['count']}/{provenance['expected']} |")
    print(f"| Probe versions | {md_list(provenance['probeVersions'])} |")
    print(f"| Repository HEADs | {md_list(provenance['repositoryHeads'])} |")
    print(f"| MumbleKit HEADs | {md_list(provenance['mumbleKitHeads'])} |")
    print(f"| Repository dirty | {provenance['repositoryDirty']} |")
    print(f"| MumbleKit dirty | {provenance['mumbleKitDirty']} |")
    if provenance["missing"]:
        print("")
        print_list("Missing Provenance", provenance["missing"])
    if perf["maxContext"]:
        print("")
        print("## Max Stall Context")
        print("")
        print("```json")
        print(json.dumps(perf["maxContext"], ensure_ascii=False, indent=2, sort_keys=True))
        print("```")
    if perf["latestContext"]:
        print("")
        print("## Latest Stall Context")
        print("")
        print("```json")
        print(json.dumps(perf["latestContext"], ensure_ascii=False, indent=2, sort_keys=True))
        print("```")
    if perf["recentContexts"]:
        print("")
        print("## Recent Stall Contexts")
        print("")
        print("```json")
        print(json.dumps(perf["recentContexts"], ensure_ascii=False, indent=2, sort_keys=True))
        print("```")
    print_failure_markdown(summary)


def markdown_text(summary: EvidenceSummary) -> str:
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        print_markdown(summary)
    return buffer.getvalue()


def print_counter_table(title: str, values: dict[str, Any]) -> None:
    print("")
    print(f"## {title}")
    print("")
    if not values:
        print("None.")
        return
    print("| Name | Count |")
    print("|---|---:|")
    for name, count in sorted(values.items()):
        print(f"| {md(name)} | {count} |")


def print_perf_markdown(stats: dict[str, Any]) -> None:
    print("")
    print("## PERF Metrics")
    print("")
    if not stats:
        print("None.")
        return
    print("| Marker | Metric | Count | Min | P50 | P95 | Max |")
    print("|---|---|---:|---:|---:|---:|---:|")
    for marker, metrics in sorted(stats.items()):
        for metric, values in sorted(metrics.items()):
            print(
                f"| {md(marker)} | {md(metric)} | "
                f"{values['count']:.0f} | {values['min']:.2f} | {values['p50']:.2f} | "
                f"{values['p95']:.2f} | {values['max']:.2f} |"
            )


def print_scenario_outcomes_markdown(outcomes: dict[str, Any]) -> None:
    print("")
    print("## Scenario Outcomes")
    print("")
    if outcomes["count"] == 0:
        print("None.")
        return
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Runs | {outcomes['count']} |")
    print(f"| Passed | {outcomes['passed']} |")
    print(f"| Failed | {outcomes['failed']} |")
    print(f"| Pass rate | {float(outcomes['passRate']) * 100.0:.1f}% |")
    print(f"| Max repeat | {outcomes['maxRepeat']} |")
    print("")
    print("| Scenario | Runs | Passed | Failed | Pass rate | Max elapsed ms |")
    print("|---|---:|---:|---:|---:|---:|")
    for scenario, values in sorted(outcomes["scenarios"].items()):
        print(
            f"| {md(scenario)} | {values['count']} | {values['passed']} | {values['failed']} | "
            f"{float(values['passRate']) * 100.0:.1f}% | {float(values['maxElapsedMs']):.2f} |"
        )
    if outcomes["failures"]:
        print("")
        print("### Failed Scenario Iterations")
        print("")
        print("| Scenario | Iteration | Exit code | Output |")
        print("|---|---:|---:|---|")
        for failure in outcomes["failures"]:
            print(
                f"| {md(failure.get('scenario', 'unknown'))} | {failure.get('iteration', 1)} | "
                f"{failure.get('exitCode', 0)} | {md(failure.get('output', ''))} |"
            )


def print_scenario_duration_markdown(scenario_duration: dict[str, Any]) -> None:
    print("")
    print("## Scenario Duration")
    print("")
    if scenario_duration["count"] == 0:
        print("None.")
        return
    slowest = scenario_duration["slowest"]
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Samples | {scenario_duration['count']} |")
    print(f"| Slowest scenario | {md(slowest.get('scenario', 'unknown'))} |")
    print(f"| Slowest ms | {float_value(slowest.get('durationMs')):.2f} |")
    print(f"| Slowest run id | {md(slowest.get('runId', 'unknown'))} |")
    print("")
    print("| Scenario | Count | Min ms | P50 ms | P95 ms | Max ms |")
    print("|---|---:|---:|---:|---:|---:|")
    for scenario, values in sorted(scenario_duration["scenarios"].items()):
        print(
            f"| {md(scenario)} | {values['count']:.0f} | {values['min']:.2f} | "
            f"{values['p50']:.2f} | {values['p95']:.2f} | {values['max']:.2f} |"
        )


def print_wait_latency_markdown(wait_latency: dict[str, Any]) -> None:
    print("")
    print("## Wait Latency")
    print("")
    if wait_latency["count"] == 0:
        print("None.")
        return
    slowest = wait_latency["slowest"]
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Samples | {wait_latency['count']} |")
    print(f"| Failed waits | {wait_latency['failedCount']} |")
    print(f"| Slowest wait | {md(slowest.get('description', 'unknown'))} |")
    print(f"| Slowest action | {md(slowest.get('action', 'unknown'))} |")
    print(f"| Slowest ms | {float_value(slowest.get('elapsedMs')):.2f} |")
    print(f"| Slowest attempts | {int_value(slowest.get('attempts'))} |")
    print("")
    print("| Wait | Count | Failed | Min ms | P50 ms | P95 ms | Max ms | Max attempts |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    for description, values in sorted(wait_latency["waits"].items()):
        print(
            f"| {md(description)} | {values['count']:.0f} | {values['failedCount']:.0f} | "
            f"{values['min']:.2f} | {values['p50']:.2f} | {values['p95']:.2f} | "
            f"{values['max']:.2f} | {values['maxAttempts']:.0f} |"
        )


def print_command_latency_markdown(command_latency: dict[str, Any]) -> None:
    print("")
    print("## Command Latency")
    print("")
    if command_latency["count"] == 0:
        print("None.")
        return
    slowest = command_latency["slowest"]
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Samples | {command_latency['count']} |")
    print(f"| Slowest action | {md(slowest.get('action', 'unknown'))} |")
    print(f"| Slowest ms | {float_value(slowest.get('durationMs')):.2f} |")
    print(f"| Slowest id | {md(slowest.get('id', 'unknown'))} |")
    print("")
    print("| Action | Count | Min ms | P50 ms | P95 ms | Max ms |")
    print("|---|---:|---:|---:|---:|---:|")
    for action, values in sorted(command_latency["actions"].items()):
        print(
            f"| {md(action)} | {values['count']:.0f} | {values['min']:.2f} | "
            f"{values['p50']:.2f} | {values['p95']:.2f} | {values['max']:.2f} |"
        )


def print_network_markdown(network: dict[str, Any]) -> None:
    print("")
    print("## Network Snapshots")
    print("")
    if network["count"] == 0:
        print("None.")
        return
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Snapshots | {network['count']} |")
    print(f"| Connected snapshots | {network['connectedCount']} |")
    print(f"| Reconnecting snapshots | {network['reconnectingCount']} |")
    print(f"| UDP states | {md(json.dumps(network['udpStates'], ensure_ascii=False, sort_keys=True))} |")
    print(f"| UDP problem state snapshots | {network['udpProblemStateCount']} |")
    print(f"| Max UDP ping mean ms | {float(network['maxUdpPingMeanMs']):.2f} |")
    print(f"| Max packet loss percent | {float(network['maxPacketLossPercent']):.2f} |")
    print(f"| Packet loss observed snapshots | {network['packetLossObservedCount']} |")
    print(f"| Timeline entries | {network['timelineCount']} |")
    print(f"| Timeline warnings | {network['timelineWarningCount']} |")
    print(f"| Timeline errors | {network['timelineErrorCount']} |")
    print(f"| Network health | {md(network['networkHealth']['status'])} |")
    print(f"| Root cause hint | {md(network['networkHealth']['rootCauseHint'])} |")
    print(f"| Network issues | {network['networkIssueCount']} |")
    print(f"| Network issue kinds | {md(json.dumps(network['networkIssueKinds'], ensure_ascii=False, sort_keys=True))} |")
    print(f"| Timeline kinds | {md(json.dumps(network['timelineKinds'], ensure_ascii=False, sort_keys=True))} |")
    if network["networkHealth"]["latestIssue"]:
        print("")
        print("### Latest Network Health Issue")
        print("")
        print("```json")
        print(json.dumps(network["networkHealth"]["latestIssue"], ensure_ascii=False, indent=2, sort_keys=True))
        print("```")
    if network["networkHealth"]["recommendations"]:
        print("")
        print("### Network Health Recommendations")
        print("")
        for recommendation in network["networkHealth"]["recommendations"]:
            print(f"- {md(recommendation)}")
    if network["recentTimeline"]:
        print("")
        print("### Recent Network Timeline")
        print("")
        print("| Timestamp | Level | Kind | Category | Message |")
        print("|---|---|---|---|---|")
        for item in network["recentTimeline"]:
            print(
                f"| {md(str(item.get('timestamp', '')))} "
                f"| {md(str(item.get('level', '')))} "
                f"| {md(str(item.get('kind', '')))} "
                f"| {md(str(item.get('category', '')))} "
                f"| {md(str(item.get('message', '')))} |"
            )
    if network["latest"]:
        print("")
        print("### Latest Network Snapshot")
        print("")
        print("```json")
        print(json.dumps(network["latest"], ensure_ascii=False, indent=2, sort_keys=True))
        print("```")


def print_network_by_scenario_markdown(network_by_scenario: dict[str, Any]) -> None:
    print("")
    print("## Network By Scenario")
    print("")
    scenarios = network_by_scenario.get("scenarios", {})
    if not scenarios:
        print("None.")
        return
    print("| Scenario | Snapshots | Health | Root cause | Expected | Timeline warnings | Timeline errors | Timeline kinds |")
    print("|---|---:|---|---|---|---:|---:|---|")
    for scenario, values in sorted(scenarios.items()):
        health = values.get("networkHealth", {})
        print(
            f"| {md(scenario)} | {values.get('count', 0)} | "
            f"{md(health.get('status', 'unknown'))} | "
            f"{md(health.get('rootCauseHint', 'unknown'))} | "
            f"{bool(values.get('expectedRootCause'))} | "
            f"{values.get('timelineWarningCount', 0)} | "
            f"{values.get('timelineErrorCount', 0)} | "
            f"{md(json.dumps(values.get('timelineKinds', {}), ensure_ascii=False, sort_keys=True))} |"
        )


def print_diagnostics_markdown(diagnostics: dict[str, Any]) -> None:
    print("")
    print("## Failure Diagnostics")
    print("")
    if diagnostics["count"] == 0:
        print("None.")
        return
    latest = diagnostics["latest"]
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Snapshots | {diagnostics['count']} |")
    print(f"| Latest scenario | {md(latest.get('scenario', 'unknown'))} |")
    print(f"| Latest reason | {md(latest.get('reason', 'unknown'))} |")
    print(f"| Failures | {md(json.dumps(latest.get('failures', []), ensure_ascii=False, sort_keys=True))} |")
    print(f"| Diagnostic commands | {md_list(list(diagnostics['commands']))} |")
    print("")
    print("### Latest Diagnostic Snapshot")
    print("")
    print("```json")
    print(json.dumps(latest, ensure_ascii=False, indent=2, sort_keys=True))
    print("```")


def print_incident_timeline_markdown(incidents: dict[str, Any]) -> None:
    print("")
    print("## Incident Timeline")
    print("")
    if incidents["count"] == 0:
        print("None.")
        return
    print("| Field | Value |")
    print("|---|---|")
    print(f"| Items | {incidents['count']} |")
    print(f"| Severities | {md(json.dumps(incidents['severities'], ensure_ascii=False, sort_keys=True))} |")
    print(f"| Kinds | {md(json.dumps(incidents['kinds'], ensure_ascii=False, sort_keys=True))} |")
    print("")
    print("| Timestamp | Severity | Kind | Summary |")
    print("|---|---|---|---|")
    for item in incidents["items"]:
        print(
            f"| {md(item.get('timestamp') or 'no-time')} "
            f"| {md(item.get('severity', 'unknown'))} "
            f"| {md(item.get('kind', 'unknown'))} "
            f"| {md(item.get('summary', ''))} |"
        )


def print_failure_markdown(summary: EvidenceSummary) -> None:
    groups = [
        ("Malformed Lines", summary.malformed_lines),
        ("Run Failures", summary.run_failures),
        ("Command Failures", summary.command_failures),
        ("Assertion Failures", summary.assertion_failures),
        ("Coverage Failures", summary.coverage_failures),
        ("Threshold Failures", summary.threshold_failures),
    ]
    for title, failures in groups:
        if failures:
            print("")
            print_list(title, failures)


def print_list(title: str, values: list[str]) -> None:
    print(f"## {title}")
    print("")
    for value in values:
        print(f"- {md(value)}")


def md(value: Any) -> str:
    text = str(value)
    return text.replace("|", "\\|").replace("\n", " ")


def md_list(values: list[Any]) -> str:
    if not values:
        return "none"
    return ", ".join(md(value) for value in values)


def print_failures(summary: EvidenceSummary) -> None:
    groups = [
        ("malformed lines", summary.malformed_lines),
        ("run failures", summary.run_failures),
        ("command failures", summary.command_failures),
        ("assertion failures", summary.assertion_failures),
        ("coverage failures", summary.coverage_failures),
        ("threshold failures", summary.threshold_failures),
    ]
    for title, failures in groups:
        if not failures:
            continue
        print("")
        print(f"{title}:")
        for failure in failures:
            print(f"  - {failure}")


def run_self_test(budget_files: list[Path] | None = None) -> int:
    sample_provenance = {
        "probe": {"version": 1, "script": "Scripts/mumble_agent_probe.py"},
        "runtime": {"python": "3.13.0", "platform": "self-test"},
        "git": {
            "repository": {"head": "abcdef123456", "dirty": True},
            "mumbleKit": {"head": "123456abcdef", "dirty": False},
        },
    }
    sample_records = [
        {
            "type": "run.start",
            "timestamp": "2026-01-01T00:00:00Z",
            "run_id": "selftest-run",
            "scenario": "baseline",
            "provenance": sample_provenance,
        },
        {
            "type": "event",
            "message": {
                "event": "log.entry",
                "data": {
                    "category": "Connection",
                    "level": "debug",
                    "message": "PERF connect_ready reconnect=false attempt=1 total_ms=123.45 auth_join_ms=67.89",
                },
            },
        },
        {"type": "command.send", "timestamp": "2026-01-01T00:00:02.000Z", "id": "selftest:1:log.recent", "action": "log.recent"},
        {
            "type": "command.response",
            "timestamp": "2026-01-01T00:00:02.050Z",
            "message": {
                "id": "selftest:1:log.recent",
                "success": True,
                "data": {
                    "entries": [
                        {
                            "category": "Audio",
                            "level": "verbose",
                            "message": "PERF audio_callback VPIO callbacks=100 sampled=12 avg_us=120 p95_us=250 p99_us=310 max_us=400",
                        }
                    ]
                },
            },
        },
        {"type": "command.send", "timestamp": "2026-01-01T00:00:03.000Z", "id": "selftest:2:performance.status", "action": "performance.status"},
        {
            "type": "command.response",
            "timestamp": "2026-01-01T00:00:03.080Z",
            "message": {
                "id": "selftest:2:performance.status",
                "success": True,
                "data": {
                    "isRunning": True,
                    "stallCount": 1,
                    "maxLagMs": 130.5,
                    "lastStallContext": {"screen": "welcome", "lagMs": 130.5},
                    "maxStallContext": {"screen": "welcome", "lagMs": 130.5},
                },
            },
        },
        {"type": "command.send", "timestamp": "2026-01-01T00:00:04.000Z", "id": "selftest:3:network.status", "action": "network.status"},
        {
            "type": "command.response",
            "timestamp": "2026-01-01T00:00:04.125Z",
            "message": {
                "id": "selftest:3:network.status",
                "success": True,
                "data": {
                    "connection": {"connected": True, "isReconnecting": False},
                    "settings": {"forceTCP": False, "autoReconnect": True, "enableQoS": True},
                    "transport": {
                        "udpState": "available",
                        "udpPingMeanMs": 42.5,
                        "udpPingSamples": 8,
                        "packetLossPercent": 1.25,
                    },
                    "recentNetworkLogs": [],
                    "timeline": [
                        {
                            "timestamp": "2026-01-01 00:00:03.800",
                            "category": "Connection",
                            "level": "info",
                            "kind": "connect_begin",
                            "message": "PERF connect_begin reconnect=false attempt=0 reason=manual host=example.com:64738",
                        },
                        {
                            "timestamp": "2026-01-01 00:00:04.050",
                            "category": "Network",
                            "level": "warning",
                            "kind": "udp_state",
                            "message": "UDP transport state changed: recovering",
                        },
                    ],
                },
            },
        },
        {
            "type": "performance.snapshot",
            "timestamp": "2026-01-01T00:00:04.300Z",
            "scenario": "baseline",
            "data": {
                "isRunning": True,
                "stallCount": 2,
                "maxLagMs": 160.25,
                "lastStallContext": {"screen": "channelList", "lagMs": 160.25},
                "maxStallContext": {"screen": "channelList", "lagMs": 160.25},
            },
        },
        {
            "type": "wait",
            "timestamp": "2026-01-01T00:00:04.400Z",
            "passed": True,
            "description": "sample wait",
            "action": "ui.get",
            "attempts": 5,
            "elapsedMs": 1250.0,
            "timeoutMs": 8000.0,
            "intervalMs": 250.0,
            "data": {},
        },
        {
            "type": "diagnostic.snapshot",
            "scenario": "baseline",
            "reason": "failed",
            "failures": ["sample failure"],
            "data": {
                "network.status": {"success": True, "data": {"transport": {"udpState": "available"}}},
                "log.recent": {"success": True, "data": {"entries": []}},
            },
        },
        {"type": "assertion", "passed": True, "description": "sample"},
        {
            "type": "run.end",
            "timestamp": "2026-01-01T00:00:05Z",
            "run_id": "selftest-run",
            "scenario": "baseline",
            "status": "passed",
            "failures": [],
        },
    ]
    with tempfile.TemporaryDirectory() as tmpdir:
        path = Path(tmpdir) / "sample.jsonl"
        with path.open("w", encoding="utf-8") as handle:
            for record in sample_records:
                handle.write(json.dumps(record) + "\n")
        summary = parse_jsonl([path])
        thresholds, errors = collect_thresholds(
            ["connect_ready.total_ms=200", "audio_callback.max_us=500"],
            budget_files or [],
        )
        network_thresholds, network_errors = collect_network_thresholds(budget_files or [])
        errors.extend(network_errors)
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        evaluate_thresholds(summary, thresholds)
        evaluate_required_events(summary, ["log.entry"])
        evaluate_required_commands(summary, ["log.recent"])
        evaluate_required_perf_markers(summary, ["connect_ready.total_ms", "audio_callback"])
        evaluate_performance_limits(summary, max_stall_count=2, max_lag_ms=200)
        evaluate_required_network_snapshot(summary, required=True)
        evaluate_network_limits(
            summary,
            max_udp_ping_ms=100,
            max_packet_loss_percent=5,
            max_timeline_warning_count=1,
            max_timeline_error_count=0,
            max_network_issue_count=2,
        )
        evaluate_network_thresholds(summary, network_thresholds)
        command_thresholds, command_errors = collect_command_thresholds(["*=500", "network.status=150"], budget_files or [])
        errors.extend(command_errors)
        scenario_thresholds, scenario_errors = collect_scenario_thresholds(["*=6000", "baseline=5500"], budget_files or [])
        errors.extend(scenario_errors)
        wait_thresholds, wait_errors = collect_wait_thresholds(["*=2000", "sample wait=1500"], budget_files or [])
        errors.extend(wait_errors)
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        evaluate_command_thresholds(summary, command_thresholds)
        evaluate_scenario_thresholds(summary, scenario_thresholds)
        evaluate_wait_thresholds(summary, wait_thresholds)
        evaluate_required_provenance(summary)
        data = to_json(summary)
        checks = [
            data["failed"] is False,
            data["records"] == 13,
            data["scenarios"] == {"baseline": 1},
            data["scenarioDuration"]["count"] == 1,
            data["scenarioDuration"]["slowest"]["scenario"] == "baseline",
            data["scenarioDuration"]["scenarios"]["baseline"]["max"] == 5000.0,
            data["waitLatency"]["count"] == 1,
            data["waitLatency"]["slowest"]["description"] == "sample wait",
            data["waitLatency"]["waits"]["sample wait"]["max"] == 1250.0,
            data["waitLatency"]["waits"]["sample wait"]["maxAttempts"] == 5.0,
            data["events"] == {"log.entry": 1},
            data["commands"] == {"log.recent": 1, "network.status": 1, "performance.status": 1},
            data["commandLatency"]["count"] == 3,
            data["commandLatency"]["slowest"]["action"] == "network.status",
            data["commandLatency"]["actions"]["network.status"]["max"] == 125.0,
            data["perfMarkers"]["connect_ready"] == 1,
            data["perfMarkers"]["audio_callback"] == 1,
            data["perfStats"]["connect_ready"]["total_ms"]["max"] == 123.45,
            data["perfStats"]["audio_callback"]["max_us"]["max"] == 400.0,
            data["performance"]["count"] == 2,
            data["performance"]["maxStallCount"] == 2,
            data["performance"]["maxLagMs"] == 160.25,
            data["performance"]["maxContext"]["screen"] == "channelList",
            data["performance"]["latestContext"]["screen"] == "channelList",
            data["performance"]["recentContexts"][0]["screen"] == "channelList",
            data["network"]["count"] == 1,
            data["network"]["connectedCount"] == 1,
            data["network"]["udpStates"] == {"available": 1},
            data["network"]["udpProblemStateCount"] == 0,
            data["network"]["maxUdpPingMeanMs"] == 42.5,
            data["network"]["packetLossObservedCount"] == 1,
            data["network"]["timelineCount"] == 2,
            data["network"]["timelineKinds"] == {"connect_begin": 1, "udp_state": 1},
            data["network"]["timelineWarningCount"] == 1,
            data["network"]["timelineErrorCount"] == 0,
            data["network"]["networkIssueCount"] == 2,
            data["network"]["networkIssueKinds"] == {"packet_loss_observed": 1, "timeline_udp_state": 1},
            data["network"]["networkHealth"]["status"] == "degraded",
            data["network"]["networkHealth"]["rootCauseHint"] == "udp_transport",
            data["network"]["networkHealth"]["latestIssue"]["kind"] == "timeline_udp_state",
            data["network"]["recentTimeline"][-1]["kind"] == "udp_state",
            data["networkByScenario"]["count"] == 1,
            data["networkByScenario"]["scenarios"]["baseline"]["networkHealth"]["rootCauseHint"] == "udp_transport",
            data["networkByScenario"]["scenarios"]["baseline"]["expectedRootCause"] is False,
            data["diagnostics"]["count"] == 1,
            data["diagnostics"]["latest"]["reason"] == "failed",
            data["diagnostics"]["commands"] == {"log.recent": 1, "network.status": 1},
            data["incidentTimeline"]["count"] == 6,
            data["incidentTimeline"]["kinds"]["slow_wait"] == 1,
            data["incidentTimeline"]["kinds"]["slow_command"] == 1,
            data["incidentTimeline"]["kinds"]["main_thread_stall"] == 2,
            data["incidentTimeline"]["kinds"]["network_udp_state"] == 1,
            data["incidentTimeline"]["kinds"]["diagnostic_snapshot"] == 1,
            data["provenance"]["count"] == 1,
            data["provenance"]["expected"] == 1,
            data["provenance"]["probeVersions"] == [1],
            data["provenance"]["repositoryHeads"] == ["abcdef123456"],
            data["provenance"]["mumbleKitHeads"] == ["123456abcdef"],
            data["provenance"]["repositoryDirty"] is True,
            data["provenance"]["mumbleKitDirty"] is False,
        ]
        if not all(checks):
            print(json.dumps(data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        debug_connect_failure_summary = EvidenceSummary(
            network_snapshots=[
                {
                    "_scenario": "network-connect-failure",
                    "connection": {"connected": False, "isConnecting": False, "isReconnecting": False},
                    "transport": {"udpState": "unknown", "udpPingSamples": 0},
                    "timeline": [
                        {
                            "timestamp": "2026-01-01 00:00:04.500",
                            "category": "Connection",
                            "level": "debug",
                            "kind": "connect_failed",
                            "message": "PERF connect_failed reconnect=false attempt=0 total_ms=12.5",
                        }
                    ],
                }
            ]
        )
        debug_connect_failure_network = network_stats(debug_connect_failure_summary)
        debug_connect_failure_checks = [
            debug_connect_failure_network["timelineErrorCount"] == 0,
            debug_connect_failure_network["networkIssueCount"] == 0,
            debug_connect_failure_network["networkHealth"]["status"] == "failing",
            debug_connect_failure_network["networkHealth"]["rootCauseHint"] == "connection_failure",
        ]
        if not all(debug_connect_failure_checks):
            print(json.dumps(debug_connect_failure_network, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        debug_connect_failure_by_scenario = network_stats_by_scenario(debug_connect_failure_summary)
        debug_connect_failure_scenario = debug_connect_failure_by_scenario["scenarios"]["network-connect-failure"]
        debug_connect_failure_scenario_checks = [
            debug_connect_failure_by_scenario["count"] == 1,
            debug_connect_failure_scenario["networkHealth"]["status"] == "failing",
            debug_connect_failure_scenario["networkHealth"]["rootCauseHint"] == "connection_failure",
            debug_connect_failure_scenario["expectedRootCause"] is True,
        ]
        if not all(debug_connect_failure_scenario_checks):
            print(json.dumps(debug_connect_failure_by_scenario, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        markdown = markdown_text(summary)
        markdown_checks = [
            "# Mumble Probe Evidence Report" in markdown,
            "| Status | passed |" in markdown,
            "## PERF Metrics" in markdown,
            "## Scenario Duration" in markdown,
            "| Slowest scenario | baseline |" in markdown,
            "## Wait Latency" in markdown,
            "| Slowest wait | sample wait |" in markdown,
            "## Command Latency" in markdown,
            "| Slowest action | network.status |" in markdown,
            "## Max Stall Context" in markdown,
            "## Recent Stall Contexts" in markdown,
            "## Network Snapshots" in markdown,
            "## Network By Scenario" in markdown,
            "Network health" in markdown,
            "Root cause hint" in markdown,
            "udp_state" in markdown,
            "## Failure Diagnostics" in markdown,
            "## Incident Timeline" in markdown,
            "slow_command" in markdown,
            "## Provenance" in markdown,
            "abcdef123456" in markdown,
        ]
        if not all(markdown_checks):
            print(markdown, file=sys.stderr)
            return 1
        failing_command_summary = parse_jsonl([path])
        evaluate_command_thresholds(
            failing_command_summary,
            [CommandThreshold(action="network.status", limit_ms=100, source="self-test", required=True)],
        )
        failing_command_data = to_json(failing_command_summary)
        failing_command_checks = [
            failing_command_data["failed"] is True,
            any("network.status" in failure for failure in failing_command_data["thresholdFailures"]),
        ]
        if not all(failing_command_checks):
            print(json.dumps(failing_command_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        failing_scenario_summary = parse_jsonl([path])
        evaluate_scenario_thresholds(
            failing_scenario_summary,
            [ScenarioThreshold(scenario="baseline", limit_ms=1000, source="self-test", required=True)],
        )
        failing_scenario_data = to_json(failing_scenario_summary)
        failing_scenario_checks = [
            failing_scenario_data["failed"] is True,
            any("scenario baseline" in failure for failure in failing_scenario_data["thresholdFailures"]),
        ]
        if not all(failing_scenario_checks):
            print(json.dumps(failing_scenario_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        failing_scenario_budget_path = Path(tmpdir) / "scenario-budget.json"
        failing_scenario_budget_path.write_text(
            json.dumps(
                {
                    "scenarioBudgets": [
                        {"scenario": "baseline", "maxMs": 1000, "required": True},
                    ]
                }
            ),
            encoding="utf-8",
        )
        budget_scenario_thresholds, budget_scenario_errors = collect_scenario_thresholds([], [failing_scenario_budget_path])
        if budget_scenario_errors:
            for error in budget_scenario_errors:
                print(error, file=sys.stderr)
            return 1
        failing_scenario_budget_summary = parse_jsonl([path])
        evaluate_scenario_thresholds(failing_scenario_budget_summary, budget_scenario_thresholds)
        failing_scenario_budget_data = to_json(failing_scenario_budget_summary)
        failing_scenario_budget_checks = [
            failing_scenario_budget_data["failed"] is True,
            any("scenarioBudgets" in failure for failure in failing_scenario_budget_data["thresholdFailures"]),
        ]
        if not all(failing_scenario_budget_checks):
            print(json.dumps(failing_scenario_budget_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        failing_wait_summary = parse_jsonl([path])
        evaluate_wait_thresholds(
            failing_wait_summary,
            [WaitThreshold(description="sample wait", limit_ms=1000, source="self-test", required=True)],
        )
        failing_wait_data = to_json(failing_wait_summary)
        failing_wait_checks = [
            failing_wait_data["failed"] is True,
            any("wait sample wait" in failure for failure in failing_wait_data["thresholdFailures"]),
        ]
        if not all(failing_wait_checks):
            print(json.dumps(failing_wait_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        failing_wait_budget_path = Path(tmpdir) / "wait-budget.json"
        failing_wait_budget_path.write_text(
            json.dumps(
                {
                    "waitBudgets": [
                        {"description": "sample wait", "maxMs": 1000, "required": True},
                    ]
                }
            ),
            encoding="utf-8",
        )
        budget_wait_thresholds, budget_wait_errors = collect_wait_thresholds([], [failing_wait_budget_path])
        if budget_wait_errors:
            for error in budget_wait_errors:
                print(error, file=sys.stderr)
            return 1
        failing_wait_budget_summary = parse_jsonl([path])
        evaluate_wait_thresholds(failing_wait_budget_summary, budget_wait_thresholds)
        failing_wait_budget_data = to_json(failing_wait_budget_summary)
        failing_wait_budget_checks = [
            failing_wait_budget_data["failed"] is True,
            any("waitBudgets" in failure for failure in failing_wait_budget_data["thresholdFailures"]),
        ]
        if not all(failing_wait_budget_checks):
            print(json.dumps(failing_wait_budget_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        failing_network_summary = parse_jsonl([path])
        evaluate_network_limits(
            failing_network_summary,
            max_udp_ping_ms=10,
            max_packet_loss_percent=1,
            max_timeline_warning_count=0,
            max_timeline_error_count=0,
            max_network_issue_count=0,
        )
        failing_network_data = to_json(failing_network_summary)
        failing_network_checks = [
            failing_network_data["failed"] is True,
            any("max-network-udp-ping-ms" in failure for failure in failing_network_data["thresholdFailures"]),
            any("max-network-packet-loss-percent" in failure for failure in failing_network_data["thresholdFailures"]),
            any("max-network-timeline-warnings" in failure for failure in failing_network_data["thresholdFailures"]),
            any("max-network-issues" in failure for failure in failing_network_data["thresholdFailures"]),
        ]
        if not all(failing_network_checks):
            print(json.dumps(failing_network_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        failing_network_budget_path = Path(tmpdir) / "network-budget.json"
        failing_network_budget_path.write_text(
            json.dumps(
                {
                    "networkBudgets": [
                        {"metric": "maxUdpPingMeanMs", "max": 10, "required": True},
                        {"metric": "maxPacketLossPercent", "max": 1, "required": True},
                        {"metric": "timelineWarningCount", "max": 0, "required": True},
                        {"metric": "networkIssueCount", "max": 0, "required": True},
                    ]
                }
            ),
            encoding="utf-8",
        )
        budget_network_thresholds, budget_network_errors = collect_network_thresholds([failing_network_budget_path])
        if budget_network_errors:
            for error in budget_network_errors:
                print(error, file=sys.stderr)
            return 1
        failing_network_budget_summary = parse_jsonl([path])
        evaluate_network_thresholds(failing_network_budget_summary, budget_network_thresholds)
        failing_network_budget_data = to_json(failing_network_budget_summary)
        failing_network_budget_checks = [
            failing_network_budget_data["failed"] is True,
            any("networkBudgets" in failure for failure in failing_network_budget_data["thresholdFailures"]),
            any("networkIssueCount" in failure for failure in failing_network_budget_data["thresholdFailures"]),
        ]
        if not all(failing_network_budget_checks):
            print(json.dumps(failing_network_budget_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        failing_performance_summary = parse_jsonl([path])
        evaluate_performance_limits(failing_performance_summary, max_stall_count=1, max_lag_ms=150)
        failing_performance_data = to_json(failing_performance_summary)
        failing_performance_checks = [
            failing_performance_data["failed"] is True,
            any("max-performance-stalls" in failure for failure in failing_performance_data["thresholdFailures"]),
            any("max-performance-lag-ms" in failure for failure in failing_performance_data["thresholdFailures"]),
        ]
        if not all(failing_performance_checks):
            print(json.dumps(failing_performance_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        missing_provenance_path = Path(tmpdir) / "missing-provenance.jsonl"
        with missing_provenance_path.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps({"type": "run.start", "timestamp": "2026-01-01T00:00:00Z"}) + "\n")
        missing_provenance_summary = parse_jsonl([missing_provenance_path])
        evaluate_required_provenance(missing_provenance_summary)
        missing_provenance_data = to_json(missing_provenance_summary)
        missing_provenance_checks = [
            missing_provenance_data["failed"] is True,
            missing_provenance_data["provenance"]["expected"] == 1,
            missing_provenance_data["provenance"]["count"] == 0,
            any("provenance" in failure for failure in missing_provenance_data["coverageFailures"]),
        ]
        if not all(missing_provenance_checks):
            print(json.dumps(missing_provenance_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        scenario_path = Path(tmpdir) / "scenarios.jsonl"
        scenario_records = [
            {"type": "run.start", "timestamp": "2026-01-01T00:00:00Z", "scenario": "baseline"},
            {"type": "run.end", "timestamp": "2026-01-01T00:00:01Z", "status": "passed", "failures": []},
            {"type": "suite.scenario", "timestamp": "2026-01-01T00:00:02Z", "scenario": "baseline", "status": "passed", "exit_code": 0},
        ]
        with scenario_path.open("w", encoding="utf-8") as handle:
            for record in scenario_records:
                handle.write(json.dumps(record) + "\n")
        scenario_summary = parse_jsonl([scenario_path])
        evaluate_required_scenarios(scenario_summary, ["baseline", "idle-welcome"])
        scenario_data = to_json(scenario_summary)
        scenario_checks = [
            scenario_data["failed"] is True,
            scenario_data["scenarios"] == {"baseline": 2},
            scenario_data["coverageFailures"],
        ]
        if not all(scenario_checks):
            print(json.dumps(scenario_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        suite_index_path = Path(tmpdir) / "suite-index.jsonl"
        suite_index_records = [
            {"type": "suite.start", "timestamp": "2026-01-01T00:00:00Z", "suite_id": "suite-a", "repeat": 2},
            {
                "type": "suite.scenario",
                "timestamp": "2026-01-01T00:00:01Z",
                "suite_id": "suite-a",
                "scenario": "baseline",
                "iteration": 1,
                "repeat": 2,
                "status": "passed",
                "exit_code": 0,
                "elapsed_ms": 120.0,
                "output": "baseline-1.jsonl",
            },
            {
                "type": "suite.scenario",
                "timestamp": "2026-01-01T00:00:02Z",
                "suite_id": "suite-a",
                "scenario": "baseline",
                "iteration": 2,
                "repeat": 2,
                "status": "failed",
                "exit_code": 1,
                "elapsed_ms": 300.0,
                "output": "baseline-2.jsonl",
            },
            {"type": "suite.end", "timestamp": "2026-01-01T00:00:02Z", "suite_id": "suite-a", "status": "passed", "failures": []},
        ]
        with suite_index_path.open("w", encoding="utf-8") as handle:
            for record in suite_index_records:
                handle.write(json.dumps(record) + "\n")
        suite_index_summary = parse_jsonl([suite_index_path])
        evaluate_suite_index(suite_index_summary, ["baseline"])
        suite_index_data = to_json(suite_index_summary)
        suite_index_checks = [
            suite_index_data["failed"] is True,
            suite_index_data["suiteIds"] == {"suite-a": 4},
            suite_index_data["suiteScenarios"] == {"baseline": 2},
            suite_index_data["scenarioOutcomes"]["count"] == 2,
            suite_index_data["scenarioOutcomes"]["passed"] == 1,
            suite_index_data["scenarioOutcomes"]["failed"] == 1,
            suite_index_data["scenarioOutcomes"]["scenarios"]["baseline"]["passRate"] == 0.5,
            suite_index_data["scenarioOutcomes"]["scenarios"]["baseline"]["maxRepeat"] == 2,
            suite_index_data["scenarioOutcomes"]["scenarios"]["baseline"]["maxElapsedMs"] == 300.0,
            suite_index_data["incidentTimeline"]["kinds"]["suite_scenario_failure"] == 1,
        ]
        if not all(suite_index_checks):
            print(json.dumps(suite_index_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        run_only_path = Path(tmpdir) / "run-only.jsonl"
        run_only_records = [
            {"type": "run.start", "timestamp": "2026-01-01T00:00:00Z", "scenario": "baseline"},
            {"type": "run.end", "timestamp": "2026-01-01T00:00:01Z", "status": "passed", "failures": []},
        ]
        with run_only_path.open("w", encoding="utf-8") as handle:
            for record in run_only_records:
                handle.write(json.dumps(record) + "\n")
        missing_index_summary = parse_jsonl([run_only_path])
        evaluate_suite_index(missing_index_summary, ["baseline"])
        missing_index_data = to_json(missing_index_summary)
        missing_index_checks = [
            missing_index_data["failed"] is True,
            any("suite.start" in failure for failure in missing_index_data["coverageFailures"]),
            any("suite.scenario" in failure for failure in missing_index_data["coverageFailures"]),
        ]
        if not all(missing_index_checks):
            print(json.dumps(missing_index_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        missing_coverage_path = Path(tmpdir) / "missing-coverage.jsonl"
        with missing_coverage_path.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps({"type": "run.start", "timestamp": "2026-01-01T00:00:00Z"}) + "\n")
        missing_coverage_summary = parse_jsonl([missing_coverage_path])
        evaluate_required_events(missing_coverage_summary, ["log.entry"])
        evaluate_required_commands(missing_coverage_summary, ["log.recent"])
        evaluate_required_perf_markers(missing_coverage_summary, ["connect_ready.total_ms"])
        missing_coverage_data = to_json(missing_coverage_summary)
        missing_coverage_checks = [
            missing_coverage_data["failed"] is True,
            any("required event" in failure for failure in missing_coverage_data["coverageFailures"]),
            any("required command" in failure for failure in missing_coverage_data["coverageFailures"]),
            any("required PERF metric" in failure for failure in missing_coverage_data["coverageFailures"]),
        ]
        if not all(missing_coverage_checks):
            print(json.dumps(missing_coverage_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        missing_network_summary = parse_jsonl([missing_coverage_path])
        evaluate_required_network_snapshot(missing_network_summary, required=True)
        missing_network_data = to_json(missing_network_summary)
        missing_network_checks = [
            missing_network_data["failed"] is True,
            any("network.status" in failure for failure in missing_network_data["coverageFailures"]),
        ]
        if not all(missing_network_checks):
            print(json.dumps(missing_network_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
        failure_path = Path(tmpdir) / "failure.jsonl"
        failure_records = [
            {"type": "error", "timestamp": "2026-01-01T00:00:01Z", "error_type": "ProbeError", "error": "boom"},
            {"type": "run.end", "timestamp": "2026-01-01T00:00:02Z", "status": "failed", "failures": ["boom"]},
            {
                "type": "suite.scenario",
                "timestamp": "2026-01-01T00:00:03Z",
                "scenario": "baseline",
                "status": "failed",
                "exit_code": 2,
            },
            {
                "type": "suite.end",
                "timestamp": "2026-01-01T00:00:04Z",
                "status": "failed",
                "failures": ["baseline exited 2"],
            },
        ]
        with failure_path.open("w", encoding="utf-8") as handle:
            for record in failure_records:
                handle.write(json.dumps(record) + "\n")
        failure_summary = parse_jsonl([failure_path])
        failure_data = to_json(failure_summary)
        failure_checks = [
            failure_data["failed"] is True,
            len(failure_data["runFailures"]) == 4,
        ]
        if not all(failure_checks):
            print(json.dumps(failure_data, indent=2, sort_keys=True), file=sys.stderr)
            return 1
    print("passed: trace analyzer self-test")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze MUTestServer probe JSONL evidence.")
    parser.add_argument("paths", nargs="*", type=Path, help="Probe JSONL evidence files")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON summary")
    parser.add_argument("--markdown", action="store_true", help="Print a Markdown triage report")
    parser.add_argument(
        "--require-scenario",
        dest="required_scenarios",
        action="append",
        default=[],
        metavar="NAME",
        help="Fail unless evidence includes this scenario. Repeat for every required scenario.",
    )
    parser.add_argument(
        "--require-suite-index",
        action="store_true",
        help="Fail unless evidence includes a single suite-index with suite.start, suite.scenario, and suite.end records.",
    )
    parser.add_argument(
        "--require-provenance",
        action="store_true",
        help="Fail unless every run.start and suite.start record includes traceable probe/runtime/git provenance.",
    )
    parser.add_argument(
        "--require-event",
        dest="required_events",
        action="append",
        default=[],
        metavar="EVENT",
        help="Fail unless evidence includes this streamed event name, for example log.entry. Repeat as needed.",
    )
    parser.add_argument(
        "--require-command",
        dest="required_commands",
        action="append",
        default=[],
        metavar="ACTION",
        help="Fail unless evidence includes a response for this command action, for example log.recent. Repeat as needed.",
    )
    parser.add_argument(
        "--require-perf-marker",
        dest="required_perf_markers",
        action="append",
        default=[],
        metavar="MARKER[.METRIC]",
        help="Fail unless evidence includes this PERF marker, or a numeric marker metric when .METRIC is supplied.",
    )
    parser.add_argument(
        "--max",
        dest="thresholds",
        action="append",
        default=[],
        metavar="MARKER.METRIC=VALUE",
        help="Fail if the max observed metric exceeds VALUE, for example connect_ready.total_ms=1500",
    )
    parser.add_argument(
        "--budget-file",
        dest="budget_files",
        action="append",
        default=[],
        type=Path,
        help="Load versioned JSON performance budgets. Missing metrics only fail when a budget has required=true.",
    )
    parser.add_argument(
        "--max-performance-stalls",
        type=int,
        help="Fail when performance snapshots report a stallCount above this value.",
    )
    parser.add_argument(
        "--max-performance-lag-ms",
        type=float,
        help="Fail when performance snapshots report maxLagMs above this value.",
    )
    parser.add_argument(
        "--require-network-snapshot",
        action="store_true",
        help="Fail unless evidence includes at least one network.status snapshot.",
    )
    parser.add_argument(
        "--max-network-udp-ping-ms",
        type=float,
        help="Fail when network snapshots report maxUdpPingMeanMs above this value.",
    )
    parser.add_argument(
        "--max-network-packet-loss-percent",
        type=float,
        help="Fail when network snapshots report maxPacketLossPercent above this value.",
    )
    parser.add_argument(
        "--max-network-timeline-warnings",
        type=int,
        help="Fail when network timeline entries include more warning-level events than this value.",
    )
    parser.add_argument(
        "--max-network-timeline-errors",
        type=int,
        help="Fail when network timeline entries include more error-level events than this value.",
    )
    parser.add_argument(
        "--max-network-issues",
        type=int,
        help="Fail when derived network health issues exceed this value.",
    )
    parser.add_argument(
        "--max-command-ms",
        dest="command_thresholds",
        action="append",
        default=[],
        metavar="ACTION=MS",
        help="Fail if the max observed round-trip for ACTION exceeds MS. Use *=MS for all commands.",
    )
    parser.add_argument(
        "--max-wait-ms",
        dest="wait_thresholds",
        action="append",
        default=[],
        metavar="DESCRIPTION=MS",
        help="Fail if the max observed wait for DESCRIPTION exceeds MS. Use *=MS for all waits.",
    )
    parser.add_argument(
        "--max-scenario-ms",
        dest="scenario_thresholds",
        action="append",
        default=[],
        metavar="SCENARIO=MS",
        help="Fail if the max observed run duration for SCENARIO exceeds MS. Use *=MS for all scenarios.",
    )
    parser.add_argument("--self-test", action="store_true", help="Validate analyzer parsing and threshold logic")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test(args.budget_files)
    if not args.paths:
        print("error: at least one JSONL path is required unless --self-test is used", file=sys.stderr)
        return 2
    missing = [str(path) for path in args.paths if not path.exists()]
    if missing:
        print(f"error: missing evidence file(s): {', '.join(missing)}", file=sys.stderr)
        return 2
    summary = parse_jsonl(args.paths)
    thresholds, threshold_errors = collect_thresholds(args.thresholds, args.budget_files)
    network_thresholds, network_threshold_errors = collect_network_thresholds(args.budget_files)
    command_thresholds, command_threshold_errors = collect_command_thresholds(args.command_thresholds, args.budget_files)
    scenario_thresholds, scenario_threshold_errors = collect_scenario_thresholds(args.scenario_thresholds, args.budget_files)
    wait_thresholds, wait_threshold_errors = collect_wait_thresholds(args.wait_thresholds, args.budget_files)
    summary.threshold_failures.extend(threshold_errors)
    summary.threshold_failures.extend(network_threshold_errors)
    summary.threshold_failures.extend(command_threshold_errors)
    summary.threshold_failures.extend(scenario_threshold_errors)
    summary.threshold_failures.extend(wait_threshold_errors)
    evaluate_required_scenarios(summary, args.required_scenarios)
    if args.require_suite_index:
        evaluate_suite_index(summary, args.required_scenarios)
    if args.require_provenance:
        evaluate_required_provenance(summary)
    evaluate_required_events(summary, args.required_events)
    evaluate_required_commands(summary, args.required_commands)
    evaluate_required_perf_markers(summary, args.required_perf_markers)
    evaluate_thresholds(summary, thresholds)
    evaluate_performance_limits(summary, args.max_performance_stalls, args.max_performance_lag_ms)
    evaluate_required_network_snapshot(summary, args.require_network_snapshot)
    evaluate_network_limits(
        summary,
        args.max_network_udp_ping_ms,
        args.max_network_packet_loss_percent,
        args.max_network_timeline_warnings,
        args.max_network_timeline_errors,
        args.max_network_issues,
    )
    evaluate_network_thresholds(summary, network_thresholds)
    evaluate_command_thresholds(summary, command_thresholds)
    evaluate_scenario_thresholds(summary, scenario_thresholds)
    evaluate_wait_thresholds(summary, wait_thresholds)
    if args.json:
        print(json.dumps(to_json(summary), ensure_ascii=False, indent=2, sort_keys=True))
    elif args.markdown:
        print_markdown(summary)
    else:
        print_text(summary)
    return 1 if summary.failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
