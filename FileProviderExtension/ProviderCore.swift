// Drive-facing logic of the extension, independent of FileProvider's
// callback style: everything here is async and throws DriveError (or a
// FileProvider/Cocoa error built by our own guards).

import DriveCore
import FileProvider
import Foundation

/// Result of one enumerateChanges round.
struct ChangeSet: Sendable {
    var updated: [FileProviderItem] = []
    var deleted: [String] = []
    var nextAnchor: Data
    var moreComing: Bool
}

final class ProviderCore: Sendable {
    let services: DriveServices
    let index: ItemIndex
    private let folderIndexRestore = OnceFlag()

    init(services: DriveServices) {
        self.services = services
        self.index = ItemIndex.shared(in: try? services.shared.providerStateDirectory())
    }

    private var client: DriveClient { services.client }

    // MARK: Root and identifiers

    /// The resolved root; the item index is reset if the root changed.
    func root() async throws(DriveError) -> DriveRoot {
        let root = try await services.root()
        await index.ensureRoot(root.id)
        if root.driveID == nil, await folderIndexRestore.claim(), var saved = await index.folderIndex(forRoot: root.id) {
            // Folder mode: DriveClient filters changes with its FolderIndex,
            // which starts empty in a new process. Re-seed it, keeping
            // anything a concurrent call already added.
            if let current = await client.folderIndexSnapshot(), current.rootID == saved.rootID {
                current.folderIDs.forEach { saved.insert(folderID: $0) }
                current.itemIDs.forEach { saved.insert(fileID: $0) }
            }
            await client.restoreFolderIndex(saved)
        }
        return root
    }

    /// Persists the item index (and, in folder mode, DriveClient's FolderIndex).
    func saveIndex(root: DriveRoot) async {
        if root.driveID == nil, let snapshot = await client.folderIndexSnapshot() {
            await index.setFolderIndex(snapshot)
        }
        await index.save()
    }

    static func driveID(for identifier: String, root: DriveRoot) -> String {
        identifier == NSFileProviderItemIdentifier.rootContainer.rawValue ? root.id : identifier
    }

    static func fpIdentifier(forDriveID id: String, root: DriveRoot) -> NSFileProviderItemIdentifier {
        id == root.id ? .rootContainer : NSFileProviderItemIdentifier(rawValue: id)
    }

    /// The parent we show the item under: a parent we already know, else the first.
    func parentID(of file: DriveFile, root: DriveRoot) async -> String {
        for p in file.parents {
            if p == root.id { return p }
            if await index.entry(p) != nil { return p }
        }
        return file.parents.first ?? root.id
    }

    private func makeItem(_ file: DriveFile, name: String, parentID: String, root: DriveRoot) -> FileProviderItem {
        FileProviderItem(file: file, displayName: name, parentIdentifier: Self.fpIdentifier(forDriveID: parentID, root: root), root: root)
    }

    // MARK: Folder listing

    /// Lists a folder, assigns display names, refreshes the index.
    func listFolder(driveID folderID: String, root: DriveRoot, markEnumerated: Bool) async throws(DriveError) -> (items: [FileProviderItem], update: ItemIndex.FolderUpdate) {
        let children = try await client.listChildren(of: folderID, root: root)
        let names = DisplayNames.assign(children)
        let update = await index.replaceChildren(of: folderID, with: children, names: names, markEnumerated: markEnumerated)
        let items = children.compactMap { file -> FileProviderItem? in
            guard let name = names[file.id] else { return nil }
            return makeItem(file, name: name, parentID: folderID, root: root)
        }
        return (items, update)
    }

    /// Items of a container (folder or root) for enumerateItems.
    func items(inContainer identifier: String) async throws(DriveError) -> [FileProviderItem] {
        let root = try await root()
        let folderID = Self.driveID(for: identifier, root: root)
        // The system also opens enumerators on documents (live updates for
        // one file). A file has no children; never record it as a listed folder.
        if await isKnownFile(folderID) { return [] }
        let result = try await listFolder(driveID: folderID, root: root, markEnumerated: true)
        await saveIndex(root: root)
        Log.enumeration.debug("Listed \(result.items.count, privacy: .public) items in \(folderID, privacy: .private)")
        return result.items
    }

    /// Folders listed per working-set page: each is one or more Drive calls,
    /// and a page should take seconds, not minutes (header: "not expected to
    /// take more than a few seconds to complete the enumeration of a page").
    static let workingSetFoldersPerPage = 10

