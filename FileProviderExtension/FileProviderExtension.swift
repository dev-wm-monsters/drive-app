// File Provider extension (NSFileProviderReplicatedExtension) exposing the
// WakeupMonster shared drive (or the configured folder) in Finder.
//
// Behaviour (contract v2):
//   - The whole tree is visible with metadata; files download on open.
//   - Existing items are read-only: rename / move / edit / delete are rolled
//     back (modifyItem returns the server state; deleteItem is rejected).
//   - New files dropped into a folder are uploaded. New folders, packages and
//     symlinks are excluded from sync (they stay local, marked "not synced").
//   - The trash container is not supported.
//
// Every FileProvider callback starts a Task, returns a Progress whose
// cancellation cancels that Task, and calls its completion handler exactly
// once (see Bridging.swift).

import CoreGraphics
import DriveCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing, @unchecked Sendable {
    private let domain: UncheckedBox<NSFileProviderDomain>
    /// The Drive side, or why it is unavailable (missing configuration).
    private let core: Result<ProviderCore, DriveError>
    private let tasks = TaskBag()

    init(domain: NSFileProviderDomain) {
        self.domain = UncheckedBox(domain)
        do {
            let config = try AppConfig.load(from: .main)
            core = .success(ProviderCore(services: DriveServices(config: config)))
        } catch {
            Log.provider.fault("Extension not configured: \(error.userMessage, privacy: .public)")
            core = .failure(error)
        }
        super.init()
        Log.provider.info("Extension started for domain \(domain.identifier.rawValue, privacy: .public)")
        Self.removeStaleTemporaryFiles(domain: domain)
    }

    /// fetchContents hands the system files in the domain's temporary
    /// directory; after a crash some may be left behind ("The extension is
    /// then responsible for deleting that file"). Only files older than a day
    /// are removed, so downloads of other live instances are never touched.
    private static func removeStaleTemporaryFiles(domain: NSFileProviderDomain) {
        guard let manager = NSFileProviderManager(for: domain),
              let directory = try? manager.temporaryDirectoryURL()
        else { return }
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
            for entry in entries {
                if let modified = try? entry.resourceValues(forKeys: Set(keys)).contentModificationDate, modified < cutoff {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }

    func invalidate() {
        Log.provider.info("Extension invalidated")
        tasks.cancelAll()
    }

    // MARK: Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> any NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer {
            // Header: unsupported trash -> NSCocoaErrorDomain / NSFeatureUnsupportedError.
            throw FileProviderErrors.unsupported
        }
        let core = try self.core.get()
        return FileProviderEnumerator(containerIdentifier: containerItemIdentifier, core: core)
    }

    // MARK: Item lookup

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Once<(NSFileProviderItem?, (any Error)?)> { completionHandler($0.0, $0.1) }
        guard identifier != .trashContainer, identifier != .workingSet else {
            done((nil, NSFileProviderError(.noSuchItem)))
            return progress
        }
        let core: ProviderCore
        do { core = try self.core.get() } catch {
            done((nil, FileProviderErrors.map(error)))
            return progress
        }
        let id = identifier.rawValue
        let progressBox = UncheckedBox(progress)
        startTask(for: progress, onCancel: { done((nil, FileProviderErrors.cancelled)) }) {
            do {
                let item = try await core.item(identifier: id)
                progressBox.value.completedUnitCount = 1
                done((item, nil))
            } catch {
                done((nil, FileProviderErrors.map(error)))
            }
        }
        return progress
    }

    // MARK: Download

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Once<(URL?, NSFileProviderItem?, (any Error)?)> { completionHandler($0.0, $0.1, $0.2) }
        let core: ProviderCore
        let temporaryDirectory: URL
        do {
            core = try self.core.get()
            // Same volume as the replicated files, as the header requires.
            guard let manager = NSFileProviderManager(for: domain.value) else {
                throw NSFileProviderError(.providerNotFound)
            }
            temporaryDirectory = try manager.temporaryDirectoryURL()
        } catch {
            done((nil, nil, FileProviderErrors.map(error)))
            return progress
        }
        let id = itemIdentifier.rawValue
        let progressBox = UncheckedBox(progress)
        startTask(for: progress, onCancel: { done((nil, nil, FileProviderErrors.cancelled)) }) {
            let destination = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
            do {
                let (file, item) = try await core.fileAndItem(identifier: id)
                guard !file.isFolder else { throw FileProviderErrors.unsupported }
                guard file.canDownload else { throw CocoaError(.fileReadNoPermission) }
                // Byte progress, so the system sees a long download advancing
                // ("will interrupt the call if it stops making progress").
                // VERIFY-ON-MAC: Finder shows a progress bar for a large file.
                let size = max(file.size ?? 0, 1)
                progressBox.value.totalUnitCount = size
                progressBox.value.completedUnitCount = 0
                try await core.services.client.download(id: file.id, to: destination, expectedMD5: file.md5Checksum) { received, total in
                    let p = progressBox.value
                    if let total, total > 0, p.totalUnitCount != total { p.totalUnitCount = total }
                    p.completedUnitCount = min(received, p.totalUnitCount)
                }
                try Task.checkCancellation()
                progressBox.value.completedUnitCount = progressBox.value.totalUnitCount
                Log.transfer.info("Downloaded \(file.id, privacy: .private)")
                if !done((destination, item, nil)) {
                    try? FileManager.default.removeItem(at: destination)
                }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                Log.transfer.error("Download failed: \(String(describing: DriveError.from(error)), privacy: .public)")
                done((nil, nil, FileProviderErrors.map(error)))
            }
        }
        return progress
    }

    // MARK: Create (upload new files)

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Once<(NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?)> {
            completionHandler($0.0, $0.1, $0.2, $0.3)
        }
        // Read everything needed from the (non-Sendable) template up front.
        let filename = itemTemplate.filename
        let parentIdentifier = itemTemplate.parentItemIdentifier.rawValue
        let type = itemTemplate.contentType ?? .data
        let mayAlreadyExist = options.contains(.mayAlreadyExist)

        // v1 uploads regular files only. Folders, packages (directories on
        // disk) and symlinks stay on disk but are excluded from sync; the
        // system then shows them as "not synced" and calls deleteItem for the
        // template identifier, which we accept (unknown item).
        // VERIFY-ON-MAC: Finder "New Folder" in the domain leaves a local,
        // "not synced" folder (rather than an error dialog or a deletion).
        if type.conforms(to: .directory) || type.conforms(to: .symbolicLink)
            || parentIdentifier == NSFileProviderItemIdentifier.trashContainer.rawValue
            || Self.isLocalOnlyName(filename) {
            Log.provider.info("Excluding a new non-file item from sync")
            done((nil, [], false, NSFileProviderError(.excludedFromSync)))
            return progress
        }
        let core: ProviderCore
        do { core = try self.core.get() } catch {
            done((nil, [], false, FileProviderErrors.map(error, context: .write)))
            return progress
        }

        let size = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        progress.totalUnitCount = Int64(max(size, 1))
        let progressBox = UncheckedBox(progress)
        startTask(for: progress, onCancel: { done((nil, [], false, FileProviderErrors.cancelled)) }) {
            do {
                if mayAlreadyExist {
                    // Re-import after a reset/restore: match by display name in the parent.
                    if let existing = try await core.existingChild(named: filename, parentIdentifier: parentIdentifier) {
                        done((existing, [], false, nil))
                        return
                    }
                    guard url != nil else {
                        // Dataless and unknown to Drive: refuse (the system removes it).
                        done((nil, [], false, nil))
                        return
                    }
                }
                guard let url else {
                    done((nil, [], false, FileProviderErrors.unsupported))
                    return
                }
                let item = try await core.upload(contents: url, desiredName: filename, parentIdentifier: parentIdentifier) { sent, total in
                    let p = progressBox.value
                    if total > 0, p.totalUnitCount != total { p.totalUnitCount = total }
                    p.completedUnitCount = sent
                }
                progressBox.value.completedUnitCount = progressBox.value.totalUnitCount
                // The returned filename may differ from the template's (free
                // name picked up front, sanitised); the system renames on disk.
                done((item, [], false, nil))
            } catch {
                Log.transfer.error("Upload failed: \(String(describing: DriveError.from(error)), privacy: .public)")
                done((nil, [], false, FileProviderErrors.map(error, context: .write)))
            }
        }
        return progress
    }

    /// Files that Finder and editors create next to documents (view settings,
    /// AppleDouble, Office/LibreOffice lock files). Uploading them would
    /// publish them to every user of the shared drive; they stay local.
    static func isLocalOnlyName(_ name: String) -> Bool {
        name == ".DS_Store" || name == "Icon\r" || name.hasPrefix("._")
            || name.hasPrefix("~$") || name.hasPrefix(".~lock.")
    }

    // MARK: Modify (rejected: roll back to the server state)

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Once<(NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?)> {
            completionHandler($0.0, $0.1, $0.2, $0.3)
        }
        let id = item.itemIdentifier.rawValue
        // Local-only metadata (last used date, tags, xattrs, flags, dates):
        // nothing to send to Drive. Returning the fields as still pending,
        // identical to changedFields, marks them unsupported, so the system
        // stops sending them and never needs the network for them (e.g.
        // opening a downloaded file offline updates lastUsedDate).
        let structural: NSFileProviderItemFields = [.contents, .filename, .parentItemIdentifier]
        if changedFields.isDisjoint(with: structural) {
            done((item, changedFields, false, nil))
            return progress
        }
        let core: ProviderCore
        do { core = try self.core.get() } catch {
            done((nil, [], false, FileProviderErrors.map(error)))
            return progress
        }
        // Existing items are read-only. Returning the unchanged server item
        // with no pending fields makes the system put the server's name,
        // parent and dates back on disk; for content edits, shouldFetchContent
        // restores the server's content. (Header: "If a field in the returned
        // item does not match ... the value from the item will be propagated
        // to the disk.")
        // VERIFY-ON-MAC: a rename/move/edit from Terminal is reverted on disk
        // (and the edited content re-downloaded) without a conflict copy.
        let refetch = changedFields.contains(.contents)
        Log.provider.info("Rolling back a local change to a read-only item")
        startTask(for: progress, onCancel: { done((nil, [], false, FileProviderErrors.cancelled)) }) {
            do {
                let current = try await core.item(identifier: id)
                done((current, [], refetch, nil))
            } catch {
                done((nil, [], false, FileProviderErrors.map(error)))
            }
        }
        return progress
    }

    // MARK: Delete (rejected)

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping ((any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let done = Once<(any Error)?> { completionHandler($0) }
        if identifier == .rootContainer {
            done(NSFileProviderError(.deletionRejected))
            return progress
        }
        let core: ProviderCore
        do { core = try self.core.get() } catch {
            done(FileProviderErrors.map(error))
            return progress
        }
        let id = identifier.rawValue
        // Excluded local items carry a system template identifier, never a
        // Drive file ID: unknown to us, so the deletion succeeds without a
        // network round trip.
        guard Self.isDriveFileID(id) else {
            done(nil)
            return progress
        }
        startTask(for: progress, onCancel: { done(FileProviderErrors.cancelled) }) {
            // deletionRejected makes the system re-create the item on disk.
            // Items Drive does not know (already deleted remotely) must report
            // success. Anything else (offline, garbled response) is NOT a
            // confirmation that the item is gone, so it is not reported as one.
            do {
                _ = try await core.item(identifier: id)
                Log.provider.info("Rejecting deletion of a read-only item")
                done(NSFileProviderError(.deletionRejected))
            } catch {
                switch DriveError.from(error) {
                case .notFound:
                    done(nil)
                case .invalidResponse(let detail) where detail.hasPrefix("HTTP 400"):
                    done(nil)   // Drive rejects the ID itself
                default:
                    done(FileProviderErrors.map(error))
                }
            }
        }
        return progress
    }

    /// Drive file IDs are URL-safe base64-like strings.
    static func isDriveFileID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }

    // MARK: Thumbnails
    // VERIFY-ON-MAC: Finder asks the extension for thumbnails through
    // NSFileProviderThumbnailing conformance alone (no extra Info.plist key).

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize, perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, (any Error)?) -> Void, completionHandler: @escaping ((any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let perItem = UncheckedBox(perThumbnailCompletionHandler)
        let done = Once<(any Error)?> { completionHandler($0) }
        let core: ProviderCore
        do { core = try self.core.get() } catch {
            done(FileProviderErrors.map(error))
            return progress
        }
        let ids = itemIdentifiers.map(\.rawValue)
        let maxPixels = Int(max(size.width, size.height).rounded(.up))
        let progressBox = UncheckedBox(progress)
        let finished = Once<Void> { _ in }
        startTask(for: progress, onCancel: { finished(()); done(FileProviderErrors.cancelled) }) {
            for id in ids {
                if Task.isCancelled || finished.hasFired { break }
                let identifier = NSFileProviderItemIdentifier(rawValue: id)
                do {
                    let data = try await core.thumbnail(identifier: id, maxPixels: maxPixels)
                    if !finished.hasFired { perItem.value(identifier, data, nil) }
                } catch {
                    if !finished.hasFired { perItem.value(identifier, nil, FileProviderErrors.map(error)) }
                }
                progressBox.value.completedUnitCount += 1
            }
            finished(())
            done(nil)
        }
        return progress
    }
}
