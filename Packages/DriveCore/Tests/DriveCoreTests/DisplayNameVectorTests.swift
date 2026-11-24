import Foundation
import XCTest
@testable import DriveCore

/// Runs every case in spec/name-vectors.json (shared with the Windows C# tests).
final class DisplayNameVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct Sanitize: Decodable { var `in`: String; var out: String }
        struct Child: Decodable {
            var id: String
            var name: String
            var mimeType: String
            var createdTime: String
            var trashed: Bool?
        }
        struct Assign: Decodable { var name: String; var children: [Child]; var expected: [String: String] }
        struct Upload: Decodable { var desired: String; var existing: [String]; var out: String }
        var sanitize: [Sanitize]
        var assign: [Assign]
        var uniqueUploadName: [Upload]
    }

    static var vectorsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DriveCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // DriveCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("spec/name-vectors.json")
    }

    func loadVectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.vectorsURL))
    }

    /// Exact code-point equality (Swift `==` would treat NFD and NFC as equal).
    func assertScalarsEqual(_ a: String, _ b: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(a.unicodeScalars), Array(b.unicodeScalars), message, file: file, line: line)
    }

    func testSanitizeVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThanOrEqual(v.sanitize.count, 12)
        for c in v.sanitize {
            assertScalarsEqual(DisplayNames.sanitize(c.in), c.out, "sanitize(\(c.in.debugDescription))")
        }
    }

    func testAssignVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThanOrEqual(v.assign.count, 7)
        for c in v.assign {
            let files = try c.children.map { ch -> DriveFile in
                DriveFile(
                    id: ch.id,
                    name: ch.name,
                    mimeType: ch.mimeType,
                    createdTime: try XCTUnwrap(RFC3339.parse(ch.createdTime), ch.createdTime),
                    trashed: ch.trashed ?? false
                )
            }
            let got = DisplayNames.assign(files)
            XCTAssertEqual(Set(got.keys), Set(c.expected.keys), c.name)
            for (id, name) in c.expected {
                assertScalarsEqual(got[id] ?? "<missing>", name, "\(c.name) [\(id)]")
            }
            // Input order must not matter.
            XCTAssertEqual(DisplayNames.assign(files.reversed()), got, "\(c.name) reversed")
        }
    }

    func testUniqueUploadNameVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThanOrEqual(v.uniqueUploadName.count, 3)
        for c in v.uniqueUploadName {
            assertScalarsEqual(
                DisplayNames.uniqueUploadName(desired: c.desired, existing: c.existing),
                c.out,
                "uniqueUploadName(\(c.desired), \(c.existing))"
            )
        }
    }

    func testSplit() {
        XCTAssertEqual(DisplayNames.split(".bashrc").stem, ".bashrc")
        XCTAssertEqual(DisplayNames.split(".bashrc").ext, "")
        XCTAssertEqual(DisplayNames.split("a.tar.gz").stem, "a.tar")
        XCTAssertEqual(DisplayNames.split("a.tar.gz").ext, ".gz")
        XCTAssertEqual(DisplayNames.split("noext").ext, "")
    }

    func testHiddenRules() {
        let t = Date()
        XCTAssertTrue(DriveFile(id: "1", name: "d", mimeType: "application/vnd.google-apps.document", createdTime: t).isHidden)
        XCTAssertTrue(DriveFile(id: "1", name: "s", mimeType: "application/vnd.google-apps.shortcut", createdTime: t).isHidden)
        XCTAssertTrue(DriveFile(id: "1", name: "v", mimeType: "video/mp4", createdTime: t, trashed: true).isHidden)
        let folder = DriveFile(id: "1", name: "f", mimeType: DriveFile.folderMimeType, createdTime: t)
        XCTAssertFalse(folder.isHidden)
        XCTAssertTrue(folder.isFolder)
        XCTAssertFalse(DriveFile(id: "1", name: "v", mimeType: "video/mp4", createdTime: t).isHidden)
    }

    func testRFC3339() {
        XCTAssertEqual(RFC3339.parse("1970-01-01T00:00:00Z"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(RFC3339.parse("1970-01-01T00:00:01.500Z"), Date(timeIntervalSince1970: 1.5))
        XCTAssertEqual(RFC3339.parse("1970-01-01T01:00:00+01:00"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(RFC3339.parse("2026-03-04T05:06:07.123Z")?.timeIntervalSince1970 ?? 0, 1_772_600_767.123, accuracy: 0.0005)
        XCTAssertNil(RFC3339.parse("2026-03-04"))
        XCTAssertNil(RFC3339.parse("2026-03-04T05:06:07"))
    }
}
