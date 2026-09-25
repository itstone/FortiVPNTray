import Foundation
import Security

public struct ConfigurationStore {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(AppIdentity.identifier)
    }
    public func profiles() throws -> [VPNProfile] { try read("profiles.json", fallback: []) }
    public func settings() throws -> AppSettings { try read("settings.json", fallback: AppSettings()) }
    public func save(profiles: [VPNProfile]) throws { try write(profiles, to: "profiles.json") }
    public func save(settings: AppSettings) throws { try write(settings, to: "settings.json") }
    private func read<T: Decodable>(_ name: String, fallback: T) throws -> T {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}

public enum Keychain {
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppIdentity.identifier, kSecAttrAccount as String: "vpn-\(id)"]
    }
    public static func password(for id: String) throws -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data, let string = String(data: data, encoding: .utf8) else {
            throw VPNError("The saved password is not valid UTF-8.")
        }
        return string
    }
    public static func save(_ password: String, for id: String) throws {
        let value = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(query(id) as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query(id).merging(value) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    public static func delete(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private static func check(_ status: OSStatus) throws {
        if status != errSecSuccess {
            throw VPNError(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        }
    }
}
