using DriveSync.Core.Names;

namespace DriveSync.Core.Model;

public static class DriveMimeTypes
{
    public const string Folder = "application/vnd.google-apps.folder";
    public const string Shortcut = "application/vnd.google-apps.shortcut";
    public const string WorkspacePrefix = "application/vnd.google-apps.";

    /// <summary>Workspace docs (Docs/Sheets/…) and shortcuts are hidden in v1; folders are not.</summary>
    public static bool IsHiddenMimeType(string? mimeType) =>
        mimeType is not null
        && mimeType.StartsWith(WorkspacePrefix, StringComparison.Ordinal)
        && !string.Equals(mimeType, Folder, StringComparison.Ordinal);
}

/// <summary>A Drive file or folder, reduced to the fields the contract requests (DriveFields.File).</summary>
public sealed record DriveItem : INamedItem
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string MimeType { get; init; }
    public long? Size { get; init; }
    public DateTimeOffset CreatedTime { get; init; }
    public DateTimeOffset ModifiedTime { get; init; }
    public string? Md5Checksum { get; init; }
    public IReadOnlyList<string> Parents { get; init; } = Array.Empty<string>();
    public bool Trashed { get; init; }
    public bool CanDownload { get; init; } = true;
    public string? LastModifyingUserName { get; init; }
    public string? ThumbnailLink { get; init; }
    public long? VideoDurationMillis { get; init; }
    public int? Width { get; init; }
    public int? Height { get; init; }

    public bool IsFolder => string.Equals(MimeType, DriveMimeTypes.Folder, StringComparison.Ordinal);
    public bool IsHidden => DisplayNames.IsHidden(this);
    public string? ParentId => Parents.Count > 0 ? Parents[0] : null;
}

public enum RootKind
{
    SharedDrive,
    Folder,
}

/// <summary>The resolved sync root. For a shared drive, <see cref="Id"/> == <see cref="DriveId"/>.</summary>
public sealed record DriveRoot(string Id, string Name, string? DriveId, RootKind Kind);

public abstract record DriveChange
{
    public sealed record Upsert(DriveItem Item) : DriveChange;
    public sealed record Removed(string FileId) : DriveChange;
}

public sealed record ChangeBatch(IReadOnlyList<DriveChange> Changes, string? NextPageToken, string? NewStartPageToken);
