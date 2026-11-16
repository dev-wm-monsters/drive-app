// SpikeStatusView.swift
// B01 section for the menu-bar menu. Built only from Text, Button and Divider so it renders in a
// `MenuBarExtra` with the default `.menu` style (each Text is a disabled menu item).
//
// Docs relied on:
// - https://developer.apple.com/documentation/swiftui/menubarextra
// - https://developer.apple.com/documentation/appkit/nspasteboard

import AppKit
import SwiftUI

struct SpikeStatusView: View {
    let controller: SpikeController

    var body: some View {
        Section("B01 spike") {
            Text("Service: \(controller.serviceStatus)")
            Text("Ping: \(controller.pingResult)")
            Text("Sample read: \(controller.sampleResult)")
            Text("FS extension: \(controller.extensionStatus)")

            Button("Register Storage Service") { controller.registerService() }
            // Login Items & Extensions holds both the agent approval and the FS extension switch.
            Button(controller.serviceNeedsApproval ? "Approve in Login Items…" : "Open Login Items…") {
                controller.openLoginItems()
            }
            Button("Ping Service") { Task { await controller.ping() } }
            Button("Read Sample Range") { Task { await controller.readSample() } }
            Button("Check FS Extension") { Task { await controller.refreshExtensionStatus() } }
            Button("Refresh Status") { controller.refreshServiceStatus() }
            Button("Copy Mount Command") { copy(controller.mountCommand) }
            Button("Copy Unmount Command") { copy(controller.unmountCommand) }
            Button("Unregister Storage Service") { controller.unregisterService() }
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
