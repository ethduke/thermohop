import Foundation
import Security
import LocalAuthentication
import ArgumentParser

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
struct Credential: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "credential", abstract: "Manage Thermohop's Keychain passwords; no password arguments or output.",
        subcommands: [CredentialSet.self, CredentialDelete.self])
}
struct CredentialSet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Read a password from stdin through EOF; removes one trailing newline.")
    @Argument var ssid: String
    @Flag var dryRun = false
    func run() throws {
        try perform {
            try validateSSID(ssid)
            if dryRun { emit(["event": "credentialPlan", "action": "set", "ssid": ssid]); return }
            guard isatty(STDIN_FILENO) == 0 else {
                throw Failure(code: 2, message: "Provide the password through a pipe, never a command argument. Interactive stdin is refused.")
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
            guard !data.isEmpty, let secret = String(data: data, encoding: .utf8), !secret.contains("\0") else {
                throw Failure(code: 2, message: "Credential must be nonempty UTF-8 without NUL.")
            }
            let query = keyQuery(ssid)
            let update = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw Failure(code: 7, message: "Unable to store credential in Keychain without interaction.") }
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
