#!/usr/bin/env python3
"""Exercise idle audio probe assertions with local fixtures, without any app."""

import argparse
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
from mumble_agent_probe import FakeWebSocket, ProbeRunner, run_scenario


IDLE_SESSION = {
    "category": "AVAudioSessionCategoryAmbient",
    "mode": "AVAudioSessionModeDefault",
    # Ambient implicitly mixes even with no explicit category option bits.
    "categoryOptions": 0,
    "mixesWithOthers": True,
    "ducksOthers": False,
    "otherAudioPlaying": True,
}
IDLE_AUDIO = {
    "running": False,
    "localAudioTestRunning": False,
    "health": {"state": "stopped", "requested": False},
    "audioSession": IDLE_SESSION,
}


class MemoryEvidence:
    def __init__(self):
        self.records = []

    def write(self, record_type, **fields):
        self.records.append({"type": record_type, **fields})


class AudioFixture(FakeWebSocket):
    def __init__(self, snapshot, bad_at=None, reset_snapshot=None):
        super().__init__()
        self.snapshot = copy.deepcopy(snapshot)
        self.bad_at = bad_at
        self.reset_snapshot = copy.deepcopy(reset_snapshot)
        self.audio_reads = 0

    def _data_for(self, action, params):
        if action == "app.cancelConnection" and self.reset_snapshot is not None:
            self.snapshot = copy.deepcopy(self.reset_snapshot)
        if action == "audio.status":
            self.audio_reads += 1
            if self.bad_at is None or self.audio_reads == self.bad_at:
                return copy.deepcopy(self.snapshot)
            return copy.deepcopy(IDLE_AUDIO)
        return super()._data_for(action, params)


class IdleAudioProbeTests(unittest.TestCase):
    def run_fixture(self, scenario, snapshot, *, bad_at=None, reset_snapshot=None):
        evidence = MemoryEvidence()
        ws = AudioFixture(snapshot, bad_at=bad_at, reset_snapshot=reset_snapshot)
        runner = ProbeRunner(ws, evidence, "idle-audio-self-test", timeout=1)
        args = argparse.Namespace(scenario=scenario, wait_timeout=0.1)
        run_scenario(args, runner, runner.run_id)
        return runner, evidence, ws

    def assert_bad_snapshot_rejected(self, snapshot):
        # Lifecycle reads: initial baseline, before transition, after resign,
        # after become active. Each lifecycle observation must be checked.
        for scenario, read_index in (
            ("idle-welcome", 1),
            ("lifecycle-idle-audio", 2),
            ("lifecycle-idle-audio", 3),
            ("lifecycle-idle-audio", 4),
        ):
            with self.subTest(scenario=scenario, read_index=read_index):
                runner, _, ws = self.run_fixture(scenario, snapshot, bad_at=read_index)
                self.assertGreaterEqual(ws.audio_reads, read_index)
                self.assertTrue(runner.failures, "bad audio snapshot was accepted")

    def test_ambient_with_implicit_mixing_keeps_other_music(self):
        for scenario in ("idle-welcome", "lifecycle-idle-audio"):
            with self.subTest(scenario=scenario):
                runner, _, _ = self.run_fixture(scenario, IDLE_AUDIO)
                self.assertEqual(runner.failures, [])

    def test_mac_and_older_fixtures_without_session_remain_supported(self):
        for audio in (
            {"running": False, "localAudioTestRunning": False},
            {"running": False, "localAudioTestRunning": False,
             "health": {"state": "stopped", "requested": False}},
        ):
            for scenario in ("idle-welcome", "lifecycle-idle-audio"):
                with self.subTest(audio=audio, scenario=scenario):
                    runner, _, _ = self.run_fixture(scenario, audio)
                    self.assertEqual(runner.failures, [])

    def test_nonmixable_default_session_is_rejected(self):
        audio = copy.deepcopy(IDLE_AUDIO)
        audio["audioSession"].update(category="AVAudioSessionCategorySoloAmbient", mixesWithOthers=False)
        self.assert_bad_snapshot_rejected(audio)

    def test_playback_category_is_not_an_idle_session_even_with_mixing(self):
        audio = copy.deepcopy(IDLE_AUDIO)
        audio["audioSession"].update(category="AVAudioSessionCategoryPlayback", categoryOptions=1)
        self.assert_bad_snapshot_rejected(audio)

    def test_missing_mixing_is_rejected(self):
        audio = copy.deepcopy(IDLE_AUDIO)
        audio["audioSession"]["mixesWithOthers"] = False
        self.assert_bad_snapshot_rejected(audio)

    def test_ducking_is_rejected(self):
        audio = copy.deepcopy(IDLE_AUDIO)
        audio["audioSession"].update(ducksOthers=True, categoryOptions=2)
        self.assert_bad_snapshot_rejected(audio)

    def test_voice_chat_mode_is_rejected(self):
        audio = copy.deepcopy(IDLE_AUDIO)
        audio["audioSession"]["mode"] = "AVAudioSessionModeVoiceChat"
        self.assert_bad_snapshot_rejected(audio)

    def test_present_but_incomplete_session_is_rejected(self):
        for session in (None, {}, {"category": "AVAudioSessionCategoryAmbient"}):
            with self.subTest(session=session):
                audio = copy.deepcopy(IDLE_AUDIO)
                audio["audioSession"] = session
                self.assert_bad_snapshot_rejected(audio)

    def test_requested_audio_is_not_stopped_when_running_is_false(self):
        for state in ("stopped", "starting", "recovering"):
            with self.subTest(health_state=state):
                audio = copy.deepcopy(IDLE_AUDIO)
                audio["health"].update(requested=True, state=state)
                self.assert_bad_snapshot_rejected(audio)

    def test_requested_audio_is_rejected_without_ios_session(self):
        audio = copy.deepcopy(IDLE_AUDIO)
        del audio["audioSession"]
        audio["health"]["requested"] = True
        self.assert_bad_snapshot_rejected(audio)

    def test_running_or_local_preview_is_rejected(self):
        for key in ("running", "localAudioTestRunning"):
            with self.subTest(key=key):
                audio = copy.deepcopy(IDLE_AUDIO)
                audio[key] = True
                self.assert_bad_snapshot_rejected(audio)

    def test_reset_cannot_mask_bad_cold_launch_session(self):
        audio = copy.deepcopy(IDLE_AUDIO)
        audio["audioSession"].update(category="AVAudioSessionCategorySoloAmbient", mixesWithOthers=False)
        runner, evidence, ws = self.run_fixture("idle-welcome", audio, reset_snapshot=IDLE_AUDIO)
        self.assertTrue(runner.failures)
        self.assertEqual(ws.snapshot, IDLE_AUDIO, "fixture cleanup did not restore the idle session")
        failure_index = next(i for i, record in enumerate(evidence.records)
                             if record["type"] == "assertion" and not record["passed"])
        reset_index = next(i for i, record in enumerate(evidence.records)
                           if record["type"] == "command.send" and record["action"] == "app.cancelConnection")
        self.assertLess(failure_index, reset_index, "cold launch must be checked before cleanup")


if __name__ == "__main__":
    unittest.main()
