// Enumerators for folders (including the root) and for the working set.
//
// Folder: enumerateItems lists the folder (all Drive pages, one FileProvider
//   page). enumerateChanges re-lists the folder and reports it as changes,
//   which is correct for any anchor; regular change tracking happens on the
//   working set, which the system consumes for replicated domains.
// Working set: enumerateChanges reads Drive's changes feed from the anchor
//   (the anchor wraps the Drive page token and the root ID) and maps it onto
//   folders the system has listed. The app signals the working set every 30 s.

import DriveCore
import FileProvider
import Foundation

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private enum Kind {
        case folder(String)   // NSFileProviderItemIdentifier raw value
        case workingSet
    }

    private let kind: Kind
    private let core: ProviderCore
    private let tasks = TaskBag()

    /// Items handed to didEnumerate/didUpdate per call.
    private static let batchSize = 200

    init(containerIdentifier: NSFileProviderItemIdentifier, core: ProviderCore) {
        self.kind = containerIdentifier == .workingSet ? .workingSet : .folder(containerIdentifier.rawValue)
        self.core = core
        super.init()
    }

    func invalidate() {
        tasks.cancelAll()
    }

    // MARK: Items

    func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let observerBox = UncheckedBox(observer)
        let kind = self.kind
        let core = self.core
        let pageData = page.rawValue
        tasks.run {
            do {
                let items: [FileProviderItem]
                var nextPage: NSFileProviderPage?
                switch kind {
                case .folder(let id):
                    items = try await core.items(inContainer: id)
                case .workingSet:
                    let result = try await core.workingSetItems(offset: Self.workingSetOffset(from: pageData))
                    items = result.items
                    nextPage = result.nextOffset.map { NSFileProviderPage(rawValue: Data("ws:\($0)".utf8)) }
                }
                try Task.checkCancellation()
                for start in stride(from: 0, to: items.count, by: Self.batchSize) {
                    let slice = items[start..<min(start + Self.batchSize, items.count)]
                    observerBox.value.didEnumerate(Array(slice))
                }
                observerBox.value.finishEnumerating(upTo: nextPage)
            } catch {
                Log.enumeration.error("enumerateItems failed: \(String(describing: DriveError.from(error)), privacy: .public)")
                observerBox.value.finishEnumeratingWithError(FileProviderErrors.map(error))
            }
        }
    }

    /// Our working-set pages are "ws:<folder offset>"; the system's initial
    /// pages (sorted by date / name) start at 0.
    static func workingSetOffset(from page: Data) -> Int {
        guard let text = String(data: page, encoding: .utf8), text.hasPrefix("ws:") else { return 0 }
        return Int(text.dropFirst(3)) ?? 0
    }

    // MARK: Changes

    func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let observerBox = UncheckedBox(observer)
        let kind = self.kind
        let core = self.core
        let anchorData = anchor.rawValue
        tasks.run {
            do {
                let changes: ChangeSet
                switch kind {
                case .folder(let id): changes = try await core.folderRefresh(identifier: id)
                case .workingSet: changes = try await core.workingSetChanges(since: anchorData)
                }
                try Task.checkCancellation()
                let observer = observerBox.value
                for start in stride(from: 0, to: changes.updated.count, by: Self.batchSize) {
                    let slice = changes.updated[start..<min(start + Self.batchSize, changes.updated.count)]
                    observer.didUpdate(Array(slice))
                }
                if !changes.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: changes.deleted.map { NSFileProviderItemIdentifier(rawValue: $0) })
                }
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(rawValue: changes.nextAnchor), moreComing: changes.moreComing)
            } catch is ProviderCore.AnchorProblem {
                Log.enumeration.info("Sync anchor expired; the system will re-enumerate")
                observerBox.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            } catch {
                let drive = DriveError.from(error)
                Log.enumeration.error("enumerateChanges failed: \(String(describing: drive), privacy: .public)")
                var context = FileProviderErrors.Context.read
                if case .workingSet = kind {
                    context = .syncAnchor
                    if drive != .cancelled { core.services.shared.recordSyncError(drive.userMessage) }
                }
                observerBox.value.finishEnumeratingWithError(FileProviderErrors.map(error, context: context))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let done = Once<NSFileProviderSyncAnchor?> { completionHandler($0) }
        let core = self.core
        tasks.run {
            do {
                let data = try await core.currentAnchor()
                done(NSFileProviderSyncAnchor(rawValue: data))
            } catch {
                // nil tells the system no anchor is available right now.
                Log.enumeration.error("currentSyncAnchor failed: \(String(describing: DriveError.from(error)), privacy: .public)")
                done(nil)
            }
        }
    }
}

/// Tracks an enumerator's running tasks so invalidate() can cancel them.
final class TaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var invalidated = false

    func run(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return }
        let task = Task { [weak self] in
            await operation()
            self?.finish(id)
        }
        tasks[id] = task
    }

    private func finish(_ id: UUID) {
        lock.lock()
        tasks[id] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        invalidated = true
        let running = Array(tasks.values)
        tasks = [:]
        lock.unlock()
        running.forEach { $0.cancel() }
    }
}
