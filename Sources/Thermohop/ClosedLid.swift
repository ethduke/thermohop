import Foundation
import ArgumentParser
import Darwin

private let awakeRoot = "/Library/Application Support/Thermohop"

struct AwakeLease: Codable {
    let controller: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let uid: UInt32
    let expires: Double
    let token: String
    let cutoff: Pressure
    let agents: [String]
    let pids: [Int32]
}

func processIdentity(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
          info.pbi_status != 4, info.pbi_status != 5 else { return nil }
    return info
}

func validAwakeLease(_ lease: AwakeLease, uid: UInt32, now: Double) -> Bool {
    guard lease.uid == uid, lease.expires.isFinite, lease.expires > now, lease.expires <= now + 6,
          lease.cutoff == .fair || lease.cutoff == .serious,
          lease.agents.count <= 32, lease.pids.count <= 256,
          lease.agents.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") && $0.utf8.count <= 255 }),
          lease.pids.allSatisfy({ $0 > 0 }),
          let info = processIdentity(lease.controller), info.pbi_uid == uid,
          info.pbi_start_tvsec == lease.startedSeconds, info.pbi_start_tvusec == lease.startedMicroseconds else { return false }
    return true
}

func protectedRead(_ path: String, owner: UInt32, limit: Int = 16384) -> Data? {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == owner, info.st_mode & S_IFMT == S_IFREG,
          info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size >= 0, info.st_size <= limit else { return nil }
    var bytes = [UInt8](repeating: 0, count: limit + 1)
    let size = read(descriptor, &bytes, bytes.count)
    guard size >= 0, size <= limit else { return nil }
    return Data(bytes.prefix(size))
}

func atomicAwakeFile(_ data: Data, path: String, mode: NSNumber) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}

