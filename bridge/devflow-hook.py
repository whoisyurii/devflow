#!/usr/bin/env python3
"""Local notification relay. Never returns an approval decision or blocks the agent."""
import datetime
import json
import os
import socket
import sys
import uuid


def send(payload):
    root = os.environ.get('DEVFLOW_DATA_DIR', os.path.expanduser('~/Library/Application Support/DevFlow'))
    payload.setdefault('event_id', str(uuid.uuid4()))
    payload.setdefault('timestamp', datetime.datetime.now(datetime.timezone.utc).isoformat())
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(0.15)
        connection.connect(os.path.join(root, 'events.sock'))
        connection.sendall((json.dumps(payload) + '\n').encode())


if __name__ == '__main__':
    try:
        payload = json.loads(sys.stdin.buffer.read(1024 * 1024))
        if '--agent' in sys.argv:
            payload['agent'] = sys.argv[sys.argv.index('--agent') + 1]
        # Tool outputs can be large or sensitive; only the event, title and final answer are needed.
        allowed = ['agent','session_id','sessionId','cwd','hook_event_name','prompt','tool_name',
                   'tool_use_id','turn_id','last_assistant_message','message','transcript_path']
        send({key: value for key, value in payload.items() if key in allowed})
    except Exception:
        pass
    # Empty stdout leaves every permission decision with the originating agent.
    sys.exit(0)
