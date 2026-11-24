using DriveSync.Core.Model;
using DriveSync.Core.Names;

namespace DriveSync.Core.Sync;

/// <summary>
/// Pure diff of the remote layout (<see cref="RemoteTree.BuildLayout"/>) against what is on disk, producing ordered
/// <see cref="SyncAction"/>s. It simulates every action on a copy of the local view so later decisions see the effect
/// of earlier ones (folder moves carry descendants, a slot freed by a rename can be reused, swaps go via a temp name).
/// Product rules: remote is authoritative for existing items (read-only locally); only NEW local files are uploaded;
/// new local folders are not uploaded in v1.
/// </summary>
public static class SyncPlanner
{
    /// <summary>Prefix for temporary names used while two placeholders swap places.</summary>
    public const string TempPrefix = "~wm-move-";

    public static SyncPlan Plan(RemoteTree remote, IEnumerable<LocalEntry> local, Func<LocalEntry, bool>? isReadyForUpload = null)
    {
        ArgumentNullException.ThrowIfNull(remote);
        ArgumentNullException.ThrowIfNull(local);
        isReadyForUpload ??= _ => true;

        var layout = remote.BuildLayout();
        var desiredById = layout.ToDictionary(e => e.Id, StringComparer.Ordinal);
        var view = new View(local);
        var actions = new List<SyncAction>();
        var warnings = new List<string>();
        var deferred = 0;

        // 1. Placeholders whose Drive item is gone (or changed kind, or duplicated identity) are deleted, shallowest
        //    first. A folder that still holds not-yet-uploaded user files is kept; only its placeholders go.
        var seenIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in view.All.OrderBy(e => SyncPath.Depth(e.Path)).ThenBy(e => e.Path, StringComparer.Ordinal).ToList())
        {
            if (!view.Contains(entry.Path) || !entry.IsPlaceholder)
            {
                continue;
            }

            var keep = entry.Identity is { } id
                       && desiredById.TryGetValue(id.FileId, out var desired)
                       && desired.Item.IsFolder == entry.IsDirectory
                       && seenIds.Add(id.FileId);
            if (keep)
            {
                continue;
            }

            if (entry.IsDirectory && view.Descendants(entry.Path).Any(d => !d.IsPlaceholder))
            {
                foreach (var d in view.Descendants(entry.Path).Where(d => d.IsPlaceholder && !d.IsDirectory)
                             .OrderByDescending(d => SyncPath.Depth(d.Path)).ToList())
                {
                    actions.Add(new SyncAction.DeletePlaceholder(d.Path, d.FileId));
                    view.Remove(d.Path);
                }

                warnings.Add($"'{entry.Path}' was removed from Drive but contains files that were not uploaded; it was kept.");
                continue;
            }

            actions.Add(new SyncAction.DeletePlaceholder(entry.Path, entry.FileId));
            view.RemoveTree(entry.Path);
        }

        // 2. Walk the remote layout parents-first: move/rename, update, create.
        foreach (var d in layout)
        {
            var parentOk = d.ParentPath.Length == 0
                           || (view.TryGet(d.ParentPath, out var parent) && parent.IsDirectory && parent.FileId == d.ParentId);
            if (!parentOk)
            {
                deferred++;
                continue;
            }

            if (view.PathOf(d.Id) is { } current)
            {
                if (!string.Equals(current, d.Path, StringComparison.Ordinal))
                {
                    if (!SyncPath.SameIgnoringCase(current, d.Path) && view.TryGet(d.Path, out var occupant))
                    {
                        if (!occupant.IsPlaceholder)
                        {
                            deferred++;
                            warnings.Add($"'{d.Path}' is taken by a local item that is not on Drive yet.");
                            continue;
                        }

                        MoveAside(occupant, view, actions);
                    }

                    actions.Add(new SyncAction.MovePlaceholder(current, d.Path, d.Id));
                    view.Move(current, d.Path);
                }

                var entry = view.Get(d.Path);
                var wanted = PlaceholderIdentity.From(d.Item);
                var localModified = !entry.IsDirectory && !entry.InSync;
                if (entry.Identity != wanted || localModified)
                {
                    var contentChanged = entry.Identity is { } have && have.ContentDiffers(d.Item);
                    actions.Add(new SyncAction.UpdatePlaceholder(d.Path, d.Item, contentChanged, localModified));
                    view.Set(entry with { Identity = wanted, InSync = true });
                }
                else if (!entry.IsDirectory && entry.IsPinned && !entry.IsFullyHydrated)
                {
                    actions.Add(new SyncAction.Hydrate(d.Path));
                }
                else if (!entry.IsDirectory && entry.IsUnpinned && entry.IsFullyHydrated)
                {
                    actions.Add(new SyncAction.Dehydrate(d.Path));
                }

                continue;
            }

            if (view.TryGet(d.Path, out var blocker))
            {
                if (!blocker.IsPlaceholder)
                {
                    deferred++;
                    warnings.Add($"'{d.Path}' is taken by a local item that is not on Drive yet.");
                    continue;
                }

                MoveAside(blocker, view, actions);
            }

            actions.Add(new SyncAction.CreatePlaceholder(d.ParentPath, d.Name, d.Item));
            view.Set(new LocalEntry
            {
                Path = d.Path,
                IsDirectory = d.Item.IsFolder,
                IsPlaceholder = true,
                Identity = PlaceholderIdentity.From(d.Item),
                InSync = true,
            });
        }

