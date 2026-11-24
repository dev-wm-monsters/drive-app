import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Google Drive v3 REST client for one configured root.
///
/// - Every call sends `supportsAllDrives=true`; list/changes also `includeItemsFromAllDrives=true`;
///   shared-drive mode adds `corpora=drive&driveId=` (list) / `driveId=` (changes).
/// - Retries per `RetryPolicy`; a 401 forces one token refresh and one retry, then `.needsLogin`.
/// - Folder mode (`DriveRoot.driveID == nil`): keeps a `FolderIndex`, filled by `listChildren` (each listed folder
///   and every visible child) and by `changes`, to filter the account-wide changes feed down to the root's tree.
/// - Never logs anything; error payloads never contain tokens or upload session URLs.
public actor DriveClient {
    public static let fields = "id,name,mimeType,size,createdTime,modifiedTime,md5Checksum,parents,trashed,thumbnailLink,hasThumbnail,iconLink,lastModifyingUser(displayName,emailAddress),videoMediaMetadata(durationMillis,width,height),imageMediaMetadata(width,height),capabilities(canDownload)"
    public static let apiBase = "https://www.googleapis.com/drive/v3/"
    public static let uploadEndpoint = "https://www.googleapis.com/upload/drive/v3/files"
    /// 8 MiB, a multiple of 256 KiB as Google requires for non-final chunks.
    public static let uploadChunkSize: Int64 = 8 * 1024 * 1024

    public let config: DriveConfig
    private let auth: AuthSession
    private let transport: any HTTPTransport
    private let retry: RetryPolicy
    private var folderIndex: FolderIndex?
    private var currentRoot: DriveRoot?

    public init(config: DriveConfig, auth: AuthSession, transport: any HTTPTransport, retry: RetryPolicy = .default) {
        self.config = config
        self.auth = auth
        self.transport = transport
        self.retry = retry
    }

    // MARK: - Folder index (folder mode)

    /// Snapshot of the folder-mode index, e.g. to persist it alongside the sync anchor.
    public func folderIndexSnapshot() -> FolderIndex? {
        folderIndex
    }

    /// Re-seeds the folder-mode index after a process restart.
    public func restoreFolderIndex(_ index: FolderIndex) {
        folderIndex = index
    }

    // MARK: - Root

    public func resolveRoot() async throws(DriveError) -> DriveRoot {
        let root: DriveRoot
        switch config.root {
        case .sharedDriveNamed(let name):
            var matches: [DriveListResponse.Drive] = []
            var pageToken: String?
            repeat {
                var q: [(String, String)] = [
                    ("q", "name = '\(Self.escapeQuery(name))'"),
                    ("pageSize", "100"),
                    ("fields", "nextPageToken,drives(id,name)"),
                ]
                if let pageToken { q.append(("pageToken", pageToken)) }
                let page: DriveListResponse = try await getJSON(Self.apiURL("drives", q))
                matches += (page.drives ?? []).filter { $0.name == name }
                pageToken = try Self.nextToken(page.nextPageToken, after: pageToken)
            } while pageToken != nil
            guard let first = matches.first else { throw .rootNotFound(name) }
            guard matches.count == 1 else { throw .rootAmbiguous(matches.map(\.id)) }
            root = DriveRoot(id: first.id, name: first.name, driveID: first.id)

        case .sharedDriveID(let id):
            let drive: DriveListResponse.Drive
            do {
                drive = try await getJSON(Self.apiURL("drives/\(FormEncoding.escape(id))", [("fields", "id,name")]))
            } catch {
                let e = mapTransportError(error) // explicit: do-catch type inference varies across Swift 6.x
                if e == .notFound { throw .rootNotFound(id) }
                throw e
            }
            root = DriveRoot(id: drive.id, name: drive.name, driveID: drive.id)

        case .folderID(let id):
            let f: DriveFile
            do {
                f = try await file(id: id)
            } catch {
                let e = mapTransportError(error) // explicit: do-catch type inference varies across Swift 6.x
                if e == .notFound { throw .rootNotFound(id) }
                throw e
            }
            guard f.isFolder, !f.trashed else { throw .rootNotFound(id) }
            root = DriveRoot(id: f.id, name: f.name, driveID: nil)
        }
        remember(root)
        return root
    }

    // MARK: - Metadata

    /// All pages of the folder's children, hidden items (Workspace docs, shortcuts, trashed) excluded.
    public func listChildren(of folderID: String, root: DriveRoot) async throws(DriveError) -> [DriveFile] {
        remember(root)
        let all = try await listFiles(
            q: "'\(Self.escapeQuery(folderID))' in parents and trashed = false",
            root: root,
            fields: "nextPageToken,files(\(Self.fields))"
        )
        let visible = all.filter { !$0.isHidden }
        if root.driveID == nil, var index = folderIndex, index.rootID == root.id {
            index.insert(folderID: folderID)
            for f in visible {
                if f.isFolder { index.insert(folderID: f.id) } else { index.insert(fileID: f.id) }
            }
            folderIndex = index
        }
        return visible
    }

    public func file(id: String) async throws(DriveError) -> DriveFile {
        let api: APIFile = try await getJSON(Self.apiURL(
            "files/\(FormEncoding.escape(id))",
            [("fields", Self.fields), ("supportsAllDrives", "true")]
        ))
        return try api.toDriveFile()
    }

    // MARK: - Content

    /// Downloads the whole file to a temp file in `file`'s directory, verifies `expectedMD5` (if given), then
    /// atomically renames it over `file`. On any failure the temp file is removed and `file` is untouched.
    public func download(id: String, to file: URL, expectedMD5: String?) async throws(DriveError) {
        try await download(id: id, to: file, expectedMD5: expectedMD5, progress: nil)
    }

    /// As `download(id:to:expectedMD5:)`, reporting `(bytesReceived, expectedTotal or nil)` while downloading
    /// (when the transport supports it; a retry starts again from 0).
    public func download(
        id: String,
        to file: URL,
        expectedMD5: String?,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws(DriveError) {
        let fm = FileManager.default
        let temp = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).download")
        defer { try? fm.removeItem(at: temp) }
        let request = Request(url: mediaURL(id))
        let transport = self.transport
        _ = try await perform(request) { req in
            try? fm.removeItem(at: temp)
            let response = try await transport.download(for: req, to: temp, progress: progress)
            if (200..<300).contains(response.statusCode) { return (Data(), response) }
            let body = (try? Data(contentsOf: temp)) ?? Data()
            try? fm.removeItem(at: temp)
            return (body, response)
        }
        if let expected = expectedMD5, !expected.isEmpty {
            let actual: String
            do {
                actual = try Hashing.md5Hex(of: temp)
            } catch {
                throw .invalidResponse("downloaded file unreadable")
            }
            guard actual == expected.lowercased() else { throw .checksumMismatch }
        }
        guard rename(temp.path, file.path) == 0 else {
            throw .invalidResponse("rename failed (errno \(errno))")
        }
    }

    /// Exactly `length` bytes from `offset`, or fewer only when the range reaches end of file.
    /// Requires `206 Partial Content`; a `200` (server ignored Range) is `.invalidResponse`.
    /// An offset at/after EOF (`416`) returns empty data.
    public func downloadRange(id: String, offset: Int64, length: Int64) async throws(DriveError) -> Data {
        guard length > 0 else { return Data() }
        guard offset >= 0 else { throw .invalidResponse("negative offset") }
        var request = Request(url: mediaURL(id))
        request.headers["Range"] = "bytes=\(offset)-\(offset + length - 1)"
        let transport = self.transport
        let (data, response) = try await perform(request, accept: { [200, 206, 416].contains($0) }) {
            try await transport.data(for: $0)
        }
        switch response.statusCode {
        case 416:
            return Data()
        case 206:
            let range = Self.parseContentRange(response.header("Content-Range"))
            if let start = range?.start, start != offset {
                throw .invalidResponse("Content-Range starts at \(start), expected \(offset)")
            }
            if Int64(data.count) > length { return Data(data.prefix(Int(length))) }
            if Int64(data.count) < length {
                guard let total = range?.total, offset + Int64(data.count) >= total else {
                    throw .invalidResponse("short partial response")
                }
            }
            return data
        default:
            throw .invalidResponse("server ignored Range (HTTP \(response.statusCode))")
        }
    }

    // MARK: - Changes

    public func startPageToken(root: DriveRoot) async throws(DriveError) -> String {
        remember(root)
        var q: [(String, String)] = [("supportsAllDrives", "true")]
        if let d = root.driveID { q.append(("driveId", d)) }
        let r: StartPageTokenResponse = try await getJSON(Self.apiURL("changes/startPageToken", q))
        guard let token = r.startPageToken, !token.isEmpty else { throw .invalidResponse("no startPageToken") }
        return token
    }

    /// One page of changes. Loop while `nextPageToken != nil`; persist `newStartPageToken` from the last page.
    /// Mapping: removed, trashed or hidden → `.removed(fileID:)`, otherwise `.upsert`.
    /// Folder mode: only changes relevant to the root's tree (see `FolderIndex`); a known item whose parents left
    /// the tree is reported as removed. `removed: true` entries carry no parents, so they are always reported.
    public func changes(since pageToken: String, root: DriveRoot) async throws(DriveError) -> ChangeBatch {
        remember(root)
        var q: [(String, String)] = [
            ("pageToken", pageToken),
            ("pageSize", "1000"),
            ("fields", "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fields)))"),
            ("supportsAllDrives", "true"),
            ("includeItemsFromAllDrives", "true"),
        ]
        if let d = root.driveID { q.append(("driveId", d)) }
        let page: ChangeListResponse = try await getJSON(Self.apiURL("changes", q))
        var out: [DriveChange] = []
        var index = folderIndex
        for change in page.changes ?? [] {
            guard let fileID = change.fileId ?? change.file?.id else { continue } // e.g. changeType "drive"
            guard change.removed != true, let apiFile = change.file else {
                out.append(.removed(fileID: fileID))
                index?.remove(fileID)
                continue
            }
            let f = try apiFile.toDriveFile()
            guard root.driveID == nil, var idx = index else {
                out.append(f.isHidden ? .removed(fileID: f.id) : .upsert(f))
                continue
            }
            guard idx.isRelevant(f) else { continue }
            if f.isHidden || !idx.isInTree(f) {
                out.append(.removed(fileID: f.id))
                idx.remove(f.id)
            } else {
                out.append(.upsert(f))
                if f.isFolder { idx.insert(folderID: f.id) } else { idx.insert(fileID: f.id) }
            }
            index = idx
        }
        folderIndex = index
        return ChangeBatch(changes: out, nextPageToken: page.nextPageToken, newStartPageToken: page.newStartPageToken)
    }

    /// Convenience: follows `nextPageToken` until the last page.
    public func allChanges(since pageToken: String, root: DriveRoot) async throws(DriveError) -> (changes: [DriveChange], newStartPageToken: String) {
        var token = pageToken
        var all: [DriveChange] = []
        while true {
            let batch = try await changes(since: token, root: root)
            all += batch.changes
            if let next = batch.nextPageToken {
                guard next != token else { throw .invalidResponse("changes pagination did not advance") }
                token = next
            } else if let start = batch.newStartPageToken {
                return (all, start)
            } else {
                throw .invalidResponse("changes page without nextPageToken or newStartPageToken")
            }
        }
    }

    // MARK: - Upload

    /// Uploads a NEW file into `parentID`. Picks a free name first (`DisplayNames.uniqueUploadName` against the
    /// parent's current names and display names), then a resumable session in 8 MiB chunks. Interruptions query
    /// the session status (`Content-Range: bytes */total`) and resume from the server's offset.
    public func upload(
        file: URL,
        desiredName: String,
        parentID: String,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws(DriveError) -> DriveFile {
        try await upload(file: file, desiredName: desiredName, parentID: parentID, root: currentRoot, progress: progress)
    }

    /// As `upload(file:desiredName:parentID:progress:)`, with the root given explicitly. Without it the free-name
    /// sibling listing is only scoped to the shared drive (`corpora=drive&driveId=`) if this client already saw the
    /// root (`resolveRoot`, `listChildren`, `changes`), which is not the case when the root came from a cache.
    public func upload(
        file: URL,
        desiredName: String,
        parentID: String,
        root: DriveRoot?,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws(DriveError) -> DriveFile {
        if let root { remember(root) }
        let total = try Self.fileSize(file)
        let siblings = try await listFiles(
            q: "'\(Self.escapeQuery(parentID))' in parents and trashed = false",
            root: currentRoot,
            fields: "nextPageToken,files(id,name,mimeType,createdTime,trashed)"
        ).filter { !$0.isHidden }
        let existing = siblings.map(\.name) + Array(DisplayNames.assign(siblings).values)
        let name = DisplayNames.uniqueUploadName(desired: desiredName, existing: existing)
        let mimeType = MIMETypes.type(forFileName: name)

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw .invalidResponse("cannot read local file")
        }
        defer { try? handle.close() }

        var session = try await startUploadSession(name: name, parentID: parentID, mimeType: mimeType, total: total)
        var offset: Int64 = 0
        var failures = 0
        var queryStatus = false
        var restarted = false
        var refreshedAfter401 = false
        progress?(0, total)

        while true {
            if Task.isCancelled { throw .cancelled }
            let token = try await auth.accessToken()
            var req = URLRequest(url: session)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let sentChunk = !queryStatus
            if queryStatus {
                req.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
                req.setValue("0", forHTTPHeaderField: "Content-Length")
                req.httpBody = Data()
            } else {
                let length = min(Self.uploadChunkSize, total - offset)
                let chunk = try Self.readChunk(handle, offset: offset, length: length)
                req.setValue(String(length), forHTTPHeaderField: "Content-Length")
                req.setValue(
                    total == 0 ? "bytes */0" : "bytes \(offset)-\(offset + length - 1)/\(total)",
                    forHTTPHeaderField: "Content-Range"
                )
                req.httpBody = chunk
            }

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.data(for: req)
            } catch {
                let e = mapTransportError(error)
                if e == .cancelled { throw e }
                failures += 1
                guard failures < retry.maxAttempts else { throw e }
                try await pause(afterFailures: failures, retryAfter: nil)
                queryStatus = true
                continue
            }

            switch response.statusCode {
            case 200, 201:
                let uploaded = try Self.decode(APIFile.self, data).toDriveFile()
                progress?(total, total)
                if var index = folderIndex, index.folderIDs.contains(parentID) {
                    index.insert(fileID: uploaded.id)
                    folderIndex = index
                }
                return uploaded
            case 308:
                let serverOffset = Self.parseUploadRange(response.header("Range"))
                guard serverOffset <= total else { throw .invalidResponse("upload offset beyond file size") }
                if serverOffset > offset {
                    failures = 0
                } else if sentChunk {
                    failures += 1
                    guard failures < retry.maxAttempts else { throw .invalidResponse("upload is not progressing") }
                }
                offset = serverOffset
                queryStatus = false
                progress?(offset, total)
            case 401:
                if refreshedAfter401 { throw .needsLogin }
                refreshedAfter401 = true
                _ = try await auth.forceRefresh(rejecting: token)
                queryStatus = true
            case 404, 410:
                // Session expired: Google requires restarting the upload from the beginning (once).
                guard !restarted else { throw .notFound }
                restarted = true
                session = try await startUploadSession(name: name, parentID: parentID, mimeType: mimeType, total: total)
                offset = 0
                queryStatus = false
                progress?(0, total)
            default:
                let e = Self.mapHTTPError(status: response.statusCode, body: data, response: response)
                failures += 1
                guard e.isRetryable, failures < retry.maxAttempts else { throw e }
                try await pause(afterFailures: failures, retryAfter: e.retryAfter ?? Self.retryAfterHeader(response))
                queryStatus = true
            }
        }
    }

    private func startUploadSession(name: String, parentID: String, mimeType: String, total: Int64) async throws(DriveError) -> URL {
        var url = Self.uploadEndpoint + "?" + FormEncoding.encode([
            ("uploadType", "resumable"),
            ("supportsAllDrives", "true"),
        ])
        url += "&" + FormEncoding.encode([("fields", Self.fields)])
        var request = Request(url: URL(string: url)!)
        request.method = "POST"
        request.headers["Content-Type"] = "application/json; charset=UTF-8"
        request.headers["X-Upload-Content-Type"] = mimeType
        request.headers["X-Upload-Content-Length"] = String(total)
        struct Metadata: Encodable { var name: String; var parents: [String] }
        do {
            request.body = try JSONEncoder().encode(Metadata(name: name, parents: [parentID]))
        } catch {
            throw .invalidResponse("cannot encode metadata")
        }
        let transport = self.transport
        let (_, response) = try await perform(request) { try await transport.data(for: $0) }
        guard let location = response.header("Location"), let session = URL(string: location) else {
            throw .invalidResponse("upload session response without Location")
        }
        return session
    }

    // MARK: - Request plumbing

    struct Request {
        var method = "GET"
        var url: URL
        var headers: [String: String] = [:]
        var body: Data?

        func urlRequest(token: String) -> URLRequest {
            var r = URLRequest(url: url)
            r.httpMethod = method
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.httpBody = body
            return r
        }
    }

    /// Sends with auth, 401 → one forced refresh, and retries/backoff per `RetryPolicy`.
    private func perform(
        _ request: Request,
        accept: (Int) -> Bool = { (200..<300).contains($0) },
        execute: (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws(DriveError) -> (Data, HTTPURLResponse) {
        var failures = 0
        var refreshedAfter401 = false
        while true {
            if Task.isCancelled { throw .cancelled }
            let token = try await auth.accessToken()
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await execute(request.urlRequest(token: token))
            } catch {
                let e = mapTransportError(error)
                if e == .cancelled { throw e }
                failures += 1
                guard failures < retry.maxAttempts else { throw e }
                try await pause(afterFailures: failures, retryAfter: nil)
                continue
            }
            let status = response.statusCode
            if accept(status) { return (data, response) }
            if status == 401 {
                if refreshedAfter401 { throw .needsLogin }
                refreshedAfter401 = true
                _ = try await auth.forceRefresh(rejecting: token)
                continue
            }
            let e = Self.mapHTTPError(status: status, body: data, response: response)
            failures += 1
            guard e.isRetryable, failures < retry.maxAttempts else { throw e }
            try await pause(afterFailures: failures, retryAfter: e.retryAfter ?? Self.retryAfterHeader(response))
        }
    }

    private func pause(afterFailures failures: Int, retryAfter: Duration?) async throws(DriveError) {
        do {
            try await retry.sleep(retry.delay(afterFailures: failures, retryAfter: retryAfter))
        } catch {
            throw .cancelled
        }
        if Task.isCancelled { throw .cancelled }
    }

    private func getJSON<T: Decodable>(_ url: URL) async throws(DriveError) -> T {
        let transport = self.transport
        let (data, _) = try await perform(Request(url: url)) { try await transport.data(for: $0) }
        return try Self.decode(T.self, data)
    }

    private func listFiles(q: String, root: DriveRoot?, fields: String) async throws(DriveError) -> [DriveFile] {
        var out: [DriveFile] = []
        var pageToken: String?
        repeat {
            var query: [(String, String)] = [
                ("q", q),
                ("pageSize", "1000"),
                ("fields", fields),
                ("supportsAllDrives", "true"),
                ("includeItemsFromAllDrives", "true"),
            ]
            if let d = root?.driveID {
                query.append(("corpora", "drive"))
                query.append(("driveId", d))
            }
            if let pageToken { query.append(("pageToken", pageToken)) }
            let page: FileListResponse = try await getJSON(Self.apiURL("files", query))
            for f in page.files ?? [] { out.append(try f.toDriveFile()) }
            pageToken = try Self.nextToken(page.nextPageToken, after: pageToken)
        } while pageToken != nil
        return out
    }

    private func remember(_ root: DriveRoot) {
        currentRoot = root
        if root.driveID == nil {
            if folderIndex?.rootID != root.id { folderIndex = FolderIndex(rootID: root.id) }
        } else {
            folderIndex = nil
        }
    }

    private func mediaURL(_ id: String) -> URL {
        Self.apiURL("files/\(FormEncoding.escape(id))", [("alt", "media"), ("supportsAllDrives", "true")])
    }

    // MARK: - Static helpers

    static func apiURL(_ path: String, _ query: [(String, String)]) -> URL {
        let q = query.isEmpty ? "" : "?" + FormEncoding.encode(query)
        return URL(string: apiBase + path + q)!
    }

    /// Escapes a value inside a single-quoted Drive query string literal.
    static func escapeQuery(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    static func nextToken(_ next: String?, after previous: String?) throws(DriveError) -> String? {
        guard let next, !next.isEmpty else { return nil }
        if next == previous { throw .invalidResponse("pagination did not advance") }
        return next
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws(DriveError) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .invalidResponse("undecodable \(T.self)")
        }
    }

    static func retryAfterHeader(_ response: HTTPURLResponse) -> Duration? {
        RetryPolicy.parseRetryAfter(response.header("Retry-After"))
    }

    /// Google error JSON → `DriveError` (uses `error.errors[0].reason`, then `error.status`).
    static func mapHTTPError(status: Int, body: Data, response: HTTPURLResponse) -> DriveError {
        let parsed = try? JSONDecoder().decode(GoogleErrorResponse.self, from: body)
        let reason = parsed?.error?.errors?.first?.reason
        let googleStatus = parsed?.error?.status
        let retryAfter = retryAfterHeader(response)
        switch status {
        case 401:
            return .needsLogin
        case 404:
            return .notFound
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 403:
            switch reason {
            case "rateLimitExceeded", "userRateLimitExceeded":
                return .rateLimited(retryAfter: retryAfter)
            case "storageQuotaExceeded", "quotaExceeded":
                return .quotaExceeded
            case nil where googleStatus == "RESOURCE_EXHAUSTED":
                return .rateLimited(retryAfter: retryAfter)
            default:
                return .forbidden(reason ?? googleStatus ?? "forbidden")
            }
        case 500...599:
            return .server(status)
        default:
            return .invalidResponse("HTTP \(status)" + (reason.map { " \($0)" } ?? ""))
        }
    }

    /// `Content-Range: bytes 0-99/1000` (or `bytes */1000`).
    static func parseContentRange(_ header: String?) -> (start: Int64?, end: Int64?, total: Int64?)? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = h.dropFirst(6)
        let parts = spec.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let total = Int64(parts[1])
        if parts[0] == "*" { return (nil, nil, total) }
        let se = parts[0].split(separator: "-", maxSplits: 1)
        guard se.count == 2, let s = Int64(se[0]), let e = Int64(se[1]) else { return nil }
        return (s, e, total)
    }

    /// Resumable upload `Range: bytes=0-N` → next offset N+1; absent → 0.
    static func parseUploadRange(_ header: String?) -> Int64 {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.lowercased().hasPrefix("bytes=") else { return 0 }
        let se = h.dropFirst(6).split(separator: "-", maxSplits: 1)
        guard se.count == 2, let end = Int64(se[1]) else { return 0 }
        return end + 1
    }

    static func fileSize(_ file: URL) throws(DriveError) -> Int64 {
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw DriveError.invalidResponse("not a regular file")
            }
            return Int64(size)
        } catch {
            throw .invalidResponse("cannot read local file")
        }
    }

    static func readChunk(_ handle: FileHandle, offset: Int64, length: Int64) throws(DriveError) -> Data {
        if length == 0 { return Data() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: Int(length)) ?? Data()
            guard Int64(data.count) == length else { throw DriveError.invalidResponse("short read") }
            return data
        } catch {
            throw .invalidResponse("local file changed or unreadable during upload")
        }
    }
}

