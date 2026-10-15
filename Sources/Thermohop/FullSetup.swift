import Foundation
import ArgumentParser
import Darwin

func fullSetupPolicy(probeURL: String = "https://example.com") throws -> AgentPolicy {
    var policy = AgentPolicy()
    policy.awake.closedLid = true
    policy.wifi.enabled = true
    policy.wifi.requiredHealth = .internet
    var probe = HealthProbe()
    probe.url = probeURL
    policy.wifi.probes = [probe]
    try policy.validate()
    return policy
}

func isFullSetupPolicy(_ policy: AgentPolicy) -> Bool {
    policy.awake.enabled && policy.awake.closedLid && policy.effectiveThermal.enabled
        && policy.effectiveThermal.pauseAt.rank <= 2 && policy.wifi.enabled
        && policy.wifi.requiredHealth == .internet
}

// Reruns preserve a valid existing policy, including custom process selectors,
// probe endpoints and timings. Replacement is always explicit.
func saveSetupPolicy(_ policy: AgentPolicy, path: String, replace: Bool) throws {
    var info = stat()
    if lstat(path, &info) == 0 {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw Failure(code: 2, message: "Setup policy must be a regular file owned by you; links are refused.")
        }
        if !replace {
            guard isFullSetupPolicy(try loadPolicy(path)) else {
                throw Failure(code: 2, message: "Existing policy was preserved. Use setup --replace-policy to write the full-setup preset.")
            }
            return
        }
    } else if errno != ENOENT { throw Failure(code: 2, message: "Setup policy is not accessible.") }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(policy).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

func setupApplication() -> (binary: URL, installer: URL)? {
    guard let binary = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let root = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard root.pathExtension == "app", let bundle = Bundle(url: root), bundle.bundleIdentifier == "io.thermohop.cli",
          bundle.executableURL?.resolvingSymlinksInPath() == binary else { return nil }
    let installer = root.appendingPathComponent("Contents/Resources/install-awake-helper.py")
    guard FileManager.default.fileExists(atPath: installer.path) else { return nil }
    return (binary, installer)
}

// Fixed local setup tools only; suppress their diagnostics because frameworks
// and AppleScript may include personal paths. No password is handled here.
func setupProcess(_ executable: String, _ arguments: [String], timeout: Double,
                  capture: Bool = false) throws -> (code: Int32, output: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    let pipe = capture ? Pipe() : nil
    if let pipe { process.standardOutput = pipe }
    else { process.standardOutput = FileHandle.nullDevice }
    try process.run()
    let expiry = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: expiry)
    defer { expiry.cancel() }
    let output = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

func setupJobIdentity(_ text: String, executable: String) -> Bool {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    return lines.contains("state = running") && lines.contains("program = " + executable)
        && lines.contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 3 && fields[0] == "pid" && fields[1] == "=" && (Int32(fields[2]) ?? 0) > 0
        }
}

func setupJobRunning(_ label: String, executable: String, arguments: [String]) -> Bool {
    guard let data = protectedRead("/Library/LaunchDaemons/" + label + ".plist", owner: 0),
          let document = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          document["Label"] as? String == label,
          document["ProgramArguments"] as? [String] == [executable] + arguments else { return false }
    guard let result = try? setupProcess("/bin/launchctl", ["print", "system/" + label], timeout: 3, capture: true),
          result.code == 0, result.output.count <= 65536,
          let text = String(data: result.output, encoding: .utf8) else { return false }
    return setupJobIdentity(text, executable: executable)
}

// The installer deliberately makes this marker root-readable only. Its trusted
// metadata can be inspected without opening it or requesting administrator access.
func setupInstallationMarker(_ path: String, owner: UInt32 = 0) -> Bool {
    var marker = stat()
    return lstat(path, &marker) == 0 && marker.st_uid == owner && marker.st_mode & S_IFMT == S_IFREG
        && marker.st_nlink == 1 && marker.st_mode & 0o777 == 0o600
        && marker.st_size == Data("thermohop optional awake helper\n".utf8).count
}

