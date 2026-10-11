import Foundation
import ArgumentParser
import AppKit
import CoreServices
import Darwin

// A shell-spawned process can receive a Core Location grant under its bundle ID
// while CoreWLAN checks its executable-path identity instead. Launch Services
// supplies the app identity that both services use. Keep each worker independent.
final class WiFiApplicationLaunch {
    private let lock = NSLock()
    private var application: NSRunningApplication?
    private var stopped = false
    private var launchFailed = false

    var failed: Bool {
        lock.lock(); defer { lock.unlock() }; return launchFailed
    }
    func complete(_ app: NSRunningApplication?, error: Error?) {
        lock.lock()
        application = app
        launchFailed = error != nil || app == nil
        let terminate = stopped
        lock.unlock()
        if terminate { app?.forceTerminate() }
    }
    func stop() {
        lock.lock(); stopped = true; let app = application; lock.unlock()
        // This refers to the launched app instance, not a PID read from a file.
        // A late launch completion also terminates its instance above.
        app?.forceTerminate()
    }
}

func launchWiFiApplication(arguments: [String], activate: Bool) throws -> WiFiApplicationLaunch {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        throw Failure(code: 3, message: "Unable to locate the installed executable.")
    }
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard bundle.pathExtension == "app", let app = Bundle(url: bundle),
          app.bundleIdentifier == "io.thermohop.cli",
          app.executableURL?.resolvingSymlinksInPath() == executable else {
        throw Failure(code: 4, message: "Wi-Fi access requires the installed Thermohop app identity. Run ./install.sh, then use ~/.local/bin/thermohop.")
    }
    guard LSRegisterURL(bundle as CFURL, true) == noErr else {
        throw Failure(code: 3, message: "Unable to register Thermohop with macOS Launch Services.")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.arguments = arguments
    configuration.createsNewApplicationInstance = true
    configuration.activates = activate
    configuration.addsToRecentItems = false
    let launch = WiFiApplicationLaunch()
    NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
        launch.complete(app, error: error)
    }
    return launch
}

func redirectWorkerOutput(_ path: String) throws {
    let descriptor = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw ExitCode(1) }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
          info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
          info.st_mode & 0o777 == 0o600, info.st_size == 0,
          dup2(descriptor, STDOUT_FILENO) >= 0 else { throw ExitCode(1) }
    let null = open("/dev/null", O_WRONLY | O_CLOEXEC)
    if null >= 0 { _ = dup2(null, STDERR_FILENO); close(null) }
}
