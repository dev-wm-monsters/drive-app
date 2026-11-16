/// Byte-range validation and segmentation (docs/03-trd.md "Range algorithm").
public enum RangeMath {
    /// Validates signed inputs from the kernel/IPC and clamps the final range at EOF.
    ///
    /// - Negative `offset` or `length` → `.invalidArgument`.
    /// - `offset + length` overflowing `Int64` → `.invalidArgument`.
    /// - Zero `length` → empty range at `offset` (no error).
    /// - `offset >= fileSize` → empty range at `offset` (no error; a read at/after EOF returns 0 bytes).
    /// - Otherwise the length is clamped to `fileSize - offset`.
    public static func clamp(offset: Int64, length: Int64, fileSize: UInt64) throws(StorageError) -> ByteRange {
        guard offset >= 0 else { throw .invalidArgument("negative offset \(offset)") }
        guard length >= 0 else { throw .invalidArgument("negative length \(length)") }
        let (_, signedOverflow) = offset.addingReportingOverflow(length)
        guard !signedOverflow else { throw .invalidArgument("offset \(offset) + length \(length) overflows") }
        let start = UInt64(offset)
        let requested = UInt64(length)
        // Cannot overflow after the Int64 check, but keep the unsigned guard explicit.
        let (_, unsignedOverflow) = start.addingReportingOverflow(requested)
        guard !unsignedOverflow else { throw .invalidArgument("offset \(offset) + length \(length) overflows") }
        guard requested > 0, start < fileSize else { return ByteRange(offset: start, length: 0) }
        return ByteRange(offset: start, length: min(requested, fileSize - start))
    }

    /// The inclusive range of segment indexes the range touches; `nil` for an empty range
    /// (or a zero `segmentSize`).
    public static func segmentIndexes(for range: ByteRange, segmentSize: UInt64 = Limits.segmentSize) -> ClosedRange<UInt64>? {
        guard range.length > 0, segmentSize > 0 else { return nil }
        let first = range.offset / segmentSize
        let last = (range.end - 1) / segmentSize
        return first...last
    }

    /// Splits a range into consecutive chunks of at most `maxChunk` bytes.
    ///
    /// Chunk boundaries are aligned to absolute multiples of `maxChunk` (so with the default,
    /// each chunk lies inside exactly one 4 MiB segment). An empty range yields `[]`.
    /// The chunks are contiguous and their lengths sum to `range.length`.
    public static func split(_ range: ByteRange, maxChunk: UInt64 = Limits.maxReadReply) -> [ByteRange] {
        guard range.length > 0 else { return [] }
        guard maxChunk > 0 else { return [range] }
        var chunks: [ByteRange] = []
        let end = range.end
        var cursor = range.offset
        while cursor < end {
            let boundary = (cursor / maxChunk + 1).multipliedReportingOverflow(by: maxChunk)
            let next = boundary.overflow ? end : min(boundary.partialValue, end)
            chunks.append(ByteRange(offset: cursor, length: next - cursor))
            cursor = next
        }
        return chunks
    }
}
