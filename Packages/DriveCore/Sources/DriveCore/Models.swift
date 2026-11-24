import Foundation

/// A Drive file or folder. `Codable` here is DriveCore's own flat representation (for local persistence);
/// Google's JSON is decoded by the internal `APIFile`.
public struct DriveFile: Sendable, Codable, Hashable, Identifiable {
    public static let folderMimeType = "application/vnd.google-apps.folder"
    public static let shortcutMimeType = "application/vnd.google-apps.shortcut"
    public static let workspacePrefix = "application/vnd.google-apps."

    public var id: String
    public var name: String
    public var mimeType: String
    public var size: Int64?
    public var createdTime: Date
    public var modifiedTime: Date
    public var md5Checksum: String?
    public var parents: [String]
    public var trashed: Bool
    public var thumbnailLink: URL?
    public var lastModifyingUserName: String?
    public var videoDurationMillis: Int64?
    public var width: Int?
    public var height: Int?
    public var canDownload: Bool

    public init(
        id: String,
        name: String,
        mimeType: String,
        size: Int64? = nil,
        createdTime: Date,
        modifiedTime: Date? = nil,
        md5Checksum: String? = nil,
        parents: [String] = [],
        trashed: Bool = false,
        thumbnailLink: URL? = nil,
        lastModifyingUserName: String? = nil,
        videoDurationMillis: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        canDownload: Bool = true
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.createdTime = createdTime
        self.modifiedTime = modifiedTime ?? createdTime
        self.md5Checksum = md5Checksum
        self.parents = parents
        self.trashed = trashed
        self.thumbnailLink = thumbnailLink
        self.lastModifyingUserName = lastModifyingUserName
        self.videoDurationMillis = videoDurationMillis
        self.width = width
        self.height = height
        self.canDownload = canDownload
    }

    public var isFolder: Bool { mimeType == Self.folderMimeType }

    /// Hidden in v1: trashed items, shortcuts and Google Workspace docs (`application/vnd.google-apps.*` except folders).
    public var isHidden: Bool {
        trashed || (mimeType.hasPrefix(Self.workspacePrefix) && !isFolder)
    }
}

public struct DriveRoot: Sendable, Hashable, Codable {
    /// Folder ID of the root (for a shared drive this equals the drive ID).
    public var id: String
    public var name: String
    /// Non-nil in shared-drive mode; nil in folder mode.
    public var driveID: String?

    public init(id: String, name: String, driveID: String?) {
        self.id = id
        self.name = name
        self.driveID = driveID
    }
}

public enum DriveChange: Sendable, Hashable {
    case upsert(DriveFile)
    case removed(fileID: String)
}

public struct ChangeBatch: Sendable {
    public var changes: [DriveChange]
    /// Non-nil: more pages follow; call `changes(since:)` again with it.
    public var nextPageToken: String?
    /// Non-nil on the last page: persist it and poll with it next time.
    public var newStartPageToken: String?

    public init(changes: [DriveChange], nextPageToken: String?, newStartPageToken: String?) {
        self.changes = changes
        self.nextPageToken = nextPageToken
        self.newStartPageToken = newStartPageToken
    }
}

// MARK: - Google JSON

/// Drive v3 `File` resource as requested with `DriveClient.fields`.
struct APIFile: Decodable {
    struct User: Decodable { var displayName: String? }
    struct Video: Decodable { var durationMillis: FlexibleInt64?; var width: Int?; var height: Int? }
    struct Image: Decodable { var width: Int?; var height: Int? }
    struct Caps: Decodable { var canDownload: Bool? }

    var id: String
    var name: String?
    var mimeType: String?
    var size: FlexibleInt64?
    var createdTime: String?
    var modifiedTime: String?
    var md5Checksum: String?
    var parents: [String]?
    var trashed: Bool?
    var thumbnailLink: String?
    var lastModifyingUser: User?
    var videoMediaMetadata: Video?
    var imageMediaMetadata: Image?
    var capabilities: Caps?

    func toDriveFile() throws(DriveError) -> DriveFile {
        guard let name, let mimeType else { throw .invalidResponse("file \(id) lacks name/mimeType") }
        let created = try createdTime.map { (s) throws(DriveError) -> Date in try RFC3339.parseOrThrow(s) }
            ?? Date(timeIntervalSince1970: 0)
        let modified = try modifiedTime.map { (s) throws(DriveError) -> Date in try RFC3339.parseOrThrow(s) } ?? created
        return DriveFile(
            id: id,
            name: name,
            mimeType: mimeType,
            size: size?.value,
            createdTime: created,
            modifiedTime: modified,
            md5Checksum: md5Checksum,
            parents: parents ?? [],
            trashed: trashed ?? false,
            thumbnailLink: thumbnailLink.flatMap(URL.init(string:)),
            lastModifyingUserName: lastModifyingUser?.displayName,
            videoDurationMillis: videoMediaMetadata?.durationMillis?.value,
            width: videoMediaMetadata?.width ?? imageMediaMetadata?.width,
            height: videoMediaMetadata?.height ?? imageMediaMetadata?.height,
            canDownload: capabilities?.canDownload ?? true
        )
    }
}

/// Google encodes int64 as JSON strings (`"size": "1234"`); accept numbers too.
struct FlexibleInt64: Decodable {
    var value: Int64
    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), let v = Int64(s) {
            value = v
        } else {
            value = try c.decode(Int64.self)
        }
    }
}

/// RFC 3339 timestamps, with or without fractional seconds, `Z` or numeric offset.
enum RFC3339 {
    static func parseOrThrow(_ s: String) throws(DriveError) -> Date {
        guard let d = parse(s) else { throw .invalidResponse("bad timestamp") }
        return d
    }

    static func parse(_ s: String) -> Date? {
        let u = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= u.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let c = u[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        func char(_ i: Int, _ c: Character) -> Bool { i < u.count && u[i] == c.asciiValue! }
        guard let year = num(0, 4), char(4, "-"), let month = num(5, 2), char(7, "-"), let day = num(8, 2),
              u.count > 10, u[10] == UInt8(ascii: "T") || u[10] == UInt8(ascii: "t") || u[10] == UInt8(ascii: " "),
              let hour = num(11, 2), char(13, ":"), let minute = num(14, 2), char(16, ":"), let second = num(17, 2)
        else { return nil }
        var i = 19
        var fraction = 0.0
        if char(i, ".") {
            i += 1
            var scale = 0.1
            let start = i
            while i < u.count, u[i] >= 48, u[i] <= 57 {
                fraction += Double(u[i] - 48) * scale
                scale /= 10
                i += 1
            }
            if i == start { return nil }
        }
        var offsetSeconds = 0
        if char(i, "Z") || char(i, "z") {
            i += 1
        } else if char(i, "+") || char(i, "-") {
            let sign = char(i, "-") ? -1 : 1
            guard let oh = num(i + 1, 2), char(i + 3, ":"), let om = num(i + 4, 2) else { return nil }
            offsetSeconds = sign * (oh * 3600 + om * 60)
            i += 6
        } else {
            return nil
        }
        guard i == u.count else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second <= 60,
              let base = utcCalendar.date(from: comps)
        else { return nil }
        return base.addingTimeInterval(fraction - Double(offsetSeconds))
    }

    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}
