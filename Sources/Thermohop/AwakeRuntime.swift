import Foundation
import Darwin
import IOKit.pwr_mgt

enum AwakeControllerMode: String, Codable {
    case monitor, awakeWatch, supervisor

    var readable: String {
        switch self {
        case .monitor: return "open-lid monitor"
        case .awakeWatch: return "awake watch"
        case .supervisor: return "supervisor"
        }
    }
}

enum AwakeControllerState: String { case running, paused, stopped, unknown }

// Only identity metadata is stored in the existing lock, never arguments,
// project paths, credentials or a cached claim that an assertion is held.
struct SupervisorLockOwner: Codable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let mode: AwakeControllerMode

    init(mode: AwakeControllerMode) throws {
        guard let info = processIdentity(getpid()) else {
            throw Failure(code: 8, message: "Unable to identify the supervisor process.")
        }
        pid = getpid(); startedSeconds = info.pbi_start_tvsec
        startedMicroseconds = info.pbi_start_tvusec; self.mode = mode
    }

    func state(for info: proc_bsdinfo?, uid: UInt32) -> AwakeControllerState {
        guard let info, info.pbi_pid == UInt32(pid), info.pbi_uid == uid,
              info.pbi_start_tvsec == startedSeconds, info.pbi_start_tvusec == startedMicroseconds,
              info.pbi_status != 5 else { return .unknown }
        return info.pbi_status == 4 ? .paused : .running
    }
}

struct AwakeRuntimeStatus {
    var monitorState: AwakeControllerState = .unknown
    var monitorPID: Int32? = nil
    var mode: AwakeControllerMode? = nil
    var assertionHeld: Bool? = nil
    var closedLidPrevention: Bool? = nil

    var preventingSleep: Bool? {
        if assertionHeld == true || closedLidPrevention == true { return true }
        return assertionHeld == false && closedLidPrevention == false ? false : nil
    }
    var fields: [String: Any] {
        ["monitorState": monitorState.rawValue,
         "monitorRunning": monitorState == .unknown ? NSNull() : (monitorState == .running) as Any,
         "monitorPID": monitorPID.map { $0 as Any } ?? NSNull(),
         "monitorMode": mode.map { $0.rawValue as Any } ?? NSNull(),
         "assertionHeld": assertionHeld.map { $0 as Any } ?? NSNull(),
         "closedLidPreventionActive": closedLidPrevention.map { $0 as Any } ?? NSNull(),
         "sleepPreventionActive": preventingSleep.map { $0 as Any } ?? NSNull()]
    }
    var readableLines: [String] {
        let identity = monitorPID.map { " (PID \($0)\(mode.map { "; " + $0.readable } ?? ""))" } ?? ""
        let monitor = monitorState == .unknown ? "unavailable" : monitorState.rawValue
        let prevention = preventingSleep.map { $0 ? "active" : "inactive" } ?? "unavailable"
        var lines = ["Monitor: \(monitor)\(identity)", "Sleep prevention by Thermohop: \(prevention)"]
        if closedLidPrevention == true { lines.append("Closed-lid sleep override: active (system-wide)") }
        return lines
    }
}

func awakeControllerStatus(uid: UInt32, name: String = "awake") -> AwakeRuntimeStatus {
    let path = "/private/tmp/thermohop-\(name)-\(uid).lock"
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
        return AwakeRuntimeStatus(monitorState: errno == ENOENT ? .stopped : .unknown)
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == uid, info.st_mode & S_IFMT == S_IFREG,
          info.st_nlink == 1, info.st_mode & 0o077 == 0 else { return AwakeRuntimeStatus() }
    // Query the kernel lock without acquiring, creating, rewriting or removing it.
    var lock = Darwin.flock()
    lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
    guard fcntl(descriptor, F_GETLK, &lock) == 0 else { return AwakeRuntimeStatus() }
    if lock.l_type == Int16(F_UNLCK) { return AwakeRuntimeStatus(monitorState: .stopped) }
    guard info.st_size > 0, info.st_size <= 1024 else { return AwakeRuntimeStatus() }
    var bytes = [UInt8](repeating: 0, count: 1025)
    let size = pread(descriptor, &bytes, bytes.count, 0)
    guard size > 0, size <= 1024,
          let owner = try? JSONDecoder().decode(SupervisorLockOwner.self, from: Data(bytes.prefix(size))),
          owner.pid > 0 else { return AwakeRuntimeStatus() }
    var process = proc_bsdinfo()
    guard proc_pidinfo(owner.pid, PROC_PIDTBSDINFO, 0, &process,
                      Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else {
        return AwakeRuntimeStatus()
    }
    let state = owner.state(for: process, uid: uid)
    return AwakeRuntimeStatus(monitorState: state, monitorPID: state == .unknown ? nil : owner.pid,
                              mode: state == .unknown ? nil : owner.mode)
}

func isThermohopSleepAssertion(_ properties: [String: Any]) -> Bool {
    properties[kIOPMAssertionNameKey] as? String == SleepAssertion.name
        && properties[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep
        && ((properties[kIOPMAssertionLevelKey] as? NSNumber)?.uint32Value ?? 0) == kIOPMAssertionLevelOn
}

func thermohopAssertionHeld(uid: UInt32) -> Bool? {
    var assertions: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
          let dictionary = assertions?.takeRetainedValue() as NSDictionary? else { return nil }
    for (key, value) in dictionary {
        guard let pid = key as? NSNumber, pid.int32Value > 0 else { continue }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid.int32Value, PROC_PIDTBSDINFO, 0, &info,
                          Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == uid else { continue }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid.int32Value, &name, UInt32(name.count)) > 0,
              String(cString: name) == "thermohop",
              let properties = value as? [[String: Any]] else { continue }
        if properties.contains(where: isThermohopSleepAssertion) { return true }
    }
    return false
}

func thermohopClosedLidPrevention(uid: UInt32) -> Bool? {
    let root = "/Library/Application Support/Thermohop"
    var marker = stat()
    guard lstat(root + "/awake-sleep-owned", &marker) == 0 else { return errno == ENOENT ? false : nil }
    guard marker.st_uid == 0, marker.st_mode & S_IFMT == S_IFREG,
          marker.st_nlink == 1, marker.st_mode & 0o022 == 0,
          let data = protectedRead(root + "/awake-status.json", owner: 0),
          let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let owner = status["uid"] as? NSNumber else { return nil }
    guard owner.uint32Value == uid else { return false }
    // The ownership journal can outlive the monitor during watchdog cleanup;
    // check the actual power setting instead of trusting a cached active flag.
    return try? ClosedLidPower().isDisabled()
}

func awakeRuntimeStatus(uid: UInt32 = getuid()) -> AwakeRuntimeStatus {
    var status = awakeControllerStatus(uid: uid)
    // A policy supervisor can keep observing with awake policy disabled or in
    // observe-only mode. Its presence still differs from holding an assertion.
    if status.monitorState == .stopped { status = awakeControllerStatus(uid: uid, name: "supervisor") }
    status.assertionHeld = thermohopAssertionHeld(uid: uid)
    status.closedLidPrevention = thermohopClosedLidPrevention(uid: uid)
    return status
}
