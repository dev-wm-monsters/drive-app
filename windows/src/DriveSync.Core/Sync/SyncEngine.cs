using DriveSync.Core.Drive;
using DriveSync.Core.Model;
using DriveSync.Core.Names;
using Microsoft.Extensions.Logging;

namespace DriveSync.Core.Sync;

public enum SyncState
{
    Starting,
    Idle,
    Syncing,
    Offline,
    NeedsLogin,
    Error,
}

public sealed record SyncStatus(SyncState State, string Message);

/// <summary>
/// Orchestrates one sync root: initial listing, 30 s change polling, reconcile (planner → placeholder actions),
/// and uploads of new local files (one at a time, outside the reconcile lock so long uploads don't stall polling).
/// Platform-neutral: all disk work goes through <see cref="IPlaceholderSystem"/>.
/// </summary>
public sealed class SyncEngine : IDisposable
{
    private readonly IDriveService _drive;
    private readonly IPlaceholderSystem _local;
    private readonly ILogger _logger;
    private readonly Func<DateTimeOffset> _clock;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private readonly SemaphoreSlim _uploadSlot = new(1, 1);
    private readonly UploadStabilityTracker _stability;
    private readonly HashSet<string> _uploadsInFlight = new(SyncPath.Comparer);
    private readonly HashSet<string> _reportedWarnings = new(StringComparer.Ordinal);
    private readonly List<Task> _uploadTasks = new();
    private readonly Dictionary<string, DriveItem> _uploadedNotConverted = new(SyncPath.Comparer);
    private string? _pageToken;

    public SyncEngine(IDriveService drive, IPlaceholderSystem local, ILogger logger, TimeSpan? uploadStableFor = null, Func<DateTimeOffset>? clock = null)
    {
        _drive = drive;
        _local = local;
        _logger = logger;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _stability = new UploadStabilityTracker(uploadStableFor ?? TimeSpan.FromSeconds(3));
    }

    public DriveRoot? Root { get; private set; }

    public RemoteTree? Tree { get; private set; }

    public SyncStatus Status { get; private set; } = new(SyncState.Starting, "Starting…");

    /// <summary>True when the last pass saw new local files that are not stable yet (the host re-checks soon).</summary>
    public bool HasFilesWaitingToSettle { get; private set; }

    public event EventHandler<SyncStatus>? StatusChanged;

    /// <summary>One-off messages for the user (balloon tips): skipped folders, failed uploads…</summary>
    public event EventHandler<string>? Notice;

    /// <summary>Raised after an upload became a placeholder (path is relative to the root).</summary>
    public event EventHandler<string>? Uploaded;

    /// <summary>Resolves the root, takes a change token, lists the whole tree and reconciles.</summary>
    public Task InitializeAsync(CancellationToken cancellationToken) =>
        RunExclusiveAsync(InitializeCoreAsync, cancellationToken);

    private async Task InitializeCoreAsync(CancellationToken ct)
    {
        SetStatus(SyncState.Syncing, "Listing Drive…");
        var root = await _drive.ResolveRootAsync(ct).ConfigureAwait(false);
        // Take the token BEFORE listing so changes made during the listing are replayed, not lost.
        var pageToken = await _drive.GetStartPageTokenAsync(root, ct).ConfigureAwait(false);
        Root = root;
        Tree = new RemoteTree(root);
        await ListMissingFoldersAsync(ct).ConfigureAwait(false);
        _pageToken = pageToken;
        await ReconcileCoreAsync(ct).ConfigureAwait(false);
    }

    /// <summary>Fetches Drive changes since the last token, then reconciles. Called every 30 s and by "Sync now".</summary>
    public async Task PollAsync(CancellationToken cancellationToken)
    {
        await RunExclusiveAsync(async ct =>
        {
            if (Tree is null || Root is null || _pageToken is null)
            {
                // The initial listing failed (offline at startup): retry it instead of polling.
                await InitializeCoreAsync(ct).ConfigureAwait(false);
                return;
            }

            var token = _pageToken;
            while (true)
            {
                var batch = await _drive.GetChangesAsync(token, Root, ct).ConfigureAwait(false);
                Tree.ApplyChanges(batch.Changes);
                if (batch.NewStartPageToken is not null)
                {
                    token = batch.NewStartPageToken;
                    break;
                }

                token = batch.NextPageToken ?? throw new DriveException(DriveErrorKind.InvalidResponse, "changes.list returned neither nextPageToken nor newStartPageToken.");
            }

            await ListMissingFoldersAsync(ct).ConfigureAwait(false);
            _pageToken = token;
            await ReconcileCoreAsync(ct).ConfigureAwait(false);
        }, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Local-only pass (after file-system events): new files, in-place edits, pin changes.</summary>
    public Task ReconcileAsync(CancellationToken cancellationToken) =>
        RunExclusiveAsync(ReconcileCoreAsync, cancellationToken);

    /// <summary>Waits for queued uploads (tests and orderly shutdown).</summary>
    public Task WhenUploadsIdleAsync()
    {
        lock (_uploadTasks)
        {
            return Task.WhenAll(_uploadTasks.ToArray());
        }
    }

    public void Dispose()
    {
        _lock.Dispose();
        _uploadSlot.Dispose();
    }

    private async Task RunExclusiveAsync(Func<CancellationToken, Task> body, CancellationToken ct)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await body(ct).ConfigureAwait(false);
            SetStatus(SyncState.Idle, "Up to date");
        }
        catch (DriveException ex) when (ex.Kind == DriveErrorKind.NeedsLogin)
        {
            SetStatus(SyncState.NeedsLogin, "Sign in again to keep syncing");
            throw;
        }
        catch (DriveException ex) when (ex.Kind is DriveErrorKind.Network or DriveErrorKind.Server or DriveErrorKind.RateLimited)
        {
            SetStatus(SyncState.Offline, "Can't reach Google Drive; will retry");
            _logger.LogWarning("Sync pass failed: {Kind}", ex.Kind);
        }
        finally
        {
            _lock.Release();
        }
    }

