// SpikeItem.swift
// FSItem subclass carrying the StorageCore attributes (including the pinned revision) that the
// service returned when the item was looked up or listed.
//
// Docs / headers relied on:
// - https://developer.apple.com/documentation/fskit/fsitem
// - https://developer.apple.com/documentation/fskit/fsitem/attributes
// - https://developer.apple.com/documentation/fskit/fsitem/identifier
// - macOS 26.5 SDK FSKit.framework/Headers/FSItem.h (FSItemIDInvalid = 0, FSItemIDParentOfRoot = 1,
//   FSItemIDRootDirectory = 2; `FSItem` has a plain `init()`).

import Foundation
@preconcurrency import FSKit
import StorageCore

/// Immutable after init. `@unchecked Sendable` because FSItem is an un-annotated ObjC class; this
/// subclass adds only `let` properties and is never mutated, so sharing it across tasks is safe.
final class SpikeItem: FSItem, @unchecked Sendable {
    let entry: StorageCore.ItemAttributes
    let fileID: FSItem.Identifier
    let parentFileID: FSItem.Identifier

    init(entry: StorageCore.ItemAttributes) {
        self.entry = entry
        self.fileID = SpikeItem.fsIdentifier(for: entry.id)
        self.parentFileID = entry.id == .root ? .parentOfRoot : SpikeItem.fsIdentifier(for: entry.parent)
        super.init()
    }

    var itemType: FSItem.ItemType {
        entry.kind == .directory ? .directory : .file
    }

    /// Catalog IDs start at 1 (root) but FSKit reserves 0, 1 (parent of root) and 2 (root).
    /// Mapping: catalog root → `.rootDirectory`; any other ID n → n + 1 (so 2 → 3, ...).
    static func fsIdentifier(for id: ItemID) -> FSItem.Identifier {
        if id == .root { return .rootDirectory }
        let (raw, overflow) = id.rawValue.addingReportingOverflow(1)
        guard !overflow, raw > FSItem.Identifier.rootDirectory.rawValue else { return .invalid }
        return FSItem.Identifier(rawValue: raw) ?? .invalid
    }

    /// Full attribute set. Every field is filled so FSKit never sees "incomplete" attributes.
    /// Read-only modes (0444 / 0555); owner is the user running the extension.
    func fsAttributes(timestamp: timespec) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        let isDirectory = entry.kind == .directory
        attributes.type = itemType
        // G0-VERIFY: whether FSKit expects S_IFMT type bits in `mode` (set here, as in stat(2)).
        attributes.mode = isDirectory ? UInt32(S_IFDIR) | 0o555 : UInt32(S_IFREG) | 0o444
        attributes.linkCount = isDirectory ? 2 : 1
        attributes.uid = getuid()
        attributes.gid = getgid()
        attributes.flags = 0
        attributes.size = entry.size
        attributes.allocSize = entry.size
        attributes.fileID = fileID
        attributes.parentID = parentFileID
        attributes.accessTime = timestamp
        attributes.modifyTime = timestamp
        attributes.changeTime = timestamp
        attributes.birthTime = timestamp
        return attributes
    }
}
