using DriveSync.Core.Model;
using DriveSync.Core.Sync;
using DriveSync.Windows.Interop;
using DriveSync.Windows.Storage;
using Microsoft.Extensions.Logging;
using Windows.Win32;
using Windows.Win32.Storage.CloudFilters;

namespace DriveSync.Windows.CloudFiles;

/// <summary>
/// <see cref="IPlaceholderSystem"/> on the Cloud Files API. Files are created dehydrated, in-sync and READ-ONLY
/// (FILE_ATTRIBUTE_READONLY); folders are created fully populated (population policy ALWAYS_FULL: no
/// FETCH_PLACEHOLDERS callbacks). Our own renames/deletes are allowed by the NOTIFY_* callbacks because they come
/// from this process.
/// </summary>
public sealed class CloudFilesPlaceholderSystem : IPlaceholderSystem
{
    private readonly string _root;
    private readonly ILogger _logger;

    public CloudFilesPlaceholderSystem(string syncRootPath, ILogger logger)
    {
        _root = syncRootPath;
        _logger = logger;
    }

    private string Full(string relative) => AppPaths.Full(_root, relative);

    public IReadOnlyList<LocalEntry> Scan()
    {
        var result = new List<LocalEntry>();
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            AttributesToSkip = 0,
            IgnoreInaccessible = true,
            ReturnSpecialDirectories = false,
        };
        foreach (var info in new DirectoryInfo(_root).EnumerateFileSystemInfos("*", options))
        {
            var relative = Path.GetRelativePath(_root, info.FullName).Replace('\\', '/');
            var attributes = info.Attributes;
            var isDirectory = attributes.HasFlag(FileAttributes.Directory);
            PlaceholderIdentity? identity = null;
            var isPlaceholder = false;
            var inSync = true;
            try
            {
                using var handle = CfInterop.Open(info.FullName, write: false, exclusive: false);
                if (CfInterop.TryGetPlaceholderInfo(handle, out var state, out var blob))
                {
                    isPlaceholder = true;
                    inSync = state == CF_IN_SYNC_STATE.CF_IN_SYNC_STATE_IN_SYNC;
                    identity = PlaceholderIdentity.TryDecode(blob);
                }
            }
            catch (IOException ex)
            {
                // Vanished or locked between enumeration and open: skip this round.
                _logger.LogDebug("Scan skipped an item: {Error}", ex.Message);
                continue;
            }

            result.Add(new LocalEntry
            {
                Path = relative,
                IsDirectory = isDirectory,
                IsPlaceholder = isPlaceholder,
                Identity = identity,
                InSync = inSync,
                Length = info is FileInfo f ? f.Length : 0,
                LastWriteTimeUtc = info.LastWriteTimeUtc,
                IsPinned = attributes.HasFlag(CfInterop.Pinned),
                IsUnpinned = attributes.HasFlag(CfInterop.Unpinned),
                IsFullyHydrated = !attributes.HasFlag(CfInterop.RecallOnDataAccess) && !attributes.HasFlag(FileAttributes.Offline),
            });
        }

