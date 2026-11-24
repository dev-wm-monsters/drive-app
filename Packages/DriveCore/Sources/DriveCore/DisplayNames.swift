import Foundation

/// Display-name algorithm shared with the Windows client (docs/14-shared-drive-sync.md, spec/name-vectors.json).
public enum DisplayNames {
    static let forbidden: Set<Unicode.Scalar> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    static let reserved: Set<String> = {
        var s: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for i in 1...9 {
            s.insert("COM\(i)")
            s.insert("LPT\(i)")
        }
        return s
    }()

    /// NFC; replace `/ \ : * ? " < > |`, U+0000–U+001F, U+007F with `_`; trim trailing spaces and dots;
    /// empty → `_`; Windows device name before the first `.` gets a `_` appended.
    public static func sanitize(_ s: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for u in nfc.unicodeScalars {
            if forbidden.contains(u) || u.value <= 0x1F || u.value == 0x7F {
                scalars.append("_")
            } else {
                scalars.append(u)
            }
        }
        while let last = scalars.last, last == " " || last == "." {
            scalars.removeLast()
        }
        var result = String(scalars)
        if result.isEmpty { return "_" }
        // Scalar-based (not grapheme-based) so a "." followed by a combining mark still splits, as in C#.
        let view = result.unicodeScalars
        let firstPart: String
        let rest: String
        if let dot = view.firstIndex(of: ".") {
            firstPart = String(view[..<dot])
            rest = String(view[dot...])
        } else {
            firstPart = result
            rest = ""
        }
        if reserved.contains(firstPart.uppercased()) {
            result = firstPart + "_" + rest
        }
        return result
    }

    /// Stem and extension: extension starts at the LAST `.` unless that `.` is the first character.
    static func split(_ name: String) -> (stem: String, ext: String) {
        let view = name.unicodeScalars
        guard let dot = view.lastIndex(of: "."), dot != view.startIndex else { return (name, "") }
        return (String(view[..<dot]), String(view[dot...]))
    }

    /// Collision key: sanitized and lower-cased. Compared by Unicode scalars (ordinal), not canonical equivalence.
    static func key(_ name: String) -> [Unicode.Scalar] {
        Array(sanitize(name).lowercased().unicodeScalars)
    }

    /// Visible children of ONE folder → display name per file ID. Hidden items are dropped.
    public static func assign(_ children: [DriveFile]) -> [String: String] {
        let visible = children.filter { !$0.isHidden }.sorted { a, b in
            if a.createdTime != b.createdTime { return a.createdTime < b.createdTime }
            return a.id.utf16.lexicographicallyPrecedes(b.id.utf16)
        }
        var taken = Set<[Unicode.Scalar]>()
        var display = [String: String]()
        for f in visible {
            let name = pick(sanitize(f.name), taken: &taken)
            display[f.id] = name
        }
        return display
    }

    /// A name for a new upload that clashes with none of `existing` (case-insensitive, after sanitizing).
    public static func uniqueUploadName(desired: String, existing: [String]) -> String {
        var taken = Set(existing.map(key))
        return pick(sanitize(desired), taken: &taken)
    }

    private static func pick(_ sanitized: String, taken: inout Set<[Unicode.Scalar]>) -> String {
        let (stem, ext) = split(sanitized)
        var candidate = sanitized
        var n = 2
        while taken.contains(key(candidate)) {
            candidate = "\(stem) (\(n))\(ext)"
            n += 1
        }
        taken.insert(key(candidate))
        return candidate
    }
}