        // 3. New local files inside synced folders → upload. New local folders are not supported in v1.
        foreach (var entry in view.All.Where(e => !e.IsPlaceholder).OrderBy(e => e.Path, StringComparer.Ordinal).ToList())
        {
            var parentPath = SyncPath.Parent(entry.Path);
            string? parentId;
            if (parentPath.Length == 0)
            {
                parentId = remote.RootId;
            }
            else
            {
                parentId = view.TryGet(parentPath, out var p) && p.IsDirectory && p.IsPlaceholder ? p.FileId : null;
            }

            if (parentId is null)
            {
                continue; // inside a user-created folder: reported once for the folder below
            }

            if (entry.IsDirectory)
            {
                warnings.Add($"New folder '{entry.Path}' is not uploaded: only new files can be added in this version.");
                continue;
            }

            if (LocalFileFilter.IsIgnored(SyncPath.Name(entry.Path)) || !isReadyForUpload(entry))
            {
                continue;
            }

            var siblings = remote.ChildrenOf(parentId).Select(c => c.Name);
            actions.Add(new SyncAction.Upload(entry.Path, parentId, DisplayNames.UniqueUploadName(SyncPath.Name(entry.Path), siblings)));
        }

        return new SyncPlan(actions, warnings, deferred);
    }

    private static void MoveAside(LocalEntry occupant, View view, List<SyncAction> actions)
    {
        var temp = SyncPath.Combine(SyncPath.Parent(occupant.Path), TempPrefix + (occupant.FileId ?? Guid.NewGuid().ToString("N")));
        actions.Add(new SyncAction.MovePlaceholder(occupant.Path, temp, occupant.FileId ?? string.Empty));
        view.Move(occupant.Path, temp);
    }

    /// <summary>Mutable simulation of the local tree (case-insensitive paths, like NTFS).</summary>
    private sealed class View
    {
        private readonly Dictionary<string, LocalEntry> _byPath = new(SyncPath.Comparer);
        private readonly Dictionary<string, string> _pathById = new(StringComparer.Ordinal);

        public View(IEnumerable<LocalEntry> entries)
        {
            foreach (var e in entries)
            {
                _byPath[e.Path] = e;
            }

            // First placeholder (shallowest, then ordinal) wins an identity; duplicates get deleted by step 1.
            foreach (var e in _byPath.Values.OrderBy(e => SyncPath.Depth(e.Path)).ThenBy(e => e.Path, StringComparer.Ordinal))
            {
                if (e.FileId is { } id)
                {
                    _pathById.TryAdd(id, e.Path);
                }
            }
        }

        public IEnumerable<LocalEntry> All => _byPath.Values;

        public bool Contains(string path) => _byPath.ContainsKey(path);

        public bool TryGet(string path, out LocalEntry entry) => _byPath.TryGetValue(path, out entry!);

        public LocalEntry Get(string path) => _byPath[path];

        public string? PathOf(string id) => _pathById.TryGetValue(id, out var p) ? p : null;

        public IEnumerable<LocalEntry> Descendants(string path) => _byPath.Values.Where(e => SyncPath.IsUnder(e.Path, path));

        public void Set(LocalEntry entry)
        {
            _byPath[entry.Path] = entry;
            if (entry.FileId is { } id)
            {
                _pathById[id] = entry.Path;
            }
        }

        public void Remove(string path)
        {
            if (_byPath.Remove(path, out var e) && e.FileId is { } id && _pathById.TryGetValue(id, out var p) && SyncPath.SameIgnoringCase(p, path))
            {
                _pathById.Remove(id);
            }
        }

        public void RemoveTree(string path)
        {
            foreach (var d in Descendants(path).ToList())
            {
                Remove(d.Path);
            }

            Remove(path);
        }

        public void Move(string from, string to)
        {
            var moved = new List<LocalEntry>();
            foreach (var e in Descendants(from).Append(_byPath[from]).ToList())
            {
                _byPath.Remove(e.Path);
                var newPath = to + e.Path[from.Length..];
                moved.Add(e with { Path = newPath });
            }

            foreach (var e in moved)
            {
                Set(e);
            }
        }
    }
}

/// <summary>Local files that are never uploaded (editor lock/temp files, shell metadata, partial downloads).</summary>
public static class LocalFileFilter
{
    private static readonly string[] IgnoredNames = { "desktop.ini", "thumbs.db", ".ds_store" };
    private static readonly string[] IgnoredPrefixes = { "~$", ".~", "~wm-" };
    private static readonly string[] IgnoredSuffixes = { ".tmp", ".crdownload", ".part", ".partial", ".download", ".!ut" };

    public static bool IsIgnored(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return IgnoredNames.Contains(name, StringComparer.OrdinalIgnoreCase)
               || IgnoredPrefixes.Any(p => name.StartsWith(p, StringComparison.OrdinalIgnoreCase))
               || IgnoredSuffixes.Any(s => name.EndsWith(s, StringComparison.OrdinalIgnoreCase));
    }
}
