import json
import os
import pathlib
import socket
import subprocess
import tempfile
import unittest

RELAY = pathlib.Path(__file__).resolve().parents[1] / 'bridge/devflow-hook.py'


class RelayTests(unittest.TestCase):
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