final class ClosedLidLease {
    private let token = UUID().uuidString
    private let directory = awakeRoot + "/awake-\(getuid())"
    private var path: String { directory + "/lease.json" }
    init() throws {
        var parent = stat(), child = stat()
        guard lstat(awakeRoot, &parent) == 0, parent.st_uid == 0, parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_mode & 0o022 == 0,
              lstat(directory, &child) == 0, child.st_uid == getuid(), child.st_mode & S_IFMT == S_IFDIR,
              child.st_mode & 0o777 == 0o700 else {
            throw Failure(code: 3, message: "Closed-lid mode requires the optional root-owned watchdog. See scripts/install-awake-helper.py and README.txt.")
        }
    }
    func renew(options: AwakeOptions) throws {
        guard let identity = processIdentity(getpid()) else { throw Failure(code: 1, message: "Unable to verify keep-awake controller identity.") }
        let lease = AwakeLease(controller: getpid(), startedSeconds: identity.pbi_start_tvsec,
            startedMicroseconds: identity.pbi_start_tvusec, uid: getuid(),
            expires: ProcessInfo.processInfo.systemUptime + 5, token: token, cutoff: options.cutoff,
            agents: options.agent, pids: options.pid)
        try atomicAwakeFile(JSONEncoder().encode(lease), path: path, mode: 0o600)
    }
    func withdraw() { try? FileManager.default.removeItem(atPath: path) }
    func confirmed() -> Bool {
        guard let data = protectedRead(awakeRoot + "/awake-status.json", owner: 0),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              status["token"] as? String == token, status["active"] as? Bool == true,
              let time = status["uptime"] as? Double,
              time <= ProcessInfo.processInfo.systemUptime, ProcessInfo.processInfo.systemUptime - time < 2 else { return false }
        return true
    }
    func waitForRestoration() -> Bool {
        let began = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - began < 3 {
            guard let data = protectedRead(awakeRoot + "/awake-status.json", owner: 0),
                  let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { Thread.sleep(forTimeInterval: 0.05); continue }
            if status["active"] as? Bool == false, status["sleepRestored"] as? Bool == true, status["uid"] as? UInt32 == getuid(),
               let time = status["uptime"] as? Double, time >= began { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
    deinit { withdraw() }
}

struct AwakeDaemon: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sleep-watchdog", abstract: "Optional root watchdog for leased closed-lid sleep prevention.", shouldDisplay: false)
    @Option var userID: UInt32
    func run() throws {
        guard geteuid() == 0, userID != 0 else { throw Failure(code: 3, message: "The sleep watchdog requires root and a non-root user ID.") }
        let marker = awakeRoot + "/awake-sleep-owned"
        let leasePath = awakeRoot + "/awake-\(userID)/lease.json"
        let lockFD = open(awakeRoot + "/awake-helper.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure(code: 8, message: "Another sleep watchdog is running.") }
        defer { close(lockFD) }
        let backend = ClosedLidPower()
        var owned = FileManager.default.fileExists(atPath: marker)
        // The journal is written before enabling. A launchd restart after a
        // crash must restore normal sleep before accepting any new lease.
        func restore() throws {
            guard owned else { return }
            try backend.setDisabled(false)
            try FileManager.default.removeItem(atPath: marker)
            owned = false
        }
        try restore()
        let cancelled = Cancellation()
        var signals: [DispatchSourceSignal] = []
        for number in [SIGTERM, SIGINT] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { cancelled.cancel() }; source.resume(); signals.append(source)
        }
        defer { for source in signals { source.cancel() }; try? restore() }
        while !cancelled.cancelled {
            let now = ProcessInfo.processInfo.systemUptime
            let lease = protectedRead(leasePath, owner: userID).flatMap { try? JSONDecoder().decode(AwakeLease.self, from: $0) }
            let heartbeat: [String: Any] = ["active": false, "sleepRestored": false, "token": lease?.token ?? "", "uptime": now,
                                          "expires": lease?.expires ?? 0, "uid": userID, "cutoffLevel": lease?.cutoff.rank ?? 2]
            try atomicAwakeFile(JSONSerialization.data(withJSONObject: heartbeat), path: awakeRoot + "/awake-status.json", mode: 0o644)
            var eligible = false
            if let lease, validAwakeLease(lease, uid: userID, now: now), lidState() != "unknown" {
                let agents = try detectAgents(names: Set(lease.agents), pids: Set(lease.pids), uid: userID)
                eligible = awakeDecision(pressure: Pressure.current, agents: agents.count, cutoff: lease.cutoff) == .keepAwake
            }
            if eligible && !owned {
                // Refuse to take ownership of another application's global bit.
                if try !backend.isDisabled() {
                    try atomicAwakeFile(Data("owned\n".utf8), path: marker, mode: 0o600)
                    owned = true
                    try backend.setDisabled(true)
                }
            } else if !eligible { try restore() }
            // Recheck safety after the potentially blocking powerd command.
            if let lease, eligible && (!validAwakeLease(lease, uid: userID, now: ProcessInfo.processInfo.systemUptime) || Pressure.current.rank >= lease.cutoff.rank) {
                eligible = false; try restore()
            }
            let disabled = try backend.isDisabled()
            let active = eligible && owned && disabled
            let status: [String: Any] = ["active": active, "sleepRestored": !owned, "token": lease?.token ?? "", "uptime": ProcessInfo.processInfo.systemUptime,
                                       "pressure": Pressure.current.rawValue, "uid": userID, "expires": lease?.expires ?? 0,
                                       "cutoffLevel": lease?.cutoff.rank ?? 2]
            try atomicAwakeFile(JSONSerialization.data(withJSONObject: status), path: awakeRoot + "/awake-status.json", mode: 0o644)
            cancelled.wait(0.5)
        }
        try restore()
    }
}

// A separate launchd job restores the journaled setting if the primary helper
// hangs. Neither process can restore another app's pre-existing global setting.
struct AwakeBackstop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sleep-backstop", shouldDisplay: false)
    func run() throws {
        guard geteuid() == 0 else { throw Failure(code: 3, message: "The sleep backstop requires root.") }
        let backend = ClosedLidPower()
        while true {
            if FileManager.default.fileExists(atPath: awakeRoot + "/awake-sleep-owned") {
                let data = protectedRead(awakeRoot + "/awake-status.json", owner: 0)
                let status = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let now = ProcessInfo.processInfo.systemUptime
                let time = status?["uptime"] as? Double ?? -Double.infinity
                let expires = status?["expires"] as? Double ?? 0
                let cutoff = status?["cutoffLevel"] as? Int ?? 2
                if Pressure.current.rank >= min(max(cutoff, 1), 2) || !time.isFinite || time > now || now - time > 5 || !expires.isFinite || expires <= now || expires > now + 6 {
                    if try backend.isDisabled() { try backend.setDisabled(false) }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

struct ClosedLidPower {
    private func command(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { kill(process.processIdentifier, SIGKILL); throw Failure(code: 5, message: "Power-management command timed out; watchdog restart will restore sleep.") }
        guard process.terminationStatus == 0 else { throw Failure(code: 1, message: "Power-management command failed; watchdog restart will restore sleep.") }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    func isDisabled() throws -> Bool {
        let lines = try command(["-g"]).split(whereSeparator: \.isNewline)
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "SleepDisabled", fields[1] == "0" || fields[1] == "1" { return fields[1] == "1" }
        }
        throw Failure(code: 1, message: "Unable to determine the global sleep setting; refusing to change it.")
    }
    func setDisabled(_ disabled: Bool) throws {
        _ = try command(["-a", "disablesleep", disabled ? "1" : "0"])
        guard try isDisabled() == disabled else { throw Failure(code: 1, message: "Unable to verify global sleep-setting change.") }
    }
}
