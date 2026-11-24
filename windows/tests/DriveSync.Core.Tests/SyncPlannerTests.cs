using DriveSync.Core.Model;
using DriveSync.Core.Sync;
using DriveSync.Core.Tests.Fakes;
using static DriveSync.Core.Tests.Fakes.TestData;

namespace DriveSync.Core.Tests;

public class SyncPlannerTests
{
    private static RemoteTree Tree(params DriveItem[] items)
    {
        var tree = new RemoteTree(SharedRoot);
        tree.AddListing("drive1", items.Where(i => i.ParentId == "drive1"));
        foreach (var folder in items.Where(i => i.IsFolder))
        {
            tree.AddListing(folder.Id, items.Where(i => i.ParentId == folder.Id));
        }

        return tree;
    }

    private static LocalEntry Placeholder(string path, DriveItem item, bool inSync = true) => new()
    {
        Path = path,
        IsDirectory = item.IsFolder,
        IsPlaceholder = true,
        Identity = PlaceholderIdentity.From(item),
        InSync = inSync,
    };

    private static LocalEntry UserFile(string path) => new() { Path = path, Length = 5 };

    [Fact]
    public void New_remote_file_and_folder_create_placeholders_parents_first()
    {
        var folder = Folder("f1", "Clips");
        var file = File("a", "clip.mp4", parent: "f1");
        var plan = SyncPlanner.Plan(Tree(folder, file), Array.Empty<LocalEntry>());

        Assert.Collection(
            plan.Actions,
            a => Assert.Equal("Clips", Assert.IsType<SyncAction.CreatePlaceholder>(a).Path),
            a => Assert.Equal("Clips/clip.mp4", Assert.IsType<SyncAction.CreatePlaceholder>(a).Path));
    }

    [Fact]
    public void In_sync_tree_produces_no_actions()
    {
        var folder = Folder("f1", "Clips");
        var file = File("a", "clip.mp4", parent: "f1");
        var plan = SyncPlanner.Plan(Tree(folder, file), new[] { Placeholder("Clips", folder), Placeholder("Clips/clip.mp4", file) });
        Assert.Empty(plan.Actions);
        Assert.Empty(plan.Warnings);
    }

    [Fact]
    public void Hidden_items_are_ignored()
    {
        var plan = SyncPlanner.Plan(Tree(Doc("d", "Plan"), File("a", "Plan") with { Trashed = true }, File("s", "x") with { MimeType = DriveMimeTypes.Shortcut }), Array.Empty<LocalEntry>());
        Assert.Empty(plan.Actions);
    }

    [Fact]
    public void Placeholder_of_now_hidden_item_is_deleted()
    {
        var plan = SyncPlanner.Plan(Tree(), new[] { Placeholder("Plan", File("d", "Plan")) });
        Assert.Equal("Plan", Assert.IsType<SyncAction.DeletePlaceholder>(Assert.Single(plan.Actions)).Path);
    }

    [Fact]
    public void Duplicate_names_get_suffixes_by_created_time()
    {
        var plan = SyncPlanner.Plan(Tree(File("b", "v.mp4", day: 2), File("a", "v.mp4", day: 1)), Array.Empty<LocalEntry>());
        var created = plan.Actions.Cast<SyncAction.CreatePlaceholder>().ToDictionary(c => c.Item.Id, c => c.Path);
        Assert.Equal("v.mp4", created["a"]);
        Assert.Equal("v (2).mp4", created["b"]);
    }

    [Fact]
    public void Remote_rename_moves_placeholder()
    {
        var before = File("a", "old.mp4");
        var after = before with { Name = "new.mp4" };
        var plan = SyncPlanner.Plan(Tree(after), new[] { Placeholder("old.mp4", before) });
        var move = Assert.IsType<SyncAction.MovePlaceholder>(Assert.Single(plan.Actions));
        Assert.Equal(("old.mp4", "new.mp4"), (move.FromPath, move.ToPath));
    }

