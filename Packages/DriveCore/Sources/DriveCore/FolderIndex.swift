import Foundation

/// Folder-mode membership: which folder (and item) IDs are known to be inside the root folder's tree.
///
/// The changes API cannot be scoped to a folder, so in folder mode `DriveClient.changes` keeps only changes whose
/// parents intersect the known folders, or whose file ID is already known. `DriveClient` fills its own index from
/// `listChildren` and from the changes it processes; a process that restarts can re-seed it with
/// `DriveClient.restoreFolderIndex(_:)`. Removing a folder does not remove its descendants (parentage is not tracked).
public struct FolderIndex: Sendable, Hashable, Codable {
    public let rootID: String
    public private(set) var folderIDs: Set<String>
    /// Every known item (folders and files), so a known file that moves out of the tree can be reported as removed.
    public private(set) var itemIDs: Set<String>

    public init(rootID: String) {
        self.rootID = rootID
        folderIDs = [rootID]
        itemIDs = [rootID]
    }

    public mutating func insert(folderID: String) {
        folderIDs.insert(folderID)
        itemIDs.insert(folderID)
    }

    public mutating func insert(fileID: String) {
        itemIDs.insert(fileID)
    }

    /// Relevant = already known, or at least one parent is a known folder.
    public func isRelevant(_ f: DriveFile) -> Bool {
        itemIDs.contains(f.id) || isInTree(f)
    }

    /// The file currently sits in the tree (is the root, or has a known folder as parent).
    public func isInTree(_ f: DriveFile) -> Bool {
        f.id == rootID || f.parents.contains(where: folderIDs.contains)
    }

    public func contains(_ id: String) -> Bool {
        itemIDs.contains(id)
    }

    /// Forgets an ID (the root itself is never removed).
    public mutating func remove(_ id: String) {
        guard id != rootID else { return }
        folderIDs.remove(id)
        itemIDs.remove(id)
    }
}
