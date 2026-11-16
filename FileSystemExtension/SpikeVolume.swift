// SpikeVolume.swift
// Read-only FSKit volume backed by StorageService over authenticated XPC.
// Lookups, listings and byte ranges come from the service; nothing is cached across revisions.
// Every mutating operation fails with EROFS (FR12). Failures map StorageError → POSIX (FR03).
//
// Docs / headers relied on:
// - https://developer.apple.com/documentation/fskit/fsvolume
// - https://developer.apple.com/documentation/fskit/fsvolume/operations  (deprecated in macOS 27 in
//   favour of FSVolume.Handler; Operations is the macOS 26 API this target builds against)
// - https://developer.apple.com/documentation/fskit/fsvolume/readwriteoperations
// - https://developer.apple.com/documentation/fskit/fsvolume/opencloseoperations
// - https://developer.apple.com/documentation/fskit/fsvolume/operations/enumeratedirectory(_:startingat:verifier:attributes:packer:replyhandler:)
// - https://developer.apple.com/documentation/fskit/fsvolume/readwriteoperations/read(from:at:length:into:replyhandler:)
// - https://developer.apple.com/documentation/fskit/fsdirectoryentrypacker
// - https://developer.apple.com/documentation/fskit/fsmutablefiledatabuffer
// - https://developer.apple.com/documentation/fskit/fsstatfsresult
// - https://developer.apple.com/documentation/fskit/fsvolume/supportedcapabilities
// - https://developer.apple.com/documentation/fskit/fs_errorforposixerror(_:)
// - https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system
// - macOS 26.5 SDK FSKit.framework/Headers/FSVolume.h and FSKit.swiftinterface (exact selectors and
//   Swift names; completion blocks are NOT annotated Sendable in the macOS 26 SDK).
//
// Concurrency: FSKit calls these methods on its own threads and accepts replies from any thread.
// Reply blocks, packers and buffers are un-annotated ObjC types, so they cross into Swift tasks in
// `FSKitBox` (unchecked). FSKit keeps the packer and buffer valid until the reply is called, and
// each reply is called exactly once.
// G0-VERIFY: witnesses use `@escaping` (non-Sendable) reply closures to match the macOS 26 SDK
// headers. Apple's current (macOS 27) documentation shows `@escaping @Sendable`; with
// `@preconcurrency import FSKit` a newer SDK should only warn. Re-check if the toolchain changes.

import Foundation
@preconcurrency import FSKit
import os
import StorageCore
import Synchronization

/// Carries a non-Sendable FSKit object into a task. See the file header for why this is safe.
struct FSKitBox<Value>: @unchecked Sendable {
    let value: Value
}

/// `@unchecked Sendable`: FSVolume is an un-annotated ObjC class. This subclass's own state is
/// immutable (`let`) or guarded by `Mutex`.
final class SpikeVolume: FSVolume, @unchecked Sendable {
    private struct InFlight {
        var tasks: [UInt64: Task<Void, Never>] = [:]
        var finishedEarly: Set<UInt64> = []
        var nextKey: UInt64 = 0
        var closed = false
    }

    static let fileSystemTypeName = "driveappspike"

    private let client: StorageServiceClient
    private let logger: Logger
    private let timestamp: timespec
    /// One SpikeItem per catalog item while FSKit holds it; dropped in reclaimItem.
    private let items = Mutex<[ItemID: SpikeItem]>([:])
    private let inFlight = Mutex(InFlight())

    init(client: StorageServiceClient, volumeID: FSVolume.Identifier, name: String, logger: Logger) {
        self.client = client
        self.logger = logger
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        self.timestamp = now
        super.init(volumeID: volumeID, volumeName: FSFileName(string: name))
    }

    // MARK: Helpers

    static func fsError(_ error: StorageError) -> any Error {
        fs_errorForPOSIXError(error.posixErrorCode)
    }

    static func fsError(posix code: Int32) -> any Error {
        fs_errorForPOSIXError(code)
    }

    private func item(for entry: StorageCore.ItemAttributes) -> SpikeItem {
        items.withLock { items in
            if let existing = items[entry.id], existing.entry == entry { return existing }
            let created = SpikeItem(entry: entry)
            items[entry.id] = created
            return created
        }
    }

