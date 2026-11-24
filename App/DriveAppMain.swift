// Menu-bar app (LSUIElement): sign in, status, open the Finder location,
// upload files, sign out. The files themselves are served by the File
// Provider extension (FileProviderExtension/).

import AppKit
import Foundation
import SwiftUI

@main
struct DriveAppMain: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Restore the session at launch, not when the menu is first opened.
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.isConnected ? "externaldrive.fill.badge.checkmark" : "externaldrive")
        }
    }
}

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(model.statusLine)
        if model.isConnected {
            if let lastSync = model.lastSync {
                Text("Last sync: \(lastSync.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Waiting for first sync\u{2026}")
            }
            if let syncError = model.syncError {
                Text(syncError)
            }
        }
        if let upload = model.upload {
            Text("Uploading \(upload.index) of \(upload.count): \(upload.fileName) (\(Int(upload.fraction * 100))%)")
        }
        if let notice = model.notice {
            Text(notice)
        }

        Divider()

        if model.canSignIn {
            Button("Sign in with Google\u{2026}") {
                Task { await model.signIn() }
            }
        }
        if model.isConnected {
            Button("Open in Finder") {
                Task { await model.openInFinder() }
            }
            Button("Upload Files\u{2026}") {
                model.chooseAndUpload()
            }
            .disabled(model.upload != nil)
        }
        if model.isConnected || model.phase == .connecting || isFailedWhileSignedIn {
            Button("Sign Out") {
                Task { await model.signOut() }
            }
        }

        Divider()

        Text("\(AppInfo.name) \(AppInfo.versionLine)")
        Button("Quit \(AppInfo.name)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var isFailedWhileSignedIn: Bool {
        if case .failed = model.phase { return model.email != nil }
        return false
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
