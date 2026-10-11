#!/usr/bin/python3
"""Explicitly install/remove the optional privileged closed-lid watchdog."""
import argparse, os, pathlib, plistlib, pwd, shutil, stat, subprocess, sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--user-id', type=int)
parser.add_argument('--remove', action='store_true')
args = parser.parse_args()
if os.geteuid() != 0:
    sys.exit('Run with sudo only when opting into the system-wide closed-lid backend.')
base = pathlib.Path('/Library/Application Support/Thermohop')
marker = base / 'awake-helper-install-marker'
labels = ['io.thermohop.awake', 'io.thermohop.awake-backstop']
plists = [pathlib.Path('/Library/LaunchDaemons') / (label + '.plist') for label in labels]

def checked_path(path):
    if path.is_symlink():
        sys.exit('Refusing a symbolic link at an installation path.')
    if path.exists() and path.stat().st_uid != 0:
        sys.exit('Refusing a non-root-owned installation path.')

checked_path(base)
if base.exists() and not marker.is_file():
    sys.exit('Refusing an existing directory not installed by this helper installer.')
for path in plists:
    checked_path(path)
    if path.exists() and not marker.is_file():
        sys.exit('Refusing an unrelated existing launchd job.')
if args.remove:
    if not marker.is_file():
        sys.exit('No helper installation found.')
    for label in labels:
        subprocess.run(['/bin/launchctl', 'bootout', 'system/' + label], check=False)
    journal = base / 'awake-sleep-owned'
    if journal.exists():
        subprocess.run(['/usr/bin/pmset', '-a', 'disablesleep', '0'], check=True)
        output = subprocess.check_output(['/usr/bin/pmset', '-g'], text=True)
        fields = [line.split() for line in output.splitlines()]
        if not any(len(row) >= 2 and row[:2] == ['SleepDisabled', '0'] for row in fields):
            sys.exit('Sleep restoration was not verified; helper files were retained.')
        journal.unlink()
    for path in plists:
        path.unlink(missing_ok=True)
    shutil.rmtree(base)
    print('Removed the optional watchdog and verified restoration of its owned sleep setting.')
    sys.exit(0)
if args.user_id is None or args.user_id <= 0:
    sys.exit('Pass --user-id with the non-root user who will run Thermohop.')
user = pwd.getpwuid(args.user_id)
source = pathlib.Path(__file__).resolve().parent.parent / '.build/release/thermohop'
if not source.is_file():
    sys.exit('Build first as your normal user: swift build -c release')
# Changing an existing installation while it owns the global bit is refused.
if (base / 'awake-sleep-owned').exists():
    sys.exit('Stop the closed-lid session and wait for sleep restoration before updating the helper.')
for label in labels:
    subprocess.run(['/bin/launchctl', 'bootout', 'system/' + label], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
base.mkdir(parents=True, exist_ok=True)
os.chown(base, 0, 0); os.chmod(base, 0o755)
lease_dir = base / ('awake-' + str(args.user_id))
if lease_dir.is_symlink():
    sys.exit('Refusing a symbolic link at the lease directory.')
lease_dir.mkdir(exist_ok=True)
os.chown(lease_dir, user.pw_uid, user.pw_gid); os.chmod(lease_dir, 0o700)
(lease_dir / 'lease.json').unlink(missing_ok=True)
binary = base / 'thermohop-awake-helper'
checked_path(binary)
# Unlink first so an old, stopped executable is not modified in place.
binary.unlink(missing_ok=True)
shutil.copyfile(source, binary)
os.chown(binary, 0, 0); os.chmod(binary, 0o755)
marker.write_text('thermohop optional awake helper\n')
os.chown(marker, 0, 0); os.chmod(marker, 0o600)
commands = [['awake', 'sleep-watchdog', '--user-id', str(args.user_id)], ['awake', 'sleep-backstop']]
for label, path, command in zip(labels, plists, commands):
    document = {'Label': label, 'ProgramArguments': [str(binary)] + command,
                'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 1,
                'StandardOutPath': '/dev/null', 'StandardErrorPath': '/dev/null'}
    with path.open('wb') as stream:
        plistlib.dump(document, stream)
    os.chown(path, 0, 0); os.chmod(path, 0o644)
    subprocess.run(['/bin/launchctl', 'bootstrap', 'system', str(path)], check=True)
print('Installed the optional root watchdogs. Sleep settings stay unchanged until an eligible --closed-lid session requests a lease.')
