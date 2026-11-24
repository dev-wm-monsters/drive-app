using System.Security.Cryptography;

namespace DriveSync.Core.Sync;

public static class Hashing
{
    /// <summary>Lower-case hex MD5, the format of Drive's md5Checksum. (MD5 is used only for Drive's integrity field.)</summary>
    public static async Task<string> Md5HexAsync(Stream stream, CancellationToken cancellationToken)
    {
#pragma warning disable CA5351 // Drive exposes md5Checksum; this is an integrity check, not security.
        using var md5 = MD5.Create();
#pragma warning restore CA5351
        var hash = await md5.ComputeHashAsync(stream, cancellationToken).ConfigureAwait(false);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}