    /// Working-set items: everything in the folders the system has listed,
    /// `workingSetFoldersPerPage` folders (sorted by ID) per page starting at
    /// `offset`. `nextOffset` is nil on the last page.
    func workingSetItems(offset: Int) async throws(DriveError) -> (items: [FileProviderItem], nextOffset: Int?) {
        let root = try await root()
        let folders = await index.enumeratedFolders.sorted()
        let start = min(max(offset, 0), folders.count)
        let end = min(start + Self.workingSetFoldersPerPage, folders.count)
        var all: [FileProviderItem] = []
        for folderID in folders[start..<end] {
            do {
                all += try await listFolder(driveID: folderID, root: root, markEnumerated: true).items
            } catch .notFound {
                await index.remove([folderID])   // folder gone; its parent's listing reports it
            }
        }
        await saveIndex(root: root)
        return (all, end < folders.count ? end : nil)
    }

    /// For folder enumerators: a fresh listing reported as changes. Always
    /// correct whatever the anchor, and the working set carries the rest.
    func folderRefresh(identifier: String) async throws(DriveError) -> ChangeSet {
        let root = try await root()
        let anchor = try await currentAnchor(root: root)
        let folderID = Self.driveID(for: identifier, root: root)
        if await isKnownFile(folderID) {
            return ChangeSet(updated: [], deleted: [], nextAnchor: anchor, moreComing: false)
        }
        let result = try await listFolder(driveID: folderID, root: root, markEnumerated: true)
        await saveIndex(root: root)
        // Deletions are global: only report items that left the tree, not
        // items re-parented into another listed folder.
        var deleted: [String] = []
        for id in result.update.departed.sorted() where await index.entry(id) == nil {
            deleted.append(id)
        }
        return ChangeSet(updated: result.items, deleted: deleted, nextAnchor: anchor, moreComing: false)
    }

    private func isKnownFile(_ id: String) async -> Bool {
        if let entry = await index.entry(id) { return !entry.isFolder }
        return false
    }

    // MARK: Single items

    /// Display name for `file` under `parentID`: from the index, else by listing the parent.
    func displayName(of file: DriveFile, parentID: String, root: DriveRoot) async throws(DriveError) -> String {
        if let e = await index.entry(file.id), e.parentID == parentID { return e.displayName }
        let children = try await client.listChildren(of: parentID, root: root)
        let names = DisplayNames.assign(children)
        await index.replaceChildren(of: parentID, with: children, names: names, markEnumerated: false)
        await saveIndex(root: root)
        return names[file.id] ?? DisplayNames.sanitize(file.name)
    }

    func item(identifier: String) async throws(DriveError) -> FileProviderItem {
        let root = try await root()
        let id = Self.driveID(for: identifier, root: root)
        if id == root.id { return FileProviderItem(root: root) }
        let file = try await client.file(id: id)
        if file.isHidden { throw .notFound }
        let parent = await parentID(of: file, root: root)
        let name = try await displayName(of: file, parentID: parent, root: root)
        return makeItem(file, name: name, parentID: parent, root: root)
    }

    /// Fresh metadata + display name, for fetchContents.
    func fileAndItem(identifier: String) async throws(DriveError) -> (DriveFile, FileProviderItem) {
        let root = try await root()
        let id = Self.driveID(for: identifier, root: root)
        let file = try await client.file(id: id)
        if file.isHidden { throw .notFound }
        let parent = await parentID(of: file, root: root)
        let name = try await displayName(of: file, parentID: parent, root: root)
        return (file, makeItem(file, name: name, parentID: parent, root: root))
    }

    /// The child of `parentIdentifier` currently shown as `filename`, if any.
    func existingChild(named filename: String, parentIdentifier: String) async throws(DriveError) -> FileProviderItem? {
        let root = try await root()
        let parentID = Self.driveID(for: parentIdentifier, root: root)
        if !(await index.isEnumerated(parentID)) {
            _ = try await listFolder(driveID: parentID, root: root, markEnumerated: false)
        }
        let match = await index.children(of: parentID).first { $0.value.displayName == filename }
        guard let match else { return nil }
        return try await item(identifier: match.key)
    }

    // MARK: Upload

    func upload(contents: URL, desiredName: String, parentIdentifier: String, progress: (@Sendable (Int64, Int64) -> Void)?) async throws(DriveError) -> FileProviderItem {
        let root = try await root()
        let parentID = Self.driveID(for: parentIdentifier, root: root)
        // Passing the root scopes the free-name sibling listing to the shared
        // drive (corpora=drive) even when the root came from the cache.
        let created = try await client.upload(file: contents, desiredName: desiredName, parentID: parentID, root: root, progress: progress)
        Log.transfer.info("Uploaded \(created.id, privacy: .private) to \(parentID, privacy: .private)")
        // The upload picked a free name, so the display name normally equals it;
        // compute it from the real listing anyway so all paths agree.
        let name: String
        do {
            let listing = try await listFolder(driveID: parentID, root: root, markEnumerated: false)
            name = listing.items.first { $0.driveID == created.id }?.filename ?? DisplayNames.sanitize(created.name)
        } catch {
            name = DisplayNames.sanitize(created.name)
            await index.upsert(id: created.id, entry: .init(parentID: parentID, displayName: name, isFolder: created.isFolder))
        }
        await saveIndex(root: root)
        return makeItem(created, name: name, parentID: parentID, root: root)
    }

