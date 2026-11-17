import Foundation
import KeyVine
import Security

/**
 Stores secrets as generic passwords in the login (file-based) keychain.

 Unlike `KeyVine`, which always uses the data-protection keychain with an access group, this store needs no
 keychain entitlement, so the app can be signed without a provisioning profile. The keychain trusts the app's
 designated requirement, which survives rebuilds and certificate renewals.
 */
struct TokenKeychain: Sendable {
    private let service: String

    init(service: String) {
        self.service = service
    }

    /** Reads or writes the value for `key`. Assigning `nil` removes the entry. Failures are logged, and a failed read returns `nil`. */
    subscript<T: KeyVineDataConvertible>(key: String) -> T? {
        get { T(keyVineData: read(from: key)) }
        nonmutating set { write(data: newValue?.keyVineData, to: key) }
    }

    private func baseQuery(for key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: key,
         kSecUseDataProtectionKeychain: kCFBooleanFalse!]
    }

    private func read(from key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = kCFBooleanTrue

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            logFailure("read", status: status)
            return nil
        }
    }

    private func write(data: Data?, to key: String) {
        let status = if let data {
            upsert(data, for: key)
        } else {
            remove(key)
        }
        if status != errSecSuccess {
            logFailure("write", status: status)
        }
    }

    private func upsert(_ data: Data, for key: String) -> OSStatus {
        let query = baseQuery(for: key)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        guard status == errSecItemNotFound else {
            return status
        }
        return SecItemAdd(query.merging([kSecValueData: data]) { $1 } as CFDictionary, nil)
    }

    private func remove(_ key: String) -> OSStatus {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    private func logFailure(_ operation: String, status: OSStatus) {
        let reason = SecCopyErrorMessageString(status, nil).map { String($0) } ?? "unknown error"
        Task {
            await Logging.shared.log("Keychain \(operation) failed with error \(status): \(reason)")
        }
    }
}
