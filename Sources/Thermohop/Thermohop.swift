import ArgumentParser

@main
struct Thermohop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thermohop",
        abstract: "macOS thermal pressure monitoring and explicit Wi-Fi profile switching.",
        version: "0.1.0",
        subcommands: [Thermal.self, WiFi.self, WiFiWorker.self])
}
