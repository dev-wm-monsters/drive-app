using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using DriveSync.Core.Model;

namespace DriveSync.Core.Sync;

/// <summary>
/// The FileIdentity blob stored on every placeholder (max 4 KiB per cfapi). It carries the Drive file ID (used by
/// FETCH_DATA to know what to download) plus the metadata the placeholder was last synced with, so changes can be
/// detected without a local database.
/// </summary>
public sealed record PlaceholderIdentity
{
    public const int MaxBytes = 4096;

    [JsonPropertyName("v")]
    public int Version { get; init; } = 1;

    [JsonPropertyName("id")]
    public required string FileId { get; init; }

    [JsonPropertyName("f")]
    public bool IsFolder { get; init; }

    [JsonPropertyName("m")]
    public string? Md5 { get; init; }

    [JsonPropertyName("s")]
    public long? Size { get; init; }

    [JsonPropertyName("t")]
    public long ModifiedUnixMs { get; init; }

    [JsonPropertyName("c")]
    public long CreatedUnixMs { get; init; }

    public static PlaceholderIdentity From(DriveItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        return new PlaceholderIdentity
        {
            FileId = item.Id,
            IsFolder = item.IsFolder,
            Md5 = item.IsFolder ? null : item.Md5Checksum,
            Size = item.IsFolder ? null : item.Size ?? 0,
            ModifiedUnixMs = item.ModifiedTime.ToUnixTimeMilliseconds(),
            CreatedUnixMs = item.CreatedTime.ToUnixTimeMilliseconds(),
        };
    }

    public byte[] Encode()
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(this);
        if (bytes.Length > MaxBytes)
        {
            throw new InvalidOperationException("Placeholder identity exceeds 4 KiB.");
        }

        return bytes;
    }

    public static PlaceholderIdentity? TryDecode(ReadOnlySpan<byte> blob)
    {
        if (blob.IsEmpty)
        {
            return null;
        }

        try
        {
            var identity = JsonSerializer.Deserialize<PlaceholderIdentity>(blob);
            return identity is { Version: 1 } && !string.IsNullOrEmpty(identity.FileId) ? identity : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>True when the remote file content differs from what this placeholder represents.</summary>
    public bool ContentDiffers(DriveItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (IsFolder || item.IsFolder)
        {
            return false;
        }

        if (Md5 is not null && item.Md5Checksum is not null)
        {
            return !string.Equals(Md5, item.Md5Checksum, StringComparison.OrdinalIgnoreCase);
        }

        return Size != (item.Size ?? 0) || ModifiedUnixMs != item.ModifiedTime.ToUnixTimeMilliseconds();
    }

    public override string ToString() => Encoding.UTF8.GetString(Encode());
}
