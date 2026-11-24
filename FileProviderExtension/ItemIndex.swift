// Persistent map Drive ID -> (parent ID, display name), plus the set of
// folders the system has enumerated.
//
// Why: display names are assigned per folder (DisplayNames.assign over all
// siblings), so item(for:) cannot compute a name from one file alone. Every
// folder listing refreshes that folder's entries here, and item(for:),
// createItem and the change engine read them back, so all paths return the
// SAME filename for an item.
//
// Storage: JSON in <App Group container>/FileProvider/item-index.json, written
// atomically after each mutation batch. Only this extension process writes it.
// One instance per process (`ItemIndex.shared`), because the system may host
// several extension instances in one process.

import DriveCore
import Foundation

actor ItemIndex {
    struct Entry: Codable, Sendable, Equatable {
        var parentID: String
        var displayName: String
        var isFolder: Bool
    }

    private struct Snapshot: Codable {
        var version = 1
        var rootID: String = ""
        var entries: [String: Entry] = [:]
        var enumeratedFolders: Set<String> = []
        /// DriveClient's folder-mode tree index (nil in shared-drive mode),
        /// persisted so change filtering survives extension restarts.
        var folderIndex: FolderIndex?
    }

    private let fileURL: URL?
    private var snapshot = Snapshot()
    private var childrenByParent: [String: Set<String>] = [:]
    private var loaded = false
    private var dirty = false

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    // MARK: Process-wide instance

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [URL: ItemIndex] = [:]

    /// The index stored in `directory` (shared per process).
    static func shared(in directory: URL?) -> ItemIndex {
        guard let directory else { return ItemIndex(fileURL: nil) }
        let url = directory.appendingPathComponent("item-index.json")
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[url] { return existing }
        let index = ItemIndex(fileURL: url)
        registry[url] = index
        return index
    }

    // MARK: Loading / saving

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data), decoded.version == 1
        else { return }
        snapshot = decoded
        rebuildChildren()
    }

    private func rebuildChildren() {
        childrenByParent = [:]
        for (id, entry) in snapshot.entries {
            childrenByParent[entry.parentID, default: []].insert(id)
        }
    }

    /// Writes pending changes atomically. Failures only cost a re-listing.
    func save() {
        guard dirty, let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            dirty = false
        } catch {
            Log.enumeration.error("Saving item index failed: \(Log.code(of: error), privacy: .public)")
        }
    }

    /// Drops everything if the configured root changed (different drive/folder).
    func ensureRoot(_ rootID: String) {
        loadIfNeeded()
        guard snapshot.rootID != rootID else { return }
        snapshot = Snapshot()
        snapshot.rootID = rootID
        childrenByParent = [:]
        dirty = true
        save()
    }

    // MARK: Queries

    func entry(_ id: String) -> Entry? {
        loadIfNeeded()
        return snapshot.entries[id]
    }

    func isEnumerated(_ folderID: String) -> Bool {
        loadIfNeeded()
        return snapshot.enumeratedFolders.contains(folderID)
    }

    var enumeratedFolders: Set<String> {
        loadIfNeeded()
        return snapshot.enumeratedFolders
    }

    func children(of parentID: String) -> [String: Entry] {
        loadIfNeeded()
        var result: [String: Entry] = [:]
        for id in childrenByParent[parentID] ?? [] {
            if let e = snapshot.entries[id] { result[id] = e }
        }
        return result
    }

    /// All known descendants of `id` (not including `id`).
    func descendants(of id: String) -> Set<String> {
        loadIfNeeded()
        var result: Set<String> = []
        var stack = Array(childrenByParent[id] ?? [])
        while let next = stack.popLast() {
            guard result.insert(next).inserted else { continue }
            stack.append(contentsOf: childrenByParent[next] ?? [])
        }
        return result
    }

    func folderIndex(forRoot rootID: String) -> FolderIndex? {
        loadIfNeeded()
        guard let f = snapshot.folderIndex, f.rootID == rootID else { return nil }
        return f
    }

    // MARK: Mutations

    func setFolderIndex(_ folderIndex: FolderIndex?) {
        loadIfNeeded()
        guard snapshot.folderIndex != folderIndex else { return }
        snapshot.folderIndex = folderIndex
        dirty = true
    }

    struct FolderUpdate: Sendable {
        /// IDs that are new in this folder or whose display name changed.
        var changed: Set<String> = []
        /// IDs that were children before and are not any more.
        var departed: Set<String> = []
    }

    /// Replaces the children of `folderID` with a fresh listing.
    /// `names` is DisplayNames.assign(children).
    @discardableResult
    func replaceChildren(of folderID: String, with children: [DriveFile], names: [String: String], markEnumerated: Bool) -> FolderUpdate {
        loadIfNeeded()
        var update = FolderUpdate()
        let previous = childrenByParent[folderID] ?? []
        var current: Set<String> = []
        for file in children {
            guard let name = names[file.id] else { continue }   // hidden items have no name
            current.insert(file.id)
            let entry = Entry(parentID: folderID, displayName: name, isFolder: file.isFolder)
            let old = snapshot.entries[file.id]
            if old != entry {
                update.changed.insert(file.id)
                if let old, old.parentID != folderID {
                    childrenByParent[old.parentID]?.remove(file.id)
                }
                snapshot.entries[file.id] = entry
            }
        }
        update.departed = previous.subtracting(current)
        for id in update.departed where snapshot.entries[id]?.parentID == folderID {
            snapshot.entries[id] = nil
        }
        childrenByParent[folderID] = current
        if markEnumerated { snapshot.enumeratedFolders.insert(folderID) }
        if !update.changed.isEmpty || !update.departed.isEmpty || markEnumerated { dirty = true }
        return update
    }

    /// Records a single item (e.g. one we just uploaded) without a folder listing.
    func upsert(id: String, entry: Entry) {
        loadIfNeeded()
        if let old = snapshot.entries[id], old.parentID != entry.parentID {
            childrenByParent[old.parentID]?.remove(id)
        }
        snapshot.entries[id] = entry
        childrenByParent[entry.parentID, default: []].insert(id)
        dirty = true
    }

    /// Forgets items (and, for folders, their enumerated state).
    func remove(_ ids: Set<String>) {
        loadIfNeeded()
        for id in ids {
            if let old = snapshot.entries.removeValue(forKey: id) {
                childrenByParent[old.parentID]?.remove(id)
                dirty = true
            }
            if snapshot.enumeratedFolders.remove(id) != nil { dirty = true }
            childrenByParent[id] = nil
        }
    }
}
