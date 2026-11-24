// The single File Provider domain this app registers.
//
// One domain, fixed identifier, display name = the shared drive's name, so
// Finder shows "WakeupMonster" under Locations. Changing the identifier would
// orphan existing installs' replicated folders; keep it stable.

import FileProvider
import Foundation

enum DomainIdentity {
    static var identifier: NSFileProviderDomainIdentifier { NSFileProviderDomainIdentifier(rawValue: "wakeupmonster") }

    static func domain(displayName: String) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: identifier, displayName: displayName)
    }
}
