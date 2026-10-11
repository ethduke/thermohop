Thermohop 0.1.0
===============
A small macOS CLI for OS thermal pressure and explicit Wi-Fi profile switching.
Swift Package Manager + Apple's ArgumentParser; Foundation, CoreWLAN,
CoreLocation, Security and LocalAuthentication. Requires macOS 13 or later and
a Swift 5.9+ toolchain. Works on macOS 15.6.1 / Apple silicon without an OS upgrade.

Build and initial setup
-----------------------
    swift build -c release
    .build/release/thermohop --help

For a stable Location privacy identity, optionally run ./install.sh. This builds
and installs a CLI-only, ad-hoc signed Thermohop.app in ~/Applications, plus a
symlink in ~/.local/bin. It has no window, GUI, menu bar item, or background daemon.
Override THERMOHOP_INSTALL_DIR and THERMOHOP_BIN_DIR to choose install directories.
The installer refuses to replace unrelated files. Add ~/.local/bin to PATH.

    thermohop wifi permission status
    thermohop wifi permission request --timeout 30

The request command is initial setup and may trigger a macOS system prompt.
Enable Location Services in System Settings > Privacy & Security > Location
Services and allow Thermohop if listed. Invoke the installed bundle executable
via the symlink rather than repeatedly running different build paths. A standalone
command-line process can fail to receive the Location prompt on some macOS/TCC
configurations, even with an embedded usage description. The CLI-only bundle is
the supported setup route to try; it cannot bypass TCC or guarantee a prompt.
If access remains unavailable, status and dry-run still work but scan/join stop
with exit 4. Do not use sudo or reset global TCC settings as a workaround.
Rebuilding or replacing the ad-hoc signed executable can require authorization
again. A distributed Developer ID signed/notarized build is not included.

macOS hides Wi-Fi names without Location permission. A powered-on interface with
no visible SSID reports connection "unknown", ssid null, and ssidVisibility
"unavailable". This does not prove disconnection. Radio-off status can explicitly
report disconnection. Ordinary commands never ask for Location permission.

Thermal commands
----------------
    thermohop thermal status
    thermohop thermal watch --duration 60 --interval 2 --threshold serious
    thermohop thermal guard --duration 300 --threshold serious

Pressure is nominal / fair / serious / critical, from ProcessInfo.thermalState.
It is not degrees Celsius. Watch emits an initial thermalState, changes,
thresholdReached on entry (including the initial sample), thresholdCleared on
recovery, and watchCompleted at the end. Watch with --exit-on-threshold, or guard,
exits 10 as soon as the sampled pressure meets/exceeds the threshold. Short spikes
between samples can be missed. Duration is bounded to 86400 seconds, interval to
60 seconds. Normal duration expiry exits 0. Unknown future OS pressure values are
conservatively treated as critical. Run guard with --threshold nominal for an
immediate threshold event regardless of the current pressure.

Guard only reports and returns a status to its caller. No global sleep assertion
cutoff, power setting changes, process killing, or keep-awake session ownership is
implemented. Any future cutoff must target an explicitly owned/configured session.

Wi-Fi discovery and manual joining
----------------------------------
    thermohop wifi status --timeout 20
    thermohop wifi scan --timeout 20
    thermohop wifi saved --timeout 20
    thermohop wifi join 'Example network' --dry-run
    thermohop wifi join 'Example network' --timeout 30

--interface selects a specific CoreWLAN interface. Scan discovers networks for
manual selection only and may list several access points for an SSID. No BSSIDs
are printed. saved reads macOS's preferred profile names without importing them
into Thermohop's allowlist. These names do not imply a usable password.

join requires an exact 1-32-byte UTF-8 SSID and a visible matching access point.
WPA2/WPA3 Personal is supported. Enterprise, WEP, legacy WPA-only, hidden networks,
and OWE are deferred. Open networks require explicit manual join --allow-open;
automatic profile selection never permits joining open networks. For matching
access points, prefer supported Personal security, then strongest signal. SSIDs
are not cryptographic network identities; this is not protection against spoofing.
An already-associated exact SSID is returned without mutation or credential access.

Credentials
-----------
Passwords are stored as generic password items in the user's Keychain, service
io.thermohop.wifi, account = exact SSID. Thermohop does not scrape macOS's existing
Wi-Fi passwords; configure a credential once for each protected profile. Use a
password manager's secret-output command piped directly into:

    thermohop wifi credential set 'Example network'
    thermohop wifi credential delete 'Example network' --dry-run

