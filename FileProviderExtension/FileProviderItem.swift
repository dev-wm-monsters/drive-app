// NSFileProviderItem for a Drive file or folder.
//
// Identifiers: the Drive file ID; the configured root maps to .rootContainer.
// filename: the per-folder display name (DisplayNames.assign over siblings),
// never the raw Drive name, so duplicates and illegal characters are handled
// identically on Mac and Windows.
// Capabilities: existing items are read-only. Folders additionally allow
// adding sub-items (new files are uploaded). No rename / move / delete /
// trash / write.

import DriveCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItemProtocol, @unchecked Sendable {
    // All stored properties are immutable: instances are safe to share.
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let fileSystemFlags: NSFileProviderFileSystemFlags
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    let mostRecentEditorNameComponents: PersonNameComponents?

    /// The Drive file ID behind this item (the root's ID for .rootContainer).
    let driveID: String

    static let fileCapabilities: NSFileProviderItemCapabilities = [.allowsReading]
    static let folderCapabilities: NSFileProviderItemCapabilities = [
        .allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
    ]

    init(file: DriveFile, displayName: String, parentIdentifier: NSFileProviderItemIdentifier, root: DriveRoot) {
        driveID = file.id
        itemIdentifier = file.id == root.id ? .rootContainer : NSFileProviderItemIdentifier(rawValue: file.id)
        parentItemIdentifier = parentIdentifier
        filename = displayName
        creationDate = file.createdTime
        contentModificationDate = file.modifiedTime

        if file.isFolder {
            contentType = .folder
            capabilities = Self.folderCapabilities
            // Writable so new files can be added; executable so it can be listed.
            fileSystemFlags = [.userReadable, .userWritable, .userExecutable]
            documentSize = nil
        } else {
            contentType = Self.contentType(displayName: displayName, mimeType: file.mimeType)
            capabilities = Self.fileCapabilities
            // Read-only on disk: editors open it read-only instead of failing on save.
            fileSystemFlags = [.userReadable]
            documentSize = file.size.map { NSNumber(value: $0) }
        }

        itemVersion = Self.version(for: file, displayName: displayName, parentIdentifier: parentIdentifier)

        if let editor = file.lastModifyingUserName, !editor.isEmpty {
            var components = PersonNameComponents()
            components.nickname = editor
            components.givenName = editor
            mostRecentEditorNameComponents = components
        } else {
            mostRecentEditorNameComponents = nil
        }
        super.init()
    }

    /// The domain root (the shared drive or folder itself).
    init(root: DriveRoot) {
        driveID = root.id
        itemIdentifier = .rootContainer
        parentItemIdentifier = .rootContainer
        filename = root.name
        contentType = .folder
        capabilities = Self.folderCapabilities
        fileSystemFlags = [.userReadable, .userWritable, .userExecutable]
        documentSize = nil
        creationDate = nil
        contentModificationDate = nil
        let v = Data("root:\(root.id):\(root.name)".utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: v, metadataVersion: v)
        mostRecentEditorNameComponents = nil
        super.init()
    }

    // MARK: Versions

    /// content = md5 (or modifiedTime when Drive has no md5), metadata =
    /// modifiedTime + display name + parent, so a display-name shift caused by
    /// a sibling change is seen as a metadata update.
    static func version(for file: DriveFile, displayName: String, parentIdentifier: NSFileProviderItemIdentifier) -> NSFileProviderItemVersion {
        let modified = String(file.modifiedTime.timeIntervalSince1970)
        let content: String
        if file.isFolder {
            content = "folder"
        } else if let md5 = file.md5Checksum, !md5.isEmpty {
            content = "md5:\(md5)"
        } else {
            content = "mtime:\(modified):\(file.size.map(String.init) ?? "-")"
        }
        let metadata = "\(modified)|\(parentIdentifier.rawValue)|\(displayName)"
        return NSFileProviderItemVersion(contentVersion: Data(content.utf8), metadataVersion: Data(metadata.utf8))
    }

    // MARK: Content type

    /// Prefer the display name's extension (what Finder uses to pick an app),
    /// then Drive's MIME type, then generic data. A file is never typed as a
    /// directory/package: Drive stores it as one blob.
    static func contentType(displayName: String, mimeType: String) -> UTType {
        let ext = (displayName as NSString).pathExtension
        if !ext.isEmpty, let t = UTType(filenameExtension: ext), !t.isDynamic, !t.conforms(to: .directory) {
            return t
        }
        if let t = UTType(mimeType: mimeType), !t.isDynamic, !t.conforms(to: .directory) {
            return t
        }
        // VERIFY-ON-MAC: iWork documents (.pages/.numbers/.key) declare package
        // UTIs; check Finder opens them correctly when typed as .data.
        return .data
    }
}
