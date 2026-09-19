#!/usr/bin/env python3
"""Check Favourite Servers ping lifetime against a real, already running DEBUG app.

Uses only the existing WebSocket API and one ephemeral 127.0.0.1 UDP endpoint.
It never starts the app, connects to a Mumble server, or changes existing
favourites/settings. Start on the idle welcome/favouriteList screen without
editors or alerts. Only this run's uniquely named favourite is removed on exit,
and the original screen is restored, including when a check fails.

Each of three visits observes six seconds of normal ping traffic. After every
exit, the fixture observes six seconds of silence, exceeding even the old timer's
one-second interval plus three-second leeway. It also replies with genuine
24-byte server discovery responses (7/32 users) to exercise the UI update path.
The UI API does not expose row labels, so this is not a visual assertion.

Packet counts detect traffic multiplication, not duplicate subscribers sharing
the native controller's single per-address timer. Native registration tests must
cover that additional invariant.
"""
from __future__ import annotations

import argparse
import ipaddress
import math
import socket
import struct
import sys
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
from mumble_agent_probe import EvidenceWriter, ProbeError, ProbeRunner, StdlibWebSocket


class LocalPingFixture:
    def __init__(self) -> None:
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("127.0.0.1", 0))
        self.socket.settimeout(0.2)
        self.port = self.socket.getsockname()[1]
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.packets: list[dict] = []
        self.errors: list[str] = []
        self.thread = threading.Thread(target=self._serve, name="favourite-ping-fixture", daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        while not self.stop.is_set():
            try:
                data, peer = self.socket.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError as exc:
                if not self.stop.is_set():
                    with self.lock:
                        self.errors.append(str(exc))
                return
            record = {
                "monotonic": time.monotonic(),
                "peer": list(peer),
                "bytes": len(data),
                "valid": peer[0] == "127.0.0.1" and len(data) == 12 and data[:4] == b"\0" * 4,
                "replied": False,
            }
            if record["valid"]:
                # Echo the nonce verbatim; its encoding is opaque to the server.
                response = struct.pack("!I", 0x010500) + data[4:12] + struct.pack("!III", 7, 32, 72000)
                try:
                    record["replied"] = self.socket.sendto(response, peer) == 24
                except OSError as exc:
                    with self.lock:
                        self.errors.append(str(exc))
            with self.lock:
                self.packets.append(record)

    def between(self, start: float, end: float) -> list[dict]:
        with self.lock:
            if self.errors:
                raise ProbeError(f"Local UDP fixture failed: {self.errors}")
            return [dict(packet) for packet in self.packets if start <= packet["monotonic"] < end]

    def close(self) -> None:
        self.stop.set()
        self.socket.close()
        self.thread.join(timeout=2)


def is_favourite_screen(snapshot: dict) -> bool:
    return snapshot.get("currentScreen") == "favouriteList" or snapshot.get("presentedSheet") == "favouriteList"


def is_welcome_screen(snapshot: dict) -> bool:
    return snapshot.get("currentScreen") == "welcome" and not snapshot.get("presentedSheet")


def require_local_api(url: str) -> None:
    host = urlparse(url).hostname
    if host == "localhost":
        return
    try:
        if host and ipaddress.ip_address(host).is_loopback:
            return
    except ValueError:
        pass
    raise ProbeError("Use a local WebSocket URL (localhost, 127.0.0.1 or ::1).")


def run(args: argparse.Namespace) -> None:
    require_local_api(args.url)
    if args.active_seconds < 6 or args.quiet_seconds < 6 or args.cycles < 3:
        raise ProbeError("Use at least three visits and six-second active/quiet windows.")
    evidence = EvidenceWriter(Path(args.output))
    ws = StdlibWebSocket(args.url, 8)
    fixture = None
    initial_ui = None
    baseline_favourites = None
    test_identity = None
    navigation_changed = False
    add_attempted = False
    failure: BaseException | None = None
    cleanup_errors: list[str] = []
    visits: list[dict] = []

    try:
        ws.connect()
        run_id = f"favourite-ping-{uuid.uuid4().hex}"
        runner = ProbeRunner(ws, evidence, run_id, 8)

        def command(action: str, params: dict | None = None):
            response = runner.command(action, params)
            if not response.get("success"):
                raise ProbeError(f"{action} failed: {response.get('error', response)}")
            return response.get("data")

        def assert_idle() -> None:
            status = command("connection.status")
            if not isinstance(status, dict) or any(status.get(key) for key in (
                "connected", "isConnecting", "isReconnecting", "hasPendingCertTrust"
            )):
                raise ProbeError(f"An idle app with no pending reconnect/certificate decision is required: {status}")

        def wait_screen(description, predicate):
            snapshot = runner.wait_for_data(description, "ui.get", None, predicate, timeout=8)
            if not predicate(snapshot):
                raise ProbeError(f"{description}: {snapshot}")
            return snapshot

        def leave_favourites() -> None:
            assert_idle()
            command("ui.dismiss", {"target": "favouriteList"})
            command("ui.root")
            # Covers both sidebar navigation and modal presentations.
            command("ui.open", {"target": "welcome"})
            wait_screen("returned to welcome", is_welcome_screen)

        def enter_favourites() -> None:
            assert_idle()
            command("ui.open", {"target": "favouriteList"})
            wait_screen("favourite list is visible", is_favourite_screen)

        def matches_owned(favourite: dict) -> bool:
            return bool(test_identity) and all(favourite.get(key) == value for key, value in test_identity.items())

        def observe(seconds: float, expected_screen) -> tuple[float, float, list[dict]]:
            start = time.monotonic()
            deadline = start + seconds
            while time.monotonic() < deadline:
                runner.collect_events(min(0.25, deadline - time.monotonic()))
                snapshot = command("ui.get")
                if not expected_screen(snapshot):
                    raise ProbeError(f"UI changed during the observation window; retry without navigating: {snapshot}")
            end = time.monotonic()
            return start, end, fixture.between(start, end)

        def record_window(kind: str, cycle: int, start: float, end: float, packets: list[dict]) -> dict:
            result = {
                "kind": kind,
                "cycle": cycle,
                "durationSeconds": round(end - start, 3),
                "packetCount": len(packets),
                "packetOffsetsSeconds": [round(packet["monotonic"] - start, 4) for packet in packets],
                "peerPorts": sorted({packet["peer"][1] for packet in packets}),
                "validReplies": sum(packet["replied"] for packet in packets),
            }
            evidence.write("udp.window", **result)
            return result

        assert_idle()
        initial_ui = command("ui.get")
        if (not isinstance(initial_ui, dict)
                or initial_ui.get("currentScreen") not in ("welcome", "favouriteList")
                or initial_ui.get("presentedSheet") not in (None, "favouriteList")
                or initial_ui.get("presentedAlert")
                or initial_ui.get("visibleOverlays")):
            raise ProbeError(f"Start on welcome or favouriteList without editors, alerts or overlays: {initial_ui}")
        baseline_favourites = command("favourite.list")
        if not isinstance(baseline_favourites, list):
            raise ProbeError("favourite.list did not return an array.")
        fixture = LocalPingFixture()
        marker = uuid.uuid4().hex
        test_identity = {
            "displayName": f"Ping lifecycle probe {marker}",
            "hostName": "127.0.0.1",
            "port": fixture.port,
            "userName": f"PingProbe_{marker}",
        }
        if any(fav.get("hostName") == "127.0.0.1" and fav.get("port") == fixture.port for fav in baseline_favourites):
            raise ProbeError("Allocated loopback port matches an existing favourite; retry with a fresh port.")
        evidence.write("probe.start", fixtureHost="127.0.0.1", fixturePort=fixture.port,
                       initialUI=initial_ui, cycles=args.cycles,
                       subscriberMultiplicity="Not observable from a shared per-address UDP timer")
        navigation_changed = True
        leave_favourites()
        # Record ownership before the request: a response timeout may follow a successful insert.
        add_attempted = True
        command("favourite.add", {
            "hostname": test_identity["hostName"], "port": fixture.port,
            "username": test_identity["userName"], "displayName": test_identity["displayName"],
            "clearCertificate": True,
        })
        created = [fav for fav in command("favourite.list") if matches_owned(fav)]
        if len(created) != 1:
            raise ProbeError(f"Expected exactly one owned test favourite, got {len(created)}.")
        evidence.write("fixture.favourite", primaryKey=created[0]["primaryKey"], **test_identity)

        for cycle in range(1, args.cycles + 1):
            enter_favourites()
            start, end, packets = observe(args.active_seconds, is_favourite_screen)
            visit = record_window("active", cycle, start, end, packets)
            visits.append(visit)
            if not packets:
                raise ProbeError(f"Visit {cycle}: no UDP ping arrived while favouriteList was visible.")
            if not all(packet["valid"] and packet["replied"] for packet in packets):
                raise ProbeError(f"Visit {cycle}: invalid discovery packet or failed local response.")
            # One dispatch timer at 1 Hz; tolerate start/end scheduling boundaries.
            maximum_packets = math.ceil(end - start) + 2
            if len(packets) > maximum_packets:
                raise ProbeError(f"Visit {cycle}: {len(packets)} pings exceed one timer's budget of {maximum_packets}.")
            evidence.write("assertion", passed=True, description="Visible list receives discovery responses without traffic multiplication",
                           maximumPackets=maximum_packets, **visit)
            leave_favourites()
            # Exclude only datagrams already in flight during the navigation animation.
            runner.collect_events(0.75)
            start, end, packets = observe(args.quiet_seconds, is_welcome_screen)
            record_window("inactive", cycle, start, end, packets)
            if packets:
                raise ProbeError(f"Visit {cycle}: {len(packets)} ping(s) continued after returning to welcome.")
            evidence.write("assertion", passed=True, description="Hidden list stays silent beyond timer interval plus leeway",
                           cycle=cycle, durationSeconds=end - start)
            assert_idle()
        if runner.failures:
            raise ProbeError(f"Automation failures: {runner.failures}")
        evidence.write("probe.checksPassed", visits=visits)
    except BaseException as exc:
        failure = exc
        evidence.write("probe.failure", error=f"{type(exc).__name__}: {exc}")
    finally:
        # Cleanup never deletes by hostname alone and never disconnects another session.
        if ws.sock is not None:
            if navigation_changed:
                try:
                    leave_favourites()
                except Exception as exc:
                    cleanup_errors.append(f"return to welcome: {exc}")
            if add_attempted:
                try:
                    favourites = command("favourite.list")
                    owned = [fav for fav in favourites if matches_owned(fav)]
                    for favourite in owned:
                        # Recheck identity immediately before mutating by primary key.
                        current = command("favourite.info", {"primaryKey": favourite["primaryKey"]})
                        if not matches_owned(current):
                            raise ProbeError("The test favourite identity changed; refusing to remove it.")
                        command("favourite.remove", {"primaryKey": favourite["primaryKey"]})
                    evidence.write("cleanup.favourite", removedPrimaryKeys=[fav["primaryKey"] for fav in owned])
                    after = command("favourite.list")
                    sort_key = lambda fav: fav["primaryKey"]
                    if sorted(after, key=sort_key) != sorted(baseline_favourites, key=sort_key):
                        raise ProbeError("Existing favourites changed during the test; they were not overwritten or restored.")
                    evidence.write("assertion", passed=True, description="Only this run's favourite was removed; existing favourites match the original snapshot")
                except Exception as exc:
                    cleanup_errors.append(f"remove owned favourite/check original favourites: {exc}")
            if navigation_changed and initial_ui:
                try:
                    if is_favourite_screen(initial_ui):
                        enter_favourites()
                    else:
                        leave_favourites()
                    restored = command("ui.get")
                    if any(restored.get(key) != initial_ui.get(key) for key in ("currentScreen", "presentedSheet")):
                        raise ProbeError(f"Original screen was not restored: {restored}")
                    evidence.write("cleanup.screen", restored=True, snapshot=restored)
                except Exception as exc:
                    cleanup_errors.append(f"restore original screen: {exc}")
        if fixture:
            fixture.close()
        ws.close()
        evidence.write("probe.complete", passed=failure is None and not cleanup_errors, cleanupErrors=cleanup_errors)
        evidence.close()
    if cleanup_errors:
        raise ProbeError(f"{failure or 'Probe checks completed'}; cleanup errors: {cleanup_errors}") from failure
    if failure:
        raise failure
    print(f"passed: Favourite Servers ping lifecycle ({args.cycles} visits), evidence: {args.output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="ws://localhost:54296")
    parser.add_argument("--output", default="Tests/Artifacts/recovery-macos/favourite-ping-lifecycle.jsonl")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--active-seconds", type=float, default=6.0)
    parser.add_argument("--quiet-seconds", type=float, default=6.0)
    run(parser.parse_args())
