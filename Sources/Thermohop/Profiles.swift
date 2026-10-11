import Foundation
import ArgumentParser

struct Profiles: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "profiles", abstract: "Explicit allowlist for regular networks and one phone hotspot.",
        subcommands: [ProfilesList.self, ProfilesAdd.self, ProfilesRemove.self])
}
func profileObjects(_ profiles: [Profile]) -> [[String: Any]] {
    profiles.map { ["ssid": $0.ssid, "role": $0.role.rawValue, "priority": $0.priority] }
}
struct ProfilesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list")
    @OptionGroup var store: StoreOptions
    func run() throws { try perform { emit(["event": "profiles", "profiles": profileObjects(orderedProfiles(try readProfiles(store.config)))]) } }
}
struct ProfilesAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add or update an allowed network; lower priority wins. Does not join it.")
    @Argument var ssid: String
    @Option var role: Role = .regular
    @Option var priority: Int = 100
    @Flag var dryRun = false
    @OptionGroup var store: StoreOptions
    func run() throws {
        try perform {
            try validateSSID(ssid)
            var file = try readProfiles(store.config)
            file.profiles.removeAll { $0.ssid == ssid }
            guard role != .hotspot || !file.profiles.contains(where: { $0.role == .hotspot }) else {
                throw Failure(code: 2, message: "Remove the existing hotspot profile before configuring another.")
            }
            file.profiles.append(Profile(ssid: ssid, role: role, priority: priority))
            if !dryRun { try writeProfiles(file, to: store.config) }
            emit(["event": dryRun ? "profilesPlan" : "profilesUpdated", "profiles": profileObjects(orderedProfiles(file))])
        }
    }
}
struct ProfilesRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an allowlist entry; its Keychain password is retained.")
    @Argument var ssid: String
    @Flag var dryRun = false
    @OptionGroup var store: StoreOptions
    func run() throws {
        try perform {
            try validateSSID(ssid)
            var file = try readProfiles(store.config)
            file.profiles.removeAll { $0.ssid == ssid }
            if !dryRun { try writeProfiles(file, to: store.config) }
            emit(["event": dryRun ? "profilesPlan" : "profilesUpdated", "profiles": profileObjects(orderedProfiles(file))])
        }
    }
}
