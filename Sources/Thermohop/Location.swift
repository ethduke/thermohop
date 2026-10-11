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
func locationStatus() -> [String: Any] {
    let manager = CLLocationManager()
    return ["authorization": authorizationName(manager.authorizationStatus),
            "servicesEnabled": CLLocationManager.locationServicesEnabled()]
}
func requireLocation() throws {
    let state = locationStatus()
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
    func run() { emit(["event": "locationPermission", "location": locationStatus()]) }
}
final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
}
struct PermissionRequest: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "request", abstract: "Initial setup only: request Location access; may show a system prompt.")
    @Option(help: "Maximum time to wait for system authorization (up to 120 seconds).") var timeout: Double = 30
    mutating func validate() throws { try validateSeconds(timeout, max: 120) }
    func run() throws {
        try perform {
            let manager = CLLocationManager()
            let delegate = LocationDelegate()
            manager.delegate = delegate
            guard CLLocationManager.locationServicesEnabled() else {
                throw Failure(code: 4, message: "Enable Location Services in System Settings > Privacy & Security first.")
            }
            if manager.authorizationStatus == .notDetermined { manager.requestAlwaysAuthorization() }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while manager.authorizationStatus == .notDetermined && ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            }
            withExtendedLifetime(delegate) {}
            let name = authorizationName(manager.authorizationStatus)
            emit(["event": "locationPermission", "location": ["authorization": name, "servicesEnabled": true]])
            guard name == "authorized" else {
                throw Failure(code: 4, message: "Location permission was not granted. Check System Settings > Privacy & Security > Location Services; a standalone CLI prompt may not appear on this system. See README.txt.")
            }
        }
    }
}
