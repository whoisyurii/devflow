import json
import os
import pathlib
import socket
import subprocess
import tempfile
import unittest
import struct
import wave

RELAY = pathlib.Path(__file__).resolve().parents[1] / 'bridge/devflow-hook.py'


class RelayTests(unittest.TestCase):
    def test_both_agents_relay_pending_context_without_raw_arguments_or_decisions(self):
        for agent in ['codex', 'claude']:
            with self.subTest(agent=agent), tempfile.TemporaryDirectory(prefix='df-', dir='/tmp') as directory:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(directory + '/events.sock')
                    server.listen(1)
                    server.settimeout(2)
                    result = subprocess.run(['/usr/bin/python3', str(RELAY), '--agent', agent],
                        input=json.dumps({'session_id': 'question', 'cwd': '/repo/React.BFF',
                            'hook_event_name': 'PreToolUse', 'tool_name': 'AskUserQuestion',
                            'tool_input': {'questions': [{'question': 'Which branch should continue?'}],
                                           'command': 'private command fixture'},
                            'notification_type': 'elicitation_dialog', 'decision': 'allow'}),
                        capture_output=True, text=True, timeout=2,
                        env={**os.environ, 'DEVFLOW_DATA_DIR': directory})
                    connection, _ = server.accept()
                    with connection:
                        payload = json.loads(connection.recv(8192))
                    self.assertEqual(payload['agent'], agent)
                    self.assertEqual(payload['pending_summary'], 'Which branch should continue?')
                    self.assertEqual(payload['notification_type'], 'elicitation_dialog')
                    self.assertNotIn('tool_input', payload)
                    self.assertNotIn('decision', payload)
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))

    def test_original_chime_is_short_quiet_and_has_smooth_endpoints(self):
        path = RELAY.parents[1] / 'DevFlow/Resources/DevFlowChime.wav'
        with wave.open(str(path)) as audio:
            self.assertEqual((audio.getnchannels(), audio.getsampwidth(), audio.getframerate()), (1, 2, 48000))
            self.assertAlmostEqual(audio.getnframes() / audio.getframerate(), 0.72)
            frames = audio.readframes(audio.getnframes())
        samples = struct.unpack('<' + 'h' * (len(frames) // 2), frames)
        self.assertGreater(max(abs(x) for x in samples), 1000)
        self.assertLess(max(abs(x) for x in samples), 9000)
        self.assertEqual(samples[0], 0)
        self.assertLess(abs(samples[-1]), 2)

    def test_absent_app_never_blocks_or_decides_permissions(self):
        with tempfile.TemporaryDirectory(prefix='df-') as directory:
            result = subprocess.run(['/usr/bin/python3', str(RELAY), '--agent', 'codex'],
                                    input=json.dumps({'hook_event_name': 'PermissionRequest'}),
                                    capture_output=True, text=True, timeout=2,
                                    env={**os.environ, 'DEVFLOW_DATA_DIR': directory})
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')

    def test_relay_keeps_final_answer_but_drops_tool_output(self):
        with tempfile.TemporaryDirectory(prefix='df-', dir='/tmp') as directory:
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(directory + '/events.sock')
            server.listen(1)
            server.settimeout(2)
            try:
                result = subprocess.run(['/usr/bin/python3', str(RELAY), '--agent', 'codex'],
                                        input=json.dumps({'session_id': 'abc', 'hook_event_name': 'Stop',
                                                          'last_assistant_message': 'complete answer', 'tool_response': 'secret fixture'}),
                                        capture_output=True, text=True, timeout=2,
                                        env={**os.environ, 'DEVFLOW_DATA_DIR': directory})
                connection, _ = server.accept()
                with connection:
                    payload = json.loads(connection.recv(8192))
                self.assertEqual(payload['agent'], 'codex')
                self.assertEqual(payload['last_assistant_message'], 'complete answer')
                self.assertNotIn('tool_response', payload)
                self.assertEqual(result.stdout, '')
            finally:
                server.close()
