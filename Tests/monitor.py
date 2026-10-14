#!/usr/bin/env python3
"""Exercise the default monitor with disposable processes and native assertions."""
import json
import pathlib
import re
import signal
import subprocess
import time
import uuid

BINARY = pathlib.Path(__file__).resolve().parents[1] / '.build/release/thermohop'
UNMATCHED = 'th-monitor-' + uuid.uuid4().hex[:12]
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


def start(arguments):
    return subprocess.Popen([str(BINARY), *arguments], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
    try:
        return process.communicate(timeout=4)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=2)
        raise AssertionError('Monitor did not stop promptly')


def rows(output):
    return [json.loads(line) for line in output.splitlines()]


def assertion_exists(pid):
    result = subprocess.run(['/usr/bin/pmset', '-g', 'assertions'],
                            capture_output=True, text=True, timeout=4)
    assert result.returncode == 0, 'Cannot inspect native assertions'
    return any(re.search(r'\bpid\s+' + str(pid) + r'\b', line)
               and 'Thermohop agent thermal guard' in line for line in result.stdout.splitlines())


def wait_assertion(pid, expected):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if assertion_exists(pid) == expected:
            return True
        time.sleep(.1)
    return False


# Bare invocation runs rather than displaying help, and has no default timeout.
process = start([])
try:
    time.sleep(.7)
    check(process.poll() is None, 'Bare command must continue monitoring')
    output, errors = stop(process)
    check(process.returncode == 130 and b'open-lid monitoring' in output
          and b'Stopped;' in output and not errors and b'{"' not in output,
          'Bare command must display readable status and handle Ctrl+C')
    check(not assertion_exists(process.pid), 'Ctrl+C must release the native assertion')
finally:
    if process.poll() is None:
        stop(process)

result = subprocess.run([str(BINARY), '--json', '--agent', UNMATCHED, '--duration', '.2'],
                        capture_output=True, timeout=5)
events = rows(result.stdout)
check(result.returncode == 0 and not result.stderr
      and events[0]['event'] == 'monitorStarted' and events[0]['duration'] == .2
      and events[0]['thermalCutoffLevel'] == 2 and events[0]['resumeDelaySeconds'] == 60
      and events[-1]['event'] == 'monitorStopped' and events[-1]['reason'] == 'durationExpired'
      and all(e['schemaVersion'] == 1 and 'timestamp' in e for e in events),
      'Root flags must select default JSON monitoring with documented safety defaults')
check(all(not e.get('assertionHeld', False) for e in events),
      'No matching agents must keep sleep allowed')

result = subprocess.run([str(BINARY), 'monitor', '--agent', UNMATCHED, '--duration', '.2'],
                        capture_output=True, timeout=5)
check(result.returncode == 0 and b'open-lid monitoring' in result.stdout
      and b'{"' not in result.stdout, 'Explicit monitor must also support readable status')

for arguments in (['--help'], ['--version'], ['monitor', '--help'], ['awake', 'watch', '--help']):
    result = subprocess.run([str(BINARY), *arguments], capture_output=True, timeout=5)
    check(result.returncode == 0 and result.stdout, 'Help/version must not start a monitor')

for value in ('0', '-1', 'nan', '86401'):
    result = subprocess.run([str(BINARY), '--duration', value], capture_output=True, timeout=5)
    check(result.returncode == 64, 'Invalid duration must fail before monitoring')

process = start(['--json', '--agent', UNMATCHED])
try:
    time.sleep(.5)
    check(process.poll() is None, 'JSON default must remain available until interrupted')
    result = subprocess.run([str(BINARY), '--duration', '.1'], capture_output=True, timeout=5)
    check(result.returncode == 8 and not result.stdout and b'Another supervisor' in result.stderr,
          'A second monitor must fail with a readable error without changing assertions')
    output, _ = stop(process)
    events = rows(output)
    check(events[0]['duration'] is None and events[-1]['reason'] == 'interrupted'
          and not events[-1]['assertionHeld'] and events[-1]['verified'],
          'Unbounded JSON session must verify shutdown')
finally:
    if process.poll() is None:
        stop(process)

# A disposable process selects real prevention without calling any AI service.
agent = subprocess.Popen(['/bin/sleep', '30'])
process = start(['--json', '--agent', UNMATCHED, '--pid', str(agent.pid)])
try:
    status = subprocess.run([str(BINARY), 'awake', 'status', '--json', '--agent', UNMATCHED],
                            capture_output=True, timeout=5)
    hardware = json.loads(status.stdout)
    if hardware['thermalLevel'] >= 2 or hardware['lid'] == 'closed':
        # Never disable the safety guard to force this native test to pass.
        output, _ = stop(process)
        check(all(not e.get('assertionHeld', False) for e in rows(output)),
              'Real unsafe heat or closed lid must leave prevention released')
    else:
        check(wait_assertion(process.pid, True), 'Matched PID must acquire a native assertion')
        process.send_signal(signal.SIGSTOP)
        time.sleep(6)
        check(not assertion_exists(process.pid), 'A stalled monitor must lose its five-second lease')
        process.send_signal(signal.SIGCONT)
        check(wait_assertion(process.pid, True), 'Resumed monitoring must safely reacquire an expired lease')
        agent.terminate(); agent.wait(timeout=2)
        check(wait_assertion(process.pid, False), 'Agent exit must release prevention while monitoring continues')
        check(process.poll() is None, 'Agent exit must not end the watcher')
        output, errors = stop(process)
        states = [e['state'] for e in rows(output) if e['event'] == 'monitorStatus']
        check(not errors and 'keepingAwake' in states and states[-1] == 'waitingForAgent',
              'JSON status must describe verified native transitions')
finally:
    if process.poll() is None:
        process.send_signal(signal.SIGCONT)
        stop(process)
    if agent.poll() is None:
        agent.terminate(); agent.wait(timeout=2)
check(not assertion_exists(process.pid), 'Native test must leave no monitor assertion')

print(f'{checks} monitor checks passed; disposable processes stopped; no network or global sleep changes')
