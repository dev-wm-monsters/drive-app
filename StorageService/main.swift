// main.swift
// DriveAppStorageService: LaunchAgent registered by the host app with SMAppService. launchd starts
// it on demand when a client looks up its Mach service (LaunchAgent plist `MachServices`).
// B01 serves the deterministic fixture catalog via StorageCore's SpikeEngine. No network, no cloud.
//
// Docs relied on:
// - https://developer.apple.com/documentation/foundation/nsxpclistener/init(machservicename:)
// - https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:)  (macOS 13+)
// - https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)
// - https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos
//
// Configuration comes from the Info.plist embedded in this binary
// (CREATE_INFOPLIST_SECTION_IN_BINARY = YES): DriveAppStorageMachService, DriveAppTeamID,
// DriveAppBaseBundleID.
// G0-VERIFY: `Bundle.main.infoDictionary` of a command-line tool reads the embedded
// `__TEXT,__info_plist` section, with build settings expanded. Check with
// `launchctl print gui/$UID/<label>` plus the "Service started" log line below.
// G0-VERIFY: the Mach name `$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID).storage` is prefixed by the App
// Group `$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID)`, which is what lets the sandboxed app and FSKit
// extension look it up. That prefix rule, and the FSKit extension running in the user's launchd
// domain where this agent's name is visible, are the core G0 assumptions.

import Foundation
import os
import StorageCore

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DriveAppStorageService", category: "service")

guard let machServiceName = MachServiceName.resolve() else {
    logger.fault("Embedded Info.plist lacks \(MachServiceName.infoPlistKey, privacy: .public); exiting")
    exit(EXIT_FAILURE)
}

// Only the host app and the FSKit extension of the same team may connect.
let clientRequirement = PeerRequirement.make(identity: ServiceIdentity.resolve()) { identity in
    [identity.appBundleID, identity.extensionBundleID]
}

let listener = NSXPCListener(machServiceName: machServiceName)
let connectionRequirement: String?
switch clientRequirement {
case .enforce(let requirement):
    listener.setConnectionCodeSigningRequirement(requirement)
    connectionRequirement = requirement
case .skippedForDebugBuild:
    logger.fault("DEBUG BUILD WITHOUT TEAM ID: accepting XPC clients WITHOUT code-signing checks")
    connectionRequirement = nil
case .unavailable:
    logger.fault("No team ID / base bundle ID in the embedded Info.plist; refusing to run unauthenticated")
    exit(EXIT_FAILURE)
}

let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
let engine = SpikeEngine(catalog: .spike, version: version)
// NSXPCListener.delegate is weak; this top-level constant keeps the delegate alive.
let delegate = ServiceDelegate(engine: engine, peerRequirement: connectionRequirement, logger: logger)
listener.delegate = delegate
listener.resume()
logger.info("Service started: version \(version, privacy: .public), pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public)")

dispatchMain()
