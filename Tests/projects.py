#!/usr/bin/env python3
"""Check project hints and path privacy with idle disposable processes."""
import json
import os
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import time
import uuid

BINARY = pathlib.Path(__file__).resolve().parents[1] / '.build/release/thermohop'
UNMATCHED = 'th-project-' + uuid.uuid4().hex[:12]
MARKER = 'synthetic-sensitive-' + uuid.uuid4().hex
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def private_output(output, private_directory):
    check(MARKER.encode() not in output, 'Output must not expose arguments or parent folder names')
    check(str(private_directory).encode() not in output, 'Output must not expose full working paths')


def status(pid, private_directory, human=False):
    arguments = ['awake', 'status', '--agent', UNMATCHED, '--pid', str(pid)]
    if not human:
        arguments.append('--json')
    result = subprocess.run([str(BINARY), *arguments], capture_output=True, timeout=5)
    check(result.returncode == 0 and not result.stderr, 'Status command must succeed without diagnostics')
    private_output(result.stdout + result.stderr, private_directory)
    return result.stdout.decode() if human else json.loads(result.stdout)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


with tempfile.TemporaryDirectory(prefix='thermohop-' + MARKER + '-', dir='/private/tmp') as temporary:
    parent = pathlib.Path(temporary)
    first = parent / 'example-project'
    second = parent / 'second-project'
    first.mkdir()
    second.mkdir()
    child_code = 'import os,sys; print("ready",flush=True)\nfor line in sys.stdin:\n os.chdir("../second-project"); print("changed",flush=True)'
    agent = subprocess.Popen([sys.executable, '-c', child_code, MARKER], cwd=first,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    monitor = None
    captured = b''
    try:
        check(bool(select.select([agent.stdout], [], [], 3)[0]) and agent.stdout.readline() == b'ready\n',
              'Disposable process must be ready before metadata checks')
        observed = status(agent.pid, parent)
        check(len(observed['agents']) == 1 and observed['agents'][0]['projectName'] == first.name
              and observed['agents'][0]['projectSource'] == 'workingDirectory',
              'Kernel metadata must yield only the project basename')
        check('cwd' not in observed['agents'][0] and 'path' not in observed['agents'][0],
              'JSON must not expose raw directory metadata')
        text = status(agent.pid, parent, human=True)
        check('project folder: example-project' in text, 'Readable status must show the project hint')

        monitor = subprocess.Popen([str(BINARY), '--json', '--agent', UNMATCHED, '--pid', str(agent.pid)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        pending = b''

        def await_project(name):
            global pending, captured
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if not select.select([monitor.stdout], [], [], .2)[0]:
                    continue
                chunk = os.read(monitor.stdout.fileno(), 65536)
                if not chunk:
                    break
                captured += chunk
                pending += chunk
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    event = json.loads(line)
                    if event.get('event') == 'monitorStatus' and any(
                            item.get('pid') == agent.pid and item.get('projectName') == name
                            for item in event.get('agents', [])):
                        return True
            return False

        check(await_project(first.name), 'Monitor must show the first project')
        agent.stdin.write(b'change\n')
        agent.stdin.flush()
        check(bool(select.select([agent.stdout], [], [], 3)[0]) and agent.stdout.readline() == b'changed\n',
              'Disposable process must change directory successfully')
        check(await_project(second.name), 'Monitor must refresh a project hint without a PID change')
        monitor.send_signal(signal.SIGINT)
        remainder, errors = monitor.communicate(timeout=3)
        captured += remainder
        private_output(captured + errors, parent)
        check(monitor.returncode == 130 and not errors and b'"monitorStopped"' in captured,
              'Ctrl+C must stop monitoring and report released sleep prevention')
    finally:
        if monitor is not None:
            stop(monitor)
        stop(agent)

    home_agent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(20)', MARKER],
                                  cwd=pathlib.Path.home())
    try:
        observed = status(home_agent.pid, parent)
        check(len(observed['agents']) == 1 and observed['agents'][0]['projectName'] is None
              and observed['agents'][0]['projectSource'] is None,
              'The personal home directory must remain unknown')
        private_output(json.dumps(observed).encode(), pathlib.Path.home())
    finally:
        stop(home_agent)

print(f'{checks} project checks passed; project changes refresh; paths and arguments stay private; test processes stopped')
