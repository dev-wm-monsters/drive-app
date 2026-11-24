import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import DriveCore

final class DriveClientTests: XCTestCase {
    let sharedRoot = DriveRoot(id: "drive1", name: "WakeupMonster", driveID: "drive1")
    let folderRoot = DriveRoot(id: "rootF", name: "Shared", driveID: nil)

    // MARK: - Root

    func testResolveRootExactlyOneDrive() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/drives"),
                       .json(200, #"{"nextPageToken":"p2","drives":[{"id":"other","name":"WakeupMonster old"}]}"#),
                       .json(200, #"{"drives":[{"id":"drive1","name":"WakeupMonster"}]}"#))
        let root = try await h.client.resolveRoot()
        XCTAssertEqual(root, DriveRoot(id: "drive1", name: "WakeupMonster", driveID: "drive1"))
        let reqs = h.transport.requests
        XCTAssertEqual(reqs.count, 2)
        XCTAssertEqual(query(reqs[0])["q"], "name = 'WakeupMonster'")
        XCTAssertEqual(query(reqs[0])["fields"], "nextPageToken,drives(id,name)")
        XCTAssertNil(query(reqs[0])["pageToken"])
        XCTAssertEqual(query(reqs[1])["pageToken"], "p2")
        XCTAssertEqual(bearer(reqs[0]), "Bearer at-1")
    }

    func testResolveRootNoneAndAmbiguous() async {
        let h = Harness()
        h.transport.on(path("/drive/v3/drives"),
                       .json(200, #"{"drives":[]}"#),
                       .json(200, #"{"drives":[{"id":"d1","name":"WakeupMonster"},{"id":"d2","name":"WakeupMonster"}]}"#))
        await expectError(.rootNotFound("WakeupMonster")) { try await h.client.resolveRoot() }
        await expectError(.rootAmbiguous(["d1", "d2"])) { try await h.client.resolveRoot() }
    }

    func testResolveRootEscapesQuotes() async throws {
        let h = Harness(root: .sharedDriveNamed("Bob's \\ drive"))
        h.transport.on(path("/drive/v3/drives"), .json(200, #"{"drives":[{"id":"d","name":"Bob's \\ drive"}]}"#))
        _ = try await h.client.resolveRoot()
        XCTAssertEqual(query(h.transport.requests[0])["q"], #"name = 'Bob\'s \\ drive'"#)
    }

    func testResolveRootFolderMode() async throws {
        let h = Harness(root: .folderID("rootF"))
        h.transport.on(path("/drive/v3/files/rootF"),
                       .json(200, fileJSON(id: "rootF", name: "Shared", mimeType: DriveFile.folderMimeType, parents: ["x"])))
        let root = try await h.client.resolveRoot()
        XCTAssertEqual(root, DriveRoot(id: "rootF", name: "Shared", driveID: nil))
        XCTAssertTrue(root.isFolderMode)
        let q = query(h.transport.requests[0])
        XCTAssertEqual(q["supportsAllDrives"], "true")
        XCTAssertEqual(q["fields"], DriveClient.fields + ",driveId")
    }

    func testResolveRootFolderInsideSharedDrive() async throws {
        let h = Harness(root: .folderID("rootF"))
        h.transport.on(path("/drive/v3/files/rootF"),
                       .json(200, fileJSON(id: "rootF", name: "Shared", mimeType: DriveFile.folderMimeType,
                                           parents: ["sd1"], extra: #""driveId":"sd1""#)))
        let root = try await h.client.resolveRoot()
        XCTAssertEqual(root, DriveRoot(id: "rootF", name: "Shared", driveID: "sd1"))
        XCTAssertTrue(root.isFolderMode)
        XCTAssertFalse(sharedRoot.isFolderMode)
        // A shared drive's own root folder given as the folder ID is plain shared-drive mode.
        XCTAssertFalse(DriveRoot(id: "sd1", name: "D", driveID: "sd1").isFolderMode)
    }

    func testFolderInsideSharedDriveScopesListAndChangesAndFilters() async throws {
        let h = Harness(root: .folderID("rootF"))
        let root = DriveRoot(id: "rootF", name: "Shared", driveID: "sd1")
        h.transport.on(path("/drive/v3/files"),
                       .json(200, """
                       {"files":[\(fileJSON(id: "sub", name: "Sub", mimeType: DriveFile.folderMimeType, parents: ["rootF"]))]}
                       """))
        _ = try await h.client.listChildren(of: "rootF", root: root)
        let lq = query(h.transport.requests[0])
        XCTAssertEqual(lq["corpora"], "drive")
        XCTAssertEqual(lq["driveId"], "sd1")
        h.transport.on(path("/drive/v3/changes/startPageToken"), .json(200, #"{"startPageToken":"s"}"#))
        _ = try await h.client.startPageToken(root: root)
        XCTAssertEqual(query(h.transport.requests[1])["driveId"], "sd1")
        h.transport.on(path("/drive/v3/changes"),
                       .json(200, """
                       {"newStartPageToken":"n","changes":[
                         {"fileId":"elsewhere","file":\(fileJSON(id: "elsewhere", name: "e.mp4", parents: ["sd1"]))},
                         {"fileId":"in","file":\(fileJSON(id: "in", name: "i.mp4", parents: ["sub"]))}
                       ]}
                       """))
        let batch = try await h.client.changes(since: "s", root: root)
        XCTAssertEqual(batch.changes.map { if case .upsert(let f) = $0 { return f.id } else { return "-" } }, ["in"])
        let cq = query(h.transport.requests[2])
        XCTAssertEqual(cq["driveId"], "sd1")
        XCTAssertEqual(cq["includeItemsFromAllDrives"], "true")
        let snapshot = await h.client.folderIndexSnapshot()
        XCTAssertEqual(snapshot?.folderIDs, ["rootF", "sub"])
    }

    func testResolveRootFolderModeErrors() async {
        let h = Harness(root: .folderID("f"))
        h.transport.on(path("/drive/v3/files/f"),
                       .googleError(404, reason: "notFound"),
                       .json(200, fileJSON(id: "f", name: "a.mp4")))
        await expectError(.rootNotFound("f")) { try await h.client.resolveRoot() }
        await expectError(.rootNotFound("f")) { try await h.client.resolveRoot() }
    }

    func testResolveRootSharedDriveID() async throws {
        let h = Harness(root: .sharedDriveID("d9"))
        h.transport.on(path("/drive/v3/drives/d9"), .json(200, #"{"id":"d9","name":"WakeupMonster"}"#))
        let root = try await h.client.resolveRoot()
        XCTAssertEqual(root, DriveRoot(id: "d9", name: "WakeupMonster", driveID: "d9"))
    }

    // MARK: - List

    func testListChildrenPaginationHiddenFilteringAndParams() async throws {
        let h = Harness()
        let size = #""size":"123456789012","md5Checksum":"abc","thumbnailLink":"https://lh3.example/t","lastModifyingUser":{"displayName":"Ann","emailAddress":"a@x"},"videoMediaMetadata":{"durationMillis":"61000","width":1920,"height":1080},"capabilities":{"canDownload":false}"#
        h.transport.on(path("/drive/v3/files"),
                       .json(200, """
                       {"nextPageToken":"tok2","files":[\(fileJSON(id: "v1", name: "clip.mp4", parents: ["drive1"], extra: size)),
                       \(fileJSON(id: "doc", name: "Plan", mimeType: "application/vnd.google-apps.document", parents: ["drive1"]))]}
                       """),
                       .json(200, """
                       {"files":[\(fileJSON(id: "sc", name: "link", mimeType: "application/vnd.google-apps.shortcut", parents: ["drive1"])),
                       \(fileJSON(id: "f1", name: "Sub", mimeType: DriveFile.folderMimeType, parents: ["drive1"])),
                       \(fileJSON(id: "i1", name: "p.jpg", mimeType: "image/jpeg", parents: ["drive1"], extra: #""imageMediaMetadata":{"width":4000,"height":3000}"#))]}
                       """))
        let files = try await h.client.listChildren(of: "drive1", root: sharedRoot)
        XCTAssertEqual(files.map(\.id), ["v1", "f1", "i1"])
        let v = files[0]
        XCTAssertEqual(v.size, 123_456_789_012)
        XCTAssertEqual(v.md5Checksum, "abc")
        XCTAssertEqual(v.thumbnailLink?.absoluteString, "https://lh3.example/t")
        XCTAssertEqual(v.lastModifyingUserName, "Ann")
        XCTAssertEqual(v.videoDurationMillis, 61000)
        XCTAssertEqual(v.width, 1920)
        XCTAssertEqual(v.height, 1080)
        XCTAssertFalse(v.canDownload)
        XCTAssertEqual(v.createdTime, RFC3339.parse("2026-01-01T10:00:00Z"))
        XCTAssertTrue(files[1].isFolder)
        XCTAssertNil(files[1].size)
        XCTAssertTrue(files[1].canDownload)
        XCTAssertEqual(files[2].width, 4000)

        let reqs = h.transport.requests
        XCTAssertEqual(reqs.count, 2)
        XCTAssertEqual(query(reqs[0]), [
            "q": "'drive1' in parents and trashed = false",
            "pageSize": "1000",
            "fields": "nextPageToken,files(\(DriveClient.fields))",
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
            "corpora": "drive",
            "driveId": "drive1",
        ])
        XCTAssertEqual(query(reqs[1])["pageToken"], "tok2")
        XCTAssertEqual(reqs[0].httpMethod, "GET")
    }

    func testListChildrenFolderModeHasNoCorpora() async throws {
        let h = Harness(root: .folderID("rootF"))
        h.transport.on(path("/drive/v3/files"), .json(200, #"{"files":[]}"#))
        _ = try await h.client.listChildren(of: "rootF", root: folderRoot)
        let q = query(h.transport.requests[0])
        XCTAssertNil(q["corpora"])
        XCTAssertNil(q["driveId"])
        XCTAssertEqual(q["includeItemsFromAllDrives"], "true")
        XCTAssertEqual(q["supportsAllDrives"], "true")
    }

    func testFieldsConstantMatchesContract() {
        XCTAssertEqual(DriveClient.fields, "id,name,mimeType,size,createdTime,modifiedTime,md5Checksum,parents,trashed,thumbnailLink,hasThumbnail,iconLink,lastModifyingUser(displayName,emailAddress),videoMediaMetadata(durationMillis,width,height),imageMediaMetadata(width,height),capabilities(canDownload)")
    }

    // MARK: - Errors / retry

    func testErrorMappingTable() async {
        let cases: [(Reply, DriveError)] = [
            (.googleError(404, reason: "notFound"), .notFound),
            (.googleError(403, reason: "storageQuotaExceeded"), .quotaExceeded),
            (.googleError(403, reason: "quotaExceeded"), .quotaExceeded),
            (.googleError(403, reason: "insufficientFilePermissions"), .forbidden("insufficientFilePermissions")),
            (.googleError(403, googleStatus: "PERMISSION_DENIED"), .forbidden("PERMISSION_DENIED")),
            (.googleError(403, reason: "rateLimitExceeded"), .rateLimited(retryAfter: nil)),
            (.googleError(403, reason: "userRateLimitExceeded", headers: ["Retry-After": "3"]), .rateLimited(retryAfter: .seconds(3))),
            (.googleError(429), .rateLimited(retryAfter: nil)),
            (.googleError(500), .server(500)),
            (.status(502, body: Data("<html>".utf8)), .server(502)),
            (.googleError(400, reason: "invalid"), .invalidResponse("HTTP 400 invalid")),
        ]
        for (reply, expected) in cases {
            let h = Harness(maxAttempts: 1)
            h.transport.on(path("/drive/v3/files/x"), reply)
            await expectError(expected) { try await h.client.file(id: "x") }
            XCTAssertEqual(h.transport.requests.count, 1, "\(expected)")
        }
    }

    func testRetryBackoffThenSuccess() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/x"),
                       .googleError(503),
                       .googleError(403, reason: "rateLimitExceeded"),
                       .failure(URLError(.networkConnectionLost)),
                       .json(200, fileJSON(id: "x", name: "a.mp4")))
        let f = try await h.client.file(id: "x")
        XCTAssertEqual(f.id, "x")
        XCTAssertEqual(h.transport.requests.count, 4)
        XCTAssertEqual(h.sleeps.sleeps, [.seconds(1), .seconds(2), .seconds(4)])
    }

    func testRetryAfterHonoured() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/x"),
                       .googleError(429, headers: ["Retry-After": "7"]),
                       .json(200, fileJSON(id: "x", name: "a.mp4")))
        _ = try await h.client.file(id: "x")
        XCTAssertEqual(h.sleeps.sleeps, [.seconds(7)])
    }

    func testRetryGivesUpAfterMaxAttempts() async {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/x"), handler: { _ in .googleError(500) })
        await expectError(.server(500)) { try await h.client.file(id: "x") }
        XCTAssertEqual(h.transport.requests.count, 5)
        XCTAssertEqual(h.sleeps.sleeps, [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    func testBackoffIsCappedAndJittered() {
        let p = RetryPolicy(jitter: { $0 }, sleep: { _ in })
        XCTAssertEqual(p.delay(afterFailures: 1, retryAfter: nil), .seconds(1))
        XCTAssertEqual(p.delay(afterFailures: 6, retryAfter: nil), .seconds(32))
        XCTAssertEqual(p.delay(afterFailures: 40, retryAfter: nil), .seconds(32))
        XCTAssertEqual(p.delay(afterFailures: 1, retryAfter: .seconds(1000)), .seconds(300))
        let real = RetryPolicy.default
        XCTAssertEqual(real.maxAttempts, 5)
        XCTAssertEqual(real.baseDelay, .seconds(1))
        XCTAssertEqual(real.maxDelay, .seconds(32))
        for _ in 0..<50 {
            let d = real.delay(afterFailures: 3, retryAfter: nil)
            XCTAssertTrue(d >= .zero && d <= .seconds(4))
        }
        XCTAssertEqual(RetryPolicy.parseRetryAfter("12"), .seconds(12))
        XCTAssertEqual(RetryPolicy.parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT",
                                                   now: RFC3339.parse("2015-10-21T07:27:00Z")!), .seconds(60))
        XCTAssertNil(RetryPolicy.parseRetryAfter("soon"))
    }

    func testNoRetryOn404() async {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/x"), handler: { _ in .googleError(404, reason: "notFound") })
        await expectError(.notFound) { try await h.client.file(id: "x") }
        XCTAssertEqual(h.transport.requests.count, 1)
        XCTAssertTrue(h.sleeps.sleeps.isEmpty)
    }

    func test401RefreshesOnceAndRetries() async throws {
        let h = Harness()
        h.scriptRefreshes()
        h.transport.on(path("/drive/v3/files/x"),
                       .googleError(401),
                       .json(200, fileJSON(id: "x", name: "a.mp4")))
        _ = try await h.client.file(id: "x")
        let api = h.transport.requests(matching: isAPI)
        XCTAssertEqual(api.map(bearer), ["Bearer at-1", "Bearer at-2"])
        XCTAssertEqual(h.transport.requests(matching: isToken).count, 1)
        XCTAssertTrue(h.sleeps.sleeps.isEmpty)
    }

    func test401AfterRefreshIsNeedsLogin() async {
        let h = Harness()
        h.scriptRefreshes()
        h.transport.on(path("/drive/v3/files/x"), handler: { _ in .googleError(401) })
        await expectError(.needsLogin) { try await h.client.file(id: "x") }
        XCTAssertEqual(h.transport.requests(matching: isAPI).count, 2)
        XCTAssertEqual(h.transport.requests(matching: isToken).count, 1)
    }

    func test401WithRevokedRefreshTokenIsNeedsLogin() async {
        let h = Harness()
        h.transport.on(isToken, .json(400, #"{"error":"invalid_grant"}"#))
        h.transport.on(path("/drive/v3/files/x"), .googleError(401))
        await expectError(.needsLogin) { try await h.client.file(id: "x") }
        let signedIn = await h.auth.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testCancellation() async {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/x"), .failure(URLError(.cancelled)))
        await expectError(.cancelled) { try await h.client.file(id: "x") }
        XCTAssertEqual(h.transport.requests.count, 1)
    }

    // MARK: - Download

    func testDownloadVerifiesMD5AndRenamesAtomically() async throws {
        let h = Harness()
        let content = Data("hello drive".utf8)
        h.transport.on(path("/drive/v3/files/f1"), .status(200, body: content))
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.mp4")
        try Data("old".utf8).write(to: dest)
        try await h.client.download(id: "f1", to: dest, expectedMD5: Hashing.md5Hex(content).uppercased())
        XCTAssertEqual(try Data(contentsOf: dest), content)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["out.mp4"])
        let q = query(h.transport.requests[0])
        XCTAssertEqual(q, ["alt": "media", "supportsAllDrives": "true"])
        XCTAssertNil(h.transport.requests[0].value(forHTTPHeaderField: "Range"))
    }

    func testDownloadMD5MismatchRemovesTempAndKeepsDestination() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/f1"), .status(200, body: Data("tampered".utf8)))
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.mp4")
        try Data("old".utf8).write(to: dest)
        await expectError(.checksumMismatch) {
            try await h.client.download(id: "f1", to: dest, expectedMD5: Hashing.md5Hex(Data("original".utf8)))
        }
        XCTAssertEqual(try Data(contentsOf: dest), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["out.mp4"])
    }

    func testDownloadErrorLeavesNoTempFile() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/f1"), .googleError(403, reason: "cannotDownloadFile"))
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("new.bin")
        await expectError(.forbidden("cannotDownloadFile")) { try await h.client.download(id: "f1", to: dest, expectedMD5: nil) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testDownloadWithoutMD5() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/f1"), .googleError(500), .status(200, body: Data([1, 2, 3])))
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("new.bin")
        try await h.client.download(id: "f1", to: dest, expectedMD5: nil)
        XCTAssertEqual(try Data(contentsOf: dest), Data([1, 2, 3]))
        XCTAssertEqual(h.sleeps.sleeps.count, 1)
    }

    func testDownloadRange206() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/f1"),
                       .status(206, headers: ["Content-Range": "bytes 100-109/1000"], body: Data(repeating: 7, count: 10)))
        let d = try await h.client.downloadRange(id: "f1", offset: 100, length: 10)
        XCTAssertEqual(d, Data(repeating: 7, count: 10))
        let r = h.transport.requests[0]
        XCTAssertEqual(r.value(forHTTPHeaderField: "Range"), "bytes=100-109")
        XCTAssertEqual(query(r), ["alt": "media", "supportsAllDrives": "true"])
    }

    func testDownloadRangeRejects200() async {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/f1"), .status(200, body: Data(repeating: 1, count: 1000)))
        await expectError(.invalidResponse("server ignored Range (HTTP 200)")) {
            try await h.client.downloadRange(id: "f1", offset: 0, length: 10)
        }
        XCTAssertEqual(h.transport.requests.count, 1)
    }

    func testDownloadRangeShortOnlyAtEOF() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/files/f1"),
                       .status(206, headers: ["Content-Range": "bytes 990-999/1000"], body: Data(repeating: 2, count: 10)),
                       .status(206, headers: ["Content-Range": "bytes 0-4/1000"], body: Data(repeating: 2, count: 5)),
                       .status(416, headers: ["Content-Range": "bytes */1000"]),
                       .status(206, headers: ["Content-Range": "bytes 0-19/1000"], body: Data(repeating: 3, count: 20)))
        let atEOF = try await h.client.downloadRange(id: "f1", offset: 990, length: 64)
        XCTAssertEqual(atEOF.count, 10)
        await expectError(.invalidResponse("short partial response")) {
            try await h.client.downloadRange(id: "f1", offset: 0, length: 64)
        }
        let beyond = try await h.client.downloadRange(id: "f1", offset: 5000, length: 10)
        XCTAssertEqual(beyond, Data())
        let trimmed = try await h.client.downloadRange(id: "f1", offset: 0, length: 8)
        XCTAssertEqual(trimmed.count, 8)
        let none = try await h.client.downloadRange(id: "f1", offset: 0, length: 0)
        XCTAssertEqual(none, Data())
        XCTAssertEqual(h.transport.requests.count, 4)
    }

    // MARK: - Changes

    func testStartPageToken() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/changes/startPageToken"),
                       .json(200, #"{"startPageToken":"100"}"#),
                       .json(200, #"{"startPageToken":"200"}"#))
        let t1 = try await h.client.startPageToken(root: sharedRoot)
        let t2 = try await h.client.startPageToken(root: folderRoot)
        XCTAssertEqual([t1, t2], ["100", "200"])
        XCTAssertEqual(query(h.transport.requests[0]), ["supportsAllDrives": "true", "driveId": "drive1"])
        XCTAssertEqual(query(h.transport.requests[1]), ["supportsAllDrives": "true"])
    }

    func testChangesSharedDrivePagingAndMapping() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/changes"),
                       .json(200, """
                       {"nextPageToken":"p2","changes":[
                         {"fileId":"a","removed":false,"file":\(fileJSON(id: "a", name: "a.mp4", parents: ["drive1"]))},
                         {"fileId":"b","removed":true},
                         {"fileId":"c","removed":false,"file":\(fileJSON(id: "c", name: "c.mp4", parents: ["drive1"], trashed: true))},
                         {"fileId":"d","removed":false,"file":\(fileJSON(id: "d", name: "Doc", mimeType: "application/vnd.google-apps.spreadsheet", parents: ["drive1"]))},
                         {"removed":false}
                       ]}
                       """),
                       .json(200, """
                       {"newStartPageToken":"p3","changes":[{"fileId":"e","file":\(fileJSON(id: "e", name: "E", mimeType: DriveFile.folderMimeType, parents: ["drive1"]))}]}
                       """))
        let b1 = try await h.client.changes(since: "p1", root: sharedRoot)
        XCTAssertEqual(b1.nextPageToken, "p2")
        XCTAssertNil(b1.newStartPageToken)
        XCTAssertEqual(b1.changes.count, 4)
        guard case .upsert(let a) = b1.changes[0] else { return XCTFail("expected upsert") }
        XCTAssertEqual(a.id, "a")
        XCTAssertEqual(Array(b1.changes[1...]), [.removed(fileID: "b"), .removed(fileID: "c"), .removed(fileID: "d")])
        let b2 = try await h.client.changes(since: "p2", root: sharedRoot)
        XCTAssertNil(b2.nextPageToken)
        XCTAssertEqual(b2.newStartPageToken, "p3")
        XCTAssertEqual(b2.changes.count, 1)

        let reqs = h.transport.requests
        XCTAssertEqual(query(reqs[0]), [
            "pageToken": "p1",
            "pageSize": "1000",
            "fields": "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(DriveClient.fields)))",
            "supportsAllDrives": "true",
            "includeItemsFromAllDrives": "true",
            "driveId": "drive1",
        ])
        XCTAssertEqual(query(reqs[1])["pageToken"], "p2")
    }

    func testAllChangesFollowsPages() async throws {
        let h = Harness()
        h.transport.on(path("/drive/v3/changes"),
                       .json(200, #"{"nextPageToken":"p2","changes":[{"fileId":"x","removed":true}]}"#),
                       .json(200, #"{"newStartPageToken":"p9","changes":[{"fileId":"y","removed":true}]}"#))
        let r = try await h.client.allChanges(since: "p1", root: sharedRoot)
        XCTAssertEqual(r.changes, [.removed(fileID: "x"), .removed(fileID: "y")])
        XCTAssertEqual(r.newStartPageToken, "p9")
    }

    func testChangesFolderModeFiltering() async throws {
        let h = Harness(root: .folderID("rootF"))
        // Tree: rootF / sub (folder) / known.mp4
        h.transport.on(path("/drive/v3/files"),
                       .json(200, """
                       {"files":[\(fileJSON(id: "sub", name: "Sub", mimeType: DriveFile.folderMimeType, parents: ["rootF"])),
                                 \(fileJSON(id: "known", name: "k.mp4", parents: ["rootF"]))]}
                       """))
        _ = try await h.client.listChildren(of: "rootF", root: folderRoot)
        h.transport.on(path("/drive/v3/changes"),
                       .json(200, """
                       {"newStartPageToken":"n","changes":[
                         {"fileId":"out","file":\(fileJSON(id: "out", name: "elsewhere.mp4", parents: ["myDrive"]))},
                         {"fileId":"new1","file":\(fileJSON(id: "new1", name: "n.mp4", parents: ["sub"]))},
                         {"fileId":"nf","file":\(fileJSON(id: "nf", name: "NewFolder", mimeType: DriveFile.folderMimeType, parents: ["sub"]))},
                         {"fileId":"deep","file":\(fileJSON(id: "deep", name: "d.mp4", parents: ["nf"]))},
                         {"fileId":"known","file":\(fileJSON(id: "known", name: "k.mp4", parents: ["myDrive"]))},
                         {"fileId":"trashed1","file":\(fileJSON(id: "trashed1", name: "t.mp4", parents: ["sub"], trashed: true))},
                         {"fileId":"gone","removed":true},
                         {"fileId":"other-trash","file":\(fileJSON(id: "other-trash", name: "x", parents: ["myDrive"], trashed: true))}
                       ]}
                       """))
        let batch = try await h.client.changes(since: "s", root: folderRoot)
        let summary: [String] = batch.changes.map {
            switch $0 {
            case .upsert(let f): return "+\(f.id)"
            case .removed(let id): return "-\(id)"
            }
        }
        XCTAssertEqual(summary, ["+new1", "+nf", "+deep", "-known", "-trashed1", "-gone"])
        let q = query(h.transport.requests.last!)
        XCTAssertNil(q["driveId"])
        let snapshot = await h.client.folderIndexSnapshot()
        let index = try XCTUnwrap(snapshot)
        XCTAssertEqual(index.folderIDs, ["rootF", "sub", "nf"])
        XCTAssertFalse(index.contains("known"))
        XCTAssertTrue(index.contains("deep"))
    }

    func testFolderIndex() {
        var idx = FolderIndex(rootID: "r")
        let t = Date()
        let child = DriveFile(id: "c", name: "c", mimeType: "video/mp4", createdTime: t, parents: ["r"])
        let stranger = DriveFile(id: "s", name: "s", mimeType: "video/mp4", createdTime: t, parents: ["z"])
        XCTAssertTrue(idx.isRelevant(child))
        XCTAssertFalse(idx.isRelevant(stranger))
        idx.insert(fileID: "s")
        XCTAssertTrue(idx.isRelevant(stranger))
        XCTAssertFalse(idx.isInTree(stranger))
        idx.insert(folderID: "z")
        XCTAssertTrue(idx.isInTree(stranger))
        idx.remove("z")
        XCTAssertFalse(idx.isInTree(stranger))
        idx.remove("r")
        XCTAssertTrue(idx.folderIDs.contains("r"))
    }

    func testRestoreFolderIndex() async throws {
        let h = Harness(root: .folderID("rootF"))
        var idx = FolderIndex(rootID: "rootF")
        idx.insert(folderID: "sub")
        await h.client.restoreFolderIndex(idx)
        h.transport.on(path("/drive/v3/changes"),
                       .json(200, #"{"newStartPageToken":"n","changes":[{"fileId":"a","file":\#(fileJSON(id: "a", name: "a", parents: ["sub"]))}]}"#))
        let b = try await h.client.changes(since: "s", root: folderRoot)
        XCTAssertEqual(b.changes.count, 1)
    }
}
