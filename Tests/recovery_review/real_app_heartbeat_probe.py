#!/usr/bin/env python3
"""Loopback-only TLS fixture: live downlink must not hide missing ping replies.

Requires an idle DEBUG app and permission for local microphone use. No audio is
recorded: inbound voice frames are discarded. A temporary self-signed certificate
is accepted only for this fixture's loopback port (the app remembers its digest).
"""
from pathlib import Path
import argparse
import select
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Scripts'))
from mumble_agent_probe import StdlibWebSocket, EvidenceWriter, ProbeRunner


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))


def number(field, value):
    return varint(field << 3) + varint(value)


def string(field, value):
    data = value.encode()
    return varint((field << 3) | 2) + varint(len(data)) + data


def frame(kind, payload):
    return struct.pack('!HI', kind, len(payload)) + payload


class Fixture:
    def __init__(self, directory):
        cert, key = Path(directory) / 'cert.pem', Path(directory) / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(cert), '-days', '1',
                        '-subj', '/CN=Mumble Loopback Recovery Test'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(cert, key)
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen()
        self.listener.settimeout(.2)
        self.stop = threading.Event()
        self.drop_replies = threading.Event()
        self.disconnect_current = threading.Event()
        self.authenticated = 0
        self.echoes = 0
        self.downlink_during_failure = 0
        self.failure_started = None
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try:
                raw, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                raw.settimeout(3)
                with self.context.wrap_socket(raw, server_side=True) as peer:
                    self.session(peer)
            except (OSError, ssl.SSLError):
                raw.close()

    def session(self, peer):
        data = bytearray()
        joined = False
        broken_session = False
        next_update = time.monotonic()
        while not self.stop.is_set():
            if self.disconnect_current.is_set():
                self.disconnect_current.clear()
                return
            if peer.pending() or select.select([peer], [], [], .1)[0]:
                chunk = peer.recv(65536)
                if not chunk:
                    return
                data.extend(chunk)
            while len(data) >= 6:
                kind, size = struct.unpack('!HI', data[:6])
                if size > 8 * 1024 * 1024:
                    raise OSError('oversized fixture input')
                if len(data) < size + 6:
                    break
                payload = bytes(data[6:6 + size])
                del data[:6 + size]
                if kind == 2 and not joined:  # Authenticate
                    self.authenticated += 1
                    broken_session = self.authenticated == 1
                    joined = True
                    peer.sendall(frame(0, number(1, 0x010500) + string(2, 'Loopback recovery fixture'))
                                 + frame(7, number(1, 0) + string(3, 'Local recovery test'))
                                 + frame(9, number(1, 1) + string(3, 'RecoveryProbe')
                                         + number(5, 0) + number(9, 1))
                                 + frame(5, number(1, 1) + number(2, 72000)))
                elif kind == 3:  # Ping: echo only while the round trip is healthy.
                    if broken_session and self.drop_replies.is_set():
                        continue
                    peer.sendall(frame(3, payload))
                    self.echoes += 1
                # Voice/control frames are consumed without saving their contents.
            if joined and time.monotonic() >= next_update:
                peer.sendall(frame(9, number(1, 1) + number(9, 1)))
                next_update = time.monotonic() + 1
                if broken_session and self.drop_replies.is_set():
                    self.downlink_during_failure += 1

    def close(self):
        self.stop.set()
        self.listener.close()
        self.thread.join(4)


