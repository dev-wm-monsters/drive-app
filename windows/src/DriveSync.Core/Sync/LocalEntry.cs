namespace DriveSync.Core.Sync;

/// <summary>One file or folder found under the sync root (produced by IPlaceholderSystem.Scan).</summary>
public sealed record LocalEntry
{
    public required string Path { get; init; }

    public bool IsDirectory { get; init; }

    /// <summary>True when the item is a cloud-files placeholder (has a cfapi reparse point).</summary>
    public bool IsPlaceholder { get; init; }

    /// <summary>Our identity blob; null for user-created items and foreign placeholders.</summary>
    public PlaceholderIdentity? Identity { get; init; }

    /// <summary>cfapi in-sync state. A placeholder modified locally loses in-sync.</summary>
    public bool InSync { get; init; } = true;

    public long Length { get; init; }

    public DateTimeOffset LastWriteTimeUtc { get; init; }

    /// <summary>"Always keep on this device" (FILE_ATTRIBUTE_PINNED).</summary>
    public bool IsPinned { get; init; }

    /// <summary>"Free up space" (FILE_ATTRIBUTE_UNPINNED).</summary>
    public bool IsUnpinned { get; init; }

    /// <summary>All data is local (no FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS / OFFLINE).</summary>
    public bool IsFullyHydrated { get; init; }

    /// <summary>FILE_ATTRIBUTE_HIDDEN or FILE_ATTRIBUTE_SYSTEM (editor lock/backup files, shell metadata): never uploaded.</summary>
    public bool IsHiddenOrSystem { get; init; }

    public string? FileId => Identity?.FileId;
}
