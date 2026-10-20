#!/usr/bin/env python3
"""Verify a real iOS Simulator call keeps client identity and audio on reconnect.

Use an idle test installation. The only server is a
loopback TLS fixture, which requires a temporary client certificate. Optional
interactive checkpoints allow another playback app to foreground/background
Mumble during an actual outage. No microphone samples are saved.
"""
import argparse
import hashlib
import json
from pathlib import Path
import select
import struct
import subprocess
import tempfile
import threading
import time
import uuid

from real_app_heartbeat_probe import Fixture, frame, number, string
from mumble_agent_probe import EvidenceWriter, ProbeRunner, StdlibWebSocket


class IdentityFixture(Fixture):
    def __init__(self, directory):
        directory = Path(directory)
        self.client_cert = directory / 'client.pem'
        self.client_key = directory / 'client-key.pem'
        self.client_p12 = directory / 'client.p12'
        self.client_name = f'ReconnectProbe-{uuid.uuid4().hex}'
        for command in [
            ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
             '-keyout', str(self.client_key), '-out', str(self.client_cert),
             '-subj', f'/CN={self.client_name}', '-addext', 'extendedKeyUsage=clientAuth'],
            ['openssl', 'pkcs12', '-export', '-legacy', '-inkey', str(self.client_key),
             '-in', str(self.client_cert), '-out', str(self.client_p12), '-passout', 'pass:probe-password'],
        ]:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.fingerprints = []
        self.offline = threading.Event()
        super().__init__(directory)
        self.context.load_verify_locations(str(self.client_cert))
        # CERT_OPTIONAL lets the fixture report the same Mumble rejection as a real
        # registered account when an anonymous replacement socket is attempted.
        import ssl
        self.context.verify_mode = ssl.CERT_OPTIONAL

    def session(self, peer):
        certificate = peer.getpeercert(binary_form=True)
        self.fingerprints.append(hashlib.sha256(certificate).hexdigest() if certificate else None)
        if self.offline.is_set():
            return
        data = bytearray()
        joined = False
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
                del data[:size + 6]
                if kind == 2 and not joined:
                    if not certificate:
                        peer.sendall(frame(4, number(1, 3) + string(2, 'Wrong certificate or password for existing user')))
                        return
                    self.authenticated += 1
                    joined = True
                    peer.sendall(frame(0, number(1, 0x010500) + string(2, 'Identity reconnect fixture'))
                                 + frame(7, number(1, 0) + string(3, 'Loopback'))
                                 + frame(9, number(1, 1) + string(3, 'BackgroundProbe') + number(5, 0) + number(4, 1))
                                 + frame(5, number(1, 1) + number(2, 72000)))
                elif kind == 3:
                    peer.sendall(frame(3, payload))


