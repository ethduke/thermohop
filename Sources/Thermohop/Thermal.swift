import Foundation
import ArgumentParser

// Thermal pressure is an OS policy signal, not a temperature measurement.
enum Pressure: String, ExpressibleByArgument, CaseIterable {
    case nominal, fair, serious, critical
    var rank: Int { Self.allCases.firstIndex(of: self)! }
    static var current: Pressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }
}

struct Thermal: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read macOS thermal pressure and report threshold events.",
        subcommands: [ThermalStatus.self, ThermalWatch.self, ThermalGuard.self])
}
struct ThermalStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Emit one thermal pressure snapshot.")
    func run() { emit(["event": "thermalStatus", "pressure": Pressure.current.rawValue]) }
}
struct ThermalWatchOptions: ParsableArguments {
    @Option(help: "Bounded observation duration in seconds (up to 86400).") var duration: Double = 60
    @Option(help: "Sampling interval in seconds (up to 60).") var interval: Double = 2
    @Option(help: "Pressure at or above which a threshold event is emitted.") var threshold: Pressure = .serious
    mutating func validate() throws {
        try validateSeconds(duration, max: 86400)
        try validateSeconds(interval, max: 60)
    }
}
func observe(_ options: ThermalWatchOptions, stopAtThreshold: Bool) throws {
    let start = ProcessInfo.processInfo.systemUptime
    var previous: Pressure?
    var above = false
    repeat {
        let pressure = Pressure.current
        if pressure != previous {
            emit(["event": "thermalState", "pressure": pressure.rawValue])
            previous = pressure
        }
        let reached = pressure.rank >= options.threshold.rank
        if reached && !above {
            emit(["event": "thresholdReached", "pressure": pressure.rawValue, "threshold": options.threshold.rawValue])
            if stopAtThreshold { throw ExitCode(10) }
        } else if !reached && above {
            emit(["event": "thresholdCleared", "pressure": pressure.rawValue, "threshold": options.threshold.rawValue])
        }
        above = reached
        let left = options.duration - (ProcessInfo.processInfo.systemUptime - start)
        if left <= 0 { break }
        Thread.sleep(forTimeInterval: min(options.interval, left))
    } while ProcessInfo.processInfo.systemUptime - start < options.duration
    emit(["event": "watchCompleted", "pressure": Pressure.current.rawValue])
}
struct ThermalWatch: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch", abstract: "Emit JSONL on pressure changes and threshold crossings.")
    @OptionGroup var options: ThermalWatchOptions
    @Flag(help: "Exit with code 10 when the threshold is reached, including on the initial sample.") var exitOnThreshold = false
    func run() throws { try observe(options, stopAtThreshold: exitOnThreshold) }
}
struct ThermalGuard: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "guard", abstract: "Wait for a thermal threshold; exit 10 if reached, 0 when the duration expires.")
    @OptionGroup var options: ThermalWatchOptions
    func run() throws { try observe(options, stopAtThreshold: true) }
}
