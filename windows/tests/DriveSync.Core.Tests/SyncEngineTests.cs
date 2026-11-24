using System.Text;
using DriveSync.Core.Model;
using DriveSync.Core.Sync;
using DriveSync.Core.Tests.Fakes;
using Microsoft.Extensions.Logging.Abstractions;
using static DriveSync.Core.Tests.Fakes.TestData;

namespace DriveSync.Core.Tests;

public class SyncEngineTests
{
    private readonly FakeDriveService _drive = new();
    private readonly FakePlaceholderSystem _fs = new();
    private DateTimeOffset _now = new(2026, 6, 1, 12, 0, 0, TimeSpan.Zero);

    private SyncEngine NewEngine() => new(_drive, _fs, NullLogger.Instance, TimeSpan.FromSeconds(3), () => _now);

    [Fact]
    public async Task Initial_sync_creates_all_placeholders()
    {
        _drive.Add(Folder("f", "Clips"), File("a", "a.mp4", parent: "f"), File("b", "b.mp4"), Doc("d", "Notes"));
        using var engine = NewEngine();
        await engine.InitializeAsync(CancellationToken.None);

        Assert.Equal(new[] { "b.mp4", "Clips", "Clips/a.mp4" }.Order(StringComparer.Ordinal), _fs.Entries.Keys.Order(StringComparer.Ordinal));
        Assert.Equal(SyncState.Idle, engine.Status.State);
    }

    [Fact]
    public async Task Poll_applies_remote_changes()
    {
        _drive.Add(File("a", "v.mp4", day: 1), File("b", "v.mp4", day: 2));
        using var engine = NewEngine();
        await engine.InitializeAsync(CancellationToken.None);
        Assert.True(_fs.Entries.ContainsKey("v (2).mp4"));

        _drive.PendingChanges.Enqueue(new ChangeBatch(
            new DriveChange[] { new DriveChange.Removed("a"), new DriveChange.Upsert(File("c", "new.mp4", day: 3)) },
            NextPageToken: null,
            NewStartPageToken: "t1"));
        await engine.PollAsync(CancellationToken.None);

        Assert.Equal("b", _fs.Entries["v.mp4"].FileId);
        Assert.Equal("c", _fs.Entries["new.mp4"].FileId);
        Assert.Equal(2, _fs.Entries.Count);
    }

    [Fact]
    public async Task New_local_file_is_uploaded_once_stable_and_converted()
    {
        _drive.Add(File("a", "clip.mp4"));
        using var engine = NewEngine();
        await engine.InitializeAsync(CancellationToken.None);

        _fs.AddUserFile("holiday.mov", Encoding.UTF8.GetBytes("hello"), _now);
        await engine.ReconcileAsync(CancellationToken.None);
        await engine.WhenUploadsIdleAsync();
        Assert.Empty(_drive.Uploads); // not stable yet
        Assert.True(engine.HasFilesWaitingToSettle);

        _now = _now.AddSeconds(5);
        await engine.ReconcileAsync(CancellationToken.None);
        await engine.WhenUploadsIdleAsync();

        var upload = Assert.Single(_drive.Uploads);
        Assert.Equal(("holiday.mov", "drive1"), (upload.Name, upload.Parent));
        Assert.True(_fs.Entries["holiday.mov"].IsPlaceholder);
        Assert.StartsWith("up", _fs.Entries["holiday.mov"].FileId, StringComparison.Ordinal);
        Assert.Contains("convert holiday.mov", _fs.Log);
        Assert.Equal(new[] { true }, _fs.ConvertedWhileLocked); // no write window between upload and conversion
        Assert.Equal(0, _fs.OpenUploadStreams);
    }

    [Fact]
    public async Task Busy_file_is_retried_later_without_duplicate_upload()
    {
        using var engine = NewEngine();
        await engine.InitializeAsync(CancellationToken.None);
        _fs.AddUserFile("big.mp4", new byte[] { 1, 2, 3 }, _now);
        _fs.Busy.Add("big.mp4");
        await engine.ReconcileAsync(CancellationToken.None);
        _now = _now.AddSeconds(5);
        await engine.ReconcileAsync(CancellationToken.None);
        await engine.WhenUploadsIdleAsync();
        Assert.Empty(_drive.Uploads);

        _fs.Busy.Clear();
        await engine.ReconcileAsync(CancellationToken.None);
        await engine.WhenUploadsIdleAsync();
        Assert.Single(_drive.Uploads);
    }

