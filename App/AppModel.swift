// State and actions behind the menu-bar UI.
//
// Flow: Sign in with Google -> tokens saved to the shared keychain -> resolve
// the root (shared drive "WakeupMonster" or configured folder) -> register the
// File Provider domain -> signal the working set every 30 s while running.

import AppKit
import DriveCore
import FileProvider
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case notConfigured(String)
        /// Unsigned / ad-hoc build: tokens cannot be shared with the extension.
        case unsupportedBuild
        case starting
        case signedOut
        case signingIn
        case connecting
        case connected
        case failed(String)
    }

    struct UploadStatus: Equatable {
        var fileName: String
        var index: Int      // 1-based
        var count: Int
        var fraction: Double
    }

    private(set) var phase: Phase = .starting
    private(set) var email: String?
    private(set) var rootName: String
    private(set) var lastSync: Date?
    private(set) var syncError: String?
    private(set) var upload: UploadStatus?
    /// Result of the last user action (sign-in, upload, Finder), cleared on the next one.
    private(set) var notice: String?

    @ObservationIgnored private let config: AppConfig?
    @ObservationIgnored private var services: DriveServices?
    @ObservationIgnored private let web = WebAuthenticator()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init() {
        do {
            let config = try AppConfig.load(from: .main)
            self.config = config
            self.rootName = config.rootDisplayName
            self.services = DriveServices(config: config)
        } catch {
            self.config = nil
            self.rootName = "WakeupMonster"
            self.phase = .notConfigured(error.userMessage)
            Log.app.error("Not configured: \(error.userMessage, privacy: .public)")
        }
    }

    /// Called once at launch: restores a saved sign-in and reconnects.
    func start() {
        guard !started else { return }
        started = true
        guard let config, let services else { return }
        guard config.hasTeamPrefixedAppGroup else {
            Log.app.error("No team-prefixed App Group; sign-in cannot be shared with the extension")
            phase = .unsupportedBuild
            return
        }
        Task {
            let tokens: OAuthTokens?
            do {
                tokens = try services.store.load()
            } catch KeychainError.missingEntitlement {
                phase = .unsupportedBuild
                return
            } catch KeychainError.corruptItem {
                phase = .signedOut
                return
            } catch {
                phase = .failed(Self.message(for: error))
                return
            }
            guard let tokens else {
                phase = .signedOut
                return
            }
            email = tokens.email
            await connect()
        }
    }

    var statusLine: String {
        switch phase {
        case .notConfigured(let message): return message
        case .unsupportedBuild: return KeychainError.unsharedBuildMessage
        case .starting: return "Starting\u{2026}"
        case .signedOut: return "Not signed in"
        case .signingIn: return "Signing in\u{2026}"
        case .connecting: return "Connecting to \(rootName)\u{2026}"
        case .connected:
            if let email { return "Connected to \(rootName) as \(email)" }
            return "Connected to \(rootName)"
        case .failed(let message): return message
        }
    }

    var isConnected: Bool { phase == .connected }
    var canSignIn: Bool {
        switch phase {
        case .signedOut, .failed: return services != nil
        default: return false
        }
    }

    // MARK: Sign in / out

    func signIn() async {
        guard let config, let services, canSignIn else { return }
        notice = nil
        phase = .signingIn
        do {
            let pkce = PKCE.generate()
            let code = try await web.authorizationCode(oauth: services.oauth, pkce: pkce, callbackScheme: config.callbackURLScheme)
            let tokens = try await services.oauth.exchange(code: code, pkce: pkce)
            try services.store.save(tokens)
            email = tokens.email
            Log.auth.info("Signed in")
            // Fresh AuthSession/DriveClient so nothing cached from before sign-in survives.
            self.services = DriveServices(config: config)
            await connect()
        } catch let error as SignInError {
            phase = .signedOut
            notice = error.message
        } catch KeychainError.missingEntitlement {
            phase = .unsupportedBuild
        } catch {
            let drive = DriveError.from(error)
            Log.auth.error("Sign-in failed: \(String(describing: drive), privacy: .public)")
            phase = drive == .cancelled ? .signedOut : .failed(drive.userMessage)
        }
    }

    func signOut() async {
        stopPolling()
        notice = nil
        do {
            try await DomainController.remove()
        } catch {
            Log.domain.error("Removing the domain failed: \(Log.code(of: error), privacy: .public)")
        }
        if let services {
            await services.auth.signOut()
            do { try services.store.clear() } catch {
                Log.keychain.error("Clearing tokens failed")
            }
            services.shared.reset()
        }
        email = nil
        lastSync = nil
        syncError = nil
        phase = .signedOut
        Log.auth.info("Signed out")
    }

    // MARK: Connect

    private func connect() async {
        guard let services else { return }
        phase = .connecting
        do {
            let root = try await services.root(forceRefresh: true)
            rootName = root.name
            try await DomainController.add(displayName: root.name)
            phase = .connected
            refreshStatus()
            startPolling()
        } catch {
            let drive = DriveError.from(error)
            Log.app.error("Connect failed: \(String(describing: drive), privacy: .public)")
            switch drive {
            case .needsLogin, .unauthorized:
                phase = .signedOut
                notice = drive.userMessage
            case .network, .server, .rateLimited:
                // Keep trying in the background; the domain may already exist.
                phase = .failed(drive.userMessage)
                scheduleReconnect()
            default:
                if error is DriveError || error is KeychainError {
                    phase = .failed(Self.message(for: error))
                } else {
                    // FileProvider refused the domain (e.g. extension not found/signed).
                    phase = .failed("Could not add the Finder location: \((error as NSError).localizedDescription)")
                }
            }
        }
    }

    /// User-facing text for any error from the sign-in / connect paths.
    static func message(for error: any Error) -> String {
        if let keychain = error as? KeychainError { return keychain.description }
        return DriveError.from(error).userMessage
    }

    private func scheduleReconnect() {
        let interval = config?.drive.pollInterval ?? .seconds(30)
        Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, case .failed = self.phase else { return }
            await self.connect()
        }
    }

    // MARK: Polling

    private func startPolling() {
        stopPolling()
        let interval = config?.drive.pollInterval ?? .seconds(30)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await DomainController.signalWorkingSet()
                } catch {
                    Log.domain.error("signalEnumerator failed: \(Log.code(of: error), privacy: .public)")
                }
                // Give the extension a moment to finish before reading its status.
                try? await Task.sleep(for: .seconds(3))
                self?.refreshStatus()
                try? await Task.sleep(for: interval - .seconds(3))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshStatus() {
        guard let services else { return }
        lastSync = services.shared.lastSync
        syncError = services.shared.lastSyncError
    }

    // MARK: Finder

    func openInFinder() async {
        notice = nil
        do {
            let url = try await DomainController.rootURL()
            NSWorkspace.shared.open(url)
        } catch {
            notice = "Could not open the folder: \((error as NSError).localizedDescription)"
        }
    }

    // MARK: Upload

    /// NSOpenPanel (multi-select) -> upload into the root folder.
    func chooseAndUpload() {
        guard isConnected, upload == nil else { return }
        NSApplication.shared.activate()
        let panel = NSOpenPanel()
        panel.title = "Upload to \(rootName)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await upload(urls) }
    }

    private func upload(_ urls: [URL]) async {
        guard let services else { return }
        notice = nil
        var uploaded = 0
        var failures: [String] = []
        do {
            let root = try await services.root()
            for (offset, url) in urls.enumerated() {
                let name = url.lastPathComponent
                upload = UploadStatus(fileName: name, index: offset + 1, count: urls.count, fraction: 0)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try await services.client.upload(file: url, desiredName: name, parentID: root.id, root: root) { sent, total in
                        let fraction = total > 0 ? Double(sent) / Double(total) : 0
                        Task { @MainActor [weak self] in self?.setUploadFraction(fraction, index: offset + 1) }
                    }
                    uploaded += 1
                    Log.transfer.info("Uploaded file \(offset + 1, privacy: .public) of \(urls.count, privacy: .public)")
                } catch {
                    let drive = DriveError.from(error)
                    failures.append("\(name): \(drive.userMessage)")
                    if drive == .needsLogin { break }
                }
            }
        } catch {
            failures.append(error.userMessage)
        }
        upload = nil
        if failures.isEmpty {
            notice = uploaded == 1 ? "Uploaded 1 file." : "Uploaded \(uploaded) files."
        } else {
            notice = "Uploaded \(uploaded) of \(urls.count). " + failures.prefix(3).joined(separator: " ")
        }
        try? await DomainController.signalWorkingSet()
    }

    private func setUploadFraction(_ fraction: Double, index: Int) {
        guard var status = upload, status.index == index else { return }
        status.fraction = min(max(fraction, 0), 1)
        upload = status
    }
}
