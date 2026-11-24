// Small state shared between the app and the File Provider extension through
// the App Group: UserDefaults(suiteName: appGroup) for scalar values and the
// App Group container directory for the extension's item index.
//
// Writers:
//   app       - root (after resolving it), cleared on sign-out
//   extension - root (if it had to resolve it itself), last sync time/error
// Readers: both. Values are re-read on every access (no caching), because the
// other process may have changed them.

import DriveCore
import Foundation

struct SharedState: Sendable {
    let appGroup: String

    init(appGroup: String) {
        self.appGroup = appGroup
    }

    init(config: AppConfig) {
        self.init(appGroup: config.appGroup)
    }

    private enum Key {
        static let root = "DriveRoot.v1"
        static let lastSync = "LastSyncDate"
        static let lastError = "LastSyncError"
        static let lastErrorDate = "LastSyncErrorDate"
    }

    // UserDefaults is created per access instead of being stored, which keeps
    // this struct Sendable regardless of the SDK's UserDefaults annotations.
    private var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    // MARK: Root

    /// The resolved Drive root, cached so the extension does not resolve it again.
    var root: DriveRoot? {
        guard let data = defaults?.data(forKey: Key.root) else { return nil }
        return try? JSONDecoder().decode(DriveRoot.self, from: data)
    }

    func setRoot(_ root: DriveRoot?) {
        guard let defaults else { return }
        if let root, let data = try? JSONEncoder().encode(root) {
            defaults.set(data, forKey: Key.root)
        } else {
            defaults.removeObject(forKey: Key.root)
        }
    }

    // MARK: Sync status (written by the extension, shown by the app)

    var lastSync: Date? {
        guard let t = defaults?.object(forKey: Key.lastSync) as? Double else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// Last sync error message (user-facing, no secrets), nil after a clean sync.
    var lastSyncError: String? { defaults?.string(forKey: Key.lastError) }

    func recordSyncSuccess(at date: Date = Date()) {
        defaults?.set(date.timeIntervalSince1970, forKey: Key.lastSync)
        defaults?.removeObject(forKey: Key.lastError)
        defaults?.removeObject(forKey: Key.lastErrorDate)
    }

    func recordSyncError(_ message: String, at date: Date = Date()) {
        defaults?.set(message, forKey: Key.lastError)
        defaults?.set(date.timeIntervalSince1970, forKey: Key.lastErrorDate)
    }

    /// Forget everything (sign-out). The item index file is removed as well.
    func reset() {
        if let defaults {
            for key in [Key.root, Key.lastSync, Key.lastError, Key.lastErrorDate] {
                defaults.removeObject(forKey: key)
            }
        }
        if let dir = try? providerStateDirectory() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Files

    /// `<App Group container>/FileProvider`, created on demand.
    func providerStateDirectory() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "App Group container \(appGroup) is unavailable."])
        }
        let dir = container.appendingPathComponent("FileProvider", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
