using DriveSync.Core.Drive;
using DriveSync.Core.Model;

namespace DriveSync.Core.Tests.Fakes;

internal sealed class FakeDriveService : IDriveService
{
    private int _nextId = 1000;

    public DriveRoot Root { get; set; } = TestData.SharedRoot;

    public Dictionary<string, DriveItem> Files { get; } = new(StringComparer.Ordinal);

    public Queue<ChangeBatch> PendingChanges { get; } = new();

    public List<(string Name, string Parent, byte[] Content)> Uploads { get; } = new();

    public int ListCalls { get; private set; }

    public void Add(params DriveItem[] items)
    {
        foreach (var i in items)
        {
            Files[i.Id] = i;
        }
    }

    public Task<DriveRoot> ResolveRootAsync(CancellationToken cancellationToken) => Task.FromResult(Root);

    public Task<IReadOnlyList<DriveItem>> ListChildrenAsync(string folderId, DriveRoot root, CancellationToken cancellationToken)
    {
        ListCalls++;
        IReadOnlyList<DriveItem> result = Files.Values.Where(f => f.ParentId == folderId && !f.IsHidden).ToList();
        return Task.FromResult(result);
    }

    public Task<DriveItem> GetFileAsync(string fileId, CancellationToken cancellationToken) => Task.FromResult(Files[fileId]);

    public Task<Stream> OpenRangeAsync(string fileId, long offset, long length, CancellationToken cancellationToken) =>
        Task.FromResult<Stream>(new MemoryStream(new byte[length]));

    public Task<string> GetStartPageTokenAsync(DriveRoot root, CancellationToken cancellationToken) => Task.FromResult("t0");

    public Task<ChangeBatch> GetChangesAsync(string pageToken, DriveRoot root, CancellationToken cancellationToken) =>
        Task.FromResult(PendingChanges.Count > 0 ? PendingChanges.Dequeue() : new ChangeBatch(Array.Empty<DriveChange>(), null, pageToken));

    public async Task<DriveItem> UploadAsync(Stream content, string name, string parentId, IProgress<long>? progress, CancellationToken cancellationToken)
    {
        using var ms = new MemoryStream();
        await content.CopyToAsync(ms, cancellationToken);
        Uploads.Add((name, parentId, ms.ToArray()));
        var id = "up" + _nextId++;
        string md5;
        using (var copy = new MemoryStream(ms.ToArray()))
        {
            md5 = await DriveSync.Core.Sync.Hashing.Md5HexAsync(copy, cancellationToken);
        }

        var item = TestData.File(id, name, parentId, day: 300, size: ms.Length, md5: md5);
        Files[id] = item;
        return item;
    }

    public Task<string?> GetUserEmailAsync(CancellationToken cancellationToken) => Task.FromResult<string?>("user@example.com");
}
