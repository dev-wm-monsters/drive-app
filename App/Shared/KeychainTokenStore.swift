// OAuth token storage shared by the app (which signs in) and the File
// Provider extension (which calls Drive).
//
// Storage: one generic-password item in the data-protection keychain
// (kSecUseDataProtectionKeychain), in access group = the App Group ID
// ("<TEAM>.<APP_BUNDLE_ID>"), so both processes read the same item.
// The value is the JSON-encoded OAuthTokens. Nothing token-related is logged.
//
// Signing requirement (TN3137): on macOS the data-protection keychain and
// any keychain access group must be authorised by a provisioning profile.
// Signed (Developer ID) builds therefore embed Developer ID provisioning
// profiles for $(APP_BUNDLE_ID) and $(APP_BUNDLE_ID).fileprovider with the
// App Groups capability (group <TEAM>.<APP_BUNDLE_ID>), passed in through
// DRIVEAPP_APP_PROFILE / DRIVEAPP_EXT_PROFILE (project.yml). With a profile
// the signature also carries com.apple.application-identifier, which the
// data-protection keychain requires.
//
// VERIFY-ON-MAC: that the App Group ID is accepted as kSecAttrAccessGroup by
// both the app and the extension under those profiles. If it is not, add
// `keychain-access-groups = [$(AppIdentifierPrefix)$(APP_BUNDLE_ID).shared]`
// to both entitlements files (and the profiles' Keychain Sharing capability)
// and pass "<TEAM>.<APP_BUNDLE_ID>.shared" as `accessGroup`.
//
// VERIFY-ON-MAC (unsigned / ad-hoc builds): those builds have no profile, the
// restricted entitlements are stripped and the App Group is the
// non-team-prefixed ".com.wakeupmonster.driveapp.dev". Every SecItem call
// then fails with errSecMissingEntitlement (-34018). That is reported as
// KeychainError.missingEntitlement (never a crash); the app shows "This build
// can't share sign-in with the Finder extension" and does not register the
// Finder location. Such builds are only useful for UI smoke tests.

import DriveCore
import Foundation
import Security

enum KeychainError: Error, Sendable, Equatable, CustomStringConvertible {
    /// errSecMissingEntitlement: the build is not entitled to the access group.
    case missingEntitlement
    case unexpectedStatus(OSStatus)
    case corruptItem

    /// Shown when this build cannot share tokens with the extension.
    static let unsharedBuildMessage = "This build can't share sign-in with the Finder extension (it is not signed with a provisioning profile). Use a signed release build."

    var description: String {
        switch self {
        case .missingEntitlement:
            return KeychainError.unsharedBuildMessage
        case .unexpectedStatus(let status):
            return "Keychain error \(status)."
        case .corruptItem:
            return "Stored sign-in data is unreadable."
        }
    }
}

struct KeychainTokenStore: TokenStore {
    let service: String
    let account: String
    let accessGroup: String

    init(accessGroup: String, service: String = "com.wakeupmonster.driveapp.oauth", account: String = "google") {
        self.accessGroup = accessGroup
        self.service = service
        self.account = account
    }

    init(config: AppConfig) {
        self.init(accessGroup: config.appGroup)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func load() throws -> OAuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.corruptItem }
            do {
                return try JSONDecoder().decode(OAuthTokens.self, from: data)
            } catch {
                Log.keychain.error("Stored tokens could not be decoded; treating as signed out")
                throw KeychainError.corruptItem
            }
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(for: status, operation: "load")
        }
    }

    func save(_ tokens: OAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery
            add[kSecValueData as String] = data
            // Readable by the extension while the user is logged in, even
            // with the screen locked; never migrates to another device.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.error(for: addStatus, operation: "add") }
        default:
            throw Self.error(for: status, operation: "update")
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status, operation: "delete")
        }
    }

    private static func error(for status: OSStatus, operation: String) -> KeychainError {
        Log.keychain.error("Keychain \(operation, privacy: .public) failed: OSStatus \(status, privacy: .public)")
        return status == errSecMissingEntitlement ? .missingEntitlement : .unexpectedStatus(status)
    }
}