func setupHeartbeatReady(_ status: [String: Any], uid: UInt32, now: Double) -> Bool {
    // Existing watchdogs use lease protocol 1 without an explicit version field.
    // App-only updates need not replace an otherwise compatible root helper.
    guard (status["protocolVersion"] as? Int ?? 1) == 1,
          ((status["uid"] as? NSNumber)?.uint32Value ?? UInt32.max) == uid,
          status["active"] is Bool, status["sleepRestored"] is Bool, status["token"] is String,
          let cutoff = status["cutoffLevel"] as? Int, (1...2).contains(cutoff),
          let expires = status["expires"] as? Double, expires.isFinite,
          let uptime = status["uptime"] as? Double, uptime.isFinite,
          uptime <= now, now - uptime < 3 else { return false }
    return true
}

func setupWatchdogReady(application: (binary: URL, installer: URL)?) -> Bool {
    guard application != nil else { return false }
    let root = "/Library/Application Support/Thermohop"
    var parent = stat(), directory = stat(), binary = stat()
    let helper = root + "/thermohop-awake-helper"
    guard lstat(root, &parent) == 0, parent.st_uid == 0, parent.st_mode & S_IFMT == S_IFDIR,
          parent.st_mode & 0o022 == 0,
          setupInstallationMarker(root + "/awake-helper-install-marker"),
          lstat(root + "/awake-\(getuid())", &directory) == 0,
          directory.st_uid == getuid(), directory.st_mode & S_IFMT == S_IFDIR, directory.st_mode & 0o777 == 0o700,
          lstat(helper, &binary) == 0, binary.st_uid == 0, binary.st_mode & S_IFMT == S_IFREG,
          binary.st_nlink == 1, binary.st_mode & 0o022 == 0, binary.st_mode & 0o111 != 0,
          let heartbeat = protectedRead(root + "/awake-status.json", owner: 0),
          let status = try? JSONSerialization.jsonObject(with: heartbeat) as? [String: Any],
          setupHeartbeatReady(status, uid: getuid(), now: ProcessInfo.processInfo.systemUptime) else { return false }
    return setupJobRunning("io.thermohop.awake", executable: helper,
                           arguments: ["awake", "sleep-watchdog", "--user-id", String(getuid())])
        && setupJobRunning("io.thermohop.awake-backstop", executable: helper, arguments: ["awake", "sleep-backstop"])
}

struct SetupReadiness {
    var policyReady = false
    var installedApp = false
    var credentialsReady = false
    var locationReady = false
    var watchdogReady = false
    var network: [String: Bool] = [:]

    var ready: Bool { policyReady && installedApp && credentialsReady && locationReady && watchdogReady }
    var nextSteps: [String] {
        var result: [String] = []
        if !installedApp { result.append("Run ./install.sh to install the CLI and bundled setup helper.") }
        if !policyReady { result.append("Run thermohop setup to create or validate the policy.") }
        if !credentialsReady { result.append("Run thermohop setup in your own terminal for SSIDs and hidden password entry; never send passwords to an agent.") }
        if !locationReady { result.append("Allow Thermohop Location access during setup so macOS exposes Wi-Fi names.") }
        if !watchdogReady { result.append("Complete setup's macOS administrator prompt to install or update the two watchdogs.") }
        if network["ready"] == false { result.append("Connect to an allowed WPA2/WPA3 network, enable the phone hotspot and check Internet access, then rerun setup.") }
        return result
    }
    var fields: [String: Any] {
        ["event": "setupStatus", "ready": ready, "policyReady": policyReady, "installedApp": installedApp,
         "credentialsReady": credentialsReady, "credentialSource": "keychain", "locationReady": locationReady,
         "watchdogReady": watchdogReady, "networkChecked": !network.isEmpty, "network": network,
         "networkAccessVerified": network["ready"] == true, "supervisionStarted": false,
         "humanInputRequired": !credentialsReady || !locationReady || !watchdogReady,
         "nextSteps": nextSteps]
    }
}

func setupCredentialsReady(_ profiles: [Profile]) -> Bool {
    profiles.contains(where: { $0.role == .regular }) && profiles.contains(where: { $0.role == .hotspot })
        && profiles.allSatisfy { credentialState($0.ssid) == "stored" }
}

