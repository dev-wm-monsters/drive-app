namespace DriveSync.Core.Sync;

/// <summary>
/// Range arithmetic for cfapi hydration (CF_OPERATION_TYPE_TRANSFER_DATA): every transfer's offset must be 4 KiB
/// aligned and its length a multiple of 4 KiB, except a range that ends at end-of-file.
/// </summary>
public static class HydrationMath
{
    public const int Alignment = 4096;

    /// <summary>Transfer buffer: 1 MiB (a multiple of 4 KiB) keeps progress smooth and memory small.</summary>
    public const int DefaultChunkSize = 1024 * 1024;

    /// <summary>
    /// The byte range to download for a FETCH_DATA request: the required range, extended by the optional range when
    /// it is contiguous (the platform's read-ahead hint), aligned down/up to 4 KiB and clamped to the file size.
    /// </summary>
    public static (long Start, long End) ComputeRange(long requiredOffset, long requiredLength, long optionalOffset, long optionalLength, long fileSize)
    {
        if (fileSize <= 0 || requiredLength <= 0)
        {
            return (0, 0);
        }

        var start = AlignDown(Math.Clamp(requiredOffset, 0, fileSize));
        var end = Math.Min(fileSize, requiredOffset + requiredLength);
        if (optionalLength > 0 && optionalOffset <= end && optionalOffset + optionalLength > end)
        {
            end = Math.Min(fileSize, optionalOffset + optionalLength);
        }

        end = Math.Min(fileSize, AlignUp(end));
        return (start, end);
    }

    /// <summary>Splits [start, end) into transfer chunks that satisfy the alignment rule.</summary>
    public static IEnumerable<(long Offset, int Length)> Chunks(long start, long end, int chunkSize = DefaultChunkSize)
    {
        if (start % Alignment != 0 || chunkSize % Alignment != 0 || chunkSize <= 0)
        {
            throw new ArgumentException("start and chunkSize must be 4 KiB aligned");
        }

        for (var offset = start; offset < end; offset += chunkSize)
        {
            yield return (offset, (int)Math.Min(chunkSize, end - offset));
        }
    }

    /// <summary>True when a transfer of [offset, offset+length) is legal for a file of <paramref name="fileSize"/> bytes.</summary>
    public static bool IsValidTransfer(long offset, long length, long fileSize) =>
        offset % Alignment == 0 && length > 0 && (length % Alignment == 0 || offset + length >= fileSize);

    public static long AlignDown(long value) => value - (value % Alignment);

    public static long AlignUp(long value) => value % Alignment == 0 ? value : value + (Alignment - (value % Alignment));
}
