import Foundation

/// Which part of Google Drive is mirrored.
public enum RootSelector: Sendable, Codable, Hashable {
    /// Resolve with `drives.list?q=name = '<name>'`; exactly one match required.
    case sharedDriveNamed(String)
    /// A known shared drive ID (shared-drive mode, no name lookup).
    case sharedDriveID(String)
    /// A single folder by ID (folder mode: changes are filtered through `FolderIndex`).
    case folderID(String)
}

public struct DriveConfig: Sendable {
    public static let driveScope = "https://www.googleapis.com/auth/drive"
    public static let defaultScopes = [driveScope, "openid", "email"]
    public static let defaultSharedDriveName = "WakeupMonster"

    public var clientID: String
    /// Only for Google "Desktop app" clients (Windows). The Mac "iOS" client has none: keep `nil`.
    public var clientSecret: String?
    public var redirectURI: URL
    public var scopes: [String]
    public var root: RootSelector
    public var pollInterval: Duration

    public init(
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: URL,
        scopes: [String] = DriveConfig.defaultScopes,
        root: RootSelector,
        pollInterval: Duration = .seconds(30)
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.root = root
        self.pollInterval = pollInterval
    }

    /// Builds the config from an `Info.plist` dictionary.
    ///
    /// Keys: `GoogleClientID` (required), `GoogleClientSecret` (optional, normally absent on Mac),
    /// `DriveRootFolderID` (non-empty wins), `DriveRootSharedDriveName`.
    /// `GoogleReversedClientID` is not read here: the caller derives `redirectURI` from it
    /// (see `iOSClientRedirectURI(reversedClientID:)`), and the File Provider extension does not need it.
    /// Values are trimmed; unexpanded build settings (`$(...)`) count as empty.
    public static func fromInfoDictionary(_ d: [String: Any], redirectURI: URL) throws(DriveError) -> DriveConfig {
        func value(_ key: String) -> String {
            guard let raw = d[key] as? String else { return "" }
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.hasPrefix("$(") ? "" : v
        }
        let clientID = value("GoogleClientID")
        guard !clientID.isEmpty else { throw .notConfigured("GoogleClientID") }
        let secret = value("GoogleClientSecret")
        let folderID = value("DriveRootFolderID")
        let driveName = value("DriveRootSharedDriveName")
        let root: RootSelector
        if !folderID.isEmpty {
            root = .folderID(folderID)
        } else if !driveName.isEmpty {
            root = .sharedDriveNamed(driveName)
        } else {
            throw .notConfigured("DriveRootSharedDriveName")
        }
        return DriveConfig(
            clientID: clientID,
            clientSecret: secret.isEmpty ? nil : secret,
            redirectURI: redirectURI,
            root: root
        )
    }

    /// `<reversed client id>:/oauth2redirect`, the redirect URI of a Google "iOS" OAuth client.
    public static func iOSClientRedirectURI(reversedClientID: String) -> URL? {
        let r = reversedClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return nil }
        return URL(string: "\(r):/oauth2redirect")
    }
}