    /// Runs `operation` as a tracked task so unmount/deactivate can cancel it. A cancelled task
    /// makes StorageServiceClient send `.cancel(requestID)` and the operation reply ECANCELED.
    private func spawn(_ operation: @escaping @Sendable () async -> Void) {
        let key = inFlight.withLock { state -> UInt64 in
            state.nextKey &+= 1
            return state.nextKey
        }
        let task = Task {
            await operation()
            self.finished(key)
        }
        let cancelNow = inFlight.withLock { state -> Bool in
            if state.finishedEarly.remove(key) != nil { return false }
            if state.closed { return true }
            state.tasks[key] = task
            return false
        }
        if cancelNow { task.cancel() }
    }

    private func finished(_ key: UInt64) {
        inFlight.withLock { state in
            if state.tasks.removeValue(forKey: key) == nil, !state.closed {
                state.finishedEarly.insert(key)
            }
        }
    }

    private func cancelInFlight(closing: Bool) {
        // Tasks stay registered until `finished(_:)` removes them; removing them here would make
        // `finished` record their keys in `finishedEarly`, where nothing ever removes them.
        let tasks = inFlight.withLock { state -> [Task<Void, Never>] in
            if closing { state.closed = true }
            return Array(state.tasks.values)
        }
        if !tasks.isEmpty {
            logger.info("Cancelling \(tasks.count, privacy: .public) in-flight operations")
        }
        for task in tasks { task.cancel() }
    }

    private func listAll(_ parent: ItemID) async throws(StorageError) -> [StorageCore.ItemAttributes] {
        var all: [StorageCore.ItemAttributes] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await client.call(.listItems(parent: parent, cursor: cursor, limit: Limits.maxListLimit)).expectPage()
            pages += 1
            if page.nextCursor != nil, page.items.isEmpty || pages >= 1_000 {
                throw .invalidArgument("listing does not make progress")
            }
            all += page.items
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }

    /// Nonzero value that changes whenever the listing changes (FSDirectoryVerifier contract).
    private static func verifier(for entries: [StorageCore.ItemAttributes]) -> FSDirectoryVerifier {
        let key = entries.map { "\($0.id.rawValue)/\($0.revision)/\($0.name)" }.joined(separator: "\n")
        let hash = FixtureFile.fnv1a64(key)
        return FSDirectoryVerifier(rawValue: hash == 0 ? 1 : hash)
    }
}

// MARK: - FSVolume.PathConfOperations

extension SpikeVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
}

// MARK: - FSVolume.Operations

