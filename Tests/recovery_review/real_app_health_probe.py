#!/usr/bin/env python3
"""Exercise a DEBUG app using only loopback endpoints and local audio.

The socket fixture deliberately accepts TCP without answering TLS. No external
Mumble server or other user is contacted. Existing reconnect preferences are
restored even when an assertion fails. Run against an idle test app.
"""
from pathlib import Path
import argparse
import socket
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Scripts'))
from mumble_agent_probe import StdlibWebSocket, EvidenceWriter, ProbeRunner


def run(args):
    evidence = EvidenceWriter(Path(args.output))
    ws = StdlibWebSocket(args.url, 8)
    ws.connect()
    runner = ProbeRunner(ws, evidence, 'voice-health', 8)
    def command(action, params=None):
        response = runner.command(action, params)
        assert response.get('success'), response
        return response.get('data') or {}
    initial = command('connection.status')
    assert not initial.get('connected') and not initial.get('isConnecting'), 'Use an idle test app.'
    saved = command('settings.get', {'key': 'NetworkAutoReconnect'})
    sockets = []
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(.2)
    stopped = threading.Event()
    def accept():
        while not stopped.is_set():
            try:
                connection, _ = listener.accept()
                sockets.append(connection)
            except socket.timeout:
                pass
            except OSError:
                break
    thread = threading.Thread(target=accept, daemon=True)
    thread.start()
    try:
        command('settings.set', {'key': 'NetworkAutoReconnect', 'value': False})
        start = time.monotonic()
        command('connection.connect', {'hostname': '127.0.0.1', 'port': listener.getsockname()[1], 'username': 'RecoveryProbe'})
        runner.collect_events(1)
        assert sockets, 'TCP fixture never accepted a connection.'
        state = command('state.get')
        assert not state.get('isConnected'), 'An unfinished TLS handshake must not appear connected.'
        status = runner.wait_for_data('unanswered TLS is closed', 'connection.status', None,
            lambda x: not x.get('connected') and not x.get('isConnecting'), timeout=26)
        assert not status.get('connected') and not status.get('isConnecting'), status
        elapsed = time.monotonic() - start
        assert 18 <= elapsed <= 27, elapsed
        evidence.write('assertion', passed=True, description='Real unanswered TCP/TLS connection times out', elapsedSeconds=elapsed)
        # Cancel several generations while connection setup and audio startup are pending.
        for _ in range(6):
            command('connection.connect', {'hostname': '127.0.0.1', 'port': listener.getsockname()[1], 'username': 'RecoveryProbe'})
            command('connection.disconnect')
        runner.collect_events(1)
        status = command('connection.status')
        audio = command('audio.status')
        assert not status.get('connected') and not status.get('isConnecting'), status
        assert not audio.get('running'), audio
        evidence.write('assertion', passed=True, description='Repeated setup cancellation leaves connection and audio stopped')
        if args.audio:
            permission = command('audio.permission')
            assert permission.get('microphone') == 'authorized', permission
            command('audio.startTest')
            status = runner.wait_for_data('real audio callbacks healthy', 'audio.status', None,
                lambda x: (x.get('health') or {}).get('state') == 'healthy', timeout=12)
            assert (status.get('health') or {}).get('state') == 'healthy', status
            command('audio.simulateCallbackStall')
            status = runner.wait_for_data('stopped callbacks detected', 'audio.status', None,
                lambda x: (x.get('health') or {}).get('state') == 'recovering', timeout=10, interval=.1)
            assert (status.get('health') or {}).get('state') == 'recovering', status
            status = runner.wait_for_data('audio callbacks recovered', 'audio.status', None,
                lambda x: (x.get('health') or {}).get('state') == 'healthy', timeout=20)
            assert (status.get('health') or {}).get('state') == 'healthy', status
            command('audio.simulateCallbackStall')
            command('audio.stopTest')
            runner.collect_events(7)
            status = command('audio.status')
            assert not status.get('running'), status
            evidence.write('assertion', passed=True, description='Real device callback stall recovers; explicit stop cancels recovery')
            for _ in range(12):
                command('audio.startTest')
                command('audio.stopTest')
            runner.collect_events(2)
            status = command('audio.status')
            assert not status.get('running') and not (status.get('health') or {}).get('requested'), status
            evidence.write('assertion', passed=True, description='Rapid local test start/stop leaves no queued microphone restart')
        assert not runner.failures, runner.failures
        print('passed: real app voice health probe', args.output)
    finally:
        command('connection.disconnect')
        if args.audio:
            command('audio.stopTest')
        value = saved.get('value')
        if value is None:
            command('settings.remove', {'key': 'NetworkAutoReconnect'})
        else:
            command('settings.set', {'key': 'NetworkAutoReconnect', 'value': value})
        stopped.set()
        listener.close()
        thread.join(timeout=1)
        for connection in sockets:
            connection.close()
        ws.close()
        evidence.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default='ws://localhost:54296')
    parser.add_argument('--output', default='Tests/Artifacts/recovery-macos/voice-health.jsonl')
    parser.add_argument('--audio', action='store_true')
    run(parser.parse_args())
