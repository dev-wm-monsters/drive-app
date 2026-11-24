using DriveSync.Core.Model;

namespace DriveSync.Core.Drive;

/// <summary>The Drive operations the sync engine needs. <see cref="GoogleDriveService"/> is the real implementation.</summary>
public interface IDriveService
{
    /// <summary>Shared drive by name (drives.list), or the configured folder/drive ID.</summary>
    Task<DriveRoot> ResolveRootAsync(CancellationToken cancellationToken);

    /// <summary>All pages of non-trashed children; hidden items (Workspace docs, shortcuts) are excluded.</summary>
    Task<IReadOnlyList<DriveItem>> ListChildrenAsync(string folderId, DriveRoot root, CancellationToken cancellationToken);

    Task<DriveItem> GetFileAsync(string fileId, CancellationToken cancellationToken);

    /// <summary>Streams bytes [offset, offset+length) of the file content (alt=media with an HTTP Range header).</summary>
    Task<Stream> OpenRangeAsync(string fileId, long offset, long length, CancellationToken cancellationToken);

    Task<string> GetStartPageTokenAsync(DriveRoot root, CancellationToken cancellationToken);

    /// <summary>One page of changes. Follow <see cref="ChangeBatch.NextPageToken"/> until <see cref="ChangeBatch.NewStartPageToken"/> is set.</summary>
    Task<ChangeBatch> GetChangesAsync(string pageToken, DriveRoot root, CancellationToken cancellationToken);

    /// <summary>Resumable upload (8 MiB chunks) of a NEW file. The caller picks a free name first (DisplayNames.UniqueUploadName).</summary>
    Task<DriveItem> UploadAsync(Stream content, string name, string parentId, IProgress<long>? progress, CancellationToken cancellationToken);

    Task<string?> GetUserEmailAsync(CancellationToken cancellationToken);
}
