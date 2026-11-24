// NSFileProviderManager calls made by the app: register / remove the single
// domain, signal the working set, locate the root folder in Finder.
//
// Completion-handler APIs are wrapped in continuations with @Sendable
// handlers, so they are safe whichever queue FileProvider calls back on.
// Only Sendable values leave these functions.

import FileProvider
import Foundation

enum DomainController {
    /// Registers (or updates) the domain. Idempotent for the same identifier.
    static func add(displayName: String) async throws {
        let domain = DomainIdentity.domain(displayName: displayName)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSFileProviderManager.add(domain) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        Log.domain.info("Domain registered")
    }

    /// Removes the domain and its replicated files (they live on Drive).
    /// Dirty user data (files added locally whose upload has not finished)
    /// is preserved by the system instead of being deleted with the domain.
    static func remove() async throws {
        guard let domain = try await registeredDomain() else { return }
        let preserved = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            NSFileProviderManager.remove(domain.value, mode: .preserveDirtyUserData) { @Sendable preservedLocation, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: preservedLocation != nil) }
            }
        }
        // VERIFY-ON-MAC: where the system puts preserved files (a folder the
        // user can find); the location itself is not logged (it holds the home path).
        Log.domain.info("Domain removed\(preserved ? "; unsynced local files were preserved" : "", privacy: .public)")
    }

    static func isRegistered() async -> Bool {
        (try? await registeredDomain()) != nil
    }

    /// Asks the system to enumerate working-set changes now; the extension
    /// then reads Drive's changes feed.
    static func signalWorkingSet() async throws {
        let manager = try await manager()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            manager.value.signalEnumerator(for: .workingSet) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// The root folder's location in Finder (under ~/Library/CloudStorage).
    static func rootURL() async throws -> URL {
        let manager = try await manager()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            manager.value.getUserVisibleURL(for: .rootContainer) { @Sendable url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? NSFileProviderError(.providerNotFound))
                }
            }
        }
    }

    // MARK: Private

    private static func registeredDomain() async throws -> UncheckedDomain? {
        let domains = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedDomains, any Error>) in
            NSFileProviderManager.getDomainsWithCompletionHandler { @Sendable domains, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: UncheckedDomains(value: domains))
                }
            }
        }
        return domains.value.first { $0.identifier == DomainIdentity.identifier }.map(UncheckedDomain.init)
    }

    private static func manager() async throws -> UncheckedManager {
        guard let domain = try await registeredDomain() else {
            throw NSFileProviderError(.providerNotFound)
        }
        guard let manager = NSFileProviderManager(for: domain.value) else {
            throw NSFileProviderError(.providerNotFound)
        }
        return UncheckedManager(value: manager)
    }

    // FileProvider classes are not annotated Sendable; these boxes only move
    // them between our own awaits, never into concurrently running code.
    private struct UncheckedDomains: @unchecked Sendable { let value: [NSFileProviderDomain] }
    private struct UncheckedDomain: @unchecked Sendable {
        let value: NSFileProviderDomain
        init(_ value: NSFileProviderDomain) { self.value = value }
    }
    private struct UncheckedManager: @unchecked Sendable { let value: NSFileProviderManager }
}
