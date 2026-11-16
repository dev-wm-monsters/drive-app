// Placeholder menu-bar app so the DMG pipeline has something to build.
// No features yet: it only shows its name and version. B01 adds the FSKit
// extension and storage service as separate targets (see project.yml).

import AppKit
import SwiftUI

@main
struct DriveAppMain: App {
    var body: some Scene {
        MenuBarExtra(AppInfo.name, systemImage: "externaldrive") {
            Text(AppInfo.name)
            Text(AppInfo.versionLine)
            Divider()
            Button("Quit \(AppInfo.name)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

/// Values read from Info.plist at runtime (never hard-coded).
enum AppInfo {
    static let name: String = string(for: "CFBundleName") ?? "DriveApp"
    static let version: String = string(for: "CFBundleShortVersionString") ?? "?"
    static let build: String = string(for: "CFBundleVersion") ?? "?"
    static let versionLine = "Version \(version) (\(build))"

    private static func string(for key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
