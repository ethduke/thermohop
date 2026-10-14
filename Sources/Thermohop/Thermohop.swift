import ArgumentParser

@main
struct Thermohop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thermohop",
        abstract: "Run without arguments for open-lid agent monitoring; advanced commands provide thermal and Wi-Fi supervision.",
        version: "0.2.0",
        subcommands: [Monitor.self, Thermal.self, WiFi.self, Policy.self, Supervise.self, Awake.self, WiFiWorker.self],
        defaultSubcommand: Monitor.self)

    static func main() {
        var command: any ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            // Help/version/completion are safe; parse errors can echo arbitrary input.
            if exitCode(for: error) == .success { exit(withError: error) }
            let message = "Invalid command or arguments. Run thermohop --help or thermohop <command> --help."
            emit(["event": "error", "code": ExitCode.validationFailure.rawValue, "message": message])
            diagnostic(message)
            exit(withError: ExitCode.validationFailure)
        }
        do {
            try command.run()
        } catch {
            if error is ExitCode || exitCode(for: error) == .success { exit(withError: error) }
            // Do not pass arbitrary framework errors to ArgumentParser's renderer.
            let message = "Operation failed."
            emit(["event": "error", "code": 1, "message": message])
            diagnostic(message)
            exit(withError: ExitCode.failure)
        }
    }
}
