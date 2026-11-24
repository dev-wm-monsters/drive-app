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

        _now = _now.AddSeconds(5);
        await engine.ReconcileAsync(CancellationToken.None);
        await engine.WhenUploadsIdleAsync();

        var upload = Assert.Single(_drive.Uploads);
        Assert.Equal(("holiday.mov", "drive1"), (upload.Name, upload.Parent));
        Assert.True(_fs.Entries["holiday.mov"].IsPlaceholder);
        Assert.StartsWith("up", _fs.Entries["holiday.mov"].FileId, StringComparison.Ordinal);
        Assert.Contains("convert holiday.mov", _fs.Log);
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
}
