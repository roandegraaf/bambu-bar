import Foundation
import Security

/// Secrets in the login keychain: each printer's LAN access code (per serial number) and the Bambu account session.
enum Keychain {
    private static let accessCodeService = "dev.rolottr.BambuBar.access-code"
    private static let cloudService = "dev.rolottr.BambuBar.cloud-account"
    private static let cloudAccount = "default"

    static func accessCode(for serial: String) -> String? {
        read(service: accessCodeService, account: serial).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setAccessCode(_ code: String, for serial: String) {
        write(Data(code.utf8), service: accessCodeService, account: serial, label: "Bambu Bar printer access code")
    }

    static func removeAccessCode(for serial: String) {
        remove(service: accessCodeService, account: serial)
    }

    static func cloudSession() -> Data? {
        read(service: cloudService, account: cloudAccount)
    }

    static func setCloudSession(_ data: Data?) {
        if let data {
            write(data, service: cloudService, account: cloudAccount, label: "Bambu Bar Bambu account")
        } else {
            remove(service: cloudService, account: cloudAccount)
        }
    }

    private static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data, service: String, account: String, label: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func remove(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
