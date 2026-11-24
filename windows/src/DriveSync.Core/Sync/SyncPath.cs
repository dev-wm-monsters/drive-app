namespace DriveSync.Core.Sync;

/// <summary>
/// Relative paths inside the sync root use '/' separators and "" for the root; the Windows layer converts them.
/// Comparisons are case-insensitive like NTFS (<see cref="Comparer"/>), but a case-only difference still counts as a rename.
/// </summary>
public static class SyncPath
{
    public const char Separator = '/';

    public static StringComparer Comparer => StringComparer.OrdinalIgnoreCase;

    public static string Combine(string parent, string name) => parent.Length == 0 ? name : parent + Separator + name;

    public static string Parent(string path)
    {
        var i = path.LastIndexOf(Separator);
        return i < 0 ? string.Empty : path[..i];
    }

    public static string Name(string path)
    {
        var i = path.LastIndexOf(Separator);
        return i < 0 ? path : path[(i + 1)..];
    }

    public static int Depth(string path) => path.Length == 0 ? 0 : path.Count(c => c == Separator) + 1;

    /// <summary>True when <paramref name="path"/> is strictly inside <paramref name="ancestor"/>.</summary>
    public static bool IsUnder(string path, string ancestor) =>
        ancestor.Length == 0
            ? path.Length > 0
            : path.Length > ancestor.Length + 1
              && path[ancestor.Length] == Separator
              && path.StartsWith(ancestor, StringComparison.OrdinalIgnoreCase);

    public static bool SameIgnoringCase(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
}
