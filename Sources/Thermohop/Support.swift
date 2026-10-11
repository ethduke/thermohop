import Foundation
import ArgumentParser
import Darwin

struct Failure: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { message }
}

func diagnostic(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func emit(_ fields: [String: Any]) {
    var object = fields
    object["schemaVersion"] = 1
    object["timestamp"] = ISO8601DateFormatter().string(from: Date())
    // All callers supply JSON primitives only.
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else {
        diagnostic("Unable to encode output.")
        Darwin.exit(1)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func perform(_ body: () throws -> Void) throws {
    do { try body() }
    catch let error as Failure {
        emit(["event": "error", "code": error.code, "message": error.message])
        diagnostic(error.message)
        throw ExitCode(error.code)
    } catch {
        // Framework errors can contain personal identifiers; keep diagnostics generic.
        emit(["event": "error", "code": 1, "message": "Operation failed."])
        diagnostic("Operation failed.")
        throw ExitCode(1)
    }
}

func validateSeconds(_ value: Double, max: Double = 3600) throws {
    guard value.isFinite, value > 0, value <= max else {
        throw ValidationError("Time must be greater than zero and at most \(Int(max)) seconds.")
    }
}

func validateSSID(_ ssid: String) throws {
    guard !ssid.isEmpty, ssid.utf8.count <= 32, !ssid.contains("\0") else {
        throw Failure(code: 2, message: "SSID must contain 1–32 UTF-8 bytes without NUL.")
    }
}

struct StoreOptions: ParsableArguments {
    @Option(help: "Profile file path; contains network names, never passwords.")
    var config: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Thermohop/profiles.json").path
}

struct WiFiOptions: ParsableArguments {
    @Option(name: .long, help: "Wi-Fi interface name; defaults to the system Wi-Fi interface.")
    var interface: String?
    @Option(help: "Maximum operation time in seconds (1–120).")
    var timeout: Double = 20
    mutating func validate() throws { try validateSeconds(timeout, max: 120) }
}

struct Profile: Codable {
    var ssid: String
    var role: Role
    var priority: Int
}

enum Role: String, Codable, ExpressibleByArgument { case regular, hotspot }
struct ProfileFile: Codable { var schemaVersion = 1; var profiles: [Profile] = [] }

func readProfiles(_ path: String) throws -> ProfileFile {
    guard FileManager.default.fileExists(atPath: path) else { return ProfileFile() }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let file = try? JSONDecoder().decode(ProfileFile.self, from: data), file.schemaVersion == 1 else {
        throw Failure(code: 2, message: "Invalid profile file; expected schemaVersion 1.")
    }
    guard Set(file.profiles.map(\.ssid)).count == file.profiles.count,
          file.profiles.filter({ $0.role == .hotspot }).count <= 1 else {
        throw Failure(code: 2, message: "Profiles must have unique SSIDs and at most one hotspot.")
    }
    for p in file.profiles { try validateSSID(p.ssid) }
    return file
}

func writeProfiles(_ file: ProfileFile, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(file).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

func orderedProfiles(_ file: ProfileFile, role: Role? = nil) -> [Profile] {
    file.profiles.filter { role == nil || $0.role == role }.sorted {
        if $0.role != $1.role { return $0.role == .regular }
        if $0.priority != $1.priority { return $0.priority < $1.priority }
        return $0.ssid < $1.ssid
    }
}
