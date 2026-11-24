// Google sign-in UI: ASWebAuthenticationSession on the authorization URL
// built by DriveCore's OAuthClient (authorization code + PKCE S256 + state).
//
// The redirect is <reversed client id>:/oauth2redirect (Google "iOS" client
// type). ASWebAuthenticationSession intercepts that scheme itself, so the app
// declares no CFBundleURLTypes.

import AppKit
import AuthenticationServices
import DriveCore
import Foundation

enum SignInError: Error, Equatable {
    case cancelled
    case couldNotStart
    case stateMismatch
    case denied(String)
    case missingCode

    var message: String {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .couldNotStart: return "Could not open the Google sign-in window."
        case .stateMismatch: return "Sign-in response did not match the request. Try again."
        case .denied(let reason): return "Google refused the sign-in (\(reason))."
        case .missingCode: return "Google returned no authorization code."
        }
    }
}

@MainActor
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// Runs the full browser round trip and returns the authorization code.
    func authorizationCode(oauth: OAuthClient, pkce: PKCE, callbackScheme: String) async throws -> String {
        let state = OAuthClient.makeState()
        let url = oauth.authorizationURL(pkce: pkce, state: state)
        let callback = try await present(url: url, callbackScheme: callbackScheme)
        // Never log `callback`: it carries the authorization code.
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw SignInError.stateMismatch }
        if let error = value("error") {
            throw error == "access_denied" ? SignInError.cancelled : SignInError.denied(error)
        }
        guard let code = value("code"), !code.isEmpty else { throw SignInError.missingCode }
        return code
    }

    private func present(url: URL, callbackScheme: String) async throws -> URL {
        defer { session = nil }
        NSApplication.shared.activate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let resume = ResumeOnce(continuation)
            // @Sendable: the handler is not MainActor-bound, so it is safe
            // whichever thread AuthenticationServices calls it on.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { @Sendable callbackURL, error in
                if let callbackURL {
                    resume.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    resume.resume(throwing: SignInError.cancelled)
                } else {
                    resume.resume(throwing: error ?? SignInError.cancelled)
                }
            }
            session.presentationContextProvider = self
            // Share Safari's cookies so an already signed-in Workspace account is offered.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                resume.resume(throwing: SignInError.couldNotStart)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // A menu-bar (LSUIElement) app usually has no window; AppKit accepts a
        // fresh window as the anchor and shows the sign-in sheet standalone.
        // VERIFY-ON-MAC: the sign-in window appears in front when started from the menu.
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

/// Resumes a continuation at most once.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }

    func resume(returning value: T) { take()?.resume(returning: value) }
    func resume(throwing error: any Error) { take()?.resume(throwing: error) }
}
