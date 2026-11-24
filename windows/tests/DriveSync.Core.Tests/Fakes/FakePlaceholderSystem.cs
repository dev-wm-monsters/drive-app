using DriveSync.Core.Model;
using DriveSync.Core.Sync;

namespace DriveSync.Core.Tests.Fakes;

/// <summary>In-memory model of a cfapi sync root: applies actions like the Windows implementation would.</summary>
internal sealed class FakePlaceholderSystem : IPlaceholderSystem
{
    public Dictionary<string, LocalEntry> Entries { get; } = new(SyncPath.Comparer);

    public Dictionary<string, byte[]> Contents { get; } = new(SyncPath.Comparer);

    public List<string> Log { get; } = new();

    public HashSet<string> Busy { get; } = new(SyncPath.Comparer);

    public IReadOnlyList<LocalEntry> Scan() => Entries.Values.ToList();

    public void AddUserFile(string path, byte[] content, DateTimeOffset lastWrite)
    {
        Entries[path] = new LocalEntry { Path = path, Length = content.Length, LastWriteTimeUtc = lastWrite };
        Contents[path] = content;
    }

    public void AddUserFolder(string path) => Entries[path] = new LocalEntry { Path = path, IsDirectory = true };

    public void CreatePlaceholder(string parentPath, string name, DriveItem item)
    {
        var path = SyncPath.Combine(parentPath, name);
        if (Entries.ContainsKey(path))
        {
            throw new IOException("exists: " + path);
        }

        if (parentPath.Length > 0 && !Entries.TryGetValue(parentPath, out _))
        {
            throw new IOException("no parent: " + parentPath);
        }

        Entries[path] = new LocalEntry
        {
            Path = path,
            IsDirectory = item.IsFolder,
            IsPlaceholder = true,
            Identity = PlaceholderIdentity.From(item),
            Length = item.Size ?? 0,
        };
        Log.Add("create " + path);
    }

    public void MovePlaceholder(string fromPath, string toPath)
    {
        if (!SyncPath.SameIgnoringCase(fromPath, toPath) && Entries.ContainsKey(toPath))
        {
            throw new IOException("target exists: " + toPath);
        }

        var moving = Entries.Values.Where(e => SyncPath.SameIgnoringCase(e.Path, fromPath) || SyncPath.IsUnder(e.Path, fromPath)).ToList();
        foreach (var e in moving)
        {
            Entries.Remove(e.Path);
        }

        foreach (var e in moving)
        {
            var newPath = toPath + e.Path[fromPath.Length..];
            Entries[newPath] = e with { Path = newPath };
        }

        Log.Add("move " + fromPath + " -> " + toPath);
    }

    public void UpdatePlaceholder(string path, DriveItem item, bool contentChanged, bool discardLocalChanges)
    {
        var e = Entries[path];
        Entries[path] = e with
        {
            Identity = PlaceholderIdentity.From(item),
            InSync = true,
            Length = item.Size ?? 0,
            IsFullyHydrated = !contentChanged && !discardLocalChanges && e.IsFullyHydrated,
        };
        Log.Add($"update {path}{(contentChanged ? " content" : string.Empty)}{(discardLocalChanges ? " discard" : string.Empty)}");
    }

    public void DeletePlaceholder(string path)
    {
        foreach (var e in Entries.Values.Where(e => SyncPath.SameIgnoringCase(e.Path, path) || SyncPath.IsUnder(e.Path, path)).ToList())
        {
            Entries.Remove(e.Path);
        }

        Log.Add("delete " + path);
    }

    public Stream OpenForUpload(string path)
    {
        if (Busy.Contains(path))
        {
            throw new IOException("in use");
        }

        return new MemoryStream(Contents[path], writable: false);
    }

    public void ConvertToPlaceholder(string path, DriveItem item)
    {
        var e = Entries[path];
        Entries[path] = e with { IsPlaceholder = true, Identity = PlaceholderIdentity.From(item), InSync = true, IsFullyHydrated = true };
        Log.Add("convert " + path);
    }

    public void Hydrate(string path) => Log.Add("hydrate " + path);

    public void Dehydrate(string path) => Log.Add("dehydrate " + path);
}