def run(args):
    evidence = EvidenceWriter(Path(args.output))
    ws = StdlibWebSocket('ws://localhost:54296', 8)
    ws.connect()
    runner = ProbeRunner(ws, evidence, 'background-identity-reconnect', 8)
    evidence.write('environment', simulator=args.simulator)
    playback_positions = set()

    def command(action, params=None):
        result = runner.command(action, params)
        assert result.get('success'), result
        return result.get('data') or {}

    def check_audio(expected_starts=None):
        state = command('audio.status')
        session = state.get('audioSession') or {}
        assert state.get('running'), state
        assert session.get('category') == 'AVAudioSessionCategoryPlayAndRecord', state
        assert session.get('mode') == 'AVAudioSessionModeVoiceChat', state
        assert session.get('mixesWithOthers') and not session.get('ducksOthers'), state
        if expected_starts is not None:
            assert state['health']['graphStartCount'] == expected_starts, state
        if args.playback_heartbeat:
            playback = json.loads(Path(args.playback_heartbeat).read_text())
            assert time.time() - playback['timestamp'] < 4 and playback['playing'], playback
            assert playback['interruptions'] == 0 and playback['sampleTime'] > 0, playback
            playback_positions.add(playback['sampleTime'])
            evidence.write('playback', **playback)
        return state

    initial = command('state.get')
    assert not initial.get('isConnected') and not initial.get('isConnecting'), 'Use an idle test app.'
    saved_reconnect = command('settings.get', {'key': 'NetworkAutoReconnect'}).get('value')
    certificate_id = None
    profile = None
    fixture = None
    try:
        command('settings.set', {'key': 'NetworkAutoReconnect', 'value': True})
        with tempfile.TemporaryDirectory(prefix='reconnect-probe-', dir=args.import_dir) as directory:
            fixture = IdentityFixture(directory)
            command('certificate.import', {'path': str(fixture.client_p12), 'password': 'probe-password'})
            certificates = command('certificate.list')['certificates']
            certificate = next(c for c in certificates if c['name'] == fixture.client_name)
            certificate_id = certificate['id']
            profile = command('favourite.add', {'hostname': '127.0.0.1', 'port': fixture.port,
                'username': 'BackgroundProbe', 'displayName': fixture.client_name,
                'certificateRefBase64': certificate_id})
            command('favourite.connect', {'primaryKey': profile['primaryKey']})
            runner.wait_for_data('loopback trust prompt', 'connection.status', None,
                lambda x: x.get('hasPendingCertTrust'), timeout=12)
            command('connection.acceptCert')
            state = runner.wait_for_data('certificate-authenticated join', 'connection.status', None,
                lambda x: x.get('connected'), timeout=15)
            assert state.get('connected') and fixture.authenticated == 1, state
            runner.wait_for_data('audio callbacks healthy', 'audio.status', None,
                lambda x: (x.get('health') or {}).get('state') == 'healthy', timeout=15)
            baseline = check_audio()['health']['graphStartCount']
            for satisfied, interfaces in [(True, 2), (True, 1), (False, 0), (True, 3), (True, 1)] * 3:
                command('network.injectPathUpdate', {'satisfied': satisfied, 'interfaces': interfaces})
                assert command('connection.status').get('connected')
            assert fixture.authenticated == 1, 'Route hints replaced a healthy socket.'
            # The original implementation reread this on every reconnect and then
            # silently authenticated without a certificate when it became unavailable.
            command('network.injectClientIdentityUnavailable', {'unavailable': True})
            if args.interactive:
                input('READY: foreground the playback fixture to background Mumble, then press Enter.\n')
            fixture.offline.set()
            fixture.disconnect_current.set()
            runner.wait_for_data('real socket failure enters recovery', 'connection.status', None,
                lambda x: x.get('isReconnecting') and not x.get('connected'), timeout=10)
            # Cover the actual delegate methods even when a headless Simulator
            # cannot deliver every scene/application lifecycle callback.
            for phase in ['didBecomeActive', 'willResignActive']:
                command('app.simulateLifecycle', {'phase': phase})
                check_audio(baseline)
            if args.interactive:
                input('RECOVERING: foreground Mumble, then return to playback and press Enter.\n')
            for _ in range(30):
                check_audio(baseline)
                assert not command('state.get').get('activeError')
                runner.collect_events(.25)
            fixture.offline.clear()
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                check_audio(baseline)
                if command('connection.status').get('connected'):
                    break
                runner.collect_events(.25)
            assert command('connection.status').get('connected'), 'Recovery did not rejoin.'
            assert fixture.authenticated == 2, fixture.authenticated
            assert fixture.fingerprints and None not in fixture.fingerprints
            assert len(set(fixture.fingerprints)) == 1, fixture.fingerprints
            check_audio(baseline)
            if args.playback_heartbeat:
                assert len(playback_positions) > 3, 'Playback position did not advance.'
            evidence.write('assertion', passed=True, graphStartCount=baseline,
                tlsAttempts=len(fixture.fingerprints), certificateSHA256=fixture.fingerprints[0],
                description='Background outage preserves client identity, voice mode, mixer options and audio graph')
            command('connection.disconnect')
            command('app.clearError')
            # A fresh request cannot reuse the previous session's cached identity,
            # and must fail locally instead of sending anonymous authentication.
            previous_attempts = len(fixture.fingerprints)
            command('favourite.connect', {'primaryKey': profile['primaryKey']})
            runner.wait_for_data('unavailable fresh identity fails locally', 'state.get', None,
                lambda x: bool(x.get('activeError')), timeout=10)
            assert len(fixture.fingerprints) == previous_attempts
            command('app.clearError')
            command('network.injectClientIdentityUnavailable', {'unavailable': False})
            command('favourite.connect', {'primaryKey': profile['primaryKey']})
            runner.wait_for_data('explicit profile join', 'connection.status', None,
                lambda x: x.get('connected'), timeout=15)
            assert fixture.authenticated == 3 and len(set(fixture.fingerprints)) == 1
            evidence.write('assertion', passed=True, description='Manual profile connection resolves its selected identity after clearing the session cache')
            print('PASS: route hints, offline recovery, stable TLS identity, unchanged voice mode/audio graph, explicit profile')
    finally:
        command('connection.disconnect')
        command('network.injectClientIdentityUnavailable', {'unavailable': False})
        command('app.clearError')
        if profile:
            command('favourite.remove', {'primaryKey': profile['primaryKey']})
        if certificate_id:
            command('certificate.delete', {'id': certificate_id})
        if saved_reconnect is None:
            command('settings.remove', {'key': 'NetworkAutoReconnect'})
        else:
            command('settings.set', {'key': 'NetworkAutoReconnect', 'value': saved_reconnect})
        if fixture:
            fixture.close()
        ws.close()
        evidence.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--import-dir', required=True, help='Writable Documents directory in the test app container')
    parser.add_argument('--interactive', action='store_true')
    parser.add_argument('--playback-heartbeat')
    parser.add_argument('--output', default='/tmp/mumble-background-reconnect.jsonl')
    run(parser.parse_args())