    [Fact]
    public void Remote_rename_of_older_duplicate_shifts_sibling_display_name()
    {
        // a (day 1) and b (day 2) were both "v.mp4": a → v.mp4, b → v (2).mp4. a is renamed remotely, so b takes "v.mp4".
        var a = File("a", "v.mp4", day: 1);
        var b = File("b", "v.mp4", day: 2);
        var renamed = a with { Name = "w.mp4" };
        var plan = SyncPlanner.Plan(Tree(renamed, b), new[] { Placeholder("v.mp4", a), Placeholder("v (2).mp4", b) });

        var moves = plan.Actions.Cast<SyncAction.MovePlaceholder>().Select(m => (m.FromPath, m.ToPath)).ToList();
        Assert.Contains(("v (2).mp4", "v.mp4"), moves);
        Assert.Contains(moves, m => m.ToPath == "w.mp4");
        // Simulate in order: no step may target an occupied path.
        var fs = new FakePlaceholderSystem();
        fs.Entries["v.mp4"] = Placeholder("v.mp4", a);
        fs.Entries["v (2).mp4"] = Placeholder("v (2).mp4", b);
        foreach (var m in plan.Actions.Cast<SyncAction.MovePlaceholder>())
        {
            fs.MovePlaceholder(m.FromPath, m.ToPath);
        }

        Assert.Equal("a", fs.Entries["w.mp4"].FileId);
        Assert.Equal("b", fs.Entries["v.mp4"].FileId);
    }

    [Fact]
    public void Swapping_names_goes_through_a_temporary_name()
    {
        var a = File("a", "x.mp4", day: 1);
        var b = File("b", "y.mp4", day: 2);
        var plan = SyncPlanner.Plan(Tree(a with { Name = "y.mp4" }, b with { Name = "x.mp4" }), new[] { Placeholder("x.mp4", a), Placeholder("y.mp4", b) });

        var fs = new FakePlaceholderSystem();
        fs.Entries["x.mp4"] = Placeholder("x.mp4", a);
        fs.Entries["y.mp4"] = Placeholder("y.mp4", b);
        foreach (var m in plan.Actions.Cast<SyncAction.MovePlaceholder>())
        {
            fs.MovePlaceholder(m.FromPath, m.ToPath);
        }

        Assert.Contains(plan.Actions, x => x is SyncAction.MovePlaceholder m && m.ToPath.Contains(SyncPlanner.TempPrefix, StringComparison.Ordinal));
        Assert.Equal("a", fs.Entries["y.mp4"].FileId);
        Assert.Equal("b", fs.Entries["x.mp4"].FileId);
        Assert.Equal(2, fs.Entries.Count);
    }

    [Fact]
    public void Case_only_rename_is_a_move()
    {
        var a = File("a", "clip.mp4");
        var plan = SyncPlanner.Plan(Tree(a with { Name = "Clip.mp4" }), new[] { Placeholder("clip.mp4", a) });
        var move = Assert.IsType<SyncAction.MovePlaceholder>(Assert.Single(plan.Actions));
        Assert.Equal("Clip.mp4", move.ToPath);
    }

    [Fact]
    public void Remote_move_between_folders_moves_placeholder()
    {
        var f1 = Folder("f1", "A");
        var f2 = Folder("f2", "B");
        var file = File("x", "x.mp4", parent: "f1");
        var plan = SyncPlanner.Plan(
            Tree(f1, f2, file with { Parents = new[] { "f2" } }),
            new[] { Placeholder("A", f1), Placeholder("B", f2), Placeholder("A/x.mp4", file) });
        var move = Assert.IsType<SyncAction.MovePlaceholder>(Assert.Single(plan.Actions));
        Assert.Equal(("A/x.mp4", "B/x.mp4"), (move.FromPath, move.ToPath));
    }

    [Fact]
    public void Folder_rename_carries_descendants_without_extra_moves()
    {
        var f1 = Folder("f1", "Old");
        var file = File("x", "x.mp4", parent: "f1");
        var plan = SyncPlanner.Plan(Tree(f1 with { Name = "New" }, file), new[] { Placeholder("Old", f1), Placeholder("Old/x.mp4", file) });
        var move = Assert.IsType<SyncAction.MovePlaceholder>(Assert.Single(plan.Actions));
        Assert.Equal(("Old", "New"), (move.FromPath, move.ToPath));
    }

