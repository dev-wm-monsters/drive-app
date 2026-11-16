// Placeholder menu-bar app so the DMG pipeline has something to build.
// It shows its name and version, plus the B01 spike status section (storage
// service registration, XPC ping, sample range read, FS extension state).

import AppKit
import SwiftUI

@main
struct DriveAppMain: App {
    @State private var spike = SpikeController()  // B01

    var body: some Scene {
        MenuBarExtra(AppInfo.name, systemImage: "externaldrive") {
            Text(AppInfo.name)
            Text(AppInfo.versionLine)
            Divider()
            SpikeStatusView(controller: spike)  // B01
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