    // MARK: Changes (working set)

    private struct Anchor: Codable {
        var rootID: String
        var token: String
    }

    func currentAnchor(root given: DriveRoot? = nil) async throws(DriveError) -> Data {
        let root: DriveRoot
        if let given { root = given } else { root = try await self.root() }
        let token = try await client.startPageToken(root: root)
        return Self.encode(Anchor(rootID: root.id, token: token))
    }

    private static func encode(_ anchor: Anchor) -> Data {
        (try? JSONEncoder().encode(anchor)) ?? Data()
    }

    enum AnchorProblem: Error { case expired }

    /// One page of Drive changes since `anchorData`, mapped onto items in
    /// folders the system has listed. Throws AnchorProblem.expired when the
    /// anchor is unusable (other root, corrupt).
    func workingSetChanges(since anchorData: Data) async throws -> ChangeSet {
        let root = try await root()
        guard let anchor = try? JSONDecoder().decode(Anchor.self, from: anchorData),
              anchor.rootID == root.id, !anchor.token.isEmpty
        else { throw AnchorProblem.expired }

        let batch: ChangeBatch
        do {
            batch = try await client.changes(since: anchor.token, root: root)
        } catch .invalidResponse(let detail) where detail.hasPrefix("HTTP 400") || detail.hasPrefix("HTTP 410") {
            // Drive rejects an invalid/expired page token with 400 (DriveClient
            // reports it as invalidResponse, not .server): re-sync instead of
            // retrying the same token forever.
            throw AnchorProblem.expired
        }

        var affectedParents: Set<String> = []
        var deleted: Set<String> = []
        var touched: Set<String> = []

        for change in batch.changes {
            switch change {
            case .removed(let id):
                if let old = await index.entry(id) { affectedParents.insert(old.parentID) }
                deleted.insert(id)
                deleted.formUnion(await index.descendants(of: id))
            case .upsert(let file):
                if file.id == root.id { continue }
                let old = await index.entry(file.id)
                if file.isHidden {
                    if let old { affectedParents.insert(old.parentID) }
                    deleted.insert(file.id)
                    deleted.formUnion(await index.descendants(of: file.id))
                    continue
                }
                let parent = await parentID(of: file, root: root)
                if let old, old.parentID != parent {
                    affectedParents.insert(old.parentID)
                    // Moved somewhere the system has never listed: it disappears here.
                    if !(await index.isEnumerated(parent)) { deleted.insert(file.id) }
                }
                affectedParents.insert(parent)
                touched.insert(file.id)
            }
        }

        // Names are per folder: re-list every affected folder the system has
        // listed and report items that are new, changed, or renamed because a
        // sibling appeared or disappeared.
        var updated: [String: FileProviderItem] = [:]
        for parent in affectedParents.subtracting(deleted).sorted() {
            guard await index.isEnumerated(parent) else { continue }
            do {
                let listing = try await listFolder(driveID: parent, root: root, markEnumerated: true)
                let report = listing.update.changed.union(touched)
                for item in listing.items where report.contains(item.driveID) {
                    updated[item.driveID] = item
                }
                deleted.formUnion(listing.update.departed)
            } catch .notFound {
                // The folder itself is gone; its own removal is in this or a later batch.
                deleted.insert(parent)
                deleted.formUnion(await index.descendants(of: parent))
            }
        }

        deleted.subtract(updated.keys)
        deleted.remove(root.id)
        await index.remove(deleted)
        await saveIndex(root: root)

        let next: String
        let moreComing: Bool
        if let start = batch.newStartPageToken {
            next = start
            moreComing = false
        } else if let page = batch.nextPageToken {
            next = page
            moreComing = true
        } else {
            next = anchor.token
            moreComing = false
        }
        services.shared.recordSyncSuccess()
        return ChangeSet(
            updated: Array(updated.values),
            deleted: deleted.sorted(),
            nextAnchor: Self.encode(Anchor(rootID: root.id, token: next)),
            moreComing: moreComing
        )
    }
}

/// True for the first caller only.
actor OnceFlag {
    private var claimed = false
    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}
