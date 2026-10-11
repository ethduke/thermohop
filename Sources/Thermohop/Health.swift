import Foundation
import Network
import Security

final class Cancellation {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func wait(_ seconds: Double) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !cancelled && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: min(0.05, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }
    }
}
final class ProbeResult {
    private let lock = NSLock()
    private var result: Bool?
    var value: Bool { lock.lock(); defer { lock.unlock() }; return result ?? false }
    func finish(_ value: Bool) { lock.lock(); if result == nil { result = value }; lock.unlock() }
}
// Read only the bounded HTTP status line; no body, redirects, cookies or credentials.
final class HTTPStatusReader {
    let connection: NWConnection
    let expected: Int
    let result: ProbeResult
    let semaphore: DispatchSemaphore
    private var bytes = Data()
    init(connection: NWConnection, expected: Int, result: ProbeResult, semaphore: DispatchSemaphore) {
        self.connection = connection; self.expected = expected; self.result = result; self.semaphore = semaphore
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
            if let data { bytes.append(data) }
            if let end = bytes.range(of: Data([13, 10])) {
                let line = String(data: bytes[..<end.lowerBound], encoding: .ascii) ?? ""
                let fields = line.split(separator: " ")
                result.finish(fields.count >= 2 && ["HTTP/1.0", "HTTP/1.1"].contains(String(fields[0])) && Int(fields[1]) == expected)
                semaphore.signal()
            } else if bytes.count >= 4096 || complete || error != nil {
                result.finish(false); semaphore.signal()
            } else { receive() }
        }
    }
}
func probeHealth(_ probe: HealthProbe, timeout: Double, cancellation: Cancellation) -> Bool {
    guard !cancellation.cancelled, timeout > 0 else { return false }
    let result = ProbeResult()
    let semaphore = DispatchSemaphore(value: 0)
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    let cancel: () -> Void
    switch probe.kind {
    case .tcp:
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(host: NWEndpoint.Host(probe.host), port: NWEndpoint.Port(rawValue: UInt16(probe.port))!, using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: result.finish(true); semaphore.signal()
            case .failed, .cancelled: result.finish(false); semaphore.signal()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "thermohop.probe"))
        cancel = { connection.cancel() }
    case .http:
        guard let url = URLComponents(string: probe.url), let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)) ?? 0),
              port.rawValue != 0 else { return false }
        let tls: NWProtocolTLS.Options? = url.scheme == "https" ? NWProtocolTLS.Options() : nil
        if let tls { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host) }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let reader = HTTPStatusReader(connection: connection, expected: probe.expectedStatus, result: result, semaphore: semaphore)
        let path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        let hostField = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let authority = hostField + (url.port.map { ":\($0)" } ?? "")
        let request = Data("HEAD \(path) HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\n\r\n".utf8)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { error in
                    if error != nil { result.finish(false); semaphore.signal() }
                    else { reader.receive() }
                })
            case .failed, .cancelled: result.finish(false); semaphore.signal()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "thermohop.http-probe"))
        cancel = { connection.cancel(); connection.stateUpdateHandler = nil }

    }
    defer { cancel() }
    while !cancellation.cancelled {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 { return false }
        if semaphore.wait(timeout: .now() + min(0.05, remaining)) == .success { return result.value }
    }
    return false
}
struct HealthReport {
    var association: Bool
    var local: Bool?
    var internet: Bool?
    func healthy(_ scope: HealthScope) -> Bool {
        guard association else { return false }
        switch scope { case .association: return true; case .local: return local == true; case .internet: return internet == true }
    }
    var fields: [String: Any] {
        ["association": association, "local": local.map { $0 as Any } ?? NSNull(), "internet": internet.map { $0 as Any } ?? NSNull()]
    }
}
func checkHealth(associated: Bool, policy: NetworkPolicy, cancellation: Cancellation, budget: Double) -> HealthReport {
    var report = HealthReport(association: associated)
    guard associated else { return report }
    let deadline = ProcessInfo.processInfo.systemUptime + budget
    for scope in [HealthScope.local, .internet] {
        let probes = policy.probes.filter { $0.scope == scope }
        guard !probes.isEmpty else { continue }
        var healthy = true
        for probe in probes {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 || cancellation.cancelled { healthy = false; break }
            if !probeHealth(probe, timeout: min(policy.probeTimeout, remaining), cancellation: cancellation) { healthy = false }
        }
        if scope == .local { report.local = healthy } else { report.internet = healthy }
    }
    return report
}