    private async Task ListMissingFoldersAsync(CancellationToken ct)
    {
        var tree = Tree!;
        while (tree.FoldersNeedingListing() is { Count: > 0 } missing)
        {
            foreach (var folderId in missing)
            {
                var children = await _drive.ListChildrenAsync(folderId, tree.Root, ct).ConfigureAwait(false);
                tree.AddListing(folderId, children);
            }
        }
    }

    private Task ReconcileCoreAsync(CancellationToken ct)
    {
        if (Tree is null)
        {
            return Task.CompletedTask;
        }

        var local = _local.Scan();
        _stability.Retain(local.Where(e => !e.IsPlaceholder).Select(e => e.Path));
        var now = _clock();
        HashSet<string> inFlight;
        lock (_uploadsInFlight)
        {
            inFlight = new HashSet<string>(_uploadsInFlight, SyncPath.Comparer);
        }

        var waiting = false;
        var plan = SyncPlanner.Plan(Tree, local, e =>
        {
            if (inFlight.Contains(e.Path))
            {
                return false;
            }

            var stable = _stability.IsStable(e, now);
            waiting |= !stable;
            return stable;
        });
        HasFilesWaitingToSettle = waiting;
        foreach (var warning in plan.Warnings)
        {
            if (_reportedWarnings.Add(warning))
            {
                Notice?.Invoke(this, warning);
            }
        }

        foreach (var action in plan.Actions)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                Execute(action, local);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                // Typical: file in use. The next pass retries; never abort the whole plan for one item.
                // IO messages carry file paths: names only at debug level (contract).
                _logger.LogWarning("Action {Action} failed: {Error} (0x{HResult:X8})", action.GetType().Name, ex.GetType().Name, ex.HResult);
                _logger.LogDebug("Action {Action} failed: {Message}", action.GetType().Name, ex.Message);
            }
        }

        return Task.CompletedTask;
    }

    private void Execute(SyncAction action, IReadOnlyList<LocalEntry> local)
    {
        switch (action)
        {
            case SyncAction.DeletePlaceholder a:
                // A placeholder the user edited in place (not in sync) keeps its bytes somewhere before it goes.
                PreserveModified(local.Where(e => SyncPath.SameIgnoringCase(e.Path, a.Path) || SyncPath.IsUnder(e.Path, a.Path)));
                _local.DeletePlaceholder(a.Path);
                break;
            case SyncAction.MovePlaceholder a:
                _local.MovePlaceholder(a.FromPath, a.ToPath);
                break;
            case SyncAction.CreatePlaceholder a:
                _local.CreatePlaceholder(a.ParentPath, a.Name, a.Item);
                break;
            case SyncAction.UpdatePlaceholder a:
                if (a.DiscardLocalChanges)
                {
                    // Throws (and skips the update) when the edited bytes cannot be saved: never discard them silently.
                    PreserveModified(local.Where(e => SyncPath.SameIgnoringCase(e.Path, a.Path)));
                }

                _local.UpdatePlaceholder(a.Path, a.Item, a.ContentChanged, a.DiscardLocalChanges);
                break;
            case SyncAction.Hydrate a:
                _local.Hydrate(a.Path);
                break;
            case SyncAction.Dehydrate a:
                _local.Dehydrate(a.Path);
                break;
            case SyncAction.Upload a:
                QueueUpload(a);
                break;
        }
    }

    private void PreserveModified(IEnumerable<LocalEntry> entries)
    {
        foreach (var entry in entries.Where(e => e.IsPlaceholder && !e.IsDirectory && !e.InSync).ToList())
        {
            if (_local.PreserveLocalChanges(entry) is { } savedTo)
            {
                Notice?.Invoke(this, $"'{SyncPath.Name(entry.Path)}' is read-only in Drive, so the Drive version was restored. Your edited copy was saved to {savedTo}.");
            }
        }
    }

    private void QueueUpload(SyncAction.Upload action)
    {
        lock (_uploadsInFlight)
        {
            if (!_uploadsInFlight.Add(action.LocalPath))
            {
                return;
            }
        }

        var task = Task.Run(async () =>
        {
            try
            {
                await UploadOneAsync(action, CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is DriveException or IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                _logger.LogWarning("Upload failed: {Error} (0x{HResult:X8})", ex is DriveException d ? d.Kind.ToString() : ex.GetType().Name, ex.HResult);
                _logger.LogDebug("Upload failed: {Message}", ex.Message);
                if (ex is DriveException { Kind: DriveErrorKind.QuotaExceeded or DriveErrorKind.Forbidden })
                {
                    Notice?.Invoke(this, $"Could not upload '{SyncPath.Name(action.LocalPath)}': {ex.Message}");
                }
            }
            finally
            {
                lock (_uploadsInFlight)
                {
                    _uploadsInFlight.Remove(action.LocalPath);
                }
            }
        });
        lock (_uploadTasks)
        {
            _uploadTasks.RemoveAll(t => t.IsCompleted);
            _uploadTasks.Add(task);
        }
    }

    private async Task UploadOneAsync(SyncAction.Upload action, CancellationToken ct)
    {
        await _uploadSlot.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var root = Root!;
            var localName = SyncPath.Name(action.LocalPath);
            // Re-list right before uploading so the free name accounts for uploads from phones since the last poll.
            var siblings = await _drive.ListChildrenAsync(action.ParentId, root, ct).ConfigureAwait(false);

            DriveItem uploaded;
            // The stream (FileShare.Read) stays open until the file is converted, so nobody can change the bytes
            // between the upload and the conversion that marks them as the in-sync Drive version.
            var stream = _local.OpenForUpload(action.LocalPath);
            await using (stream.ConfigureAwait(false))
            {
                var length = stream.CanSeek ? stream.Length : -1;
                var md5 = await Hashing.Md5HexAsync(stream, ct).ConfigureAwait(false);
                // Crash between upload and convert leaves a plain local file; adopt the identical Drive copy instead
                // of uploading a duplicate.
                var existing = siblings.FirstOrDefault(s =>
                    !s.IsFolder && s.Size == length && string.Equals(s.Md5Checksum, md5, StringComparison.OrdinalIgnoreCase)
                    && string.Equals(DisplayNames.Key(s.Name), DisplayNames.Key(localName), StringComparison.Ordinal));
                DriveItem? previous;
                lock (_uploadedNotConverted)
                {
                    _uploadedNotConverted.TryGetValue(action.LocalPath, out previous);
                }

                if (previous is not null && previous.Size == length
                    && string.Equals(previous.Md5Checksum, md5, StringComparison.OrdinalIgnoreCase))
                {
                    uploaded = previous; // uploaded earlier, conversion failed (file was busy): just retry the conversion
                }
                else if (existing is not null)
                {
                    uploaded = existing;
                }
                else
                {
                    stream.Position = 0;
                    var name = DisplayNames.UniqueUploadName(localName, siblings.Select(s => s.Name));
                    uploaded = await _drive.UploadAsync(stream, name, action.ParentId, null, ct).ConfigureAwait(false);
                    _logger.LogInformation("Uploaded a new file ({Bytes} bytes)", length);
                }

                lock (_uploadedNotConverted)
                {
                    _uploadedNotConverted[action.LocalPath] = uploaded;
                }

                await _lock.WaitAsync(ct).ConfigureAwait(false);
                try
                {
                    Tree!.AddListing(action.ParentId, siblings.Where(s => s.Id != uploaded.Id).Append(uploaded));
                    // Convert in place (keeps the bytes local, no re-download); the next plan renames it if its
                    // display name differs from the local name.
                    _local.ConvertToPlaceholder(action.LocalPath, uploaded);
                    lock (_uploadedNotConverted)
                    {
                        _uploadedNotConverted.Remove(action.LocalPath);
                    }

                    _stability.Forget(action.LocalPath);
                }
                finally
                {
                    _lock.Release();
                }
            }

            // Reconcile after the stream is closed: the follow-up rename of the converted file needs DELETE access.
            await RunExclusiveAsync(ReconcileCoreAsync, ct).ConfigureAwait(false);

            Uploaded?.Invoke(this, action.LocalPath);
        }
        finally
        {
            _uploadSlot.Release();
        }
    }

    private void SetStatus(SyncState state, string message)
    {
        if (Status.State == state && Status.Message == message)
        {
            return;
        }

        Status = new SyncStatus(state, message);
        StatusChanged?.Invoke(this, Status);
    }
}
