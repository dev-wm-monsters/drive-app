namespace DriveSync.Windows;

/// <summary>
/// FileSystemWatcher over the sync root, debounced: bursts of events (a copy in progress, our own placeholder updates)
/// collapse into one local reconcile pass. New files are uploaded only once stable (see UploadStabilityTracker), so
/// the watcher also re-arms itself while non-placeholder files are pending.
/// </summary>
public sealed class LocalChangeWatcher : IDisposable
{
    private readonly FileSystemWatcher _watcher;
    private readonly Timer _debounce;
    private readonly TimeSpan _delay;
    private readonly Action _onChanged;

    public LocalChangeWatcher(string root, Action onChanged, TimeSpan? delay = null)
    {
        _onChanged = onChanged;
        _delay = delay ?? TimeSpan.FromSeconds(2);
        _debounce = new Timer(_ => _onChanged(), null, Timeout.Infinite, Timeout.Infinite);
        _watcher = new FileSystemWatcher(root)
        {
            IncludeSubdirectories = true,
            InternalBufferSize = 64 * 1024,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.Size
                           | NotifyFilters.LastWrite | NotifyFilters.Attributes,
        };
        _watcher.Created += (_, _) => Poke();
        _watcher.Changed += (_, _) => Poke();
        _watcher.Renamed += (_, _) => Poke();
        _watcher.Deleted += (_, _) => Poke();
        _watcher.Error += (_, _) => Poke(); // buffer overflow: a full scan catches up
    }

    public void Start() => _watcher.EnableRaisingEvents = true;

    /// <summary>Schedules a pass after the debounce delay (restarting the delay on every call).</summary>
    public void Poke() => _debounce.Change(_delay, Timeout.InfiniteTimeSpan);

    public void Dispose()
    {
        _watcher.Dispose();
        _debounce.Dispose();
    }
}
