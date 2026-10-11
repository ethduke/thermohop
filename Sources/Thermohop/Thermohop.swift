import ArgumentParser

@main
struct Thermohop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thermohop",
        abstract: "Agent-aware thermal safety, sleep prevention and verified Wi-Fi policy for macOS.",
        version: "0.2.0",
        subcommands: [Thermal.self, WiFi.self, Policy.self, Supervise.self, Awake.self, WiFiWorker.self])
}
