using System.Globalization;
using System.Text.Json;
using DriveSync.Core.Names;

namespace DriveSync.Core.Tests;

/// <summary>Runs every case in spec/name-vectors.json (shared with the Swift DriveCore tests).</summary>
public class NameVectorTests
{
    private static readonly JsonDocument Vectors = JsonDocument.Parse(
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "vectors", "name-vectors.json")));

    public static TheoryData<string, string> SanitizeCases()
    {
        var data = new TheoryData<string, string>();
        foreach (var c in Vectors.RootElement.GetProperty("sanitize").EnumerateArray())
        {
            data.Add(c.GetProperty("in").GetString()!, c.GetProperty("out").GetString()!);
        }

        return data;
    }

    public static TheoryData<string> AssignCases()
    {
        var data = new TheoryData<string>();
        foreach (var c in Vectors.RootElement.GetProperty("assign").EnumerateArray())
        {
            data.Add(c.GetProperty("name").GetString()!);
        }

        return data;
    }

    public static TheoryData<int> UploadCases()
    {
        var data = new TheoryData<int>();
        var n = Vectors.RootElement.GetProperty("uniqueUploadName").GetArrayLength();
        for (var i = 0; i < n; i++)
        {
            data.Add(i);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(SanitizeCases))]
    public void Sanitize_matches_vector(string input, string expected) =>
        Assert.Equal(expected, DisplayNames.Sanitize(input));

    [Theory]
    [MemberData(nameof(AssignCases))]
    public void Assign_matches_vector(string caseName)
    {
        var c = Vectors.RootElement.GetProperty("assign").EnumerateArray().Single(x => x.GetProperty("name").GetString() == caseName);
        var children = c.GetProperty("children").EnumerateArray().Select(ch => new TestItem(
            ch.GetProperty("id").GetString()!,
            ch.GetProperty("name").GetString()!,
            ch.GetProperty("mimeType").GetString()!,
            DateTimeOffset.Parse(ch.GetProperty("createdTime").GetString()!, CultureInfo.InvariantCulture),
            ch.TryGetProperty("trashed", out var t) && t.GetBoolean())).ToList();

        var expected = c.GetProperty("expected").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!);
        var actual = DisplayNames.Assign(children);

        Assert.Equal(expected.OrderBy(k => k.Key, StringComparer.Ordinal), actual.OrderBy(k => k.Key, StringComparer.Ordinal));
    }

    [Theory]
    [MemberData(nameof(UploadCases))]
    public void UniqueUploadName_matches_vector(int index)
    {
        var c = Vectors.RootElement.GetProperty("uniqueUploadName")[index];
        var existing = c.GetProperty("existing").EnumerateArray().Select(e => e.GetString()!).ToList();
        Assert.Equal(c.GetProperty("out").GetString(), DisplayNames.UniqueUploadName(c.GetProperty("desired").GetString()!, existing));
    }

    [Fact]
    public void Vector_file_has_cases() =>
        Assert.True(Vectors.RootElement.GetProperty("sanitize").GetArrayLength() > 0);

    [Theory]
    [InlineData(".bashrc", ".bashrc", "")]
    [InlineData("a.tar.gz", "a.tar", ".gz")]
    [InlineData("notes", "notes", "")]
    [InlineData("a.", "a", ".")]
    public void Split_uses_last_dot_unless_leading(string name, string stem, string ext) =>
        Assert.Equal((stem, ext), DisplayNames.Split(name));

    [Fact]
    public void Sanitize_normalizes_to_nfc()
    {
        var decomposed = "Café.mov";
        Assert.Equal("Café.mov", DisplayNames.Sanitize(decomposed));
    }

    [Theory]
    [InlineData("com9.log", "com9_.log")]
    [InlineData("AUX", "AUX_")]
    [InlineData("nul.tar.gz", "nul_.tar.gz")]
    [InlineData("COM10.txt", "COM10.txt")]
    [InlineData("del\u007f", "del_")]
    public void Sanitize_extra_cases(string input, string expected) =>
        Assert.Equal(expected, DisplayNames.Sanitize(input));

    private sealed record TestItem(string Id, string Name, string MimeType, DateTimeOffset CreatedTime, bool Trashed) : INamedItem;
}
