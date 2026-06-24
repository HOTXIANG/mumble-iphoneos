#!/usr/bin/env python3
"""Run traceable smoke probes against the DEBUG MUTestServer WebSocket API.

The client intentionally uses only Python's standard library so it can run on a
fresh macOS runner without websocat or the third-party websockets package.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import platform
import random
import socket
import struct
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


DEFAULT_URL = "ws://localhost:54296"
DEFAULT_CATEGORIES = ["General", "UI", "Audio", "Connection", "Network"]
SCENARIOS = [
    "baseline",
    "idle-welcome",
    "lifecycle-idle-audio",
    "mixer-lifecycle",
    "vad-onboarding",
    "network-settings",
    "network-connect-failure",
    "network-auto-reconnect",
    "network-udp-degraded",
    "network-udp-toast-throttle",
    "ui-performance-sampling",
]
PROBE_VERSION = 1
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class ProbeError(Exception):
    pass


class WebSocketClosed(ProbeError):
    pass


@dataclass(frozen=True)
class Command:
    action: str
    params: dict[str, Any] | None = None


class EvidenceWriter:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._file = self.path.open("w", encoding="utf-8")

    def write(self, record_type: str, **fields: Any) -> None:
        record = {
            "type": record_type,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            **fields,
        }
        self._file.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        self._file.flush()

    def close(self) -> None:
        self._file.close()


def repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def command_output(args: list[str], cwd: Path) -> str | None:
    try:
        completed = subprocess.run(
            args,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    return completed.stdout.strip()


def git_snapshot(path: Path) -> dict[str, Any]:
    head = command_output(["git", "rev-parse", "--short=12", "HEAD"], path)
    branch = command_output(["git", "branch", "--show-current"], path)
    status_text = command_output(["git", "status", "--short"], path)
    status = status_text.splitlines() if status_text else []
    return {
        "path": str(path),
        "head": head,
        "branch": branch or None,
        "dirty": bool(status),
        "status": status,
    }


def provenance(args: argparse.Namespace) -> dict[str, Any]:
    root = repository_root()
    return {
        "probe": {
            "version": PROBE_VERSION,
            "script": str(Path(__file__).resolve()),
            "scenarios": SCENARIOS,
            "timeout": args.timeout,
            "waitTimeout": args.wait_timeout,
            "settleSeconds": args.settle_seconds,
        },
        "runtime": {
            "python": sys.version.split()[0],
            "platform": platform.platform(),
            "cwd": os.getcwd(),
        },
        "git": {
            "repository": git_snapshot(root),
            "mumbleKit": git_snapshot(root / "MumbleKit"),
        },
    }


class StdlibWebSocket:
    def __init__(self, url: str, timeout: float) -> None:
        parsed = urlparse(url)
        if parsed.scheme != "ws":
            raise ProbeError(f"Only ws:// URLs are supported, got {url!r}")
        if not parsed.hostname:
            raise ProbeError(f"Missing host in URL {url!r}")

        self.url = url
        self.host = parsed.hostname
        self.port = parsed.port or 80
        self.path = parsed.path or "/"
        if parsed.query:
            self.path += f"?{parsed.query}"
        self.timeout = timeout
        self.sock: socket.socket | None = None

    def connect(self) -> None:
        sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        sock.settimeout(self.timeout)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        host_header = self.host if self.port == 80 else f"{self.host}:{self.port}"
        request = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {host_header}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        sock.sendall(request.encode("ascii"))
        response = self._read_http_response(sock)
        headers = self._parse_headers(response)
        status_line = response.split("\r\n", 1)[0]
        accept = headers.get("sec-websocket-accept", "")
        expected = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
        if not status_line.startswith("HTTP/1.1 101") or accept != expected:
            sock.close()
            raise ProbeError(f"WebSocket handshake failed: {status_line}")
        self.sock = sock

    def close(self) -> None:
        if self.sock is None:
            return
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        self.sock.close()
        self.sock = None

    def send_json(self, payload: dict[str, Any]) -> None:
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._send_frame(0x1, data)

    def recv_json(self) -> dict[str, Any]:
        raw = self.recv_text()
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ProbeError(f"Received invalid JSON: {raw[:200]!r}") from exc
        if not isinstance(decoded, dict):
            raise ProbeError(f"Expected JSON object, got {type(decoded).__name__}")
        return decoded

    def recv_text(self) -> str:
        message = bytearray()
        while True:
            opcode, payload = self._recv_frame()
            if opcode == 0x8:
                raise WebSocketClosed("WebSocket closed by server")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            if opcode not in (0x0, 0x1):
                continue
            message.extend(payload)
            return message.decode("utf-8")

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self.sock is None:
            raise ProbeError("WebSocket is not connected")
        first = 0x80 | opcode
        mask_bit = 0x80
        length = len(payload)
        if length < 126:
            header = struct.pack("!BB", first, mask_bit | length)
        elif length <= 0xFFFF:
            header = struct.pack("!BBH", first, mask_bit | 126, length)
        else:
            header = struct.pack("!BBQ", first, mask_bit | 127, length)
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def _recv_frame(self) -> tuple[int, bytes]:
        if self.sock is None:
            raise ProbeError("WebSocket is not connected")
        header = self._recv_exact(2)
        first, second = header
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._recv_exact(8))[0]
        mask = self._recv_exact(4) if masked else b""
        payload = self._recv_exact(length) if length else b""
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        return opcode, payload

    def _recv_exact(self, length: int) -> bytes:
        if self.sock is None:
            raise ProbeError("WebSocket is not connected")
        chunks = bytearray()
        while len(chunks) < length:
            chunk = self.sock.recv(length - len(chunks))
            if not chunk:
                raise WebSocketClosed("Socket closed while reading frame")
            chunks.extend(chunk)
        return bytes(chunks)

    @staticmethod
    def _read_http_response(sock: socket.socket) -> str:
        data = bytearray()
        while b"\r\n\r\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                raise ProbeError("Socket closed during WebSocket handshake")
            data.extend(chunk)
            if len(data) > 65536:
                raise ProbeError("Handshake response was too large")
        return data.decode("iso-8859-1")

    @staticmethod
    def _parse_headers(response: str) -> dict[str, str]:
        headers: dict[str, str] = {}
        for line in response.split("\r\n")[1:]:
            if not line or ":" not in line:
                continue
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
        return headers


class ProbeRunner:
    def __init__(self, ws: StdlibWebSocket, evidence: EvidenceWriter, run_id: str, timeout: float) -> None:
        self.ws = ws
        self.evidence = evidence
        self.run_id = run_id
        self.timeout = timeout
        self.responses: dict[str, dict[str, Any]] = {}
        self.failures: list[str] = []
        self.events: list[dict[str, Any]] = []
        self.log_messages: list[str] = []

    def command(
        self,
        action: str,
        params: dict[str, Any] | None = None,
        alias: str | None = None,
        record_failure: bool = True,
    ) -> dict[str, Any]:
        request_id = f"{self.run_id}:{len(self.responses) + 1}:{action}"
        payload: dict[str, Any] = {"id": request_id, "action": action}
        if params:
            payload["params"] = params
        self.evidence.write("command.send", id=request_id, action=action, params=params or {})
        self.ws.send_json(payload)
        response = self._receive_response(request_id)
        self.responses[alias or action] = response
        if record_failure and not response.get("success"):
            self.failures.append(f"{action} failed: {response.get('error', 'unknown error')}")
        return response

    def collect_events(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                if self.ws.sock is not None:
                    self.ws.sock.settimeout(max(0.05, min(0.5, deadline - time.monotonic())))
                message = self.ws.recv_json()
            except socket.timeout:
                continue
            except WebSocketClosed:
                raise
            self._record_message(message)

    def assert_baseline(self) -> None:
        help_data = self._data_for("help.actions")
        domains = help_data.get("domains", {}) if isinstance(help_data, dict) else {}
        required_domains = {"log", "state", "ui", "audio", "connection", "performance", "network"}
        missing = sorted(required_domains.difference(domains.keys()))
        self._assert(not missing, f"help.actions exposes required domains: missing={missing}")

        log_config = self._data_for("log.getConfig")
        categories = log_config.get("categories", {}) if isinstance(log_config, dict) else {}
        required_categories = set(DEFAULT_CATEGORIES)
        missing_categories = sorted(required_categories.difference(categories.keys()))
        self._assert(not missing_categories, f"log.getConfig exposes required categories: missing={missing_categories}")

        self._assert(bool(self._data_for("state.get")), "state.get returns a non-empty snapshot")
        self._assert(bool(self._data_for("ui.get")), "ui.get returns a non-empty snapshot")
        performance = self._data_for("performance.status")
        self._assert(bool(performance.get("isRunning")), "main-thread performance monitor is running")
        network = self._data_for("network.status")
        self._assert(bool(network.get("connection")), "network.status returns connection diagnostics")
        self._assert(bool(network.get("transport")), "network.status returns transport diagnostics")

    def reset_for_scenario(self) -> None:
        self.command("app.cancelConnection", alias="reset.app.cancelConnection", record_failure=False)
        self.command("connection.disconnect", alias="reset.connection.disconnect", record_failure=False)
        for target in [
            "audioPluginMixer",
            "vadOnboarding",
            "preferences",
            "toast",
            "error",
            "certTrust",
            "imagePreview",
        ]:
            self.command("ui.dismiss", {"target": target}, alias=f"reset.dismiss.{target}", record_failure=False)
        self.command("app.clearError", alias="reset.app.clearError", record_failure=False)
        self.command("app.clearToast", alias="reset.app.clearToast", record_failure=False)
        self.command("app.dismissCert", alias="reset.app.dismissCert", record_failure=False)
        self.command("ui.root", alias="reset.ui.root", record_failure=False)
        started = time.monotonic()
        last_data: dict[str, Any] = {}
        for attempt in range(1, 11):
            self.command("app.clearError", alias=f"reset.retry.clearError.{attempt}", record_failure=False)
            self.command("app.clearToast", alias=f"reset.retry.clearToast.{attempt}", record_failure=False)
            self.command("ui.dismiss", {"target": "error"}, alias=f"reset.retry.dismiss.error.{attempt}", record_failure=False)
            self.command("ui.dismiss", {"target": "toast"}, alias=f"reset.retry.dismiss.toast.{attempt}", record_failure=False)
            response = self.command("ui.get", alias=f"reset.retry.ui.get.{attempt}", record_failure=False)
            data = response.get("data", {})
            last_data = data if isinstance(data, dict) else {}
            if (
                not last_data.get("presentedSheet")
                and not last_data.get("presentedAlert")
                and not last_data.get("visibleOverlays")
                and last_data.get("currentScreen") == "welcome"
            ):
                self.evidence.write(
                    "wait",
                    passed=True,
                    description="scenario reset clears presented UI",
                    action="ui.get",
                    attempts=attempt,
                    elapsedMs=round((time.monotonic() - started) * 1000.0, 2),
                    timeoutMs=3000.0,
                    intervalMs=100.0,
                    data=last_data,
                )
                return
            time.sleep(0.1)
        self.evidence.write(
            "wait",
            passed=False,
            description="scenario reset clears presented UI",
            action="ui.get",
            attempts=10,
            elapsedMs=round((time.monotonic() - started) * 1000.0, 2),
            timeoutMs=3000.0,
            intervalMs=100.0,
            data=last_data,
        )
        self.failures.append("Timed out waiting for scenario reset clears presented UI")

    def assert_idle_welcome(self) -> None:
        self.assert_baseline()
        connection = self._data_for("connection.status")
        audio = self._data_for("audio.status")
        connected = bool(connection.get("connected")) if isinstance(connection, dict) else False
        connecting = bool(connection.get("isConnecting")) if isinstance(connection, dict) else False
        audio_running = bool(audio.get("running")) if isinstance(audio, dict) else False
        local_test = bool(audio.get("localAudioTestRunning")) if isinstance(audio, dict) else False
        self._assert(not connected and not connecting, "idle-welcome starts without an active connection")
        self._assert(not audio_running and not local_test, "idle-welcome does not start microphone or local audio test")

    def assert_audio_running(self, audio: dict[str, Any], description: str) -> None:
        running = bool(audio.get("running")) if isinstance(audio, dict) else False
        local_test = bool(audio.get("localAudioTestRunning")) if isinstance(audio, dict) else False
        self._assert(running and local_test, description)

    def assert_audio_stopped(self, audio: dict[str, Any], description: str) -> None:
        running = bool(audio.get("running")) if isinstance(audio, dict) else False
        local_test = bool(audio.get("localAudioTestRunning")) if isinstance(audio, dict) else False
        self._assert(not running and not local_test, description)

    def wait_for_data(
        self,
        description: str,
        action: str,
        params: dict[str, Any] | None,
        predicate: Any,
        timeout: float,
        interval: float = 0.25,
    ) -> dict[str, Any]:
        started = time.monotonic()
        deadline = time.monotonic() + timeout
        attempt = 0
        last_data: dict[str, Any] = {}
        while time.monotonic() < deadline:
            attempt += 1
            response = self.command(action, params, alias=f"wait:{description}:{attempt}")
            data = response.get("data", {})
            last_data = data if isinstance(data, dict) else {}
            if response.get("success") and predicate(last_data):
                elapsed_ms = (time.monotonic() - started) * 1000.0
                self.evidence.write(
                    "wait",
                    passed=True,
                    description=description,
                    action=action,
                    attempts=attempt,
                    elapsedMs=round(elapsed_ms, 2),
                    timeoutMs=round(timeout * 1000.0, 2),
                    intervalMs=round(interval * 1000.0, 2),
                    data=last_data,
                )
                return last_data
            time.sleep(interval)
        elapsed_ms = (time.monotonic() - started) * 1000.0
        self.evidence.write(
            "wait",
            passed=False,
            description=description,
            action=action,
            attempts=attempt,
            elapsedMs=round(elapsed_ms, 2),
            timeoutMs=round(timeout * 1000.0, 2),
            intervalMs=round(interval * 1000.0, 2),
            data=last_data,
        )
        self.failures.append(f"Timed out waiting for {description}")
        return last_data

    def _receive_response(self, request_id: str) -> dict[str, Any]:
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            try:
                if self.ws.sock is not None:
                    self.ws.sock.settimeout(max(0.05, min(0.5, deadline - time.monotonic())))
                message = self.ws.recv_json()
            except socket.timeout:
                continue
            self._record_message(message)
            if message.get("id") == request_id:
                return message
        raise ProbeError(f"Timed out waiting for response to {request_id}")

    def _record_message(self, message: dict[str, Any]) -> None:
        if "event" in message:
            self.events.append(message)
            if message.get("event") == "log.entry":
                data = message.get("data")
                if isinstance(data, dict) and isinstance(data.get("message"), str):
                    self.log_messages.append(data["message"])
            self.evidence.write("event", message=message)
        elif "id" in message:
            self.evidence.write("command.response", message=message)
        else:
            self.evidence.write("message", message=message)

    def collect_diagnostics(self, scenario: str, reason: str) -> None:
        diagnostics: dict[str, Any] = {}
        commands = [
            Command("state.get"),
            Command("ui.get"),
            Command("app.get"),
            Command("connection.status"),
            Command("network.status", {"logLimit": 80}),
            Command("audio.status"),
            Command("audio.permission"),
            Command("performance.status"),
            Command("log.recent", {"limit": 160, "minimumLevel": "debug"}),
        ]
        for command in commands:
            alias = f"diagnostic.{command.action}"
            try:
                response = self.command(command.action, command.params, alias=alias, record_failure=False)
                diagnostics[command.action] = {
                    "success": bool(response.get("success")),
                    "data": response.get("data", {}),
                    "error": response.get("error"),
                }
            except Exception as exc:
                diagnostics[command.action] = {
                    "success": False,
                    "error": str(exc),
                    "errorType": type(exc).__name__,
                }
        self.evidence.write(
            "diagnostic.snapshot",
            scenario=scenario,
            reason=reason,
            failures=list(self.failures),
            data=diagnostics,
        )

    def _data_for(self, action: str) -> dict[str, Any]:
        response = self.responses.get(action, {})
        data = response.get("data", {})
        return data if isinstance(data, dict) else {}

    def _assert(self, condition: bool, description: str) -> None:
        self.evidence.write("assertion", passed=condition, description=description)
        if not condition:
            self.failures.append(description)


def scenario_commands(name: str, run_id: str) -> list[Command]:
    marker = {
        "message": f"PERF agent_probe marker=1 scenario={name} run={run_id}",
        "category": "General",
        "level": "info",
    }
    stream = {
        "enabled": True,
        "categories": DEFAULT_CATEGORIES,
        "minimumLevel": "debug",
    }
    commands = [
        Command("performance.reset"),
        Command("log.stream", stream),
        Command("log.marker", marker),
        Command("help.actions"),
        Command("log.getConfig"),
        Command("state.get"),
        Command("ui.get"),
        Command("connection.status"),
        Command("audio.status"),
        Command("audio.permission"),
        Command("performance.status"),
        Command("network.status"),
        Command("app.get"),
        Command("log.recent", {"limit": 120, "minimumLevel": "debug"}),
    ]
    if name in SCENARIOS:
        return commands
    raise ProbeError(f"Unknown scenario {name!r}")


def response_data(response: dict[str, Any]) -> dict[str, Any]:
    data = response.get("data", {})
    return data if isinstance(data, dict) else {}


def ui_presented_sheet(name: str) -> Any:
    return lambda data: data.get("presentedSheet") == name or data.get("currentScreen") == name


def audio_running(data: dict[str, Any]) -> bool:
    return bool(data.get("running")) and bool(data.get("localAudioTestRunning"))


def audio_stopped(data: dict[str, Any]) -> bool:
    return not bool(data.get("running")) and not bool(data.get("localAudioTestRunning"))


def microphone_permission_allows_audio(data: dict[str, Any]) -> bool:
    return str(data.get("microphone", "unknown")) in {"authorized", "unsupported"}


def connection_idle(data: dict[str, Any]) -> bool:
    return not bool(data.get("connected")) and not bool(data.get("isConnecting")) and not bool(data.get("isReconnecting"))


def network_timeline_has(data: dict[str, Any], expected_kind: str) -> bool:
    timeline = data.get("timeline")
    if not isinstance(timeline, list):
        return False
    return any(isinstance(item, dict) and item.get("kind") == expected_kind for item in timeline)


def network_has_reconnect_evidence(data: dict[str, Any]) -> bool:
    connection = data.get("connection")
    connection = connection if isinstance(connection, dict) else {}
    if bool(connection.get("isReconnecting")):
        return True
    if int_value(connection.get("reconnectAttempt")) > 0:
        return True
    timeline = data.get("timeline")
    if not isinstance(timeline, list):
        return False
    for item in timeline:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("kind", ""))
        message = str(item.get("message", "")).lower()
        if kind == "reconnect" or "reconnect" in message or "reconnecting: true" in message:
            return True
    return False


def network_has_udp_degraded_evidence(data: dict[str, Any]) -> bool:
    transport = data.get("transport")
    transport = transport if isinstance(transport, dict) else {}
    udp_state = str(transport.get("udpState", "unknown"))
    if udp_state in {"stalled", "recovering", "unavailable"}:
        return True
    if float_value(transport.get("udpPingMeanMs")) > 150.0:
        return True
    if float_value(transport.get("packetLossPercent")) > 0.0:
        return True
    return network_timeline_has(data, "udp_state")


def active_toast(data: dict[str, Any]) -> dict[str, Any]:
    toast = data.get("activeToast")
    return toast if isinstance(toast, dict) else {}


def toast_contains(data: dict[str, Any], text: str, toast_type: str | None = None) -> bool:
    return toast_contains_any(data, [text], toast_type)


def toast_contains_any(data: dict[str, Any], texts: list[str], toast_type: str | None = None) -> bool:
    toast = active_toast(data)
    message = str(toast.get("message", ""))
    if not any(text in message for text in texts):
        return False
    if toast_type is not None and toast.get("type") != toast_type:
        return False
    return True


def float_value(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def int_value(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def setting_value(response: dict[str, Any]) -> Any:
    data = response_data(response)
    return data.get("value")


def restore_setting(runner: ProbeRunner, key: str, value: Any) -> None:
    if value is None:
        runner.command("settings.remove", {"key": key}, alias=f"restore:{key}", record_failure=False)
    else:
        runner.command("settings.set", {"key": key, "value": value}, alias=f"restore:{key}", record_failure=False)


def run_scenario(args: argparse.Namespace, runner: ProbeRunner, run_id: str) -> None:
    try:
        for command in scenario_commands(args.scenario, run_id):
            runner.command(command.action, command.params)
        runner.reset_for_scenario()

        if args.scenario == "idle-welcome":
            runner.assert_idle_welcome()
            return

        runner.assert_baseline()

        if args.scenario == "lifecycle-idle-audio":
            runner.command("ui.root", alias="ui.root.lifecycleIdle")
            before_audio = response_data(runner.command("audio.status", alias="audio.beforeLifecycleIdle"))
            runner.assert_audio_stopped(before_audio, "lifecycle-idle-audio starts without audio running")
            runner.command(
                "app.simulateLifecycle",
                {"phase": "willResignActive"},
                alias="app.simulateLifecycle.willResignActive",
            )
            background_audio = response_data(runner.command("audio.status", alias="audio.afterWillResignActive"))
            runner.assert_audio_stopped(
                background_audio,
                "lifecycle-idle-audio keeps audio stopped after background transition",
            )
            runner.command(
                "app.simulateLifecycle",
                {"phase": "didBecomeActive"},
                alias="app.simulateLifecycle.didBecomeActive",
            )
            foreground_audio = response_data(runner.command("audio.status", alias="audio.afterDidBecomeActive"))
            runner.assert_audio_stopped(
                foreground_audio,
                "lifecycle-idle-audio keeps audio stopped after foreground transition",
            )
            connection = response_data(runner.command("connection.status", alias="connection.afterLifecycleIdle"))
            runner._assert(connection_idle(connection), "lifecycle-idle-audio remains disconnected and idle")
            return

        if args.scenario == "ui-performance-sampling":
            runner.command("ui.root", alias="ui.root.performanceSampling")
            previous_stall_count = 0
            for iteration in range(1, 9):
                runner.command("app.refreshModel", alias=f"app.refreshModel.performanceSampling.{iteration}")
                runner.command("state.get", alias=f"state.get.performanceSampling.{iteration}")
                runner.command("ui.get", alias=f"ui.get.performanceSampling.{iteration}")
                runner.command("app.get", alias=f"app.get.performanceSampling.{iteration}")
                performance = response_data(
                    runner.command("performance.status", alias=f"performance.status.performanceSampling.{iteration}")
                )
                runner.evidence.write(
                    "performance.snapshot",
                    scenario=args.scenario,
                    sample=f"ui-performance-sampling-{iteration}",
                    data=performance,
                )
                stall_count = int(performance.get("stallCount") or 0)
                runner._assert(
                    stall_count == previous_stall_count,
                    f"ui-performance-sampling iteration {iteration} does not add main-thread stalls",
                )
                previous_stall_count = stall_count
            runner.command(
                "log.marker",
                {
                    "message": f"PERF ui_performance_sampling marker=1 samples=8 run={run_id}",
                    "category": "UI",
                    "level": "info",
                },
                alias="log.marker.uiPerformanceSampling",
            )
            return

        if args.scenario == "network-settings":
            keys = [
                "NetworkForceTCP",
                "NetworkAutoReconnect",
                "NetworkQoS",
                "NetworkReconnectMaxAttempts",
                "NetworkReconnectInterval",
            ]
            original = {
                key: setting_value(runner.command("settings.get", {"key": key}, alias=f"original:{key}"))
                for key in keys
            }
            try:
                runner.command("settings.set", {"key": "NetworkForceTCP", "value": True}, alias="set:NetworkForceTCP")
                runner.command(
                    "settings.set",
                    {"key": "NetworkAutoReconnect", "value": False},
                    alias="set:NetworkAutoReconnect",
                )
                runner.command("settings.set", {"key": "NetworkQoS", "value": False}, alias="set:NetworkQoS")
                runner.command(
                    "settings.set",
                    {"key": "NetworkReconnectMaxAttempts", "value": 3},
                    alias="set:NetworkReconnectMaxAttempts",
                )
                runner.command(
                    "settings.set",
                    {"key": "NetworkReconnectInterval", "value": 0.5},
                    alias="set:NetworkReconnectInterval",
                )
                configured = response_data(
                    runner.command("network.status", {"logLimit": 40}, alias="network.status.configured")
                )
                settings = configured.get("settings", {})
                settings = settings if isinstance(settings, dict) else {}
                runner._assert(settings.get("forceTCP") is True, "network-settings exposes forced TCP setting")
                runner._assert(settings.get("autoReconnect") is False, "network-settings exposes disabled auto reconnect")
                runner._assert(settings.get("enableQoS") is False, "network-settings exposes disabled QoS")
                runner._assert(settings.get("reconnectMaxAttempts") == 3, "network-settings exposes reconnect attempt budget")
                runner._assert(
                    float(settings.get("reconnectInterval", 0.0)) == 0.5,
                    "network-settings exposes reconnect interval budget",
                )
            finally:
                for key, value in original.items():
                    restore_setting(runner, key, value)
            restored = response_data(runner.command("network.status", {"logLimit": 40}, alias="network.status.restored"))
            restored_settings = restored.get("settings", {})
            restored_settings = restored_settings if isinstance(restored_settings, dict) else {}
            runner._assert(
                restored_settings.get("forceTCP") == (False if original["NetworkForceTCP"] is None else original["NetworkForceTCP"]),
                "network-settings restores forced TCP setting",
            )
            runner._assert(
                restored_settings.get("autoReconnect") == (True if original["NetworkAutoReconnect"] is None else original["NetworkAutoReconnect"]),
                "network-settings restores auto reconnect setting",
            )
            runner._assert(
                restored_settings.get("enableQoS") == (True if original["NetworkQoS"] is None else original["NetworkQoS"]),
                "network-settings restores QoS setting",
            )
            return

        if args.scenario == "network-connect-failure":
            original_auto_reconnect = setting_value(
                runner.command("settings.get", {"key": "NetworkAutoReconnect"}, alias="original:NetworkAutoReconnect")
            )
            try:
                runner.command(
                    "settings.set",
                    {"key": "NetworkAutoReconnect", "value": False},
                    alias="set:NetworkAutoReconnect",
                )
                runner.command(
                    "connection.connect",
                    {
                        "hostname": "127.0.0.1",
                        "port": 1,
                        "username": f"Probe{run_id[:6]}",
                        "displayName": "Probe Unreachable Localhost",
                    },
                    alias="connection.connect.unreachable",
                )
                runner.collect_events(min(1.0, args.wait_timeout))
                connection = runner.wait_for_data(
                    "unreachable connection returns to idle",
                    "connection.status",
                    None,
                    connection_idle,
                    timeout=args.wait_timeout,
                    interval=0.5,
                )
                runner._assert(connection_idle(connection), "network-connect-failure does not leave connection active")
                audio = response_data(runner.command("audio.status", alias="audio.afterConnectFailure"))
                runner.assert_audio_stopped(audio, "network-connect-failure does not start audio after failed connect")
                network = response_data(
                    runner.command("network.status", {"logLimit": 120}, alias="network.status.afterConnectFailure")
                )
                recent_logs = response_data(
                    runner.command(
                        "log.recent",
                        {"limit": 160, "minimumLevel": "debug", "categories": ["Connection", "Network"]},
                        alias="log.recent.afterConnectFailure",
                    )
                )
                entries = recent_logs.get("entries", [])
                log_messages = [
                    str(entry.get("message", ""))
                    for entry in entries
                    if isinstance(entry, dict)
                ]
                has_failure_log = any("connect_failed" in message or "Connection error" in message for message in log_messages)
                has_failure_event = any(event.get("event") == "connection.error" for event in runner.events)
                has_failure_timeline = network_timeline_has(network, "connect_failed")
                runner._assert(
                    has_failure_log or has_failure_event or has_failure_timeline,
                    "network-connect-failure records connection failure in logs, events, or network timeline",
                )
            finally:
                restore_setting(runner, "NetworkAutoReconnect", original_auto_reconnect)
                runner.command("connection.disconnect", alias="cleanup:connection.disconnect", record_failure=False)
            restored = response_data(runner.command("network.status", {"logLimit": 40}, alias="network.status.restored"))
            restored_settings = restored.get("settings", {})
            restored_settings = restored_settings if isinstance(restored_settings, dict) else {}
            runner._assert(
                restored_settings.get("autoReconnect") == (True if original_auto_reconnect is None else original_auto_reconnect),
                "network-connect-failure restores auto reconnect setting",
            )
            return

        if args.scenario == "network-auto-reconnect":
            keys = [
                "NetworkAutoReconnect",
                "NetworkReconnectMaxAttempts",
                "NetworkReconnectInterval",
            ]
            original = {
                key: setting_value(runner.command("settings.get", {"key": key}, alias=f"original:{key}"))
                for key in keys
            }
            try:
                runner.command(
                    "settings.set",
                    {"key": "NetworkAutoReconnect", "value": True},
                    alias="set:NetworkAutoReconnect",
                )
                runner.command(
                    "settings.set",
                    {"key": "NetworkReconnectMaxAttempts", "value": 3},
                    alias="set:NetworkReconnectMaxAttempts",
                )
                runner.command(
                    "settings.set",
                    {"key": "NetworkReconnectInterval", "value": 1.0},
                    alias="set:NetworkReconnectInterval",
                )
                configured = response_data(
                    runner.command("network.status", {"logLimit": 60}, alias="network.status.reconnectConfigured")
                )
                settings = configured.get("settings", {})
                settings = settings if isinstance(settings, dict) else {}
                runner._assert(settings.get("autoReconnect") is True, "network-auto-reconnect enables auto reconnect")
                runner._assert(settings.get("reconnectMaxAttempts") == 3, "network-auto-reconnect sets reconnect attempt budget")
                runner._assert(
                    float(settings.get("reconnectInterval", 0.0)) == 1.0,
                    "network-auto-reconnect sets reconnect interval budget",
                )
                runner.command(
                    "connection.connect",
                    {
                        "hostname": "127.0.0.1",
                        "port": 1,
                        "username": f"Probe{run_id[:6]}",
                        "displayName": "Probe Auto Reconnect Localhost",
                    },
                    alias="connection.connect.autoReconnect",
                )
                reconnecting_network = runner.wait_for_data(
                    "auto reconnect produces reconnect evidence",
                    "network.status",
                    {"logLimit": 160},
                    network_has_reconnect_evidence,
                    timeout=args.wait_timeout,
                    interval=0.25,
                )
                runner._assert(
                    network_has_reconnect_evidence(reconnecting_network),
                    "network-auto-reconnect records reconnect state, attempt, or timeline evidence",
                )
                connection = reconnecting_network.get("connection", {})
                connection = connection if isinstance(connection, dict) else {}
                runner._assert(
                    not bool(connection.get("connected")),
                    "network-auto-reconnect does not report connected before a successful retry",
                )
                audio = response_data(runner.command("audio.status", alias="audio.afterAutoReconnectFailure"))
                runner.assert_audio_stopped(audio, "network-auto-reconnect does not start audio while retrying failed connect")
            finally:
                runner.command("connection.disconnect", alias="cleanup:connection.disconnect", record_failure=False)
                for key, value in original.items():
                    restore_setting(runner, key, value)
            restored = response_data(runner.command("network.status", {"logLimit": 40}, alias="network.status.restored"))
            restored_settings = restored.get("settings", {})
            restored_settings = restored_settings if isinstance(restored_settings, dict) else {}
            runner._assert(
                restored_settings.get("autoReconnect") == (True if original["NetworkAutoReconnect"] is None else original["NetworkAutoReconnect"]),
                "network-auto-reconnect restores auto reconnect setting",
            )
            runner._assert(
                restored_settings.get("reconnectMaxAttempts") == (10 if original["NetworkReconnectMaxAttempts"] is None else original["NetworkReconnectMaxAttempts"]),
                "network-auto-reconnect restores reconnect attempt budget",
            )
            runner._assert(
                float(restored_settings.get("reconnectInterval", 0.0))
                == (1.0 if original["NetworkReconnectInterval"] is None else float(original["NetworkReconnectInterval"])),
                "network-auto-reconnect restores reconnect interval budget",
            )
            return

        if args.scenario == "network-udp-degraded":
            marker_message = f"UDP transport state changed: recovering; ping_ms=175.0 packet_loss_percent=2.5 run={run_id}"
            runner.command(
                "log.marker",
                {
                    "message": marker_message,
                    "category": "Network",
                    "level": "warning",
                },
                alias="log.marker.udpDegraded",
            )
            network = response_data(
                runner.command("network.status", {"logLimit": 120}, alias="network.status.udpDegraded")
            )
            runner._assert(
                network_has_udp_degraded_evidence(network),
                "network-udp-degraded records UDP transport degradation in transport metrics or timeline",
            )
            recent_logs = response_data(
                runner.command(
                    "log.recent",
                    {"limit": 120, "minimumLevel": "debug", "category": "Network"},
                    alias="log.recent.udpDegraded",
                )
            )
            entries = recent_logs.get("entries", [])
            log_messages = [
                str(entry.get("message", ""))
                for entry in entries
                if isinstance(entry, dict)
            ]
            runner._assert(
                any("UDP transport state changed" in message for message in log_messages),
                "network-udp-degraded keeps the UDP degradation marker in recent Network logs",
            )
            return

        if args.scenario == "network-udp-toast-throttle":
            stalled_udp_toast = ["UDP stalled", "UDP 停滞"]
            restored_udp_toast = ["UDP channel restored", "UDP 连接已恢复"]
            runner.command("app.clearToast", alias="app.clearToast.udpThrottle")
            runner.command(
                "network.injectUDPStatus",
                {"state": "stalled"},
                alias="network.injectUDPStatus.stalled",
            )
            stalled_app = runner.wait_for_data(
                "UDP stalled toast appears",
                "app.get",
                None,
                lambda data: toast_contains_any(data, stalled_udp_toast, "error"),
                timeout=min(args.wait_timeout, 2.0),
                interval=0.1,
            )
            runner._assert(
                toast_contains_any(stalled_app, stalled_udp_toast, "error"),
                "network-udp-toast-throttle shows the first stalled UDP toast",
            )
            runner.command(
                "network.injectUDPStatus",
                {"state": "recovering"},
                alias="network.injectUDPStatus.recovering",
            )
            recovering_app = response_data(runner.command("app.get", alias="app.get.afterUDPRecovering"))
            runner._assert(
                toast_contains_any(recovering_app, stalled_udp_toast, "error"),
                "network-udp-toast-throttle suppresses immediate recovering toast replacement",
            )
            runner.command(
                "network.injectUDPStatus",
                {"state": "available"},
                alias="network.injectUDPStatus.available",
            )
            restored_app = runner.wait_for_data(
                "UDP restored toast appears",
                "app.get",
                None,
                lambda data: toast_contains_any(data, restored_udp_toast, "success"),
                timeout=min(args.wait_timeout, 2.0),
                interval=0.1,
            )
            runner._assert(
                toast_contains_any(restored_app, restored_udp_toast, "success"),
                "network-udp-toast-throttle still shows the restored UDP toast",
            )
            return

        if args.scenario == "mixer-lifecycle":
            runner.command("ui.root")
            runner.command("ui.open", {"target": "preferences"})
            runner.wait_for_data(
                "preferences presentation before advanced audio settings",
                "ui.get",
                None,
                lambda data: data.get("presentedSheet") == "preferences"
                and data.get("currentScreen") == "preferences",
                timeout=args.wait_timeout,
            )
            runner.command("ui.open", {"target": "advancedAudioSettings"})
            advanced_ui = runner.wait_for_data(
                "advanced audio settings presentation",
                "ui.get",
                None,
                lambda data: data.get("currentScreen") == "advancedAudioSettings",
                timeout=args.wait_timeout,
            )
            if advanced_ui.get("currentScreen") != "advancedAudioSettings":
                return
            mixer_permission = response_data(runner.command("audio.permission", alias="audio.permission.mixer"))
            if not microphone_permission_allows_audio(mixer_permission):
                runner._assert(
                    False,
                    f"mixer-lifecycle microphone permission is authorized for local audio test: state={mixer_permission.get('microphone', 'unknown')}",
                )
                return
            runner.command("ui.open", {"target": "audioPluginMixer"})
            mixer_ui = runner.wait_for_data(
                "audio plugin mixer presentation",
                "ui.get",
                None,
                ui_presented_sheet("audioPluginMixer"),
                timeout=args.wait_timeout,
            )
            runner._assert(ui_presented_sheet("audioPluginMixer")(mixer_ui), "mixer-lifecycle presents audioPluginMixer UI")
            mixer_audio = runner.wait_for_data(
                "audio plugin mixer local audio running",
                "audio.status",
                None,
                audio_running,
                timeout=args.wait_timeout,
            )
            runner.assert_audio_running(mixer_audio, "mixer-lifecycle starts local audio while mixer is open")
            runner.command("ui.dismiss", {"target": "audioPluginMixer"})
            runner.wait_for_data(
                "audio plugin mixer dismissed",
                "ui.get",
                None,
                lambda data: data.get("presentedSheet") != "audioPluginMixer",
                timeout=args.wait_timeout,
            )
            stopped_audio = runner.wait_for_data(
                "audio plugin mixer local audio stopped after dismiss",
                "audio.status",
                None,
                audio_stopped,
                timeout=args.wait_timeout,
            )
            runner.assert_audio_stopped(stopped_audio, "mixer-lifecycle stops local audio after mixer dismiss when disconnected")
            return

        if args.scenario == "vad-onboarding":
            runner.command("ui.root")
            runner.command("ui.open", {"target": "vadOnboarding"})
            vad_ui = runner.wait_for_data(
                "VAD onboarding presentation",
                "ui.get",
                None,
                ui_presented_sheet("vadOnboarding"),
                timeout=args.wait_timeout,
            )
            runner._assert(ui_presented_sheet("vadOnboarding")(vad_ui), "vad-onboarding presents VAD onboarding UI")
            vad_permission = response_data(runner.command("audio.permission", alias="audio.permission.vad"))
            if not microphone_permission_allows_audio(vad_permission):
                runner._assert(
                    False,
                    f"vad-onboarding microphone permission is authorized for local audio test: state={vad_permission.get('microphone', 'unknown')}",
                )
                return
            vad_audio = runner.wait_for_data(
                "VAD onboarding local audio running",
                "audio.status",
                None,
                audio_running,
                timeout=args.wait_timeout,
            )
            runner.assert_audio_running(vad_audio, "vad-onboarding starts local audio while presented")
            runner.command("ui.dismiss", {"target": "vadOnboarding"})
            runner.wait_for_data(
                "VAD onboarding dismissed",
                "ui.get",
                None,
                lambda data: data.get("presentedSheet") != "vadOnboarding",
                timeout=args.wait_timeout,
            )
    finally:
        try:
            response = runner.command("performance.status", alias="performance.final")
            data = response.get("data", {})
            if isinstance(data, dict):
                runner.evidence.write("performance.snapshot", scenario=args.scenario, data=data)
        except Exception as exc:
            runner.evidence.write(
                "performance.snapshot",
                scenario=args.scenario,
                error=str(exc),
                error_type=type(exc).__name__,
            )


def default_output_path(scenario: str) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return Path("Tests") / "Artifacts" / f"{stamp}-{scenario}.jsonl"


def default_suite_output_dir() -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return Path("Tests") / "Artifacts" / f"{stamp}-suite"


def run_probe(args: argparse.Namespace, websocket_factory: Any | None = None) -> int:
    run_id = args.run_id or uuid.uuid4().hex[:12]
    output = Path(args.output) if args.output else default_output_path(args.scenario)
    evidence = EvidenceWriter(output)
    ws = websocket_factory() if websocket_factory else StdlibWebSocket(args.url, timeout=args.timeout)
    runner = ProbeRunner(ws, evidence, run_id, timeout=args.timeout)
    status = "failed"

    evidence.write("run.start", run_id=run_id, scenario=args.scenario, url=args.url, provenance=provenance(args))
    try:
        ws.connect()
        evidence.write("websocket.connected", url=args.url)
        run_scenario(args, runner, run_id)
        if args.settle_seconds > 0:
            runner.collect_events(args.settle_seconds)
        status = "passed" if not runner.failures else "failed"
        return 0 if not runner.failures else 1
    except Exception as exc:
        runner.failures.append(str(exc))
        evidence.write("error", error=str(exc), error_type=type(exc).__name__)
        return 2
    finally:
        if runner.failures:
            try:
                runner.collect_diagnostics(args.scenario, reason=status)
            except Exception as exc:
                evidence.write(
                    "diagnostic.snapshot",
                    scenario=args.scenario,
                    reason=status,
                    failures=list(runner.failures),
                    error=str(exc),
                    error_type=type(exc).__name__,
                )
        ws.close()
        evidence.write("run.end", run_id=run_id, scenario=args.scenario, status=status, failures=runner.failures, output=str(output))
        evidence.close()
        if not getattr(args, "suppress_failure_output", False):
            print(f"{status}: scenario={args.scenario} evidence={output}")
        if runner.failures and not getattr(args, "suppress_failure_output", False):
            for failure in runner.failures:
                print(f" - {failure}", file=sys.stderr)


def run_suite(args: argparse.Namespace, websocket_factory: Any | None = None) -> int:
    suite_id = args.run_id or uuid.uuid4().hex[:12]
    output_dir = Path(args.output) if args.output else default_suite_output_dir()
    output_dir.mkdir(parents=True, exist_ok=True)
    suite_index = EvidenceWriter(output_dir / "suite-index.jsonl")
    failures: list[str] = []

    repeat = max(1, int(getattr(args, "repeat", 1)))
    suite_index.write("suite.start", suite_id=suite_id, scenarios=SCENARIOS, repeat=repeat, url=args.url, provenance=provenance(args))
    try:
        for iteration in range(1, repeat + 1):
            for scenario in SCENARIOS:
                scenario_args = argparse.Namespace(**vars(args))
                scenario_args.scenario = scenario
                scenario_args.output = str(output_dir / f"{scenario}.jsonl" if repeat == 1 else output_dir / f"{scenario}-{iteration}.jsonl")
                scenario_args.run_id = f"{suite_id}-{scenario}" if repeat == 1 else f"{suite_id}-{scenario}-{iteration}"
                started = time.monotonic()
                status = run_probe(scenario_args, websocket_factory=websocket_factory)
                elapsed_ms = (time.monotonic() - started) * 1000.0
                suite_index.write(
                    "suite.scenario",
                    suite_id=suite_id,
                    scenario=scenario,
                    iteration=iteration,
                    repeat=repeat,
                    status="passed" if status == 0 else "failed",
                    exit_code=status,
                    elapsed_ms=round(elapsed_ms, 2),
                    output=scenario_args.output,
                )
                if status != 0:
                    failures.append(f"{scenario} iteration {iteration} exited {status}")
        return 0 if not failures else 1
    finally:
        suite_index.write("suite.end", suite_id=suite_id, status="passed" if not failures else "failed", failures=failures)
        suite_index.close()
        print(f"{'passed' if not failures else 'failed'}: suite evidence={output_dir}")
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)


class FakeSocket:
    def settimeout(self, timeout: float) -> None:
        _ = timeout


class FakeWebSocket:
    def __init__(self, fail_audio_status: bool = False) -> None:
        self.sock: FakeSocket | None = FakeSocket()
        self.messages: list[dict[str, Any]] = []
        self.current_screen = "welcome"
        self.presented_sheet: str | None = None
        self.audio_running = False
        self.local_audio_test_running = False
        self.fail_audio_status = fail_audio_status
        self.log_stream_enabled = False
        self.recent_logs: list[dict[str, Any]] = []
        self.settings: dict[str, Any] = {}
        self.connection_attempted = False
        self.connection_failed = False
        self.connection_reconnecting = False
        self.reconnect_attempt = 0
        self.network_degraded = False
        self.active_toast: dict[str, Any] | None = None
        self.last_udp_transient_toast_sequence: int | None = None
        self.sequence = 0

    def connect(self) -> None:
        return

    def close(self) -> None:
        self.sock = None

    def send_json(self, payload: dict[str, Any]) -> None:
        request_id = str(payload.get("id", ""))
        action = str(payload.get("action", ""))
        params = payload.get("params", {})
        if not isinstance(params, dict):
            params = {}
        if action == "log.marker":
            entry = self._log_entry(params)
            self.recent_logs.append(entry)
            if entry.get("category") == "Network" and "UDP transport state changed" in str(entry.get("message", "")):
                self.network_degraded = True
            if self.log_stream_enabled:
                self.messages.append({"event": "log.entry", "data": entry})
        if action == "connection.connect":
            self.connection_attempted = True
            self.connection_failed = True
            auto_reconnect = bool(self.settings.get("NetworkAutoReconnect", True))
            if auto_reconnect:
                self.connection_reconnecting = True
                self.reconnect_attempt = 1
            begin_entry = self._connection_log_entry(
                "debug",
                "PERF connect_begin reconnect=false attempt=0 reason=manual host=127.0.0.1:1",
            )
            failed_entry = self._connection_log_entry(
                "debug",
                "PERF connect_failed reconnect=false attempt=0 total_ms=12.5 title=Connection error message=Connection refused",
            )
            reconnect_entry = self._connection_log_entry(
                "warning",
                "Connection closed unexpectedly. Attempting reconnect (Attempt 1/3)...",
            )
            scheduled_entry = self._connection_log_entry(
                "debug",
                "Reconnect scheduled after 1.00s (attempt 1/3).",
            )
            entries = [begin_entry, failed_entry]
            if auto_reconnect:
                entries.extend([reconnect_entry, scheduled_entry])
            self.recent_logs.extend(entries)
            self.messages.append(
                {
                    "event": "connection.connecting",
                    "data": {
                        "isReconnecting": auto_reconnect,
                        "reconnectAttempt": 1 if auto_reconnect else 0,
                        "reconnectMaxAttempts": 3 if auto_reconnect else 0,
                    },
                }
            )
            if self.log_stream_enabled:
                for entry in entries:
                    self.messages.append({"event": "log.entry", "data": entry})
            if not auto_reconnect:
                self.messages.append(
                    {
                        "event": "connection.error",
                        "data": {"title": "Connection error", "message": "Connection refused"},
                    }
                )
        if action == "connection.disconnect":
            self.connection_reconnecting = False
            self.reconnect_attempt = 0
        if action == "app.clearToast":
            self.active_toast = None
        if action == "network.injectUDPStatus":
            self._inject_udp_status(str(params.get("state", "unknown")))
        self.messages.append({"id": request_id, "success": True, "data": self._data_for(action, params)})

    def recv_json(self) -> dict[str, Any]:
        if not self.messages:
            raise socket.timeout()
        return self.messages.pop(0)

    def _data_for(self, action: str, params: dict[str, Any]) -> dict[str, Any]:
        if action == "help.actions":
            return {"domains": {key: [] for key in ["log", "state", "ui", "audio", "connection", "performance", "network"]}}
        if action == "log.getConfig":
            return {"categories": {key: {} for key in DEFAULT_CATEGORIES}}
        if action == "state.get":
            return {"app": {"bundleIdentifier": "self-test"}, "ui": self._ui_snapshot()}
        if action == "ui.get":
            return self._ui_snapshot()
        if action == "connection.status":
            return {
                "connected": False,
                "isConnecting": False,
                "isReconnecting": self.connection_reconnecting,
                "reconnectAttempt": self.reconnect_attempt,
                "reconnectMaxAttempts": int(self.settings.get("NetworkReconnectMaxAttempts", 10)),
                "lastError": "Connection refused" if self.connection_failed else None,
            }
        if action == "audio.status":
            return {
                "running": self.audio_running or self.fail_audio_status,
                "localAudioTestRunning": self.local_audio_test_running or self.fail_audio_status,
            }
        if action == "audio.permission":
            return {"microphone": "authorized"}
        if action in {"performance.status", "performance.reset"}:
            return self._performance_snapshot()
        if action == "network.status":
            return self._network_snapshot()
        if action == "app.get":
            return {
                "name": "Mumble",
                "mode": "self-test",
                "activeToast": self.active_toast,
                "performance": self._performance_snapshot(),
            }
        if action == "app.simulateLifecycle":
            return {
                "name": "Mumble",
                "mode": "self-test",
                "lifecyclePhase": str(params.get("phase", "")),
                "lifecycleSupported": True,
                "activeToast": self.active_toast,
                "performance": self._performance_snapshot(),
            }
        if action == "settings.get":
            key = str(params.get("key", ""))
            return {"key": key, "value": self.settings.get(key)}
        if action == "settings.set":
            key = str(params.get("key", ""))
            value = params.get("value")
            self.settings[key] = value
            return {"key": key, "value": value}
        if action == "settings.remove":
            key = str(params.get("key", ""))
            self.settings.pop(key, None)
            return {"key": key, "removed": True}
        if action == "settings.list":
            prefix = params.get("prefix")
            entries = [
                {"key": key, "value": value}
                for key, value in sorted(self.settings.items())
                if not isinstance(prefix, str) or key.startswith(prefix)
            ]
            return {"entries": entries}
        if action == "log.recent":
            return {"entries": self.recent_logs[-int(params.get("limit", 120)) :]}
        if action == "log.stream":
            self.log_stream_enabled = bool(params.get("enabled", True))
            return {"isEnabled": self.log_stream_enabled}
        if action == "log.marker":
            return {"accepted": True}
        if action == "ui.root":
            self.current_screen = "welcome"
            self.presented_sheet = None
            return self._ui_snapshot()
        if action == "ui.open":
            return self._open_ui(str(params.get("target", "")))
        if action == "ui.dismiss":
            return self._dismiss_ui(str(params.get("target", "")))
        return {}

    def _inject_udp_status(self, state: str) -> None:
        self.sequence += 1
        if state == "stalled":
            self.active_toast = {"message": "UDP stalled, recovering audio channel...", "type": "error"}
            self.last_udp_transient_toast_sequence = self.sequence
        elif state == "recovering":
            if self.last_udp_transient_toast_sequence is None or self.sequence - self.last_udp_transient_toast_sequence > 4:
                self.active_toast = {"message": "Re-establishing UDP channel...", "type": "info"}
                self.last_udp_transient_toast_sequence = self.sequence
        elif state == "unavailable":
            if self.last_udp_transient_toast_sequence is None or self.sequence - self.last_udp_transient_toast_sequence > 4:
                self.active_toast = {"message": "UDP unavailable, using TCP tunnel", "type": "info"}
                self.last_udp_transient_toast_sequence = self.sequence
        elif state == "available":
            self.active_toast = {"message": "UDP channel restored", "type": "success"}

    def _performance_snapshot(self) -> dict[str, Any]:
        return {
            "isRunning": True,
            "intervalMs": 500,
            "thresholdMs": 120.0,
            "stallCount": 0,
            "lastLagMs": 0,
            "maxLagMs": 0,
            "lastStallContext": {},
            "maxStallContext": {},
        }

    def _network_snapshot(self) -> dict[str, Any]:
        return {
            "connection": {
                "connected": False,
                "isConnecting": self.connection_reconnecting,
                "isReconnecting": self.connection_reconnecting,
                "reconnectAttempt": self.reconnect_attempt,
                "reconnectMaxAttempts": int(self.settings.get("NetworkReconnectMaxAttempts", 10)),
                "reconnectReason": "Connection refused" if self.connection_reconnecting else None,
            },
            "settings": {
                "forceTCP": bool(self.settings.get("NetworkForceTCP", False)),
                "autoReconnect": bool(self.settings.get("NetworkAutoReconnect", True)),
                "enableQoS": bool(self.settings.get("NetworkQoS", True)),
                "reconnectMaxAttempts": int(self.settings.get("NetworkReconnectMaxAttempts", 10)),
                "reconnectInterval": float(self.settings.get("NetworkReconnectInterval", 1.0)),
            },
            "transport": self._network_transport_snapshot(),
            "recentNetworkLogs": self._recent_logs_for_category("Network"),
            "timeline": [
                {
                    "timestamp": "2026-01-01 00:00:00.000",
                    "category": "Connection",
                    "level": "info",
                    "kind": "connecting",
                    "message": "Connecting (reconnecting: False)",
                }
            ]
            + (
                [
                    {
                        "timestamp": "2026-01-01 00:00:00.050",
                        "category": "Connection",
                        "level": "debug",
                        "kind": "connect_failed",
                        "message": "PERF connect_failed reconnect=false attempt=0 total_ms=12.5 title=Connection error message=Connection refused",
                    }
                ]
                if self.connection_failed
                else []
            )
            + (
                [
                    {
                        "timestamp": "2026-01-01 00:00:00.075",
                        "category": "Connection",
                        "level": "warning",
                        "kind": "reconnect",
                        "message": "Connection closed unexpectedly. Attempting reconnect (Attempt 1/3)...",
                    },
                    {
                        "timestamp": "2026-01-01 00:00:00.080",
                        "category": "Connection",
                        "level": "debug",
                        "kind": "reconnect",
                        "message": "Reconnect scheduled after 1.00s (attempt 1/3).",
                    },
                ]
                if self.connection_reconnecting
                else []
            )
            + self._network_marker_timeline(),
        }

    def _network_transport_snapshot(self) -> dict[str, Any]:
        if self.network_degraded:
            return {
                "udpState": "recovering",
                "udpPingMeanMs": 175.0,
                "udpPingVarianceMs": 40.0,
                "udpPingSamples": 8,
                "lastGood": 140,
                "lastLate": 20,
                "lastLost": 4,
                "packetAccountingTotal": 164,
                "packetLossPercent": 2.44,
                "latePacketPercent": 12.2,
            }
        return {"udpState": "unknown", "udpPingSamples": 0, "packetAccountingTotal": 0}

    def _recent_logs_for_category(self, category: str) -> list[dict[str, Any]]:
        return [entry for entry in self.recent_logs if entry.get("category") == category]

    def _network_marker_timeline(self) -> list[dict[str, Any]]:
        timeline = []
        for entry in self._recent_logs_for_category("Network"):
            message = str(entry.get("message", ""))
            level = str(entry.get("level", "info"))
            if "UDP transport state changed" in message or "udp" in message.lower():
                kind = "udp_state"
            else:
                kind = "warning" if level == "warning" else "log"
            timeline.append(
                {
                    "timestamp": str(entry.get("timestamp", "2026-01-01 00:00:00.000")),
                    "category": "Network",
                    "level": level,
                    "kind": kind,
                    "message": message,
                }
            )
        return timeline

    def _open_ui(self, target: str) -> dict[str, Any]:
        if target == "preferences":
            self.current_screen = "preferences"
            self.presented_sheet = "preferences"
        elif target == "advancedAudioSettings" and self.current_screen == "preferences":
            self.current_screen = "advancedAudioSettings"
        elif target in {"audioPluginMixer", "vadOnboarding"}:
            self.presented_sheet = target
            self.audio_running = True
            self.local_audio_test_running = True
        return self._ui_snapshot()

    def _dismiss_ui(self, target: str) -> dict[str, Any]:
        if self.presented_sheet == target:
            self.presented_sheet = None
        if target == "preferences":
            self.current_screen = "welcome"
        if target == "audioPluginMixer":
            self.audio_running = False
            self.local_audio_test_running = False
        return self._ui_snapshot()

    def _log_entry(self, params: dict[str, Any]) -> dict[str, Any]:
        return {
            "timestamp": "2026-01-01 00:00:00.000",
            "category": str(params.get("category", "General")),
            "level": str(params.get("level", "info")),
            "levelRaw": 2,
            "symbol": "INFO",
            "message": str(params.get("message", "websocket-marker")),
            "file": "FakeWebSocket",
            "function": "log.marker",
            "line": 0,
        }

    def _connection_log_entry(self, level: str, message: str) -> dict[str, Any]:
        return {
            "timestamp": "2026-01-01 00:00:00.050",
            "category": "Connection",
            "level": level,
            "levelRaw": 1,
            "symbol": "DEBUG",
            "message": message,
            "file": "FakeWebSocket",
            "function": "connection.connect",
            "line": 0,
        }

    def _ui_snapshot(self) -> dict[str, Any]:
        return {"currentScreen": self.current_screen, "presentedSheet": self.presented_sheet}


def run_self_test() -> int:
    output = Path("Tests") / "Artifacts" / "self-test.jsonl"
    evidence = EvidenceWriter(output)
    failures: list[str] = []
    for scenario in SCENARIOS:
        run_id = f"selftest-{scenario}"
        runner = ProbeRunner(ws=FakeWebSocket(), evidence=evidence, run_id=run_id, timeout=1)  # type: ignore[arg-type]
        args = argparse.Namespace(
            scenario=scenario,
            timeout=1,
            wait_timeout=0.1,
            settle_seconds=0,
        )
        evidence.write("run.start", run_id=run_id, scenario=scenario, url="self-test", provenance=provenance(args))
        run_scenario(args, runner, run_id)
        evidence.write("run.end", status="passed" if not runner.failures else "failed", failures=runner.failures)
        failures.extend(f"{scenario}: {failure}" for failure in runner.failures)
    evidence.close()
    suite_args = argparse.Namespace(
        url="self-test",
        scenario="all",
        output=str(Path("Tests") / "Artifacts" / "self-test-suite"),
        timeout=1,
        wait_timeout=0.1,
        settle_seconds=0,
        run_id="selftest-suite",
        repeat=2,
        self_test=True,
    )
    suite_status = run_suite(suite_args, websocket_factory=FakeWebSocket)
    if suite_status != 0:
        failures.append(f"suite self-test exited {suite_status}")
    diagnostic_output = Path("Tests") / "Artifacts" / "self-test-diagnostic.jsonl"
    diagnostic_args = argparse.Namespace(
        url="self-test",
        scenario="idle-welcome",
        output=str(diagnostic_output),
        timeout=1,
        wait_timeout=0.1,
        settle_seconds=0,
        run_id="selftest-diagnostic",
        self_test=True,
        suppress_failure_output=True,
    )
    diagnostic_status = run_probe(diagnostic_args, websocket_factory=lambda: FakeWebSocket(fail_audio_status=True))
    if diagnostic_status == 0:
        failures.append("diagnostic self-test unexpectedly passed")
    diagnostic_text = diagnostic_output.read_text(encoding="utf-8")
    if '"type": "diagnostic.snapshot"' not in diagnostic_text:
        failures.append("diagnostic self-test did not write diagnostic.snapshot")
    if '"network.status"' not in diagnostic_text or '"log.recent"' not in diagnostic_text:
        failures.append("diagnostic self-test did not include network/log diagnostics")
    if failures:
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)
        return 1
    print(f"passed: self-test evidence={output}")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run MUTestServer WebSocket smoke probes.")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"WebSocket URL, default: {DEFAULT_URL}")
    parser.add_argument("--scenario", choices=[*SCENARIOS, "all"], default="baseline")
    parser.add_argument(
        "--output",
        help="JSONL evidence path for one scenario, or suite output directory when --scenario all is used.",
    )
    parser.add_argument("--timeout", type=float, default=8.0, help="Per-command timeout in seconds")
    parser.add_argument("--wait-timeout", type=float, default=8.0, help="Timeout for scenario UI/audio waits in seconds")
    parser.add_argument("--settle-seconds", type=float, default=1.0, help="Extra event collection window after commands")
    parser.add_argument("--run-id", help="Stable run id to include in log markers")
    parser.add_argument("--repeat", type=int, default=1, help="Repeat the full scenario suite this many times when --scenario all is used")
    parser.add_argument("--self-test", action="store_true", help="Validate local assertion/evidence logic without connecting")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return run_self_test()
    if args.scenario == "all":
        return run_suite(args)
    return run_probe(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
