import Foundation
import Security
import LocalAuthentication
import ArgumentParser
import Darwin

private let service = "io.thermohop.wifi"
func keyQuery(_ ssid: String) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: ssid,
     kSecUseAuthenticationContext as String: context]
}
func passwordFor(_ ssid: String) throws -> String? {
    var query = keyQuery(ssid)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
          let value = String(data: data, encoding: .utf8) else {
        throw Failure(code: 7, message: "Keychain credential unavailable without interaction. Unlock or authorize the Keychain item during setup.")
    }
    return value
}

// Inspect metadata only. Setup status never retrieves or prints a password.
func credentialState(_ ssid: String) -> String {
    var query = keyQuery(ssid)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecSuccess { return "stored" }
    if status == errSecItemNotFound { return "missing" }
    return "unavailable"
}

func validateCredential(_ data: Data) throws {
    guard !data.isEmpty, data.count <= 4096,
          let secret = String(data: data, encoding: .utf8), !secret.contains("\0") else {
        throw Failure(code: 2, message: "Credential must contain 1–4096 UTF-8 bytes without NUL.")
    }
}

func storePassword(_ data: Data, for ssid: String) throws {
    try validateCredential(data)
    let query = keyQuery(ssid)
    let update = [kSecValueData as String: data]
    var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
        throw Failure(code: 7, message: "Unable to store credential in Keychain without interaction.")
    }
    guard let stored = try passwordFor(ssid), Data(stored.utf8) == data else {
        throw Failure(code: 7, message: "Keychain credential storage could not be verified.")
    }
}

func requireSetupTerminal() throws {
    guard isatty(STDIN_FILENO) == 1, isatty(STDERR_FILENO) == 1 else {
        throw Failure(code: 2, message: "Interactive setup requires a local terminal. Agents should use wifi setup --status and ask the user to run wifi setup; for automation, pipe password-manager output into wifi credential set.")
    }
}

func terminalInput(_ prompt: String, hidden: Bool) throws -> Data {
    try requireSetupTerminal()
    // libc restores terminal echo on interruption and job-control signals.
    // One extra byte lets validation reject truncated, overlong input.
    var buffer = [CChar](repeating: 0, count: 4098)
    defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    let succeeded = buffer.withUnsafeMutableBufferPointer { pointer in
        readpassphrase(prompt, pointer.baseAddress, pointer.count,
            RPP_REQUIRE_TTY | (hidden ? 0 : RPP_ECHO_ON)) != nil
    }
    guard succeeded else { throw Failure(code: 2, message: "Setup input cancelled or unavailable.") }
    return buffer.withUnsafeBufferPointer { Data(bytes: $0.baseAddress!, count: strlen($0.baseAddress!)) }
}

struct Credential: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "credential", abstract: "Manage Thermohop's Keychain passwords; no password arguments or output.",
        subcommands: [CredentialSet.self, CredentialDelete.self])
}
struct CredentialSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Store a piped password, or use --prompt for hidden input in a local terminal.")
    @Argument var ssid: String
    @Flag(help: "Read a hidden password interactively; never use this from an agent's terminal recorder.") var prompt = false
    @Flag var dryRun = false
    func run() throws {
        try perform {
            try validateSSID(ssid)
            if dryRun { emit(["event": "credentialPlan", "action": "set", "ssid": ssid]); return }
            if prompt {
                var data = try terminalInput("Wi-Fi password: ", hidden: true)
                defer { data.resetBytes(in: 0..<data.count) }
                try storePassword(data, for: ssid)
                emit(["event": "credentialStored", "ssid": ssid])
                return
            }
            guard isatty(STDIN_FILENO) == 0 else {
                throw Failure(code: 2, message: "Use --prompt for hidden input, or pipe password-manager output. Never pass a password as a command argument.")
            }
            // Poll every byte so a stalled writer cannot create an unbounded wait.
            var data = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw Failure(code: 5, message: "Credential input timed out.") }
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
                if ready < 0 { throw Failure(code: 7, message: "Credential input failed.") }
                if ready == 0 { continue }
                var byte: UInt8 = 0
                let count = Darwin.read(STDIN_FILENO, &byte, 1)
                if count == 0 { break }
                guard count == 1 else { throw Failure(code: 7, message: "Credential input failed.") }
                data.append(byte)
                guard data.count <= 4096 else { throw Failure(code: 2, message: "Credential input is too large.") }
            }
            if data.last == 10 { data.removeLast(); if data.last == 13 { data.removeLast() } }
            defer { data.resetBytes(in: 0..<data.count) }
            try storePassword(data, for: ssid)
            emit(["event": "credentialStored", "ssid": ssid])
        }
    }
}
struct CredentialDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete")
    @Argument var ssid: String
    @Flag var dryRun = false
    func run() throws {
        try perform {
            try validateSSID(ssid)
            if dryRun { emit(["event": "credentialPlan", "action": "delete", "ssid": ssid]); return }
            let status = SecItemDelete(keyQuery(ssid) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure(code: 7, message: "Unable to delete credential without Keychain interaction.")
            }
            emit(["event": "credentialDeleted", "ssid": ssid])
        }
    }
}
