import Foundation
import CoreWLAN
import ArgumentParser
import Darwin

struct WiFi: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wifi", abstract: "Inspect Wi-Fi, join explicitly, or select only configured profiles.",
        subcommands: [WiFiStatus.self, WiFiScan.self, WiFiSaved.self, WiFiJoin.self,
                      WiFiFallback.self, WiFiReturn.self, WiFiHotspot.self,
                      WiFiSetup.self, Permission.self, Profiles.self, Credential.self])
}

// CoreWLAN's synchronous calls have no cancellation API. Isolate them in a child
// process so the caller's deadline is bounded even if a system service stalls.
func worker(_ operation: String, options: WiFiOptions, ssid: String? = nil,
            allowOpen: Bool = false, timeout: Double? = nil, cancelled: (() -> Bool)? = nil) throws -> [String: Any] {
    if cancelled?() == true { throw Failure(code: 130, message: "Wi-Fi operation cancelled.") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermohop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let outputURL = directory.appendingPathComponent("result.json")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let deadline = ProcessInfo.processInfo.systemUptime + (timeout ?? options.timeout)
    var arguments = ["wifi-worker", "--operation", operation, "--result-path", outputURL.path,
                     "--deadline-uptime", String(deadline)]
    if let name = options.interface { arguments += ["--interface", name] }
    if let ssid { arguments += ["--ssid", ssid] }
    if allowOpen { arguments.append("--allow-open") }
    let launch = try launchWiFiApplication(arguments: arguments, activate: operation == "permissionRequest")
    defer { launch.stop() }
    while cancelled?() != true && ProcessInfo.processInfo.systemUptime < deadline {
        if launch.failed { throw Failure(code: 3, message: "Unable to launch the installed Wi-Fi worker through macOS. Run install.sh and retry.") }
        if let data = try? Data(contentsOf: outputURL),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if result["event"] as? String == "error" {
                throw Failure(code: (result["code"] as? NSNumber)?.int32Value ?? 1,
                              message: result["message"] as? String ?? "Wi-Fi operation failed.")
            }
            return result.filter { $0.key != "schemaVersion" && $0.key != "timestamp" }
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    if cancelled?() == true { throw Failure(code: 130, message: "Wi-Fi operation cancelled; any association already started by macOS may still complete.") }
    throw Failure(code: 5, message: "Wi-Fi operation timed out. If joining, check wifi status before retrying; macOS may have already begun association.")
}

struct WiFiStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Report SSID visibility explicitly; unknown is never treated as disconnected.")
    @OptionGroup var options: WiFiOptions
    func run() throws {
        try perform {
            let result = try worker("status", options: options)
            if let message = result["diagnostic"] as? String { diagnostic(message) }
            emit(result)
        }
    }
}
struct WiFiScan: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scan", abstract: "Discover networks for manual selection; never joins or adds profiles.")
    @OptionGroup var options: WiFiOptions
    func run() throws { try perform { emit(try worker("scan", options: options)) } }
}
struct WiFiSaved: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "saved", abstract: "Read macOS preferred SSIDs; does not import them into the automatic allowlist.")
    @OptionGroup var options: WiFiOptions
    func run() throws { try perform { emit(try worker("saved", options: options)) } }
}
struct WiFiJoin: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "join", abstract: "Explicitly join an exact SSID using a Thermohop Keychain credential.")
    @Argument var ssid: String
    @Flag(help: "Plan only: no scan, Keychain access, or network changes.") var dryRun = false
    @Flag(help: "Permit manually joining an open network. Automatic profile selection never allows open networks.") var allowOpen = false
    @OptionGroup var options: WiFiOptions
    func run() throws {
        try perform {
            try validateSSID(ssid)
            if dryRun {
                emit(["event": "joinPlan", "ssid": ssid, "allowOpen": allowOpen, "dryRun": true,
                      "timeout": options.timeout, "credentialSource": "keychain", "availabilityChecked": false])
            } else { emit(try worker("join", options: options, ssid: ssid, allowOpen: allowOpen)) }
        }
    }
}

