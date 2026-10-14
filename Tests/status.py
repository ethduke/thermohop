#!/usr/bin/env python3
"""Check readable status and JSON metadata using a disposable, idle process."""
import json
import os
import pathlib
import subprocess
import sys
import uuid

BINARY = pathlib.Path(__file__).resolve().parents[1] / '.build/release/thermohop'
UNMATCHED = 'th-status-' + uuid.uuid4().hex[:12]
MARKER = 'synthetic-sensitive-' + uuid.uuid4().hex
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def run(arguments):
    result = subprocess.run([str(BINARY), 'awake', 'status', *arguments], capture_output=True, timeout=5)
    assert result.returncode == 0 and not result.stderr, 'Status command failed'
    check(MARKER.encode() not in result.stdout, 'Status must not expose process arguments')
    return result.stdout


text = run(['--agent', UNMATCHED]).decode()
check('Thermohop awake status' in text and 'Detected agent processes: 0' in text
      and 'No recognized agent processes' in text and '{"' not in text,
      'Default status must be readable without JSON')
status = json.loads(run(['--json', '--agent', UNMATCHED]))
check(status['event'] == 'awakeStatus' and status['schemaVersion'] == 1
      and status['agents'] == [] and not status['assertionHeld'],
      'JSON status must preserve the existing machine fields')

agent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(20)', MARKER])
try:
    arguments = ['--agent', UNMATCHED, '--pid', str(agent.pid)]
    text = run(arguments).decode()
    check('1. ' in text and f'PID {agent.pid}' in text and 'parent:' in text
          and f'(PID {os.getpid()})' in text and 'Task titles are unavailable' in text,
          'Readable status must number the process and identify its parent truthfully')
    status = json.loads(run(['--json', *arguments]))
    check(len(status['agents']) == 1 and status['agents'][0]['pid'] == agent.pid
          and status['agents'][0]['parentPID'] == os.getpid()
          and status['agents'][0]['state'] in ('starting', 'runnable', 'waiting')
          and status['agents'][0]['displayName'],
          'JSON must expose safe process metadata without guessing a task')
    monitor = subprocess.run([str(BINARY), *arguments, '--duration', '.2'], capture_output=True, timeout=5)
    check(monitor.returncode == 0 and MARKER.encode() not in monitor.stdout + monitor.stderr,
          'Readable monitoring must not expose process arguments')
    if status['thermalLevel'] < 2 and status['lid'] != 'closed':
        check(b'1. ' in monitor.stdout and f'PID {agent.pid}'.encode() in monitor.stdout,
              'Default monitor must also show the numbered process list')
finally:
    agent.terminate(); agent.wait(timeout=2)

print(f'{checks} status checks passed; disposable process stopped; no task prompts or arguments read')