func setupProfiles(regular: String?, hotspot: String?, path: String) throws {
    guard regular != nil || hotspot != nil else { return }
    var file = try readProfiles(path)
    if let regular { try validateSSID(regular) }
    if let hotspot { try validateSSID(hotspot) }
    guard regular == nil || regular != hotspot else { throw Failure(code: 2, message: "Router and hotspot must have different SSIDs.") }
    if let hotspot, file.profiles.contains(where: { $0.role == .hotspot && $0.ssid != hotspot }) {
        throw Failure(code: 2, message: "Remove the existing hotspot before configuring a different one.")
    }
    for (name, role, priority) in [(regular, Role.regular, 10), (hotspot, Role.hotspot, 100)] {
        guard let name else { continue }
        let previous = file.profiles.first { $0.ssid == name && $0.role == role }
        file.profiles.removeAll { $0.ssid == name }
        file.profiles.append(Profile(ssid: name, role: role, priority: previous?.priority ?? priority))
    }
    guard file.profiles.contains(where: { $0.role == .regular }), file.profiles.contains(where: { $0.role == .hotspot }) else {
        throw Failure(code: 2, message: "Supply both router and hotspot names for initial noninteractive setup.")
    }
    try writeProfiles(file, to: path)
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Set up closed-lid, thermal and Wi-Fi supervision; macOS authorization and hidden passwords stay local.")
    @Option(help: "Policy to create or reuse; contains no passwords.") var policy = "policy.json"
    @OptionGroup var store: StoreOptions
    @Flag(help: "Read-only JSON readiness; no dialogs, scans, probes or changes.") var status = false
    @Flag(help: "Print the setup plan only; no files, Keychain access or system changes.") var dryRun = false
    @Flag(help: "Agent mode: never read terminal input; reuse existing credentials and report remaining human steps.") var nonInteractive = false
    @Flag(help: "Allow native Location/admin dialogs in agent mode after the user has authorized setup; never reads a password.") var authorize = false
    @Flag(help: "Explicitly replace an existing policy with the full-setup preset.") var replacePolicy = false
    @Option(help: "Router SSID; omitted names are requested in the local wizard.") var regular: String?
    @Option(help: "Phone hotspot SSID.") var hotspot: String?
    @Option(help: "Internet HEAD probe endpoint (expected HTTP 200); default https://example.com.") var probeURL: String?

    mutating func validate() throws {
        guard !policy.isEmpty, !policy.contains("\0"),
              !(status && (dryRun || authorize || replacePolicy || regular != nil || hotspot != nil || probeURL != nil)) else {
            throw ValidationError("Use --status without setup actions.")
        }
    }

    func readiness() -> SetupReadiness {
        let app = setupApplication()
        let profiles = (try? readProfiles(store.config).profiles) ?? []
        var result = SetupReadiness()
        result.policyReady = (try? loadPolicy(policy)).map(isFullSetupPolicy) ?? false
        result.installedApp = app != nil
        result.credentialsReady = setupCredentialsReady(profiles)
        if let options = try? WiFiOptions.parse([]), let response = try? worker("permissionStatus", options: options) {
            let location = response["location"] as? [String: Any]
            result.locationReady = location?["authorization"] as? String == "authorized"
                && location?["servicesEnabled"] as? Bool == true && location?["initialized"] as? Bool == true
        }
        result.watchdogReady = setupWatchdogReady(application: app)
        return result
    }

    func run() throws {
        var incomplete = false
        try perform(jsonOutput: status || dryRun || nonInteractive) {
            if status { emit(readiness().fields); return }
            let preset = try fullSetupPolicy(probeURL: probeURL ?? "https://example.com")
            if let regular { try validateSSID(regular) }
            if let hotspot { try validateSSID(hotspot) }
            if dryRun {
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset))
                emit(["event": "setupPlan", "policy": encoded, "requiresAdministrator": true,
                      "watchdogs": 2, "passwordStorage": "keychain", "supervisionStarted": false,
                      "permissionDialogs": false, "networkChanges": false]); return
            }
            guard getuid() > 0, geteuid() == getuid() else {
                throw Failure(code: 3, message: "Run setup as your normal user; macOS handles administrator authentication separately.")
            }
            if !nonInteractive {
                guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
                    throw Failure(code: 2, message: "Run setup in your local terminal, or use --non-interactive for an agent.")
                }
                guard setupApplication() != nil else {
                    throw Failure(code: 4, message: "Install Thermohop first with ./install.sh, then run thermohop setup.")
                }
                diagnostic("Setup enables closed-lid, thermal and Wi-Fi policy. macOS will explain the two administrator watchdogs; Wi-Fi passwords stay in Keychain. Supervision starts only when you run supervise.")
            }
            try saveSetupPolicy(preset, path: policy, replace: replacePolicy)
            if nonInteractive { try setupProfiles(regular: regular, hotspot: hotspot, path: store.config) }
            var current = readiness()
            let mayAuthorize = !nonInteractive || authorize
            if mayAuthorize && !current.locationReady {
                diagnostic("Allow Location access in the macOS dialog so Thermohop can read Wi-Fi names.")
                var options = try WiFiOptions.parse([]); options.timeout = 30
                _ = try? worker("permissionRequest", options: options)
            }
            if mayAuthorize && !current.watchdogReady, let app = setupApplication() {
                diagnostic("Approve the macOS dialog to install the two sleep-restoration watchdogs; setup itself does not disable sleep.")
                _ = try? setupProcess("/usr/bin/python3", [app.installer.path, "--gui", "--binary", app.binary.path], timeout: 180)
                // Give newly bootstrapped jobs time to publish their first heartbeat.
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while ProcessInfo.processInfo.systemUptime < deadline && !setupWatchdogReady(application: app) {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            let profiles = try readProfiles(store.config).profiles
            if !nonInteractive && (!setupCredentialsReady(profiles) || regular != nil || hotspot != nil) {
                var wizard = try WiFiSetup.parse([])
                wizard.store = store
                wizard.regular = regular ?? orderedProfiles(ProfileFile(profiles: profiles), role: .regular).first?.ssid
                wizard.hotspot = hotspot ?? profiles.first(where: { $0.role == .hotspot })?.ssid
                try wizard.configure(report: false)
            }
            current = readiness()
            if current.ready {
                let profiles = try readProfiles(store.config).profiles
                let networkPolicy = try loadPolicy(policy).wifi
                let options = try WiFiOptions.parse([])
                let observation = try? worker("status", options: options)
                let networks = (try? worker("scan", options: options))?["networks"] as? [[String: Any]] ?? []
                let secure = Set(networks.filter {
                    ["wpa2Personal", "wpa3Personal", "wpa3Transition"].contains($0["security"] as? String ?? "")
                }.compactMap { $0["ssid"] as? String })
                let ssid = observation?["ssid"] as? String
                let associated = observation?["powerOn"] as? Bool == true && ssid.map { secure.contains($0) } == true
                let configured = ssid.map { name in profiles.contains { $0.ssid == name } } ?? false
                let hotspotVisible = profiles.contains { $0.role == .hotspot && secure.contains($0.ssid) }
                let healthy = checkHealth(associated: associated && configured, policy: networkPolicy, cancellation: Cancellation(), budget: 5).healthy(.internet)
                current.network = ["currentNetworkAllowed": associated && configured, "hotspotVisible": hotspotVisible,
                                   "internetHealthy": healthy, "ready": associated && configured && hotspotVisible && healthy]
            }
            if nonInteractive { emit(current.fields) }
            else {
                let lines = ["Thermohop setup: \(current.ready ? "configuration ready" : "needs local action")",
                             "Policy: \(current.policyReady ? "ready" : "needs setup")",
                             "Wi-Fi credentials: \(current.credentialsReady ? "stored in Keychain" : "needs setup")",
                             "Location access: \(current.locationReady ? "authorized" : "needs setup")",
                             "Sleep watchdogs: \(current.watchdogReady ? "installed and running" : "needs setup")"]
                for line in lines + current.nextSteps { diagnostic(line) }
                if current.ready { diagnostic("Next: thermohop supervise --policy \(policy == "policy.json" ? "policy.json" : "<your-policy>")") }
            }
            incomplete = !current.ready || current.network["ready"] == false
        }
        if incomplete { throw ExitCode(2) }
    }
}
