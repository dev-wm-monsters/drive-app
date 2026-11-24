using System.Collections.Concurrent;
using DriveSync.Core.Model;
using DriveSync.Core.Names;
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
    private readonly string _preserveRoot;
    private readonly ILogger _logger;
    private readonly ConcurrentDictionary<string, byte> _hydrating = new(StringComparer.OrdinalIgnoreCase);

    /// <param name="preserveRoot">Folder (outside the sync root) that receives local edits of read-only items.</param>
    public CloudFilesPlaceholderSystem(string syncRootPath, string preserveRoot, ILogger logger)
    {
        _root = syncRootPath;
        _preserveRoot = preserveRoot;
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
                IsHiddenOrSystem = (attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0,
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
            // Pinned files cannot be dehydrated: re-create them. NOT_IN_SYNC is NOT handled that way: it means the
            // file was edited after the scan, and those bytes must first be preserved by the next pass.
            if (hr.Value == CfInterop.ErrorCloudFilePinned && dehydrate)
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
            // Never a blind recursive delete: a user file dropped in after the scan must survive.
            var kept = DeletePlaceholderTree(full, IsPlaceholderFile);
            if (kept > 0)
            {
                throw new IOException($"Kept a removed folder: it holds {kept} local item(s) that are not on Drive.");
            }
        }
        else if (File.Exists(full))
        {
            ClearReadOnly(full);
            File.Delete(full);
        }

        _logger.LogDebug("Deleted placeholder {Path}", path);
    }

    /// <summary>
    /// Deletes the files under <paramref name="directory"/> that <paramref name="isOurs"/> accepts, then every folder
    /// left empty (deepest first, <paramref name="directory"/> last). Returns how many other files were kept.
    /// </summary>
    internal static int DeletePlaceholderTree(string directory, Func<string, bool> isOurs)
    {
        var options = new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = false };
        var kept = 0;
        foreach (var file in Directory.EnumerateFiles(directory, "*", options).ToList())
        {
            if (isOurs(file))
            {
                ClearReadOnly(file);
                File.Delete(file);
            }
            else
            {
                kept++;
            }
        }

        var folders = Directory.EnumerateDirectories(directory, "*", options).Append(directory)
            .OrderByDescending(d => d.Length).ToList();
        foreach (var folder in folders)
        {
            if (!Directory.EnumerateFileSystemEntries(folder, "*", new EnumerationOptions { AttributesToSkip = 0 }).Any())
            {
                Directory.Delete(folder, recursive: false);
            }
        }

        return kept;
    }

    /// <summary>True for a cfapi placeholder file; false for user files and anything that cannot be inspected.</summary>
    internal static bool IsPlaceholderFile(string fullPath)
    {
        try
        {
            using var handle = CfInterop.Open(fullPath, write: false, exclusive: false);
            return CfInterop.TryGetPlaceholderInfo(handle, out _, out _);
        }
        catch (IOException)
        {
            return false;
        }
    }

    public string? PreserveLocalChanges(LocalEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.IsDirectory || !entry.IsFullyHydrated)
        {
            // Not (fully) local: only cached Drive ranges, nothing the user wrote. (Writes hydrate the whole file.)
            return null;
        }

        // FileShare.Read: fails while an app still has the file open for writing; the caller retries later.
        using var source = new FileStream(Full(entry.Path), FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.SequentialScan);
#pragma warning disable CA5351 // compared with Drive's md5Checksum (integrity, not security)
        var md5 = Convert.ToHexString(System.Security.Cryptography.MD5.HashData(source)).ToLowerInvariant();
#pragma warning restore CA5351
        if (entry.Identity is { Md5: { } driveMd5 } && string.Equals(md5, driveMd5, StringComparison.OrdinalIgnoreCase))
        {
            return null; // same bytes as Drive (e.g. only the read-only attribute was toggled)
        }

        var (stem, ext) = DisplayNames.Split(SyncPath.Name(entry.Path));
        var folder = AppPaths.Full(_preserveRoot, SyncPath.Parent(entry.Path));
        var target = Path.Combine(folder, $"{stem} (edited {md5[..8]}){ext}");
        if (!File.Exists(target))
        {
            Directory.CreateDirectory(folder);
            var partial = target + ".partial";
            source.Position = 0;
            using (var copy = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                source.CopyTo(copy);
                copy.Flush(flushToDisk: true);
            }

            File.Move(partial, target, overwrite: true);
            _logger.LogInformation("Saved local edits of a read-only item before restoring the Drive version");
        }

        return target;
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
        // Hydration progress raises file-system events and so new reconcile passes: start one hydration per file only.
        if (!_hydrating.TryAdd(full, 0))
        {
            return;
        }

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
            finally
            {
                _hydrating.TryRemove(full, out _);
            }
        });
    }

    public void Dehydrate(string path)
    {
        using var handle = CfInterop.Open(Full(path), write: true, exclusive: true);
        CfInterop.Check(PInvoke.CfDehydratePlaceholder(handle, 0, -1, CF_DEHYDRATE_FLAGS.CF_DEHYDRATE_FLAG_NONE), "CfDehydratePlaceholder");
    }

    /// <summary>
    /// Clears the in-sync state of a placeholder whose downloaded bytes failed the md5 check, so the next reconcile
    /// pass dehydrates it (the corrupt ranges must not be served from the local cache). Best effort.
    /// </summary>
    public void MarkNotInSync(string fullPath)
    {
        try
        {
            using var handle = CfInterop.Open(fullPath, write: true, exclusive: false);
            CfInterop.Check(PInvoke.CfSetInSyncState(handle, CF_IN_SYNC_STATE.CF_IN_SYNC_STATE_NOT_IN_SYNC, CF_SET_IN_SYNC_FLAGS.CF_SET_IN_SYNC_FLAG_NONE), "CfSetInSyncState");
        }
        catch (IOException ex)
        {
            _logger.LogWarning("Could not mark a corrupt download for re-download: {Error}", ex.Message);
        }
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
        _logger.LogInformation("Re-creating a placeholder that could not be dehydrated (pinned)");
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
