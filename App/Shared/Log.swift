// Unified logging for the app and the File Provider extension.
//
// Privacy rules (contract): never log tokens, auth codes or upload session
// URLs. File names and Drive IDs are logged with `privacy: .private` only.

import Foundation
import os

enum Log {
    /// One subsystem for both processes so `log stream --predicate
    /// 'subsystem == "<APP_BUNDLE_ID>"'` shows the app and the extension.
    static let subsystem: String = {
        let id = Bundle.main.bundleIdentifier ?? "DriveApp"
        let suffix = ".fileprovider"
        return id.hasSuffix(suffix) ? String(id.dropLast(suffix.count)) : id
    }()

    static let app = Logger(subsystem: subsystem, category: "app")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let domain = Logger(subsystem: subsystem, category: "domain")
    static let provider = Logger(subsystem: subsystem, category: "fileprovider")
    static let enumeration = Logger(subsystem: subsystem, category: "enumeration")
    static let transfer = Logger(subsystem: subsystem, category: "transfer")

    /// "<domain> <code>" for errors from Foundation/FileProvider: their
    /// descriptions can carry file paths (user and file names) or URLs, so
    /// only this is logged at public level.
    static func code(of error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
