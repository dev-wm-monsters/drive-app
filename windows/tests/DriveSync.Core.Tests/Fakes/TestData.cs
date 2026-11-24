using DriveSync.Core.Model;

namespace DriveSync.Core.Tests.Fakes;

internal static class TestData
{
    public static readonly DriveRoot SharedRoot = new("drive1", "WakeupMonster", "drive1", RootKind.SharedDrive);

    private static readonly DateTimeOffset Epoch = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public static DriveItem File(string id, string name, string parent = "drive1", int day = 1, long size = 10, string? md5 = null) => new()
    {
        Id = id,
        Name = name,
        MimeType = "video/mp4",
        Size = size,
        CreatedTime = Epoch.AddDays(day),
        ModifiedTime = Epoch.AddDays(day),
        Md5Checksum = md5 ?? ("md5-" + id),
        Parents = new[] { parent },
    };

    public static DriveItem Folder(string id, string name, string parent = "drive1", int day = 1) => new()
    {
        Id = id,
        Name = name,
        MimeType = DriveMimeTypes.Folder,
        CreatedTime = Epoch.AddDays(day),
        ModifiedTime = Epoch.AddDays(day),
        Parents = new[] { parent },
    };

    public static DriveItem Doc(string id, string name, string parent = "drive1") => File(id, name, parent) with
    {
        MimeType = "application/vnd.google-apps.document",
        Size = null,
        Md5Checksum = null,
    };
}
