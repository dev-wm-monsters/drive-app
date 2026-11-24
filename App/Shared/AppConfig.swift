// Runtime configuration, read from the running bundle's Info.plist.
//
// project.yml (settings.base) is the single source; XcodeGen writes the same
// keys into App/Info.plist and FileProviderExtension/Info.plist:
//   GoogleClientID, GoogleReversedClientID, DriveRootSharedDriveName,
//   DriveRootFolderID, DriveAppGroup.
// Nothing here is hard-coded per environment.

import DriveCore
import Foundation

struct AppConfig: Sendable {
    /// DriveCore configuration (client ID, redirect URI, scopes, root, poll interval).
    let drive: DriveConfig
    /// App Group shared by the app and the extension: "<TEAM>.<APP_BUNDLE_ID>".
    /// Also used as the keychain access group for the shared token store.
    let appGroup: String

    /// Info.plist key holding the App Group identifier.
    static let appGroupKey = "DriveAppGroup"
    /// Info.plist key holding the reversed Google client ID.
    static let reversedClientIDKey = "GoogleReversedClientID"

    /// Loads the configuration from `bundle` (the app or the extension bundle).
    static func load(from bundle: Bundle = .main) throws(DriveError) -> AppConfig {
        let info = bundle.infoDictionary ?? [:]
        let redirectURI = try redirectURI(from: info)
        let drive = try DriveConfig.fromInfoDictionary(info, redirectURI: redirectURI)
        // Not validated here: an unsigned/ad-hoc build carries ".<bundle id>"
        // (empty DEVELOPMENT_TEAM). The app still starts and reports that
        // sign-in cannot be shared (see hasTeamPrefixedAppGroup).
        let group = (info[appGroupKey] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return AppConfig(drive: drive, appGroup: group)
    }

    /// `<reversed client id>:/oauth2redirect` (Google "iOS" OAuth client type).
    static func redirectURI(from info: [String: Any]) throws(DriveError) -> URL {
        let reversed = (info[reversedClientIDKey] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !reversed.hasPrefix("$("),
              let url = DriveConfig.iOSClientRedirectURI(reversedClientID: reversed)
        else {
            throw .notConfigured("\(reversedClientIDKey) is empty. Set GOOGLE_REVERSED_CLIENT_ID in project.yml.")
        }
        return url
    }

    /// False for builds without a team (unsigned / ad-hoc): the App Group,
    /// and with it the shared keychain group, does not exist there.
    var hasTeamPrefixedAppGroup: Bool {
        !appGroup.isEmpty && !appGroup.hasPrefix(".") && !appGroup.hasPrefix("$(")
    }

    /// The custom URL scheme ASWebAuthenticationSession listens for.
    var callbackURLScheme: String { drive.redirectURI.scheme ?? "" }

    /// Human-readable name of the configured root, for UI before it is resolved.
    var rootDisplayName: String {
        switch drive.root {
        case .sharedDriveNamed(let name): return name
        case .sharedDriveID(let id): return id
        case .folderID(let id): return id
        }
    }
}
