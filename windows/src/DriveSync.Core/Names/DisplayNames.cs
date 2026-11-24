using System.Globalization;
using System.Text;

namespace DriveSync.Core.Names;

/// <summary>
/// Minimal shape needed to assign display names. Implemented by <see cref="Model.DriveItem"/> and by test fixtures.
/// </summary>
public interface INamedItem
{
    string Id { get; }
    string Name { get; }
    string MimeType { get; }
    DateTimeOffset CreatedTime { get; }
    bool Trashed { get; }
}

/// <summary>
/// The display-name algorithm from the binding contract (Contract v2, "Display-name algorithm").
/// MUST stay byte-for-byte equivalent to the Swift implementation (Packages/DriveCore); both are checked
/// against spec/name-vectors.json.
/// </summary>
public static class DisplayNames
{
    private static readonly HashSet<string> ReservedDeviceNames = BuildReserved();

    private static HashSet<string> BuildReserved()
    {
        var set = new HashSet<string>(StringComparer.Ordinal) { "CON", "PRN", "AUX", "NUL" };
        for (var i = 1; i <= 9; i++)
        {
            set.Add("COM" + i.ToString(CultureInfo.InvariantCulture));
            set.Add("LPT" + i.ToString(CultureInfo.InvariantCulture));
        }

        return set;
    }

    /// <summary>
    /// NFC-normalize; replace / \ : * ? " &lt; &gt; | and U+0000–U+001F, U+007F with '_'; trim trailing spaces and dots;
    /// empty → "_"; reserved device name (part before the first '.', uppercased) gets '_' appended to that part.
    /// </summary>
    public static string Sanitize(string? name)
    {
        var normalized = (name ?? string.Empty).Normalize(NormalizationForm.FormC);
        var sb = new StringBuilder(normalized.Length);
        foreach (var ch in normalized)
        {
            sb.Append(IsForbidden(ch) ? '_' : ch);
        }

        var result = sb.ToString().TrimEnd(' ', '.');
        if (result.Length == 0)
        {
            return "_";
        }

        var firstDot = result.IndexOf('.', StringComparison.Ordinal);
        var head = firstDot < 0 ? result : result[..firstDot];
        if (ReservedDeviceNames.Contains(head.ToUpperInvariant()))
        {
            result = head + "_" + (firstDot < 0 ? string.Empty : result[firstDot..]);
        }

        return result;
    }

    /// <summary>Case-insensitive comparison key: sanitize + ToLowerInvariant.</summary>
    public static string Key(string name) => Sanitize(name).ToLowerInvariant();

    /// <summary>
    /// Splits at the LAST '.', unless that dot is at index 0 (".bashrc" → (".bashrc", "")).
    /// "a.tar.gz" → ("a.tar", ".gz").
    /// </summary>
    public static (string Stem, string Extension) Split(string name)
    {
        var lastDot = name.LastIndexOf('.');
        return lastDot <= 0 ? (name, string.Empty) : (name[..lastDot], name[lastDot..]);
    }

    /// <summary>True for Google Workspace docs (except folders), shortcuts and trashed items: never shown in v1.</summary>
    public static bool IsHidden(INamedItem item) => item.Trashed || Model.DriveMimeTypes.IsHiddenMimeType(item.MimeType);

    /// <summary>
    /// Assigns unique display names to the children of ONE folder. Hidden items are dropped and reserve nothing.
    /// Order: createdTime ascending, then id (ordinal). Returns id → display name.
    /// </summary>
    public static IReadOnlyDictionary<string, string> Assign(IEnumerable<INamedItem> children)
    {
        ArgumentNullException.ThrowIfNull(children);
        var ordered = children
            .Where(c => !IsHidden(c))
            .OrderBy(c => c.CreatedTime)
            .ThenBy(c => c.Id, StringComparer.Ordinal)
            .ToList();

        var taken = new HashSet<string>(StringComparer.Ordinal);
        var result = new Dictionary<string, string>(ordered.Count, StringComparer.Ordinal);
        foreach (var child in ordered)
        {
            var candidate = FirstFree(Sanitize(child.Name), taken);
            taken.Add(Key(candidate));
            result[child.Id] = candidate;
        }

        return result;
    }

    /// <summary>A name for a new upload that does not clash (case-insensitively, after sanitizing) with any existing name.</summary>
    public static string UniqueUploadName(string desired, IEnumerable<string> existingNames)
    {
        ArgumentNullException.ThrowIfNull(existingNames);
        var taken = new HashSet<string>(existingNames.Select(Key), StringComparer.Ordinal);
        return FirstFree(Sanitize(desired), taken);
    }

    private static string FirstFree(string sanitized, HashSet<string> takenKeys)
    {
        var candidate = sanitized;
        var (stem, ext) = Split(sanitized);
        var n = 2;
        while (takenKeys.Contains(Key(candidate)))
        {
            candidate = stem + " (" + n.ToString(CultureInfo.InvariantCulture) + ")" + ext;
            n++;
        }

        return candidate;
    }

    private static bool IsForbidden(char ch) =>
        ch is '/' or '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|' || ch <= '\u001F' || ch == '\u007F';
}
