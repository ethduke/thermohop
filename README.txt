Thermohop
=========
A macOS CLI that gives agents structured thermal and Wi-Fi tools. An agent can
read the Mac's state, preview a network switch, run an explicit action, and use
JSON events and exit codes to decide what to do next. Routine commands are
noninteractive, Wi-Fi waits are bounded, and passwords stay in Keychain.
Thermohop itself has no reasoning loop or background autonomous agent.

Build
-----
Requires macOS 13+ and Swift 5.9+. Supports macOS 15.6.1 on Apple silicon.
    swift build -c release
    .build/release/thermohop --help

Run ./install.sh for live Wi-Fi and permission commands. It installs a CLI-only
app bundle in ~/Applications and a symlink in ~/.local/bin; no GUI. Thermal
commands also work directly from the build tree. Commands below assume that bin
directory is on PATH.

Agent workflow
--------------
    thermohop thermal status
    thermohop thermal watch --duration 60 --threshold serious
    thermohop thermal guard --duration 300 --threshold serious
    thermohop wifi status
    thermohop wifi scan
    thermohop wifi join 'Example network' --dry-run

Thermal commands read macOS's ProcessInfo.thermalState, not sensor temperatures:
    nominal   Normal thermal conditions.
    fair      Slightly elevated thermal pressure.
    serious   High thermal pressure.
    critical  Thermal pressure significantly affects performance; cooling needed.

status emits one JSON snapshot. watch samples pressure and emits JSONL on changes
and threshold crossings. guard exits 10 when pressure meets or exceeds the chosen
threshold (for example, serious includes critical), or 0 when its duration expires.
It does not stop workloads or disable sleep assertions; the calling agent decides
how to respond. Brief spikes between samples can be missed.
State definitions: https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum

Wi-Fi status reports the interface and visible connection state. scan discovers
networks for manual selection. join connects to an exact SSID through CoreWLAN,
using its Thermohop Keychain password, then verifies association with that SSID.
Configure the automatic allowlist explicitly:
    thermohop wifi profiles add 'Example home' --role regular --priority 10
    thermohop wifi profiles add 'Example phone' --role hotspot
    thermohop wifi fallback --dry-run
    thermohop wifi hotspot --dry-run
    thermohop wifi return --dry-run

fallback tries configured regular networks by priority, then the configured
hotspot. return tries regular profiles only. Remove --dry-run for an intentional
switch. Dry-run does not scan, access credentials, or verify availability.
Public discoveries and macOS saved networks never enter the allowlist implicitly.
Profiles contain names/roles/priorities only, under
~/Library/Application Support/Thermohop/profiles.json; --config overrides the path.

Initial permission and credential setup
--------------------------------------
macOS requires Location access to reveal SSIDs:
    thermohop wifi permission status
    thermohop wifi permission request --timeout 30

The request may show a system prompt. Enable Location Services in System Settings
> Privacy & Security and allow Thermohop if listed. Wi-Fi workers and permission
setup launch through macOS Launch Services using the registered app identity.
A shell-spawned executable can report authorized while CoreWLAN checks a different
identity and redacts SSIDs. The installed bundle is registered automatically;
there is no persistent background service. Ad-hoc signing means replacing a build
may require authorization again. Test permission status, wifi status and wifi scan
without reinstalling between them; authorization alone does not prove SSID access.
Missing access returns exit 4. An unavailable SSID is reported as unknown
connection state, never silently treated as disconnected.
Each process waits up to two seconds for Location's initial authorization callback
before reading Wi-Fi names. location.initialized distinguishes a completed check
from initialization timeout (authorization unknown); required access checks return
exit 5 on that timeout instead of misreporting permission as notDetermined.

Pipe a password manager's secret output into:
    thermohop wifi credential set 'Example home'

No password arguments: set reads piped stdin through EOF, with a 10-second limit.
Credentials use Thermohop's device-local Keychain items, not configuration files
or imported macOS Wi-Fi passwords. Locked/inaccessible credentials return exit 7.
Enable the phone hotspot manually before switching.

Agent output and limits
-----------------------
Data commands emit JSON/JSONL with schemaVersion 1 and UTC timestamps. Runtime
errors include code/message; diagnostics go to stderr. Help and parser errors are
plain text. Exit codes: 0 success, 1 internal/filesystem, 2 invalid input/config,
3 Wi-Fi unavailable, 4 permission, 5 timeout, 6 no usable network/association
failure, 7 Keychain failure, 10 thermal threshold, 64 argument syntax/validation.

Wi-Fi --timeout is >0 and <=120 seconds. Launch and operation share that deadline;
the launched worker instance is terminated on timeout or cancellation. Results
use a private temporary file; passwords never enter it or launch arguments. A timeout can leave association already
started by macOS; recheck status before retrying. Join supports WPA2/WPA3 Personal;
open networks need explicit join --allow-open and are excluded from fallback.
Successful association does not prove Internet access. Background monitoring,
automatic return, Instant Hotspot activation, enterprise/hidden networks, and
keep-awake cutoff are deferred. See each command's --help for options.