    [Fact]
    public void Remote_delete_deletes_placeholder_and_frees_name_for_sibling()
    {
        var a = File("a", "v.mp4", day: 1);
        var b = File("b", "v.mp4", day: 2);
        var plan = SyncPlanner.Plan(Tree(b), new[] { Placeholder("v.mp4", a), Placeholder("v (2).mp4", b) });
        Assert.IsType<SyncAction.DeletePlaceholder>(plan.Actions[0]);
        Assert.Equal(("v (2).mp4", "v.mp4"), Assert.IsType<SyncAction.MovePlaceholder>(plan.Actions[1]) is var m ? (m.FromPath, m.ToPath) : default);
    }

    [Fact]
    public void Remote_folder_delete_is_one_action()
    {
        var f1 = Folder("f1", "A");
        var file = File("x", "x.mp4", parent: "f1");
        var plan = SyncPlanner.Plan(Tree(), new[] { Placeholder("A", f1), Placeholder("A/x.mp4", file) });
        Assert.Equal("A", Assert.IsType<SyncAction.DeletePlaceholder>(Assert.Single(plan.Actions)).Path);
    }

    [Fact]
    public void Remote_folder_delete_keeps_folder_with_unuploaded_user_files()
    {
        var f1 = Folder("f1", "A");
        var file = File("x", "x.mp4", parent: "f1");
        var plan = SyncPlanner.Plan(Tree(), new[] { Placeholder("A", f1), Placeholder("A/x.mp4", file), UserFile("A/mine.mov") });
        Assert.Equal("A/x.mp4", Assert.IsType<SyncAction.DeletePlaceholder>(Assert.Single(plan.Actions)).Path);
        Assert.Single(plan.Warnings);
    }

    [Fact]
    public void Content_change_updates_with_dehydrate_flag()
    {
        var a = File("a", "v.mp4");
        var plan = SyncPlanner.Plan(Tree(a with { Md5Checksum = "new", Size = 99 }), new[] { Placeholder("v.mp4", a) });
        var update = Assert.IsType<SyncAction.UpdatePlaceholder>(Assert.Single(plan.Actions));
        Assert.True(update.ContentChanged);
        Assert.False(update.DiscardLocalChanges);
    }

    [Fact]
    public void Metadata_only_change_does_not_dehydrate()
    {
        var a = File("a", "v.mp4");
        var plan = SyncPlanner.Plan(Tree(a with { ModifiedTime = a.ModifiedTime.AddHours(1) }), new[] { Placeholder("v.mp4", a) });
        Assert.False(Assert.IsType<SyncAction.UpdatePlaceholder>(Assert.Single(plan.Actions)).ContentChanged);
    }

    [Fact]
    public void Local_in_place_modification_is_reverted()
    {
        var a = File("a", "v.mp4");
        var plan = SyncPlanner.Plan(Tree(a), new[] { Placeholder("v.mp4", a, inSync: false) });
        var update = Assert.IsType<SyncAction.UpdatePlaceholder>(Assert.Single(plan.Actions));
        Assert.True(update.DiscardLocalChanges);
    }

    [Fact]
    public void Local_new_file_is_uploaded_with_free_name()
    {
        var plan = SyncPlanner.Plan(Tree(File("a", "v.mp4", day: 1), File("b", "v.mp4", day: 2)), new[]
        {
            Placeholder("v.mp4", File("a", "v.mp4", day: 1)),
            Placeholder("v (2).mp4", File("b", "v.mp4", day: 2)),
            UserFile("V (3).MP4"),
        });
        var upload = Assert.IsType<SyncAction.Upload>(Assert.Single(plan.Actions));
        Assert.Equal("drive1", upload.ParentId);
        Assert.Equal("V (3).MP4", upload.DesiredName);
    }

