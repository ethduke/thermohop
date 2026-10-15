import Foundation
import ArgumentParser

struct WiFiSetup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup",
        abstract: "Set up router/hotspot profiles and hidden Keychain passwords in a local terminal; --status is read-only for agents.")
    @Flag(help: "Report profile/credential readiness as JSON without prompts, secrets, scans or network changes.") var status = false
    @Option(help: "Exact router SSID; otherwise ask interactively.") var regular: String?
    @Option(help: "Exact phone hotspot SSID; otherwise ask interactively.") var hotspot: String?
    @OptionGroup var store: StoreOptions

    func run() throws {
        try perform {
            guard !status || (regular == nil && hotspot == nil) else {
                throw Failure(code: 2, message: "Use --status without --regular or --hotspot.")
            }
            if status { try reportStatus(); return }
            try configure()
        }
    }

    func configure(report: Bool = true) throws {
        try requireSetupTerminal()
        var file = try readProfiles(store.config)
        diagnostic("Wi-Fi setup stores passwords in this Mac's Keychain, never in profiles or logs. It does not join networks or enable Wi-Fi supervision.")
        let router = try name(regular, prompt: "Router SSID: ")
        let phone = try name(hotspot, prompt: "Phone hotspot SSID: ")
        guard router != phone else { throw Failure(code: 2, message: "Router and hotspot must have different SSIDs.") }
        guard !file.profiles.contains(where: { $0.role == .hotspot && $0.ssid != phone }) else {
            throw Failure(code: 2, message: "Remove the existing hotspot profile before configuring another.")
        }
        let targets = [(router, Role.regular, 10), (phone, Role.hotspot, 100)]
        for (ssid, role, defaultPriority) in targets {
            let state = credentialState(ssid)
            guard state != "unavailable" else {
                throw Failure(code: 7, message: "Keychain credential metadata is unavailable. Unlock/authorize Keychain locally, then retry setup.")
            }
            if state == "stored" {
                diagnostic("Keeping the stored \(role.rawValue) password; use wifi credential set --prompt to replace it.")
            } else {
                var data = try terminalInput("\(role.rawValue) Wi-Fi password: ", hidden: true)
                defer { data.resetBytes(in: 0..<data.count) }
                try storePassword(data, for: ssid)
                if report { emit(["event": "credentialStored", "ssid": ssid]) }
            }
            let priority = file.profiles.first(where: { $0.ssid == ssid && $0.role == role })?.priority ?? defaultPriority
            file.profiles.removeAll { $0.ssid == ssid }
            file.profiles.append(Profile(ssid: ssid, role: role, priority: priority))
            // Persist each completed entry: cancellation leaves resumable setup.
            try writeProfiles(file, to: store.config)
        }
        if report {
            try reportStatus()
            diagnostic("Next: verify wifi permission status, wifi status and wifi scan; enable the phone hotspot manually. Configure wifi.enabled and health probes in your policy before supervision.")
        }
    }

    private func name(_ supplied: String?, prompt: String) throws -> String {
        let value: String
        if let supplied { value = supplied }
        else {
            let data = try terminalInput(prompt, hidden: false)
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw Failure(code: 2, message: "SSID must be UTF-8.")
            }
            value = decoded
        }
        try validateSSID(value)
        return value
    }

    private func reportStatus() throws {
        let profiles = orderedProfiles(try readProfiles(store.config))
        var entries = [[String: Any]]()
        var ready = profiles.contains(where: { $0.role == .regular }) && profiles.contains(where: { $0.role == .hotspot })
        for profile in profiles {
            let state = credentialState(profile.ssid)
            ready = ready && state == "stored"
            entries.append(["ssid": profile.ssid, "role": profile.role.rawValue,
                            "priority": profile.priority, "credential": state])
        }
        emit(["event": "wifiSetupStatus", "config": store.config, "profiles": entries,
              "credentialsReady": ready, "humanInputRequired": !ready,
              "credentialSource": "keychain", "networkAccessVerified": false,
              "nextSteps": ready ? ["wifi permission status", "wifi status", "wifi scan", "Configure wifi.enabled and health probes in the supervisor policy"] : ["Run thermohop wifi setup in a local terminal; do not send passwords to the agent"]])
    }
}
