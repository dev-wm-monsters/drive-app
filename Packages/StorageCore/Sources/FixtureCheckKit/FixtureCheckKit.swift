import Foundation
import StorageCore

// Logic behind the `fixture-check` executable, kept in a library so tests can drive it
// without spawning processes. Everything is `package` access: not part of the public API.

package let chunkSize = 1024 * 1024

/// Seeded splitmix64 RNG so `verify --seed S` is reproducible.
package struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    package init(seed: UInt64) { state = seed }
    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return FixtureFile.splitmix64(state &- 0x9E37_79B9_7F4A_7C15)
    }
}

// MARK: - Manifest

package struct ManifestFile: Codable, Hashable, Sendable {
    package let path: String
    package let size: UInt64
    package let sha256: String
    package let seed: String
}

package struct Manifest: Codable, Hashable, Sendable {
    package let catalog: String
    package let generator: String
    package let directories: [String]
    package let files: [ManifestFile]
}

package enum FixtureManifest {
    package static let generatorDescription =
        "byte i = LE(splitmix64(seed ^ (i / 8)))[i % 8]; seed = fnv1a64(utf8(name))"

    /// SHA-256 of a fixture, generated and hashed in 1 MiB chunks.
    package static func sha256(of fixture: FixtureFile) -> String {
        var hasher = SHA256Digest.Hasher()
        var offset: UInt64 = 0
        while offset < fixture.size {
            let length = min(UInt64(chunkSize), fixture.size - offset)
            let chunk = fixture.bytes(in: ByteRange(offset: offset, length: length))
            hasher.update(chunk)
            offset += length
        }
        return SHA256Digest.hexString(hasher.finalize())
    }

    package static func make(_ catalog: FixtureCatalog) -> Manifest {
        var dirs: [String] = []
        var files: [ManifestFile] = []
        for entry in catalog.entries {
            if let fixture = entry.fixture {
                files.append(ManifestFile(path: entry.path, size: fixture.size, sha256: sha256(of: fixture),
                                          seed: String(format: "0x%016llx", fixture.seed)))
            } else {
                dirs.append(entry.path)
            }
        }
        return Manifest(catalog: catalog.name, generator: generatorDescription, directories: dirs, files: files)
    }
}

// MARK: - Generate

package enum FixtureGenerator {
    /// Writes the catalog under `root` as real directories and files (1 MiB writes).
    /// Existing catalog files are overwritten; unrelated files are left alone.
    package static func generate(_ catalog: FixtureCatalog, into root: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var written = 0
        for entry in catalog.entries {
            let url = root.appendingPathComponent(entry.path)
            guard let fixture = entry.fixture else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            let handle = try FileHandle(forWritingTo: url)
            var offset: UInt64 = 0
            while offset < fixture.size {
                let length = min(UInt64(chunkSize), fixture.size - offset)
                try handle.write(contentsOf: fixture.data(in: ByteRange(offset: offset, length: length)))
                offset += length
            }
            try handle.close()
            written += 1
        }
        return written
    }
}

// MARK: - Verify

package struct Check: Codable, Hashable, Sendable {
    package let name: String
    package let pass: Bool
    package let detail: String
}

package struct VerifyReport: Codable, Hashable, Sendable {
    package let pass: Bool
    package let catalog: String
    package let root: String
    package let randomReads: Int
    package let seed: UInt64
    package let checks: [Check]
}

