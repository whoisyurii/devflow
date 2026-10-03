#!/usr/bin/env python3
"""Emit explicit, verified workflow milestones to DevFlow."""
import argparse
import importlib.util
import os
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('event', choices=['worktree-ready','branch-pushed'])
parser.add_argument('--path', default=os.getcwd())
parser.add_argument('--remote', default='origin')
args = parser.parse_args()


def git(*arguments):
    return subprocess.check_output(['git','-C',os.path.abspath(args.path),*arguments], text=True, timeout=20).strip()


try:
    path = git('rev-parse','--show-toplevel')
    commit = git('rev-parse','HEAD')
    branch = git('symbolic-ref','--short','HEAD')
    if args.event == 'branch-pushed':
        if args.remote.startswith('-'):
            raise ValueError('Invalid remote')
        remote = git('ls-remote','--exit-code',args.remote,'refs/heads/'+branch)
        if remote.split()[0] != commit:
            raise ValueError('Remote branch does not match local HEAD; no push notification was emitted.')
    spec = importlib.util.spec_from_file_location('devflow_hook', os.path.join(os.path.dirname(__file__),'devflow-hook.py'))
    relay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(relay)
    relay.send({'agent':'claude','session_id':'workflow:'+path,'cwd':path,'branch':branch,'commit':commit,
                'hook_event_name':'WorktreeReady' if args.event=='worktree-ready' else 'BranchPushed'})
except (FileNotFoundError, ConnectionRefusedError):
    pass  # Companion is not running; never make a successful workflow fail.
except Exception as error:
    print(str(error),file=sys.stderr)
    sys.exit(1)