extension SpikeVolume: FSVolume.Operations {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supports64BitObjectIDs = true
        capabilities.supportsSymbolicLinks = false
        capabilities.supportsHardLinks = false
        capabilities.supportsFastStatFS = true
        capabilities.supports2TBFiles = true
        capabilities.doesNotSupportVolumeSizes = true
        capabilities.doesNotSupportSettingFilePermissions = true
        capabilities.doesNotSupportImmutableFiles = true
        // The catalog matches names exactly (Unicode canonical equivalence, case-sensitive), so the
        // volume must not claim case-insensitive lookups.
        capabilities.caseFormat = .sensitive
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: Self.fileSystemTypeName)
        result.blockSize = 4096
        // Preferred I/O size: one IPC read reply, so kernel reads map to a single XPC round trip.
        result.ioSize = Int(Limits.maxReadReply)
        result.totalBlocks = 0
        result.availableBlocks = 0
        result.freeBlocks = 0
        result.usedBlocks = 0
        result.totalBytes = 0
        result.availableBytes = 0
        result.freeBytes = 0
        result.usedBytes = 0
        result.totalFiles = 0
        result.freeFiles = 0
        return result
    }

    /// Kernel-level read-only mount (FSMountOptions is macOS 26.4+). FSKit reads it after mount.
    /// G0-VERIFY: the 26.5 header declares this optional property read-write, hence the no-op setter.
    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions {
        get { .readOnly }
        set {}
    }

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        let reply = FSKitBox(value: reply)
        inFlight.withLock { $0.closed = false }
        // FR03: activation succeeds only if StorageService answers; otherwise a controlled error.
        spawn { [self] in
            do throws(StorageError) {
                let root = try await client.call(.stat(.root)).expectAttributes()
                guard root.kind == .directory else { throw .notDirectory }
                logger.info("Volume activated")
                reply.value(item(for: root), nil)
            } catch {
                logger.error("Activation failed: \(error.description, privacy: .public)")
                reply.value(nil, Self.fsError(error))
            }
        }
    }

    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        cancelInFlight(closing: true)
        items.withLock { $0.removeAll() }
        logger.info("Volume deactivated")
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        logger.info("Volume mounted")
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        cancelInFlight(closing: false)
        logger.info("Volume unmounted")
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil) // Nothing is ever dirty on a read-only volume.
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                       of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? SpikeItem else { return reply(nil, Self.fsError(posix: EINVAL)) }
        reply(item.fsAttributes(timestamp: timestamp), nil)
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                       on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? SpikeItem else { return reply(nil, Self.fsError(posix: EINVAL)) }
        // G0-VERIFY: the kernel may push access-time-only updates on open/read. Those are accepted
        // as no-ops so reads do not fail; any other change (chmod, chown, truncate, utimes of
        // modify time, chflags) is EROFS (FR12).
        let mutating: [FSItem.Attribute] = [
            .type, .mode, .linkCount, .uid, .gid, .flags, .size, .allocSize, .fileID, .parentID,
            .modifyTime, .changeTime, .birthTime, .backupTime, .addedTime,
        ]
        if mutating.contains(where: { newAttributes.isValid($0) }) {
            return reply(nil, Self.fsError(.readOnly))
        }
        if newAttributes.isValid(.accessTime) {
            newAttributes.consumedAttributes = .accessTime
        }
        reply(item.fsAttributes(timestamp: timestamp), nil)
    }

    func lookupItem(named name: FSFileName,
                    inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let directory = directory as? SpikeItem else { return reply(nil, nil, Self.fsError(posix: EINVAL)) }
        guard directory.entry.kind == .directory else { return reply(nil, nil, Self.fsError(.notDirectory)) }
        // Names that are not valid UTF-8 cannot exist in the catalog.
        guard let childName = name.string else { return reply(nil, nil, Self.fsError(.unknownItem)) }
        let parent = directory.entry.id
        let reply = FSKitBox(value: reply)
        spawn { [self] in
            do throws(StorageError) {
                let entry = try await client.call(.lookup(parent: parent, name: childName)).expectAttributes()
                reply.value(item(for: entry), FSFileName(string: entry.name), nil)
            } catch {
                if error != .unknownItem {
                    logger.error("lookup failed: \(error.description, privacy: .public)")
                }
                reply.value(nil, nil, Self.fsError(error))
            }
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        if let item = item as? SpikeItem {
            items.withLock { items in
                if items[item.entry.id] === item { items[item.entry.id] = nil }
            }
        }
        reply(nil)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, Self.fsError(posix: EINVAL)) // The catalog has no symbolic links.
    }

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, Self.fsError(.readOnly))
    }

    func createSymbolicLink(named name: FSFileName,
                            inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, Self.fsError(.readOnly))
    }

    func createLink(to item: FSItem,
                    named name: FSFileName,
                    inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, Self.fsError(.readOnly))
    }

    func removeItem(_ item: FSItem,
                    named name: FSFileName,
                    fromDirectory directory: FSItem,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(Self.fsError(.readOnly))
    }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, Self.fsError(.readOnly))
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        guard let directory = directory as? SpikeItem, directory.entry.kind == .directory else {
            return reply(.initial, Self.fsError(.notDirectory))
        }
        let reply = FSKitBox(value: reply)
        let packer = FSKitBox(value: packer)
        let wantsAttributes = attributes != nil
        let startCookie = cookie.rawValue
        let callerVerifier = verifier.rawValue
        spawn { [self] in
            let entries: [StorageCore.ItemAttributes]
            do throws(StorageError) {
                entries = try await listAll(directory.entry.id)
            } catch {
                logger.error("listing failed: \(error.description, privacy: .public)")
                return reply.value(.initial, Self.fsError(error))
            }
            let current = Self.verifier(for: entries)
            // G0-VERIFY: FSKit's expected error for a stale verifier/cookie; FSError.invalidDirectoryCookie
            // (FSKitErrorDomain 4506) is the only documented code for it.
            if callerVerifier != FSDirectoryVerifier.initial.rawValue, callerVerifier != current.rawValue {
                return reply.value(current, FSError(.invalidDirectoryCookie))
            }
            // Cookie = index into [".", "..", entries...]. With attributes requested, "." and ".."
            // are not packed (FSKit documentation), so enumeration starts at index 2.
            let total = UInt64(entries.count) + 2
            var index = max(startCookie, wantsAttributes ? 2 : 0)
            if index > total {
                return reply.value(current, FSError(.invalidDirectoryCookie))
            }
            while index < total {
                let next = FSDirectoryCookie(rawValue: index + 1)
                let packed: Bool
                switch index {
                case 0:
                    packed = packer.value.packEntry(name: FSFileName(string: "."), itemType: .directory,
                                                    itemID: directory.fileID, nextCookie: next, attributes: nil)
                case 1:
                    let parentID = directory.entry.id == .root ? directory.fileID : directory.parentFileID
                    packed = packer.value.packEntry(name: FSFileName(string: ".."), itemType: .directory,
                                                    itemID: parentID, nextCookie: next, attributes: nil)
                default:
                    let child = SpikeItem(entry: entries[Int(index - 2)])
                    packed = packer.value.packEntry(name: FSFileName(string: child.entry.name),
                                                    itemType: child.itemType,
                                                    itemID: child.fileID,
                                                    nextCookie: next,
                                                    attributes: wantsAttributes ? child.fsAttributes(timestamp: timestamp) : nil)
                }
                if !packed { break }
                index += 1
            }
            reply.value(current, nil)
        }
    }
}