    [Fact]
    public void Race_remote_and_local_same_name_uploads_with_suffix_and_defers_remote()
    {
        // A phone uploaded "new.mp4" while the user dropped a local "new.mp4": the upload must pick a free name,
        // and the remote placeholder waits until the local file has been converted and renamed.
        var plan = SyncPlanner.Plan(Tree(File("p", "new.mp4")), new[] { UserFile("new.mp4") });
        var upload = Assert.IsType<SyncAction.Upload>(Assert.Single(plan.Actions));
        Assert.Equal("new (2).mp4", upload.DesiredName);
        Assert.Equal(1, plan.Deferred);
    }

    [Fact]
    public void Local_file_not_ready_is_not_uploaded()
    {
        var plan = SyncPlanner.Plan(Tree(), new[] { UserFile("new.mp4") }, _ => false);
        Assert.Empty(plan.Actions);
    }

    [Theory]
    [InlineData("~$report.docx")]
    [InlineData("desktop.ini")]
    [InlineData("movie.mp4.crdownload")]
    [InlineData("x.tmp")]
    public void Temp_files_are_not_uploaded(string name)
    {
        var plan = SyncPlanner.Plan(Tree(), new[] { UserFile(name) });
        Assert.Empty(plan.Actions);
    }

    [Fact]
    public void Hidden_or_system_local_files_are_not_uploaded()
    {
        // Office/editor owner and backup files are often hidden and have no recognisable name (e.g. "8F3A2B10").
        var plan = SyncPlanner.Plan(Tree(), new[] { UserFile("8F3A2B10") with { IsHiddenOrSystem = true } });
        Assert.Empty(plan.Actions);
    }

    [Fact]
    public void Local_new_folder_is_reported_not_uploaded()
    {
        var plan = SyncPlanner.Plan(Tree(), new[] { new LocalEntry { Path = "MyFolder", IsDirectory = true }, UserFile("MyFolder/a.mp4") });
        Assert.Empty(plan.Actions);
        Assert.Contains(plan.Warnings, w => w.Contains("MyFolder", StringComparison.Ordinal));
    }

    [Fact]
    public void Remote_item_whose_name_is_taken_by_local_user_file_is_deferred()
    {
        var plan = SyncPlanner.Plan(Tree(File("a", "clip.mp4")), new[] { UserFile("clip.mp4") }, _ => false);
        Assert.Empty(plan.Actions);
        Assert.Equal(1, plan.Deferred);
    }

    [Fact]
    public void Pinned_dehydrated_file_is_hydrated_and_unpinned_hydrated_file_is_dehydrated()
    {
        var a = File("a", "a.mp4");
        var b = File("b", "b.mp4");
        var plan = SyncPlanner.Plan(Tree(a, b), new[]
        {
            Placeholder("a.mp4", a) with { IsPinned = true, IsFullyHydrated = false },
            Placeholder("b.mp4", b) with { IsUnpinned = true, IsFullyHydrated = true },
        });
        Assert.Contains(plan.Actions, x => x is SyncAction.Hydrate { Path: "a.mp4" });
        Assert.Contains(plan.Actions, x => x is SyncAction.Dehydrate { Path: "b.mp4" });
    }

    [Fact]
    public void Duplicate_identity_keeps_first_and_deletes_copy()
    {
        var a = File("a", "a.mp4");
        var plan = SyncPlanner.Plan(Tree(a), new[] { Placeholder("a.mp4", a), Placeholder("zz.mp4", a) });
        Assert.Equal("zz.mp4", Assert.IsType<SyncAction.DeletePlaceholder>(Assert.Single(plan.Actions)).Path);
    }

    [Fact]
    public void Kind_change_recreates_placeholder()
    {
        var asFile = File("a", "thing");
        var plan = SyncPlanner.Plan(Tree(Folder("a", "thing")), new[] { Placeholder("thing", asFile) });
        Assert.IsType<SyncAction.DeletePlaceholder>(plan.Actions[0]);
        Assert.True(Assert.IsType<SyncAction.CreatePlaceholder>(plan.Actions[1]).Item.IsFolder);
    }
}
