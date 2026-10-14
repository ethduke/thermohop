#!/usr/bin/env python3
"""Check live monitor state and real sleep assertions without heat or network changes."""
import json
import pathlib
import signal
import subprocess
import tempfile
import time
import uuid

BINARY = pathlib.Path(__file__).resolve().parents[1] / '.build/release/thermohop'
UNMATCHED = 'th-runtime-' + uuid.uuid4().hex[:12]
MARKER = 'synthetic-sensitive-' + uuid.uuid4().hex
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def status(human=False):
    arguments = ['awake', 'status', '--agent', UNMATCHED]
    if not human:
        arguments.append('--json')
    result = subprocess.run([str(BINARY), *arguments], capture_output=True, timeout=5)
    assert result.returncode == 0 and not result.stderr, 'Runtime status failed'
    assert MARKER.encode() not in result.stdout + result.stderr, 'Status exposed process arguments'
    return result.stdout.decode() if human else json.loads(result.stdout)


def await_status(predicate):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        observed = status()
        if predicate(observed):
            return observed
        time.sleep(.1)
    raise AssertionError('Expected live status transition was not observed')


def start(arguments):
    return subprocess.Popen([str(BINARY), *arguments], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGCONT)
        process.send_signal(signal.SIGINT)
    try:
        return process.communicate(timeout=4)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=2)
        raise AssertionError('Disposable monitor did not stop promptly')


initial = status()
check(initial['monitorState'] == 'stopped' and initial['monitorRunning'] is False
      and initial['monitorPID'] is None, 'No controller must report stopped')
check(initial['assertionHeld'] is False and initial['sleepPreventionActive'] is False,
      'A read-only status check must not prevent sleep')
text = status(human=True)
check('Monitor: stopped' in text and 'Sleep prevention by Thermohop: inactive' in text,
      'Stopped/inactive must be explicit in readable output')

process = start(['--json', '--agent', UNMATCHED])
try:
    observed = await_status(lambda item: item['monitorPID'] == process.pid and item['monitorState'] == 'running')
    check(observed['monitorRunning'] and observed['monitorMode'] == 'monitor'
          and observed['assertionHeld'] is False and observed['sleepPreventionActive'] is False,
          'A monitor waiting for an agent is running without preventing sleep')
    text = status(human=True)
    check(f'Monitor: running (PID {process.pid}; open-lid monitor)' in text
          and 'Sleep prevention by Thermohop: inactive' in text,
          'Readable output must separate running from actual prevention')
    output, errors = stop(process)
    check(process.returncode == 130 and not errors and b'"monitorStopped"' in output,
          'Ctrl+C must stop the waiting monitor')
    check(await_status(lambda item: item['monitorState'] == 'stopped')['sleepPreventionActive'] is False,
          'Ctrl+C must return status to stopped/inactive')
finally:
    if process.poll() is None:
        stop(process)

agent = subprocess.Popen(['/usr/bin/python3', '-c', 'import time; time.sleep(45)', MARKER])
process = start(['--json', '--agent', UNMATCHED, '--pid', str(agent.pid)])
try:
    observed = await_status(lambda item: item['monitorState'] == 'running' and item['monitorPID'] == process.pid)
    if observed['thermalLevel'] >= 2 or observed['lid'] == 'closed':
        check(observed['sleepPreventionActive'] is False,
              'Actual unsafe conditions must not be bypassed for testing')
    else:
        observed = await_status(lambda item: item['assertionHeld'] is True)
        check(observed['sleepPreventionActive'] and observed['agents'] == [],
              'Sleep prevention must come from macOS independently of status process filters')
        check('Sleep prevention by Thermohop: active' in status(human=True),
              'Readable output must report the real active assertion')
        process.send_signal(signal.SIGSTOP)
        observed = await_status(lambda item: item['monitorState'] == 'paused')
        check(observed['monitorRunning'] is False and observed['monitorPID'] == process.pid,
              'A suspended monitor must report paused with its live PID')
        time.sleep(6)
        observed = status()
        check(observed['monitorState'] == 'paused' and observed['assertionHeld'] is False
              and observed['sleepPreventionActive'] is False,
              'Paused status must reflect expiration of the five-second OS lease')
        process.send_signal(signal.SIGCONT)
        observed = await_status(lambda item: item['monitorState'] == 'running' and item['assertionHeld'] is True)
        check(observed['sleepPreventionActive'], 'Resumed monitor must report reacquired prevention')
    output, errors = stop(process)
    check(process.returncode == 130 and not errors and MARKER.encode() not in output,
          'Ctrl+C must clean up without exposing arguments')
    check(await_status(lambda item: item['monitorState'] == 'stopped')['sleepPreventionActive'] is False,
          'Stopped status must reflect real assertion release')
finally:
    if process.poll() is None:
        stop(process)
    if agent.poll() is None:
        agent.terminate()
        agent.wait(timeout=3)

process = start(['--json', '--agent', UNMATCHED])
try:
    await_status(lambda item: item['monitorPID'] == process.pid)
    process.kill()
    process.communicate(timeout=3)
    observed = await_status(lambda item: item['monitorState'] == 'stopped')
    check(observed['monitorPID'] is None and observed['sleepPreventionActive'] is False,
          'Stale identity metadata after a crash must not report a live monitor')
finally:
    if process.poll() is None:
        stop(process)

process = start(['awake', 'watch', '--observe-only', '--agent', UNMATCHED])
try:
    observed = await_status(lambda item: item['monitorPID'] == process.pid)
    check(observed['monitorState'] == 'running' and observed['monitorMode'] == 'awakeWatch'
          and observed['sleepPreventionActive'] is False,
          'Legacy observe-only watch must be identified without claiming sleep prevention')
finally:
    stop(process)
check(status()['monitorState'] == 'stopped', 'All disposable monitor processes must be stopped')

with tempfile.TemporaryDirectory(prefix='thermohop-runtime-') as directory:
    root = pathlib.Path(directory)
    policy = root / 'policy.json'
    profiles = root / 'profiles.json'
    profiles.write_text(json.dumps({'schemaVersion': 1, 'profiles': []}))
    for awake_enabled, observe_only in ((True, False), (True, True), (False, False)):
        policy.write_text(json.dumps({'awake': {'enabled': awake_enabled, 'agents': [UNMATCHED]},
                                      'wifi': {'enabled': False}}))
        arguments = ['supervise', '--policy', str(policy), '--config', str(profiles), '--duration', '30']
        if observe_only:
            arguments.append('--observe-only')
        process = start(arguments)
        try:
            observed = await_status(lambda item: item['monitorPID'] == process.pid)
            check(observed['monitorState'] == 'running' and observed['monitorMode'] == 'supervisor'
                  and observed['sleepPreventionActive'] is False,
                  'The policy supervisor must expose its controller without inventing prevention')
            output, errors = stop(process)
            check(process.returncode == 130 and not errors and b'"supervisorStopped"' in output,
                  'The policy supervisor must stop normally with its identity lock released')
        finally:
            if process.poll() is None:
                stop(process)
check(status()['monitorState'] == 'stopped', 'Supervisor cleanup must report stopped')

print(f'{checks} runtime checks passed; running/stopped/paused and OS lease verified; no heat or global sleep changes; test processes stopped')