    [Fact]
    public async Task Upload_racing_with_same_remote_name_gets_free_name_then_local_file_is_renamed()
    {
        using var engine = NewEngine();
        await engine.InitializeAsync(CancellationToken.None);
        _fs.AddUserFile("new.mp4", new byte[] { 9 }, _now);
        // Phone uploads "new.mp4" before our upload starts.
        _drive.Add(File("phone", "new.mp4", day: 2));
        _drive.PendingChanges.Enqueue(new ChangeBatch(new DriveChange[] { new DriveChange.Upsert(_drive.Files["phone"]) }, null, "t1"));
        await engine.PollAsync(CancellationToken.None);
        _now = _now.AddSeconds(5);
        await engine.ReconcileAsync(CancellationToken.None);
        await engine.WhenUploadsIdleAsync();

        Assert.Equal("new (2).mp4", Assert.Single(_drive.Uploads).Name);
        // After conversion the planner moved our file to its display name and created the phone's placeholder.
        Assert.Equal("phone", _fs.Entries["new.mp4"].FileId);
        Assert.StartsWith("up", _fs.Entries["new (2).mp4"].FileId, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Changes_paging_follows_next_page_token()
    {
        using var engine = NewEngine();
        await engine.InitializeAsync(CancellationToken.None);
        _drive.PendingChanges.Enqueue(new ChangeBatch(new DriveChange[] { new DriveChange.Upsert(File("a", "a.mp4")) }, "p2", null));
        _drive.PendingChanges.Enqueue(new ChangeBatch(new DriveChange[] { new DriveChange.Upsert(File("b", "b.mp4")) }, null, "t2"));
        await engine.PollAsync(CancellationToken.None);
        Assert.Equal(2, _fs.Entries.Count);
    }

    [Fact]
    public async Task Edited_placeholder_is_preserved_before_the_drive_version_is_restored()
    {
        _drive.Add(File("a", "v.mp4"));
        using var engine = NewEngine();
        var notices = new List<string>();
        engine.Notice += (_, m) => notices.Add(m);
        await engine.InitializeAsync(CancellationToken.None);

        _fs.EditPlaceholder("v.mp4", new byte[] { 4, 5, 6 });
        await engine.ReconcileAsync(CancellationToken.None);

        Assert.Equal(new byte[] { 4, 5, 6 }, _fs.Preserved["v.mp4"]);
        Assert.True(_fs.Log.IndexOf("preserve v.mp4") < _fs.Log.IndexOf("update v.mp4 discard"));
        Assert.Contains(notices, n => n.Contains("saved/v.mp4", StringComparison.Ordinal));
        Assert.True(_fs.Entries["v.mp4"].InSync);
    }

    [Fact]
    public async Task Edited_placeholder_is_not_reverted_when_its_bytes_cannot_be_saved()
    {
        _drive.Add(File("a", "v.mp4"));
        using var engine = NewEngine();
        await engine.InitializeAsync(CancellationToken.None);

        _fs.EditPlaceholder("v.mp4", new byte[] { 4, 5, 6 });
        _fs.PreserveFails.Add("v.mp4");
        await engine.ReconcileAsync(CancellationToken.None);

        Assert.DoesNotContain(_fs.Log, l => l.StartsWith("update v.mp4", StringComparison.Ordinal));
        Assert.False(_fs.Entries["v.mp4"].InSync);

        _fs.PreserveFails.Clear();
        await engine.ReconcileAsync(CancellationToken.None);
        Assert.Contains("update v.mp4 discard", _fs.Log);
        Assert.True(_fs.Preserved.ContainsKey("v.mp4"));
    }

    [Fact]
    public async Task Edited_placeholder_removed_from_drive_is_preserved_before_delete()
    {
        _drive.Add(Folder("f", "Clips"), File("a", "v.mp4", parent: "f"));
        using var engine = NewEngine();
        await engine.InitializeAsync(CancellationToken.None);
        _fs.EditPlaceholder("Clips/v.mp4", new byte[] { 7 });

        _drive.PendingChanges.Enqueue(new ChangeBatch(new DriveChange[] { new DriveChange.Removed("f") }, null, "t1"));
        await engine.PollAsync(CancellationToken.None);

        Assert.Equal(new byte[] { 7 }, _fs.Preserved["Clips/v.mp4"]);
        Assert.Empty(_fs.Entries);
    }

    [Fact]
    public async Task Unmodified_dehydrated_placeholder_that_lost_in_sync_is_reverted_without_notice()
    {
        _drive.Add(File("a", "v.mp4"));
        using var engine = NewEngine();
        var notices = new List<string>();
        engine.Notice += (_, m) => notices.Add(m);
        await engine.InitializeAsync(CancellationToken.None);

        _fs.Entries["v.mp4"] = _fs.Entries["v.mp4"] with { InSync = false }; // e.g. read-only attribute toggled
        await engine.ReconcileAsync(CancellationToken.None);

        Assert.Contains("update v.mp4 discard", _fs.Log);
        Assert.Empty(_fs.Preserved);
        Assert.Empty(notices);
    }
}
