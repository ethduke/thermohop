import Foundation
import Darwin

// Only processes started in this new process group may receive workload signals.
final class OwnedWorkload {
    private(set) var pid: pid_t = 0
    private(set) var stopped = false
    private var ownsPause = false
    private var closed = false
    private(set) var exitCode: Int32?

    init(command: [String]) throws {
        guard let first = command.first else { throw Failure(code: 2, message: "Workload command is empty.") }
        let path: String
        if first.contains("/") { path = URL(fileURLWithPath: first).standardized.path }
        else {
            let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
            guard let match = directories.map({ String($0) + "/" + first }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw Failure(code: 2, message: "Workload executable not found on PATH.")
            }
            path = match
        }
        guard FileManager.default.isExecutableFile(atPath: path) else { throw Failure(code: 2, message: "Workload executable is unavailable.") }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0, posix_spawn_file_actions_init(&actions) == 0 else {
            throw Failure(code: 1, message: "Unable to initialize owned workload.")
        }
        defer { posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions) }
        var empty = sigset_t(); sigemptyset(&empty)
        var defaults = sigset_t(); sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGPIPE, SIGCHLD] { sigaddset(&defaults, signal) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &empty) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 else {
            throw Failure(code: 1, message: "Unable to configure owned process group.")
        }
        // Workload output must not corrupt the supervisor JSON stream or expose secrets.
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0 else {
                throw Failure(code: 1, message: "Unable to isolate workload output.")
            }
        }
        let argv = command.map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + environment { free(pointer) } }
        let status = argv.withUnsafeBufferPointer { args in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&pid, path, &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard status == 0, pid > 0, getpgid(pid) == pid else {
            if pid > 0 { kill(pid, SIGTERM) }
            throw Failure(code: 1, message: "Unable to start verified owned process group.")
        }
    }
    func poll() {
        guard exitCode == nil else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG | WUNTRACED | WCONTINUED)
        if result == pid {
            if status & 0x7f == 0x7f && (status >> 8) & 0xff == 0x13 { stopped = false; ownsPause = false }
            else if status & 0xff == 0x7f { stopped = true }
            else { exitCode = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }
        }
    }
    func pause() -> Bool {
        poll()
        // Never claim ownership of a workload already stopped by somebody else.
        if stopped { return ownsPause }
        guard exitCode == nil, getpgid(pid) == pid, kill(-pid, SIGSTOP) == 0 else { return false }
        ownsPause = true
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        repeat { poll(); if stopped { return true }; Thread.sleep(forTimeInterval: 0.01) }
        while exitCode == nil && ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    func resume() -> Bool {
        poll()
        guard exitCode == nil, stopped, ownsPause, getpgid(pid) == pid, kill(-pid, SIGCONT) == 0 else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        repeat { poll(); if !stopped { return exitCode == nil }; Thread.sleep(forTimeInterval: 0.01) }
        while exitCode == nil && ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
    func close(resumeOwnedPause: Bool) {
        guard !closed else { return }
        closed = true
        if (resumeOwnedPause || ownsPause) && stopped { _ = resume() }
        kill(-pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        repeat { poll(); Thread.sleep(forTimeInterval: 0.01) }
        while kill(-pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline
        if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        let reapDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        while exitCode == nil && ProcessInfo.processInfo.systemUptime < reapDeadline { poll(); Thread.sleep(forTimeInterval: 0.01) }
    }
}