// MARK: - FSVolume.OpenCloseOperations

extension SpikeVolume: FSVolume.OpenCloseOperations {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        // FR12: refuse write opens up front.
        reply(modes.contains(.write) ? Self.fsError(.readOnly) : nil)
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }
}

// MARK: - FSVolume.ReadWriteOperations

extension SpikeVolume: FSVolume.ReadWriteOperations {
    /// FR05: exactly the requested bytes up to EOF, at the revision pinned at lookup. Zero-length
    /// reads and reads at/after EOF return 0 without error. Larger reads are split into
    /// ≤ 4 MiB IPC replies (Limits.maxReadReply). On a mid-read failure FSKit gets the bytes read
    /// so far plus the error, as documented.
    func read(from item: FSItem,
              at offset: off_t,
              length: Int,
              into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard let file = item as? SpikeItem else { return reply(0, Self.fsError(posix: EINVAL)) }
        guard file.entry.kind == .file else { return reply(0, Self.fsError(.isDirectory)) }
        let wanted = min(length, buffer.length)
        let range: ByteRange
        do throws(StorageError) {
            range = try RangeMath.clamp(offset: Int64(offset), length: Int64(wanted), fileSize: file.entry.size)
        } catch {
            return reply(0, Self.fsError(error))
        }
        if range.isEmpty { return reply(0, nil) }

        let reply = FSKitBox(value: reply)
        let buffer = FSKitBox(value: buffer)
        spawn { [self] in
            var written = 0
            do throws(StorageError) {
                for chunk in RangeMath.split(range, maxChunk: Limits.maxReadReply) {
                    let data = try await client.call(.readRange(
                        requestID: client.nextRequestID(),
                        item: file.entry.id,
                        revision: file.entry.revision,
                        offset: Int64(chunk.offset),
                        length: Int64(chunk.length))).expectBytes()
                    guard data.count <= Int(chunk.length) else {
                        throw .messageTooLarge(limit: Int(chunk.length), actual: data.count)
                    }
                    let copied = buffer.value.withUnsafeMutableBytes { destination -> Bool in
                        guard written + data.count <= destination.count else { return false }
                        data.withUnsafeBytes { source in
                            UnsafeMutableRawBufferPointer(rebasing: destination[written ..< written + data.count])
                                .copyMemory(from: source)
                        }
                        return true
                    }
                    guard copied else { throw .invalidArgument("read buffer too small") }
                    written += data.count
                    // Short reply: the file ended earlier than the size seen at lookup.
                    if data.count < Int(chunk.length) { break }
                }
                reply.value(written, nil)
            } catch {
                if error != .cancelled {
                    logger.error("read failed after \(written, privacy: .public) bytes: \(error.description, privacy: .public)")
                }
                reply.value(written, Self.fsError(error))
            }
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        reply(0, Self.fsError(.readOnly))
    }
}