// MARK: - Response shapes

struct FileListResponse: Decodable {
    var nextPageToken: String?
    var files: [APIFile]?
}

struct DriveListResponse: Decodable {
    struct Drive: Decodable {
        var id: String
        var name: String
    }
    var nextPageToken: String?
    var drives: [Drive]?
}

struct StartPageTokenResponse: Decodable {
    var startPageToken: String?
}

struct ChangeListResponse: Decodable {
    struct Change: Decodable {
        var fileId: String?
        var removed: Bool?
        var file: APIFile?
    }
    var nextPageToken: String?
    var newStartPageToken: String?
    var changes: [Change]?
}

struct GoogleErrorResponse: Decodable {
    struct Body: Decodable {
        struct Item: Decodable { var reason: String? }
        var code: Int?
        var status: String?
        var errors: [Item]?
    }
    var error: Body?
}

/// Minimal extension → MIME map for `X-Upload-Content-Type` (Drive derives thumbnails/previews from it).
enum MIMETypes {
    static let table: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "avi": "video/x-msvideo",
        "mkv": "video/x-matroska", "webm": "video/webm", "mts": "video/mp2t", "3gp": "video/3gpp",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "heic": "image/heic",
        "heif": "image/heif", "webp": "image/webp", "tif": "image/tiff", "tiff": "image/tiff", "bmp": "image/bmp",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "aac": "audio/aac", "flac": "audio/flac",
        "pdf": "application/pdf", "zip": "application/zip", "txt": "text/plain", "csv": "text/csv",
        "json": "application/json", "srt": "application/x-subrip",
    ]

    static func type(forFileName name: String) -> String {
        let ext = DisplayNames.split(name).ext.dropFirst().lowercased()
        return table[ext] ?? "application/octet-stream"
    }
}
