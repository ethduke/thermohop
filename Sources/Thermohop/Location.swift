import Foundation
import CoreLocation
import ArgumentParser

func authorizationName(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedAlways: return "authorized"
    case .authorizedWhenInUse: return "authorized"
    @unknown default: return "unknown"
    }
}
// Keep one manager alive per process. Authorization is only reliable after the
// initial delegate callback has been delivered on this thread's run loop.
final class LocationSession: NSObject, CLLocationManagerDelegate {
    static let shared = LocationSession()
    let manager = CLLocationManager()
    private(set) var initialized = false

    private override init() {
        super.init()
        manager.delegate = self
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        initialized = true
    }

    func waitForInitialization(timeout: Double = 2) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !initialized {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return false }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: min(0.05, remaining)))
        }
        return true
    }
}

func locationStatus() -> [String: Any] {
    let session = LocationSession.shared
    let initialized = session.waitForInitialization()
    return ["authorization": initialized ? authorizationName(session.manager.authorizationStatus) : "unknown",
            "servicesEnabled": CLLocationManager.locationServicesEnabled(),
            "initialized": initialized]
}
func requireLocation() throws {
    let state = locationStatus()
    guard state["initialized"] as? Bool == true else {
        throw Failure(code: 5, message: "Location authorization initialization timed out; permission is unknown. Retry status before requesting access again.")
    }
    guard state["servicesEnabled"] as? Bool == true,
          state["authorization"] as? String == "authorized" else {
        throw Failure(code: 4, message: "Wi-Fi names require Location access. Run wifi permission status; use wifi permission request for initial setup and check System Settings > Privacy & Security > Location Services.")
    }
}
struct Permission: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "permission", abstract: "Inspect or explicitly request macOS Location permission.",
        subcommands: [PermissionStatus.self, PermissionRequest.self])
}
struct PermissionStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    func run() throws {
        try perform {
            let state = try worker("permissionStatus", options: WiFiOptions.parse([]))
            emit(state)
            guard (state["location"] as? [String: Any])?["initialized"] as? Bool == true else {
                throw Failure(code: 5, message: "Location authorization initialization timed out; permission is unknown.")
            }
        }
    }
}
struct PermissionRequest: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "request", abstract: "Initial setup only: request Location access; may show a system prompt.")
    @Option(help: "Maximum time to wait for system authorization (up to 120 seconds).") var timeout: Double = 30
    mutating func validate() throws { try validateSeconds(timeout, max: 120) }
    func run() throws {
        try perform {
            var options = try WiFiOptions.parse([]); options.timeout = timeout
            emit(try worker("permissionRequest", options: options))
        }
    }
}

func requestLocation(timeout: Double) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    let session = LocationSession.shared
    guard session.waitForInitialization(timeout: min(2, timeout)) else {
        throw Failure(code: 5, message: "Location authorization initialization timed out; no permission request was made.")
    }
    let manager = session.manager
    guard CLLocationManager.locationServicesEnabled() else {
        throw Failure(code: 4, message: "Enable Location Services in System Settings > Privacy & Security first.")
    }
    if manager.authorizationStatus == .notDetermined { manager.requestAlwaysAuthorization() }
    while manager.authorizationStatus == .notDetermined && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    let name = authorizationName(manager.authorizationStatus)
    guard name == "authorized" else {
        throw Failure(code: 4, message: "Location permission was not granted. Check System Settings > Privacy & Security > Location Services for Thermohop. See README.txt.")
    }
    emit(["event": "locationPermission", "location": ["authorization": name, "servicesEnabled": true, "initialized": true]])
}
