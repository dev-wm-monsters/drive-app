using DriveSync.Core.Model;
using DriveSync.Core.Sync;
using static DriveSync.Core.Tests.Fakes.TestData;

namespace DriveSync.Core.Tests;

public class RemoteTreeTests
{
    [Fact]
    public void Changes_for_unrelated_files_are_ignored_in_folder_mode()
    {
        var tree = new RemoteTree(new DriveRoot("root", "Shared", null, RootKind.Folder));
        tree.AddListing("root", new[] { File("a", "a.mp4", parent: "root") });
        var changed = tree.ApplyChanges(new DriveChange[] { new DriveChange.Upsert(File("z", "elsewhere.mp4", parent: "other")) });
        Assert.False(changed);
        Assert.Equal(1, tree.Count);
    }

    [Fact]
    public void New_folder_and_child_in_any_order_are_both_kept()
    {
        var tree = new RemoteTree(SharedRoot);
        tree.AddListing("drive1", Array.Empty<DriveItem>());
        tree.ApplyChanges(new DriveChange[]
        {
            new DriveChange.Upsert(File("c", "child.mp4", parent: "f")),
            new DriveChange.Upsert(Folder("f", "New")),
        });
        Assert.Equal(new[] { "New", "New/child.mp4" }, tree.BuildLayout().Select(e => e.Path));
    }

    [Fact]
    public void Trashed_or_hidden_upsert_removes_item()
    {
        var tree = new RemoteTree(SharedRoot);
        tree.AddListing("drive1", new[] { File("a", "a.mp4") });
        tree.ApplyChanges(new DriveChange[] { new DriveChange.Upsert(File("a", "a.mp4") with { Trashed = true }) });
        Assert.Empty(tree.BuildLayout());
    }

    [Fact]
    public void Removed_change_drops_item_and_descendants_disappear_from_layout()
    {
        var tree = new RemoteTree(SharedRoot);
        tree.AddListing("drive1", new[] { Folder("f", "F") });
        tree.AddListing("f", new[] { File("a", "a.mp4", parent: "f") });
        tree.ApplyChanges(new DriveChange[] { new DriveChange.Removed("f") });
        Assert.Empty(tree.BuildLayout());
    }

    [Fact]
    public void Folder_moved_in_from_outside_needs_listing()
    {
        var tree = new RemoteTree(SharedRoot);
        tree.AddListing("drive1", Array.Empty<DriveItem>());
        tree.ApplyChanges(new DriveChange[] { new DriveChange.Upsert(Folder("f", "Moved In")) });
        Assert.Equal(new[] { "f" }, tree.FoldersNeedingListing());
        tree.AddListing("f", Array.Empty<DriveItem>());
        Assert.Empty(tree.FoldersNeedingListing());
    }

    [Fact]
    public void Listing_replaces_stale_children()
    {
        var tree = new RemoteTree(SharedRoot);
        tree.AddListing("drive1", new[] { File("a", "a.mp4"), File("b", "b.mp4") });
        tree.AddListing("drive1", new[] { File("b", "b.mp4") });
        Assert.Equal(new[] { "b.mp4" }, tree.BuildLayout().Select(e => e.Path));
    }
}
