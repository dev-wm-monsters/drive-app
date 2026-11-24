using DriveSync.Core.Sync;

namespace DriveSync.Core.Tests;

public class HydrationMathTests
{
    [Theory]
    [InlineData(0, 100, 0, 0, 100, 0, 100)]                 // whole small file, ends at EOF
    [InlineData(5000, 10, 0, 0, 1_000_000, 4096, 8192)]     // unaligned request is widened to 4 KiB
    [InlineData(0, 4096, 4096, 8192, 1_000_000, 0, 12288)]  // contiguous optional range is appended
    [InlineData(0, 4096, 65536, 4096, 1_000_000, 0, 4096)]  // non-contiguous optional range is ignored
    [InlineData(999_000, 50_000, 0, 0, 1_000_000, 995_328, 1_000_000)] // clamped to EOF
    public void Range_is_aligned_and_clamped(long ro, long rl, long oo, long ol, long size, long start, long end) =>
        Assert.Equal((start, end), HydrationMath.ComputeRange(ro, rl, oo, ol, size));

    [Fact]
    public void Every_chunk_is_a_legal_transfer()
    {
        const long size = 5 * 1024 * 1024 + 123;
        var (start, end) = HydrationMath.ComputeRange(4096 * 3 + 7, size, 0, 0, size);
        var chunks = HydrationMath.Chunks(start, end).ToList();
        Assert.All(chunks, c => Assert.True(HydrationMath.IsValidTransfer(c.Offset, c.Length, size)));
        Assert.Equal(end, chunks[^1].Offset + chunks[^1].Length);
        Assert.Equal(end - start, chunks.Sum(c => (long)c.Length));
    }

    [Fact]
    public void Unaligned_middle_chunk_is_illegal() =>
        Assert.False(HydrationMath.IsValidTransfer(4096, 100, 1_000_000));
}
