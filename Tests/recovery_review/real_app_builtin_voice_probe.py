#!/usr/bin/env python3
"""Exercise real macOS VPIO on the built-in mic/speakers, then restore routing.

Only run with authorization to switch system defaults and use the microphone.
The fixture accepts only loopback clients and discards voice without recording.
"""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile
import time

from real_app_heartbeat_probe import Fixture, StdlibWebSocket, EvidenceWriter, ProbeRunner


def run(args):
    output = Path(args.output)
    evidence = EvidenceWriter(output)
    ws = StdlibWebSocket(args.url, 8)
    ws.connect()
    runner = ProbeRunner(ws, evidence, 'builtin-vpio', 8)
    saved_settings = {}
    route_saved = False
    saved_defaults = None
    fixture = None
    # Keep the restoration record even if the test or cleanup fails.
    route_file = output.with_name('builtin-route-before-' + str(time.time_ns()) + '.json').resolve()

    def command(action, params=None):
        result = runner.command(action, params)
        assert result.get('success'), result
        return result.get('data') or {}

    def route(*arguments):
        result = subprocess.run([args.route_tool, *map(str, arguments)], capture_output=True, text=True, check=True)
        value = json.loads(result.stdout)
        evidence.write('route', action=arguments[0], data=value)
        return value

    def healthy():
        status = runner.wait_for_data('built-in VPIO becomes healthy', 'audio.status', None,
            lambda x: (x.get('health') or {}).get('state') == 'healthy', timeout=18, interval=.2)
        health = status.get('health') or {}
        assert health.get('state') == 'healthy', status
        assert health.get('backend') == 'MKVoiceProcessingDevice', health
        assert health.get('graphStartCount', 0) > 0, health
        return health

    def stable(seconds, label):
        initial = healthy()
        count = initial['graphStartCount']
        maximum_input_age = maximum_output_age = 0
        started = time.monotonic()
        sample_count = 0
        while time.monotonic() - started < seconds:
            status = command('audio.status')
            health = status.get('health') or {}
            assert status.get('running') and health.get('state') == 'healthy', status
            assert health.get('backend') == 'MKVoiceProcessingDevice', health
            assert health.get('graphStartCount') == count, 'Unrequested audio graph rebuild: ' + repr(health)
            assert health['inputCallbackAge'] < 1 and health['outputCallbackAge'] < 1, health
            maximum_input_age = max(maximum_input_age, health['inputCallbackAge'])
            maximum_output_age = max(maximum_output_age, health['outputCallbackAge'])
            if sample_count % 5 == 0:
                state = command('state.get')
                assert state.get('isConnected') and not state.get('voiceHealthMessage'), state
                assert fixture.authenticated == expected_joins, 'Unexpected network reconnect.'
            sample_count += 1
            runner.collect_events(.5)
        evidence.write('assertion', passed=True, description=label, durationSeconds=time.monotonic() - started,
            graphStartCount=count, samples=sample_count,
            maximumInputCallbackAge=maximum_input_age, maximumOutputCallbackAge=maximum_output_age)
        print('PASS:', label, 'graph starts:', count, flush=True)
        return count

    def join():
        command('connection.connect', {'hostname': '127.0.0.1', 'port': fixture.port, 'username': 'RecoveryProbe'})
        status = runner.wait_for_data('local certificate or connection', 'connection.status', None,
            lambda x: x.get('hasPendingCertTrust') or x.get('connected'), timeout=15)
        if status.get('hasPendingCertTrust'):
            command('connection.acceptCert')
        status = runner.wait_for_data('local call joined', 'connection.status', None,
            lambda x: x.get('connected'), timeout=15)
        assert status.get('connected'), status

    initial = command('connection.status')
    assert not initial.get('connected') and not initial.get('isConnecting'), 'Use an idle test app.'
    assert command('audio.permission').get('microphone') == 'authorized', 'Grant microphone permission before running.'
    try:
        for key, value in [('AudioFollowSystemInputDevice', True), ('AudioStereoInput', False),
                           ('NetworkAutoReconnect', False)]:
            saved_settings[key] = command('settings.get', {'key': key}).get('value')
            command('settings.set', {'key': key, 'value': value})
        saved_defaults = route('save', route_file)['defaults']
        route_saved = True
        builtin = route('builtin')
        assert all(builtin['defaults'][key]['transport'] == 'builtIn' for key in ['input', 'output']), builtin
        runner.collect_events(2)
        with tempfile.TemporaryDirectory(prefix='mumble-builtin-tls-') as directory:
            fixture = Fixture(directory)
            join()
            expected_joins = 1
            initial_count = stable(args.duration, 'Built-in VPIO remains healthy without recovery loop')
            route('list')  # Capture physical devices and VPIO aggregate while active.
            command('audio.simulateCallbackStall')
            recovering = runner.wait_for_data('real callback stall detected', 'audio.status', None,
                lambda x: (x.get('health') or {}).get('state') == 'recovering', timeout=10, interval=.1)
            assert (recovering.get('health') or {}).get('state') == 'recovering', recovering
            recovered = healthy()
            assert recovered['graphStartCount'] == initial_count + 1, recovered
            stable(args.duration, 'VPIO recovers once from real callback stall and stays healthy')
            command('connection.disconnect')
            runner.collect_events(2)
            assert not command('audio.status').get('running')
            join()
            expected_joins = 2
            stable(args.duration, 'Rejoining with built-in devices does not restart the recovery loop')
            assert not runner.failures, runner.failures
            print('PASS: built-in microphone/speakers VPIO integration', flush=True)
    finally:
        cleanup_errors = []
        for action in ['connection.disconnect', 'audio.stopTest']:
            try:
                command(action)
            except Exception as error:
                cleanup_errors.append(str(error))
        # Release VPIO before restoring defaults, even if a command failed.
        try:
            runner.collect_events(2)
        except Exception:
            pass
        if fixture:
            try:
                fixture.close()
            except Exception as error:
                cleanup_errors.append('Fixture cleanup failed: ' + str(error))
        if route_saved:
            try:
                restored = route('restore', route_file)
                assert all(restored['defaults'][key]['uid'] == saved_defaults[key]['uid']
                           for key in ['input', 'output', 'systemOutput']), restored
            except Exception as error:
                cleanup_errors.append('Audio routing restoration failed: ' + str(error))
        for key, value in saved_settings.items():
            try:
                if value is None:
                    command('settings.remove', {'key': key})
                else:
                    command('settings.set', {'key': key, 'value': value})
            except Exception as error:
                cleanup_errors.append(str(error))
        evidence.write('cleanup', success=not cleanup_errors, errors=cleanup_errors, routeRestoreFile=str(route_file))
        ws.close()
        evidence.close()
        if cleanup_errors:
            raise RuntimeError('; '.join(cleanup_errors))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default='ws://localhost:54296')
    parser.add_argument('--route-tool', required=True)
    parser.add_argument('--duration', type=float, default=60)
    parser.add_argument('--output', default='Tests/Artifacts/recovery-macos/builtin-vpio-runtime.jsonl')
    run(parser.parse_args())
