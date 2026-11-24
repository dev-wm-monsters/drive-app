using DriveSync.Core.Model;

namespace DriveSync.Core.Sync;

/// <summary>Planner output. Executed in list order by the engine against an <see cref="IPlaceholderSystem"/>.</summary>
public abstract record SyncAction
{
    /// <summary>Create a placeholder for a remote item that has no local representation yet.</summary>
    public sealed record CreatePlaceholder(string ParentPath, string Name, DriveItem Item) : SyncAction
    {
        public string Path => SyncPath.Combine(ParentPath, Name);
    }

    /// <summary>Rename/move an existing placeholder (remote rename, move, or display-name shift of a sibling).</summary>
    public sealed record MovePlaceholder(string FromPath, string ToPath, string FileId) : SyncAction;

    /// <summary>
    /// Refresh metadata/identity. <see cref="ContentChanged"/> → dehydrate so the next open downloads the new bytes.
    /// <see cref="DiscardLocalChanges"/> → the user modified a read-only item in place; restore the Drive version.
    /// </summary>
    public sealed record UpdatePlaceholder(string Path, DriveItem Item, bool ContentChanged, bool DiscardLocalChanges) : SyncAction;

    /// <summary>Remove a placeholder whose Drive item is gone, trashed, hidden or out of the root.</summary>
    public sealed record DeletePlaceholder(string Path, string? FileId) : SyncAction;

    /// <summary>A new local file (not a placeholder) inside a synced folder: upload it as <see cref="DesiredName"/>.</summary>
    public sealed record Upload(string LocalPath, string ParentId, string DesiredName) : SyncAction;

    /// <summary>Pinned ("Always keep on this device") but not fully local: hydrate in the background.</summary>
    public sealed record Hydrate(string Path) : SyncAction;

    /// <summary>Unpinned ("Free up space") but still hydrated: dehydrate.</summary>
    public sealed record Dehydrate(string Path) : SyncAction;
}

public sealed record SyncPlan(IReadOnlyList<SyncAction> Actions, IReadOnlyList<string> Warnings, int Deferred);
