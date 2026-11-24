// DriveError -> errors FileProvider understands.
//
// The headers require errors in NSFileProviderErrorDomain or NSCocoaErrorDomain;
// anything else must be wrapped in NSCocoaErrorDomain/NSXPCConnectionReplyInvalid
// with NSUnderlyingErrorKey (NSFileProviderReplicatedExtension.h, "Error cases").
//   notAuthenticated / serverUnreachable -> system shows a message and backs off
//                                            until the next signalEnumerator
//                                            (the app signals every 30 s).
//   noSuchItem                           -> system deletes the item from disk.
//   anything else                        -> transient, retried by the system.

import DriveCore
import FileProvider
import Foundation

enum FileProviderErrors {
    enum Context: Sendable {
        case read          // item lookup, enumeration, download
        case write         // create (upload)
        case syncAnchor    // enumerateChanges: an invalid token means "re-sync"
    }

    static func map(_ error: any Error, context: Context = .read) -> any Error {
        // Already a FileProvider/Cocoa error (e.g. thrown by our own guards).
        let ns = error as NSError
        if ns.domain == NSFileProviderErrorDomain || ns.domain == NSCocoaErrorDomain,
           !(error is DriveError), !(error is CancellationError) {
            return error
        }
        let drive = DriveError.from(error)
        switch drive {
        case .needsLogin, .unauthorized:
            return NSFileProviderError(.notAuthenticated)
        case .network, .rateLimited:
            return NSFileProviderError(.serverUnreachable)
        case .server(let status):
            if context == .syncAnchor, status == 400 || status == 410 {
                return NSFileProviderError(.syncAnchorExpired)
            }
            return status >= 500 ? NSFileProviderError(.serverUnreachable) : wrapped(drive)
        case .notFound:
            return context == .syncAnchor ? NSFileProviderError(.syncAnchorExpired) : NSFileProviderError(.noSuchItem)
        case .quotaExceeded:
            return NSFileProviderError(.insufficientQuota)
        case .forbidden:
            return context == .write ? NSFileProviderError(.cannotSynchronize) : CocoaError(.fileReadNoPermission)
        case .cancelled:
            return CocoaError(.userCancelled)
        case .checksumMismatch:
            return CocoaError(.fileReadCorruptFile)
        case .rootNotFound, .rootAmbiguous, .notConfigured:
            // Needs user action in the app; the app shows the guidance.
            return NSFileProviderError(.cannotSynchronize)
        case .invalidResponse:
            return wrapped(drive)
        }
    }

    /// NSCocoaErrorDomain / NSXPCConnectionReplyInvalid with the original
    /// error underneath, as the headers prescribe for unrepresentable errors.
    static func wrapped(_ error: DriveError) -> any Error {
        NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.xpcConnectionReplyInvalid.rawValue,
            userInfo: [
                NSUnderlyingErrorKey: error as NSError,
                NSLocalizedDescriptionKey: error.userMessage,
            ]
        )
    }

    static var cancelled: any Error { CocoaError(.userCancelled) }
    static var unsupported: any Error { CocoaError(.featureUnsupported) }
}