package enum FixtureVerifier {
    private static let mib: UInt64 = 1024 * 1024

    /// Walks the expected catalog under `root`: names, kinds, sizes, whole-file SHA-256,
    /// boundary reads, `randomReads` seeded random range reads and a zero-length read.
    package static func verify(_ catalog: FixtureCatalog, root: URL, randomReads: Int, seed: UInt64) -> VerifyReport {
        var checks: [Check] = []
        func add(_ name: String, _ pass: Bool, _ detail: String) {
            checks.append(Check(name: name, pass: pass, detail: detail))
        }
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            add("root", false, "\(root.path) is not a directory")
            return report(catalog, root, randomReads, seed, checks)
        }
        add("root", true, root.path)

        // Directory trees: exact name sets (canonical-equivalent comparison).
        var dirPaths = [""]
        dirPaths += catalog.entries.filter { $0.attributes.kind == .directory }.map(\.path)
        for dirPath in dirPaths {
            let expected = Set(catalog.entries.filter { parentPath(of: $0.path) == dirPath }.map(\.attributes.name))
            let label = "tree:/" + dirPath
            do {
                let actual = Set(try fm.contentsOfDirectory(atPath: url(root, dirPath).path))
                let missing = expected.subtracting(actual).sorted()
                let extra = actual.subtracting(expected).sorted()
                add(label, missing.isEmpty && extra.isEmpty,
                    missing.isEmpty && extra.isEmpty ? "\(expected.count) entries"
                        : "missing \(missing) extra \(extra)")
            } catch {
                add(label, false, "list failed: \(error)")
            }
        }

        let files = catalog.entries.compactMap { entry in entry.fixture.map { (entry.path, $0) } }
        for entry in catalog.entries where entry.fixture == nil {
            var d: ObjCBool = false
            let ok = fm.fileExists(atPath: url(root, entry.path).path, isDirectory: &d) && d.boolValue
            add("kind:" + entry.path, ok, ok ? "directory" : "expected directory")
        }

        var readable: [(String, FixtureFile)] = []
        for (path, fixture) in files {
            let fileURL = url(root, path)
            var d: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &d), !d.boolValue else {
                add("kind:" + path, false, "expected regular file")
                continue
            }
            let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value
            add("size:" + path, size == fixture.size, "expected \(fixture.size) actual \(size.map(String.init) ?? "?")")
            let expectedHash = FixtureManifest.sha256(of: fixture)
            do {
                let actualHash = try sha256(of: fileURL)
                add("sha256:" + path, actualHash == expectedHash,
                    actualHash == expectedHash ? expectedHash : "expected \(expectedHash) actual \(actualHash)")
            } catch {
                add("sha256:" + path, false, "read failed: \(error)")
            }
            readable.append((path, fixture))

            // Boundary reads.
            let s = fixture.size
            var probes: [(UInt64, UInt64)] = [(0, 1), (0, s), (s, 1), (s + 100, 10),
                                               (4 * mib - 1, 2), (4 * mib, 1), (4 * mib + 1, 1), (4 * mib - 4096, 8192)]
            if s > 0 { probes += [(s - 1, 1), (s - 1, 100)] }
            var failures: [String] = []
            for (offset, length) in probes {
                if let problem = compareRead(fileURL, fixture, offset: offset, length: length) { failures.append(problem) }
            }
            add("ranges:" + path, failures.isEmpty,
                failures.isEmpty ? "\(probes.count) boundary reads" : failures.prefix(3).joined(separator: "; "))
        }

        // Zero-length reads.
        if let (path, fixture) = readable.first(where: { $0.1.size > 1 }) {
            var problems: [String] = []
            for offset in [0, fixture.size / 2, fixture.size] {
                do {
                    let handle = try FileHandle(forReadingFrom: url(root, path))
                    defer { try? handle.close() }
                    try handle.seek(toOffset: offset)
                    let got = try handle.read(upToCount: 0) ?? Data()
                    if !got.isEmpty { problems.append("offset \(offset): got \(got.count) bytes") }
                } catch {
                    problems.append("offset \(offset): \(error)")
                }
            }
            add("zero-length-read", problems.isEmpty, problems.isEmpty ? "\(path) at 0, mid, EOF" : problems.joined(separator: "; "))
        } else {
            add("zero-length-read", false, "no readable non-trivial file")
        }

        // Random reads.
        if randomReads > 0 {
            if readable.isEmpty {
                add("random-reads", false, "no readable files")
            } else {
                var rng = SeededGenerator(seed: seed)
                var failures: [String] = []
                var bytes: UInt64 = 0
                for _ in 0..<randomReads {
                    let (path, fixture) = readable[Int.random(in: 0..<readable.count, using: &rng)]
                    let offset = UInt64.random(in: 0...(fixture.size + 16), using: &rng)
                    let length: UInt64
                    switch UInt8.random(in: 0..<4, using: &rng) {
                    case 0: length = UInt64.random(in: 0...64, using: &rng)
                    case 1: length = UInt64.random(in: 0...65_536, using: &rng)
                    case 2: length = UInt64.random(in: 0...(4 * mib + 2), using: &rng)
                    default: length = UInt64.random(in: 0...4096, using: &rng)
                    }
                    bytes += length
                    if let problem = compareRead(url(root, path), fixture, offset: offset, length: length) {
                        failures.append("\(path) \(problem)")
                    }
                }
                add("random-reads", failures.isEmpty,
                    failures.isEmpty ? "\(randomReads) reads, \(bytes) bytes requested, seed \(seed)"
                        : "\(failures.count)/\(randomReads) failed: " + failures.prefix(3).joined(separator: "; "))
            }
        }
        return report(catalog, root, randomReads, seed, checks)
    }

    private static func report(_ catalog: FixtureCatalog, _ root: URL, _ n: Int, _ seed: UInt64, _ checks: [Check]) -> VerifyReport {
        VerifyReport(pass: !checks.isEmpty && checks.allSatisfy(\.pass), catalog: catalog.name, root: root.path,
                     randomReads: n, seed: seed, checks: checks)
    }

    private static func url(_ root: URL, _ path: String) -> URL {
        path.isEmpty ? root : root.appendingPathComponent(path)
    }

    private static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// pread-style read via FileHandle seek + read; nil when it matches the generator.
    private static func compareRead(_ fileURL: URL, _ fixture: FixtureFile, offset: UInt64, length: UInt64) -> String? {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            var got = Data()
            while UInt64(got.count) < length {
                let want = Int(min(UInt64(chunkSize), length - UInt64(got.count)))
                guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else { break }
                got.append(chunk)
            }
            let range = try RangeMath.clamp(offset: Int64(offset), length: Int64(length), fileSize: fixture.size)
            let expected = fixture.data(in: range)
            if got == expected { return nil }
            let firstDiff = zip(got, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            return "read(\(offset), \(length)): got \(got.count) bytes, expected \(expected.count)"
                + (firstDiff.map { ", first mismatch at +\($0)" } ?? "")
        } catch {
            return "read(\(offset), \(length)): \(error)"
        }
    }

    package static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256Digest.Hasher()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return SHA256Digest.hexString(hasher.finalize())
    }
}

