#!/usr/bin/env python3
"""Send real Mumble authentication rejections to an idle DEBUG app over loopback.

Checks application error state, not native alert visibility; inspect the UI
separately with --keep-error. No external server or saved password is used.
The app may remember the fixture endpoint and its temporary certificate digest.
"""
import argparse
from pathlib import Path
import select
import struct
import tempfile

from real_app_heartbeat_probe import Fixture, frame, number, string
from mumble_agent_probe import EvidenceWriter, ProbeRunner, StdlibWebSocket


class RejectFixture(Fixture):
    def __init__(self, directory, reason, explanation):
        self.reason = reason
        self.explanation = explanation
        super().__init__(directory)

    def session(self, peer):
        data = bytearray()
        while not self.stop.is_set():
            if not peer.pending() and not select.select([peer], [], [], .1)[0]:
                continue
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
                del data[:size + 6]
                if kind == 2:  # Authenticate, followed by Reject.
                    self.authenticated += 1
                    peer.sendall(frame(4, number(1, self.reason) + string(2, self.explanation)))
                    return


def run(args):
    evidence = EvidenceWriter(Path(args.output))
    ws = StdlibWebSocket('ws://localhost:54296', 8)
    ws.connect()
    runner = ProbeRunner(ws, evidence, 'connection-rejection', 8)

    def command(action, params=None):
        result = runner.command(action, params)
        assert result.get('success'), result
        return result.get('data') or {}

    initial = command('state.get')
    assert not initial.get('isConnected') and not initial.get('isConnecting'), 'Use an idle test app.'
    assert not initial.get('activeError') and not initial.get('pendingCertTrust'), 'Dismiss existing alerts first.'
    assert not command('ui.get').get('presentedSheet'), 'Dismiss sheets first.'
    attempted = False
    completed = False
    reject_certificate = args.reject_certificate or args.manual_reject
    manual_decision = args.manual_trust or args.manual_reject
    try:
        with tempfile.TemporaryDirectory(prefix='mumble-rejection-') as directory:
            fixture = RejectFixture(directory, args.reason, args.explanation)
            try:
                attempted = True
                command('connection.connect', {
                    'hostname': '127.0.0.1', 'port': fixture.port,
                    'username': 'RejectionProbe', 'password': args.password,
                })
                status = runner.wait_for_data('certificate decision', 'connection.status', None,
                    lambda x: x.get('hasPendingCertTrust'), timeout=12)
                assert status.get('hasPendingCertTrust'), status
                if args.reject_certificate:
                    command('connection.rejectCert')
                elif not manual_decision:
                    command('connection.acceptCert')
                state = runner.wait_for_data('authentication error', 'state.get', None,
                    lambda x: bool(x.get('activeError')), timeout=60 if manual_decision else 12)
                error = state.get('activeError') or {}
                assert error.get('message') and error.get('title'), state
                if args.explanation and not reject_certificate:
                    assert args.explanation in error['message'], error
                if args.expected_error:
                    assert args.expected_error in error['message'], error
                assert not state.get('isConnecting') and not state.get('isConnected'), state
                assert not state.get('pendingCertTrust'), state
                runner.collect_events(2)
                assert fixture.authenticated == (0 if reject_certificate else 1), 'Unexpected authentication retry.'
                assert command('state.get').get('activeError') == error, 'Close event cleared the error.'
                evidence.write('assertion', passed=True, reason=args.reason, error=error,
                    description='Authentication rejection stops connecting, keeps error and does not retry')
                completed = True
                print(f"passed: rejection reason {args.reason}: {error['message']}")
            finally:
                fixture.close()
    finally:
        if attempted and not completed:
            command('connection.disconnect')
        if not args.keep_error:
            command('app.clearError')
        ws.close()
        evidence.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--reason', type=int, choices=range(8), default=4)
    parser.add_argument('--password', default='incorrect-test-password')
    parser.add_argument('--explanation', default='')
    parser.add_argument('--expected-error')
    certificate_action = parser.add_mutually_exclusive_group()
    certificate_action.add_argument('--manual-trust', action='store_true')
    certificate_action.add_argument('--manual-reject', action='store_true')
    certificate_action.add_argument('--reject-certificate', action='store_true')
    parser.add_argument('--keep-error', action='store_true')
    parser.add_argument('--output', default='/tmp/mumble-connection-rejection.jsonl')
    run(parser.parse_args())