func selectProfile(role: Role?, store: StoreOptions, options: WiFiOptions, dryRun: Bool) throws {
    let candidates = orderedProfiles(try readProfiles(store.config), role: role)
    guard !candidates.isEmpty else { throw Failure(code: 6, message: "No configured profiles for this operation. Add profiles explicitly first.") }
    if dryRun {
        emit(["event": "selectionPlan", "profiles": profileObjects(candidates), "dryRun": true,
              "timeout": options.timeout, "availabilityChecked": false])
        return
    }
    let deadline = ProcessInfo.processInfo.systemUptime + options.timeout
    let snapshot = try worker("scan", options: options)
    guard let networks = snapshot["networks"] as? [[String: Any]] else { throw Failure(code: 1, message: "Invalid scan result.") }
    let visible = Set(networks.compactMap { $0["ssid"] as? String })
    var lastFailure: Failure?
    for profile in candidates where visible.contains(profile.ssid) {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Failure(code: 5, message: "Profile selection timed out.") }
        emit(["event": "profileAttempt", "ssid": profile.ssid, "role": profile.role.rawValue])
        do {
            emit(try worker("join", options: options, ssid: profile.ssid, timeout: remaining))
            return
        } catch let failure as Failure {
            // Permission errors and timeouts must never trigger another mutation.
            if failure.code == 4 || failure.code == 5 { throw failure }
            lastFailure = failure
            emit(["event": "profileFailed", "ssid": profile.ssid, "code": failure.code])
        }
    }
    if let lastFailure { throw lastFailure }
    throw Failure(code: 6, message: "No configured candidate is visible. Enable the phone's hotspot manually if needed.")
}
struct WiFiFallback: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fallback", abstract: "Try configured regular profiles by priority, then the configured hotspot; one bounded operation.")
    @OptionGroup var options: WiFiOptions
    @OptionGroup var store: StoreOptions
    @Flag var dryRun = false
    func run() throws { try perform { try selectProfile(role: nil, store: store, options: options, dryRun: dryRun) } }
}
struct WiFiReturn: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "return", abstract: "Join the highest-priority available configured regular network.")
    @OptionGroup var options: WiFiOptions
    @OptionGroup var store: StoreOptions
    @Flag var dryRun = false
    func run() throws { try perform { try selectProfile(role: .regular, store: store, options: options, dryRun: dryRun) } }
}
struct WiFiHotspot: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hotspot", abstract: "Join only the explicitly configured phone hotspot; does not enable the phone's radio.")
    @OptionGroup var options: WiFiOptions
    @OptionGroup var store: StoreOptions
    @Flag var dryRun = false
    func run() throws { try perform { try selectProfile(role: .hotspot, store: store, options: options, dryRun: dryRun) } }
}

func networkSecurity(_ network: CWNetwork) -> String {
    if network.supportsSecurity(.wpa3Personal) { return "wpa3Personal" }
    if network.supportsSecurity(.wpa3Transition) { return "wpa3Transition" }
    if network.supportsSecurity(.wpa2Personal) { return "wpa2Personal" }
    if network.supportsSecurity(.none) { return "open" }
    return "unsupported"
}
func interfaceFor(_ name: String?) throws -> CWInterface {
    let client = CWWiFiClient.shared()
    guard let interface = name.map({ client.interface(withName: $0) }) ?? client.interface() else {
        throw Failure(code: 3, message: "Wi-Fi interface unavailable. Check the interface name and hardware access.")
    }
    return interface
}
func scan(_ interface: CWInterface, name: String? = nil) throws -> [CWNetwork] {
    try requireLocation()
    guard interface.powerOn() else { throw Failure(code: 3, message: "Wi-Fi is powered off; enable it manually.") }
    let results: Set<CWNetwork>
    do { results = try interface.scanForNetworks(withName: name) }
    catch { throw Failure(code: 6, message: "Wi-Fi scan failed. Check Location access and system network restrictions.") }
    guard !results.contains(where: { $0.ssid == nil }) else {
        throw Failure(code: 4, message: "macOS redacted network names. Confirm Location permission for this executable; no selection was made.")
    }
    return results.sorted {
        if $0.rssiValue != $1.rssiValue { return $0.rssiValue > $1.rssiValue }
        if $0.ssid != $1.ssid { return ($0.ssid ?? "") < ($1.ssid ?? "") }
        return ($0.bssid ?? "") < ($1.bssid ?? "")
    }
}