def run(args):
    evidence = EvidenceWriter(Path(args.output))
    ws = StdlibWebSocket(args.url, 8)
    ws.connect()
    runner = ProbeRunner(ws, evidence, 'bidirectional-heartbeat', 8)

    def command(action, params=None):
        result = runner.command(action, params)
        assert result.get('success'), result
        return result.get('data') or {}

    initial = command('connection.status')
    assert not initial.get('connected') and not initial.get('isConnecting'), 'Use an idle test app.'
    saved = command('settings.get', {'key': 'NetworkAutoReconnect'})
    with tempfile.TemporaryDirectory(prefix='mumble-loopback-tls-') as directory:
        fixture = Fixture(directory)
        try:
            command('settings.set', {'key': 'NetworkAutoReconnect', 'value': True})
            command('connection.connect', {'hostname': '127.0.0.1', 'port': fixture.port, 'username': 'RecoveryProbe'})
            status = runner.wait_for_data('loopback certificate prompt', 'connection.status', None,
                lambda x: x.get('hasPendingCertTrust') or x.get('connected'), timeout=12)
            if status.get('hasPendingCertTrust'):
                command('connection.acceptCert')
            status = runner.wait_for_data('loopback joined', 'connection.status', None,
                lambda x: x.get('connected'), timeout=15)
            assert status.get('connected'), status
            if args.path_updates:
                joined_count = fixture.authenticated
                for satisfied, interfaces in [(True, 1), (True, 3), (True, 2), (False, 0), (True, 1)] * 3:
                    command('network.injectPathUpdate', {'satisfied': satisfied, 'interfaces': interfaces})
                    status = command('connection.status')
                    assert status.get('connected') and not status.get('isReconnecting'), status
                runner.collect_events(7)
                assert fixture.authenticated == joined_count, 'Path hints caused another server login.'
                assert command('connection.status').get('connected')
                evidence.write('assertion', passed=True,
                    description='15 interface/reachability updates retain healthy connection without another login')
            if args.audio:
                status = runner.wait_for_data('connected audio healthy', 'audio.status', None,
                    lambda x: (x.get('health') or {}).get('state') == 'healthy', timeout=12)
                assert (status.get('health') or {}).get('state') == 'healthy', status
                command('audio.simulateCallbackStall')
                state = runner.wait_for_data('voice failure is exposed to channel UI', 'state.get', None,
                    lambda x: bool(x.get('voiceHealthMessage')), timeout=10, interval=.1)
                assert state.get('isConnected') and state.get('voiceHealthMessage'), state
                state = runner.wait_for_data('voice recovery clears channel warning', 'state.get', None,
                    lambda x: x.get('voiceHealthMessage') is None, timeout=20, interval=.2)
                assert state.get('isConnected') and state.get('voiceHealthMessage') is None, state
                assert (command('audio.status').get('health') or {}).get('state') == 'healthy'
                command('audio.startTest')
                command('audio.stopTest')
                runner.collect_events(2)
                assert (command('audio.status').get('health') or {}).get('state') == 'healthy'
                evidence.write('assertion', passed=True,
                    description='Joined audio stall shows UI warning and recovers; leaving settings preserves call audio')
            deadline = time.monotonic() + 10
            while fixture.echoes == 0 and time.monotonic() < deadline:
                runner.collect_events(.2)
            assert fixture.echoes > 0, 'No healthy round trip established.'
            fixture.failure_started = time.monotonic()
            fixture.drop_replies.set()
            status = runner.wait_for_data('missing replies invalidates live downlink', 'connection.status', None,
                lambda x: not x.get('connected'), timeout=35, interval=.2)
            elapsed = time.monotonic() - fixture.failure_started
            assert not status.get('connected'), status
            assert 24 <= elapsed <= 35, elapsed
            assert fixture.downlink_during_failure >= 20, fixture.downlink_during_failure
            evidence.write('assertion', passed=True,
                description='Live TLS downlink cannot mask failed heartbeat round trip',
                elapsedSeconds=elapsed, downlinkFrames=fixture.downlink_during_failure)
            status = runner.wait_for_data('automatic reconnect restores joined session', 'connection.status', None,
                lambda x: x.get('connected') and fixture.authenticated >= 2, timeout=20)
            assert status.get('connected') and fixture.authenticated >= 2, status
            if args.retry_cooldown:
                count = fixture.authenticated
                close_at = time.monotonic()
                fixture.disconnect_current.set()
                runner.collect_events(10)
                assert fixture.authenticated == count, 'A brief rejoin reset the login cooldown.'
                status = runner.wait_for_data('second failure observes escalating cooldown', 'connection.status', None,
                    lambda x: x.get('connected') and fixture.authenticated == count + 1, timeout=20)
                elapsed = time.monotonic() - close_at
                assert status.get('connected') and elapsed >= 14.5, (status, elapsed)
                evidence.write('assertion', passed=True, elapsedSeconds=elapsed,
                    description='Brief successful rejoin does not reset cooldown; second retry waits at least 15 seconds')
            command('connection.disconnect')
            runner.collect_events(2)
            status = command('connection.status')
            assert not status.get('connected') and not status.get('isConnecting'), status
            assert not command('audio.status').get('running')
            evidence.write('assertion', passed=True,
                description='Automatic reconnect rejoins; explicit disconnect stops connection and audio')
            assert not runner.failures, runner.failures
            print('passed: real app bidirectional heartbeat recovery', args.output)
        finally:
            command('connection.disconnect')
            if saved.get('value') is None:
                command('settings.remove', {'key': 'NetworkAutoReconnect'})
            else:
                command('settings.set', {'key': 'NetworkAutoReconnect', 'value': saved['value']})
            fixture.close()
            ws.close()
            evidence.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default='ws://localhost:54296')
    parser.add_argument('--output', default='Tests/Artifacts/recovery-macos/bidirectional-heartbeat.jsonl')
    parser.add_argument('--audio', action='store_true', help='Also inject a device stall during the local call')
    parser.add_argument('--path-updates', action='store_true', help='Verify advisory path changes never tear down a healthy call')
    parser.add_argument('--retry-cooldown', action='store_true', help='Verify repeated brief joins retain retry backoff')
    run(parser.parse_args())