        return result;
    }

    public unsafe void CreatePlaceholder(string parentPath, string name, DriveItem item)
    {
        var identity = PlaceholderIdentity.From(item).Encode();
        var flags = CF_PLACEHOLDER_CREATE_FLAGS.CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC;
        if (item.IsFolder)
        {
            flags |= CF_PLACEHOLDER_CREATE_FLAGS.CF_PLACEHOLDER_CREATE_FLAG_DISABLE_ON_DEMAND_POPULATION;
        }

        fixed (char* fileName = name)
        fixed (byte* id = identity)
        {
            var info = new CF_PLACEHOLDER_CREATE_INFO
            {
                RelativeFileName = fileName,
                FsMetadata = CfInterop.Metadata(item, setAttributes: true),
                FileIdentity = id,
                FileIdentityLength = (uint)identity.Length,
                Flags = flags,
            };
            var hr = PInvoke.CfCreatePlaceholders(Full(parentPath), new ReadOnlySpan<CF_PLACEHOLDER_CREATE_INFO>(&info, 1), CF_CREATE_FLAGS.CF_CREATE_FLAG_NONE, out _);
            CfInterop.Check(hr, "CfCreatePlaceholders");
            CfInterop.Check(info.Result, "CfCreatePlaceholders(entry)");
        }

        _logger.LogDebug("Created placeholder {Path}", SyncPath.Combine(parentPath, name));
    }

    public void MovePlaceholder(string fromPath, string toPath)
    {
        var from = Full(fromPath);
        var to = Full(toPath);
        if (SyncPath.SameIgnoringCase(fromPath, toPath))
        {
            // Case-only rename: go through a temporary name so NTFS sees two distinct names.
            var temp = Full(SyncPath.Combine(SyncPath.Parent(fromPath), SyncPlanner.TempPrefix + Guid.NewGuid().ToString("N")));
            Move(from, temp);
            Move(temp, to);
        }
        else
        {
            Move(from, to);
        }

        _logger.LogDebug("Moved placeholder {From} -> {To}", fromPath, toPath);
    }

    public void UpdatePlaceholder(string path, DriveItem item, bool contentChanged, bool discardLocalChanges)
    {
        var full = Full(path);
        var dehydrate = !item.IsFolder && (contentChanged || discardLocalChanges);
        if (!item.IsFolder)
        {
            EnsureReadOnly(full);
        }

        {
            using var handle = CfInterop.Open(full, write: true, exclusive: dehydrate);
            if (discardLocalChanges)
            {
                // Dehydration requires in-sync; local bytes are intentionally discarded (existing items are read-only).
                CfInterop.Check(PInvoke.CfSetInSyncState(handle, CF_IN_SYNC_STATE.CF_IN_SYNC_STATE_IN_SYNC, CF_SET_IN_SYNC_FLAGS.CF_SET_IN_SYNC_FLAG_NONE), "CfSetInSyncState");
            }

            var flags = CF_UPDATE_FLAGS.CF_UPDATE_FLAG_MARK_IN_SYNC | (dehydrate ? CF_UPDATE_FLAGS.CF_UPDATE_FLAG_DEHYDRATE : 0);
            var hr = PInvoke.CfUpdatePlaceholder(handle, CfInterop.Metadata(item, setAttributes: false), PlaceholderIdentity.From(item).Encode(), default, flags);
            if (hr.Value is CfInterop.ErrorCloudFilePinned or CfInterop.ErrorCloudFileNotInSync && dehydrate)
            {
                handle.Dispose();
                Recreate(path, item);
                return;
            }

            CfInterop.Check(hr, "CfUpdatePlaceholder");
        }
    }

    public void DeletePlaceholder(string path)
    {
        var full = Full(path);
        if (Directory.Exists(full))
        {
            foreach (var file in Directory.EnumerateFiles(full, "*", SearchOption.AllDirectories))
            {
                ClearReadOnly(file);
            }

            Directory.Delete(full, recursive: true);
        }
        else if (File.Exists(full))
        {
            ClearReadOnly(full);
            File.Delete(full);
        }

        _logger.LogDebug("Deleted placeholder {Path}", path);
    }

    public Stream OpenForUpload(string path) =>
        // FileShare.Read: fails while any other process holds the file open for writing.
        new FileStream(Full(path), FileMode.Open, FileAccess.Read, FileShare.Read, bufferSize: 1 << 16, FileOptions.Asynchronous | FileOptions.SequentialScan);

    public void ConvertToPlaceholder(string path, DriveItem item)
    {
        var full = Full(path);
        var identity = PlaceholderIdentity.From(item).Encode();
        using (var handle = CfInterop.Open(full, write: true, exclusive: false))
        {
            // Keep the uploaded bytes (no dehydrate): the file is immediately "available on this device" and in sync.
            CfInterop.Check(PInvoke.CfConvertToPlaceholder(handle, identity, CF_CONVERT_FLAGS.CF_CONVERT_FLAG_MARK_IN_SYNC), "CfConvertToPlaceholder");
            CfInterop.Check(
                PInvoke.CfUpdatePlaceholder(handle, CfInterop.Metadata(item, setAttributes: false), identity, default, CF_UPDATE_FLAGS.CF_UPDATE_FLAG_MARK_IN_SYNC),
                "CfUpdatePlaceholder(after convert)");
        }

        EnsureReadOnly(full);
        _logger.LogDebug("Converted {Path} to a placeholder", path);
    }

    public void Hydrate(string path)
    {
        var full = Full(path);
        // CfHydratePlaceholder blocks until our own FETCH_DATA handler has delivered the data: run it off the sync thread.
        _ = Task.Run(() =>
        {
            try
            {
                using var handle = CfInterop.Open(full, write: false, exclusive: false);
                CfInterop.Check(PInvoke.CfHydratePlaceholder(handle, 0, -1, CF_HYDRATE_FLAGS.CF_HYDRATE_FLAG_NONE), "CfHydratePlaceholder");
            }
            catch (IOException ex)
            {
                _logger.LogWarning("Background hydration failed: {Error}", ex.Message);
            }
        });
    }

    public void Dehydrate(string path)
    {
        using var handle = CfInterop.Open(Full(path), write: true, exclusive: true);
        CfInterop.Check(PInvoke.CfDehydratePlaceholder(handle, 0, -1, CF_DEHYDRATE_FLAGS.CF_DEHYDRATE_FLAG_NONE), "CfDehydratePlaceholder");
    }

    /// <summary>Marks the sync root folder itself in sync (Explorer shows the green check on the root).</summary>
    public void MarkRootInSync()
    {
        try
        {
            using var handle = CfInterop.Open(_root, write: true, exclusive: false);
            _ = PInvoke.CfSetInSyncState(handle, CF_IN_SYNC_STATE.CF_IN_SYNC_STATE_IN_SYNC, CF_SET_IN_SYNC_FLAGS.CF_SET_IN_SYNC_FLAG_NONE);
        }
        catch (IOException ex)
        {
            _logger.LogDebug("Could not mark the root in sync: {Error}", ex.Message);
        }
    }

    private void Recreate(string path, DriveItem item)
    {
        _logger.LogInformation("Re-creating a placeholder that could not be dehydrated (pinned or modified)");
        DeletePlaceholder(path);
        CreatePlaceholder(SyncPath.Parent(path), SyncPath.Name(path), item);
    }

    private static void Move(string from, string to)
    {
        if (Directory.Exists(from))
        {
            Directory.Move(from, to);
        }
        else
        {
            File.Move(from, to);
        }
    }

    private static void EnsureReadOnly(string full)
    {
        var attributes = File.GetAttributes(full);
        if (!attributes.HasFlag(FileAttributes.ReadOnly))
        {
            File.SetAttributes(full, (attributes & CfInterop.Settable) | FileAttributes.ReadOnly);
        }
    }

    private static void ClearReadOnly(string full)
    {
        var attributes = File.GetAttributes(full);
        if (attributes.HasFlag(FileAttributes.ReadOnly))
        {
            var cleared = (attributes & CfInterop.Settable) & ~FileAttributes.ReadOnly;
            File.SetAttributes(full, cleared == 0 ? FileAttributes.Normal : cleared);
        }
    }
}
