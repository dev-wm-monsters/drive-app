using DriveSync.Core.Model;
using DriveSync.Core.Names;

namespace DriveSync.Core.Sync;

/// <summary>A remote item at its computed local location.</summary>
public sealed record DesiredEntry(string Id, string Path, string ParentPath, string ParentId, string Name, DriveItem Item);

/// <summary>
/// In-memory snapshot of the visible (non-hidden) Drive tree under the root, updated from listings and the changes
/// feed. Items whose parent chain does not reach the root are kept but not laid out (they may become reachable).
/// In folder mode this is also the "known folder IDs" filter the contract requires for changes without driveId.
/// </summary>
public sealed class RemoteTree
{
    private readonly Dictionary<string, DriveItem> _items = new(StringComparer.Ordinal);
    private readonly HashSet<string> _listedFolders = new(StringComparer.Ordinal);

    public RemoteTree(DriveRoot root)
    {
        Root = root ?? throw new ArgumentNullException(nameof(root));
    }

    public DriveRoot Root { get; }

    public string RootId => Root.Id;

    public int Count => _items.Count;

    public bool TryGet(string id, out DriveItem item) => _items.TryGetValue(id, out item!);

    /// <summary>Replaces the known children of <paramref name="folderId"/> with a fresh listing.</summary>
    public void AddListing(string folderId, IEnumerable<DriveItem> children)
    {
        ArgumentNullException.ThrowIfNull(children);
        var fresh = children.Where(c => !c.IsHidden).ToDictionary(c => c.Id, StringComparer.Ordinal);
        foreach (var stale in _items.Values.Where(i => i.ParentId == folderId && !fresh.ContainsKey(i.Id)).Select(i => i.Id).ToList())
        {
            _items.Remove(stale);
        }

        foreach (var child in fresh.Values)
        {
            _items[child.Id] = child;
        }

        _listedFolders.Add(folderId);
    }

    /// <summary>Adds/updates one item we know belongs here (e.g. the result of our own upload).</summary>
    public void Upsert(DriveItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (item.IsHidden)
        {
            _items.Remove(item.Id);
        }
        else
        {
            _items[item.Id] = item;
        }
    }

    /// <summary>
    /// Applies a batch from changes.list. Upserts are kept only when relevant: the item is already known, or one of its
    /// parents is the root or a known folder. Irrelevant upserts are retried after the rest of the batch so a new
    /// folder and its children can arrive in any order. Returns true when anything changed.
    /// </summary>
    public bool ApplyChanges(IEnumerable<DriveChange> changes)
    {
        ArgumentNullException.ThrowIfNull(changes);
        var changed = false;
        var pending = new List<DriveItem>();
        foreach (var change in changes)
        {
            switch (change)
            {
                case DriveChange.Removed removed:
                    changed |= _items.Remove(removed.FileId);
                    break;
                case DriveChange.Upsert upsert when upsert.Item.Id == RootId:
                    break;
                case DriveChange.Upsert upsert:
                    if (IsRelevant(upsert.Item))
                    {
                        Upsert(upsert.Item);
                        changed = true;
                    }
                    else
                    {
                        pending.Add(upsert.Item);
                    }

                    break;
            }
        }

        bool progress;
        do
        {
            progress = false;
            foreach (var item in pending.ToList())
            {
                if (IsRelevant(item))
                {
                    Upsert(item);
                    pending.Remove(item);
                    progress = changed = true;
                }
            }
        }
        while (progress && pending.Count > 0);

        return changed;
    }

    public bool IsRelevant(DriveItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        return _items.ContainsKey(item.Id)
               || item.Parents.Any(p => p == RootId || (_items.TryGetValue(p, out var parent) && parent.IsFolder));
    }

    public IReadOnlyList<DriveItem> ChildrenOf(string folderId) =>
        _items.Values.Where(i => string.Equals(i.ParentId, folderId, StringComparison.Ordinal)).ToList();

    /// <summary>Reachable folders (root included) whose children have never been listed.</summary>
    public IReadOnlyList<string> FoldersNeedingListing()
    {
        var result = new List<string>();
        if (!_listedFolders.Contains(RootId))
        {
            result.Add(RootId);
        }

        result.AddRange(BuildLayout().Where(e => e.Item.IsFolder && !_listedFolders.Contains(e.Id)).Select(e => e.Id));
        return result;
    }

    /// <summary>
    /// Computes the local layout: breadth-first from the root, display names assigned per folder with the shared
    /// algorithm. Parents always precede their children in the result.
    /// </summary>
    public IReadOnlyList<DesiredEntry> BuildLayout()
    {
        var childrenByParent = _items.Values
            .Where(i => i.ParentId is not null)
            .GroupBy(i => i.ParentId!, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal);

        var result = new List<DesiredEntry>();
        var queue = new Queue<(string Id, string Path)>();
        var visited = new HashSet<string>(StringComparer.Ordinal) { RootId };
        queue.Enqueue((RootId, string.Empty));
        while (queue.Count > 0)
        {
            var (folderId, folderPath) = queue.Dequeue();
            if (!childrenByParent.TryGetValue(folderId, out var children))
            {
                continue;
            }

            var names = DisplayNames.Assign(children);
            foreach (var child in children.Where(c => names.ContainsKey(c.Id)).OrderBy(c => names[c.Id], StringComparer.OrdinalIgnoreCase))
            {
                var path = SyncPath.Combine(folderPath, names[child.Id]);
                result.Add(new DesiredEntry(child.Id, path, folderPath, folderId, names[child.Id], child));
                if (child.IsFolder && visited.Add(child.Id))
                {
                    queue.Enqueue((child.Id, path));
                }
            }
        }

        return result;
    }
}