// MARK: - CLI

package struct GenerateSummary: Codable, Hashable, Sendable {
    package let catalog: String
    package let directory: String
    package let files: Int
}

package enum FixtureCheckCLI {
    package static let usage = """
        usage:
          fixture-check generate <dir>
          fixture-check verify <mountpoint> [--random-reads N] [--seed S]
          fixture-check manifest
        """

    package static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs the CLI. Exit codes: 0 pass, 1 failure, 2 usage error.
    package static func run(_ arguments: [String], catalog: FixtureCatalog = .spike,
                            out: (String) -> Void, err: (String) -> Void) -> Int32 {
        guard let command = arguments.first else { err(usage); return 2 }
        switch command {
        case "generate":
            guard arguments.count == 2 else { err(usage); return 2 }
            let dir = URL(fileURLWithPath: arguments[1])
            do {
                let n = try FixtureGenerator.generate(catalog, into: dir)
                out(json(GenerateSummary(catalog: catalog.name, directory: dir.path, files: n)))
                return 0
            } catch {
                err("generate failed: \(error)")
                return 1
            }
        case "verify":
            guard arguments.count >= 2 else { err(usage); return 2 }
            var randomReads = 200
            var seed: UInt64 = 1
            var i = 2
            while i < arguments.count {
                let flag = arguments[i]
                guard i + 1 < arguments.count else { err(usage); return 2 }
                switch flag {
                case "--random-reads":
                    guard let n = Int(arguments[i + 1]), n >= 0 else { err("bad --random-reads"); return 2 }
                    randomReads = n
                case "--seed":
                    guard let s = UInt64(arguments[i + 1]) else { err("bad --seed"); return 2 }
                    seed = s
                default:
                    err(usage); return 2
                }
                i += 2
            }
            let report = FixtureVerifier.verify(catalog, root: URL(fileURLWithPath: arguments[1]),
                                                randomReads: randomReads, seed: seed)
            out(json(report))
            return report.pass ? 0 : 1
        case "manifest":
            guard arguments.count == 1 else { err(usage); return 2 }
            out(json(FixtureManifest.make(catalog)))
            return 0
        default:
            err(usage)
            return 2
        }
    }
}