// Internal implementation command. Passwords are read from Keychain in the child,
// never passed in argv, environment, stdout, or a temporary file.
struct WiFiWorker: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "wifi-worker", abstract: "Internal bounded Wi-Fi worker; use wifi commands.", shouldDisplay: false)
    @Option var operation: String
    @Option var interface: String?
    @Option var ssid: String?
    @Flag var allowOpen = false
    @Option var resultPath: String?
    @Option var deadlineUptime: Double?
    func run() throws {
        if let resultPath { try redirectWorkerOutput(resultPath) }
        let remaining = deadlineUptime.map { $0 - ProcessInfo.processInfo.systemUptime } ?? 120
        guard remaining.isFinite, remaining > 0, remaining <= 120 else {
            try perform { throw Failure(code: 5, message: "Wi-Fi worker launch deadline expired or is invalid; no operation was started.") }
            return
        }
        // Also bound direct invocation of this internal command.
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + remaining)
        watchdog.setEventHandler {
            diagnostic("Internal Wi-Fi worker deadline exceeded.")
            Darwin.exit(5)
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        try perform {
            // Resolve Location before asking CoreWLAN for potentially redacted names.
            let location = locationStatus()
            if operation == "permissionStatus" {
                emit(["event": "locationPermission", "location": location]); return
            }
            if operation == "permissionRequest" {
                try requestLocation(timeout: max(0.01, remaining - 0.1)); return
            }
            let iface = try interfaceFor(interface)
            switch operation {
            case "status":
                let visibleSSID = iface.ssid()
                let powered = iface.powerOn()
                let visibility = visibleSSID != nil ? "visible" : (powered ? "unavailable" : "radioOff")
                var result: [String: Any] = ["event": "wifiStatus", "interface": iface.interfaceName ?? "unknown",
                    "powerOn": powered, "ssidVisibility": visibility,
                    "connection": visibleSSID != nil ? "associated" : (powered ? "unknown" : "disconnected"),
                    "location": location, "ssid": visibleSSID.map { $0 as Any } ?? NSNull()]
                if powered && visibleSSID == nil {
                    result["diagnostic"] = location["initialized"] as? Bool == false
                        ? "Location authorization initialization timed out; permission and connection state are unknown."
                        : (location["authorization"] as? String == "authorized"
                            ? "Location access is authorized, but CoreWLAN returned no SSID. macOS may be withholding the name, the interface may be unassociated, or the query may have failed; connection state is unknown."
                            : "SSID unavailable: Location access is not authorized; connection state is unknown.")
                    diagnostic("SSID unavailable; connection state is unknown.")
                }
                emit(result)
            case "saved":
                try requireLocation()
                let profiles = (iface.configuration()?.networkProfiles.array as? [CWNetworkProfile]) ?? []
                guard !profiles.contains(where: { $0.ssid == nil }) else {
                    throw Failure(code: 4, message: "macOS redacted saved network names.")
                }
                emit(["event": "savedNetworks", "ssids": profiles.compactMap(\.ssid).sorted()])
            case "scan":
                let networks = try scan(iface)
                emit(["event": "wifiScan", "networks": networks.map { network in
                    ["ssid": network.ssid!, "rssiDBm": network.rssiValue,
                     "security": networkSecurity(network)] as [String: Any]
                }])
            case "join":
                guard let ssid else { throw Failure(code: 2, message: "An exact SSID is required.") }
                try validateSSID(ssid)
                try requireLocation()
                // A visible current association needs no credential read or mutation.
                if iface.ssid() == ssid {
                    emit(["event": "wifiJoined", "ssid": ssid, "alreadyAssociated": true]); return
                }
                let matches = try scan(iface, name: ssid).filter { $0.ssid == ssid }
                let secure = matches.filter { ["wpa2Personal", "wpa3Personal", "wpa3Transition"].contains(networkSecurity($0)) }
                guard let network = secure.first ?? (allowOpen ? matches.first(where: { networkSecurity($0) == "open" }) : nil) else {
                    throw Failure(code: 6, message: "Exact SSID not visible with supported security. WPA2/WPA3 Personal is supported; open networks require explicit --allow-open.")
                }
                let open = networkSecurity(network) == "open"
                let password = open ? nil : try passwordFor(ssid)
                guard open || password != nil else {
                    throw Failure(code: 7, message: "No Thermohop Keychain credential for this SSID. Use wifi credential set during setup.")
                }
                do { try iface.associate(to: network, password: password) }
                catch { throw Failure(code: 6, message: "Wi-Fi association failed. Check the credential, hotspot availability, and system network restrictions.") }
                // Parent enforces the total deadline while the child verifies association.
                while iface.ssid() != ssid { Thread.sleep(forTimeInterval: 0.1) }
                emit(["event": "wifiJoined", "ssid": ssid, "alreadyAssociated": false])
            default: throw Failure(code: 2, message: "Unknown worker operation.")
            }
        }
    }
}
