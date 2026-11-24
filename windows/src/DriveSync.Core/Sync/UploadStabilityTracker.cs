namespace DriveSync.Core.Sync;

/// <summary>
/// A new local file is uploaded only after its size and last-write time stayed unchanged for <see cref="StableFor"/>
/// (copies in progress, apps still writing). The Windows layer additionally requires that no one has it open for write.
/// </summary>
public sealed class UploadStabilityTracker
{
    private readonly Dictionary<string, (long Length, DateTimeOffset LastWrite, DateTimeOffset FirstSeen)> _seen = new(SyncPath.Comparer);

    public UploadStabilityTracker(TimeSpan stableFor) => StableFor = stableFor;

    public TimeSpan StableFor { get; }

    public bool IsStable(LocalEntry entry, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (_seen.TryGetValue(entry.Path, out var s) && s.Length == entry.Length && s.LastWrite == entry.LastWriteTimeUtc)
        {
            return now - s.FirstSeen >= StableFor;
        }

        _seen[entry.Path] = (entry.Length, entry.LastWriteTimeUtc, now);
        return false;
    }

    public void Forget(string path) => _seen.Remove(path);

    /// <summary>Drops entries for paths that no longer exist.</summary>
    public void Retain(IEnumerable<string> existingPaths)
    {
        var keep = new HashSet<string>(existingPaths, SyncPath.Comparer);
        foreach (var path in _seen.Keys.Where(p => !keep.Contains(p)).ToList())
        {
            _seen.Remove(path);
        }
    }
}