set reads stdin until EOF with a 10-second deadline and 4096-byte limit, removing
one final newline/CRLF. Terminal stdin is refused. Never place a password in argv,
a configuration file, shell history, an environment variable, or a log. Passwords
are never printed or passed to child processes in arguments or environment.
Keychain operations disallow authentication interaction; locked/inaccessible items
fail with exit 7. Unlock/authorize the item's access during initial setup if needed.
Credentials are device-local and available only while the Keychain is unlocked.
The credential commands support --dry-run and do not read stdin/Keychain then.

Configured fallback and return
------------------------------
    thermohop wifi profiles add 'Example home' --role regular --priority 10
    thermohop wifi profiles add 'Example office' --role regular --priority 20
    thermohop wifi profiles add 'Example phone' --role hotspot
    thermohop wifi profiles list
    thermohop wifi fallback --dry-run
    thermohop wifi hotspot --dry-run
    thermohop wifi return --dry-run

Remove --dry-run to perform an intentional switch. fallback discovers candidates
once, then rescans each exact SSID before joining. It tries visible configured
regular profiles in ascending priority, then the one
configured hotspot. Equal priorities use SSID order. Failed associations or missing
credentials can move to the next candidate. Permission failure or timeout stops
immediately to avoid another mutation while the result is uncertain. return tries
regular profiles only; hotspot tries the configured hotspot only. return chooses
priority order, rather than remembering the network used before the hotspot.
All candidates must be explicitly configured; discovered public networks and the
macOS preferred list never become automatic fallback candidates.

Profiles are nonsecret names/roles/priorities in:
    ~/Library/Application Support/Thermohop/profiles.json
Override with --config on profiles/fallback/return/hotspot. Writes are atomic and
mode 0600; newly created directories are mode 0700. Do not modify profiles
concurrently. At most one hotspot and no duplicate SSIDs are accepted. add updates
an existing SSID. profiles remove retains its Keychain credential; delete it
separately if needed. These profiles do not alter macOS's preferred-network list.

Dry-run validates arguments and profiles and reports the intended plan without
scanning, checking availability, reading credentials, or altering network state.
It is not evidence that a future real join will succeed. These commands also do
not turn on Wi-Fi or enable a phone hotspot. Enable Personal Hotspot on the phone
manually; Instant Hotspot activation/pairing is deferred.

There is no background connection-health monitor, automatic return daemon,
Internet/captive-portal check, or automatic rollback. Successful join means Wi-Fi
association with the requested SSID, not Internet reachability. OS auto-join policy
and other apps can still change networks independently.

Output and exit codes
---------------------
Successful data commands emit one JSON object per line on stdout; watch and
selection commands emit JSONL events. Every data event has schemaVersion 1 and
an ISO-8601 UTC timestamp. Field/event names are stable within schema version 1;
additional fields may be added. Consumers should ignore unknown fields. Status
ssid is a string or null. Human help/version text and ArgumentParser syntax
errors follow the parser's standard format; syntax errors are not JSON.

Runtime failures emit an error event (code/message) plus a generic diagnostic on
stderr. Framework error descriptions are suppressed to avoid leaking credentials
or personal identifiers. Status can return 0 with an explicit visibility warning.
JSON includes network names for its purpose; avoid publishing local output logs.

    0   Completed successfully (or a thermal observation duration expired)
    1   Unexpected/internal or filesystem failure
    2   Invalid profile/configuration/SSID/credential input
    3   Wi-Fi interface unavailable or powered off
    4   Location permission unavailable or names redacted
    5   Operation/input deadline exceeded; outcome may be uncertain
    6   No configured/visible usable candidate, scan or association failure
    7   Keychain credential missing, inaccessible, or storage failure
    10  Thermal threshold reached
    64  ArgumentParser syntax/argument validation error

Wi-Fi --timeout must be >0 and <=120 seconds. CoreWLAN scan/join calls run in an
isolated child because Apple's synchronous API has no cancellation/deadline
parameter. The parent kills a stalled worker at the deadline. Timeout cannot undo
an association already handed to macOS: check status before retrying. fallback's
single total deadline includes scanning and all attempts. The hidden wifi-worker
command is an implementation detail, with its own 120-second safety watchdog;
use the public wifi commands for configurable deadlines.

Verification scope
------------------
Initial verification targets macOS 15.6.1 on an M1 Max: release build, read-only
thermal/permission/Wi-Fi status, permission-denied scan behavior, bounded watch,
threshold exit, parser/configuration errors, and disposable dry-run profile plans.
No real join, Keychain password write, Location grant, power change, or phone change
is required for smoke verification. Live authorized scan/association and credential
access must be validated after the owner completes initial permission setup.

References
----------
https://github.com/apple/swift-argument-parser
https://developer.apple.com/documentation/corewlan
https://developer.apple.com/forums/thread/732431
https://developer.apple.com/documentation/corelocation
https://developer.apple.com/documentation/foundation/processinfo/thermalstate
