using DriveSync.Core.Model;

namespace DriveSync.Core.Sync;

/// <summary>
/// Local side of the sync engine. Windows: CloudFilesPlaceholderSystem (cfapi). Tests: an in-memory fake.
/// All paths are relative to the sync root and use '/' (see <see cref="SyncPath"/>).
/// </summary>
public interface IPlaceholderSystem
{
    IReadOnlyList<LocalEntry> Scan();

    /// <summary>Creates a dehydrated, in-sync placeholder (read-only for files) carrying <see cref="PlaceholderIdentity"/>.</summary>
    void CreatePlaceholder(string parentPath, string name, DriveItem item);

    void MovePlaceholder(string fromPath, string toPath);

    void UpdatePlaceholder(string path, DriveItem item, bool contentChanged, bool discardLocalChanges);

    void DeletePlaceholder(string path);

    /// <summary>Opens a new local file for upload; throws <see cref="IOException"/> while another process writes to it.</summary>
    Stream OpenForUpload(string path);

    /// <summary>Turns an uploaded local file into an in-sync, read-only placeholder for <paramref name="item"/> (data stays local).</summary>
    void ConvertToPlaceholder(string path, DriveItem item);

    void Hydrate(string path);

    void Dehydrate(string path);
}
