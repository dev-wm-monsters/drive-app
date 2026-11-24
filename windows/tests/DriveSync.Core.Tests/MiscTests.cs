using DriveSync.Core.Config;
using DriveSync.Core.Logging;
using DriveSync.Core.Sync;
using Microsoft.Extensions.Configuration;
using static DriveSync.Core.Tests.Fakes.TestData;

namespace DriveSync.Core.Tests;

public class ConfigTests
{
    private static IConfiguration Load(params (string Key, string? Value)[] overrides) =>
        new ConfigurationBuilder()
            .AddJsonFile(Path.Combine(AppContext.BaseDirectory, "vectors", "appsettings.json"), optional: false)
            .AddInMemoryCollection(overrides.GroupBy(o => o.Key).Select(g => new KeyValuePair<string, string?>(g.Key, g.Last().Value)))
            .Build();

    [Fact]
    public void Shipped_appsettings_has_contract_defaults_and_placeholder_credentials()
    {
        var config = DriveAppConfig.FromConfiguration(Load());
        Assert.Equal("WakeupMonster", config.SharedDriveName);
        Assert.Equal(string.Empty, config.FolderId);
        Assert.Equal("WakeupMonster", config.RootFolderName);
        Assert.Equal("DriveApp", config.AppName);
        Assert.Equal("WakeupMonster.DriveApp.Dev", config.AppId);
        Assert.Equal(string.Empty, config.GoogleClientId);
        Assert.False(config.UsesFolderId);
        Assert.Equal(TimeSpan.FromSeconds(30), config.PollInterval);
        Assert.Contains(config.Validate(), e => e.Contains("Google:ClientId", StringComparison.Ordinal));
    }

    [Fact]
    public void Filled_config_is_valid_and_folder_id_overrides_name()
    {
        var config = DriveAppConfig.FromConfiguration(Load(
            ("Google:ClientId", "1-x.apps.googleusercontent.com"),
            ("Google:ClientSecret", "s"),
            ("Drive:FolderId", "1AbC_d-9")));
        Assert.Empty(config.Validate());
        Assert.True(config.UsesFolderId);
    }

    [Theory]
    [InlineData("App:Id", "Bad!Id")]
    [InlineData("Sync:RootFolderName", "a/b")]
    [InlineData("Drive:FolderId", "id with spaces")]
    [InlineData("Google:ClientId", "not-a-google-id")]
    public void Invalid_values_are_reported(string key, string value)
    {
        var config = DriveAppConfig.FromConfiguration(Load(("Google:ClientId", "1-x.apps.googleusercontent.com"), ("Google:ClientSecret", "s"), (key, value)));
        Assert.NotEmpty(config.Validate());
    }

    [Fact]
    public void Scopes_match_contract() =>
        Assert.Equal(new[] { "https://www.googleapis.com/auth/drive", "openid", "email" }, DriveAppConfig.Scopes);
}

public class PlaceholderIdentityTests
{
    [Fact]
    public void Round_trips_and_stays_small()
    {
        var item = File("1AbCdEfGhIjKlMnOpQrStUvWxYz0123456", "clip.mp4", md5: "0123456789abcdef0123456789abcdef");
        var identity = PlaceholderIdentity.From(item);
        var bytes = identity.Encode();
        Assert.True(bytes.Length < 512);
        Assert.Equal(identity, PlaceholderIdentity.TryDecode(bytes));
    }

    [Fact]
    public void Garbage_decodes_to_null()
    {
        Assert.Null(PlaceholderIdentity.TryDecode("not json"u8));
        Assert.Null(PlaceholderIdentity.TryDecode(ReadOnlySpan<byte>.Empty));
        Assert.Null(PlaceholderIdentity.TryDecode("{\"v\":2,\"id\":\"x\"}"u8));
    }

    [Fact]
    public void Content_change_prefers_md5()
    {
        var item = File("a", "a.mp4", md5: "m1");
        var identity = PlaceholderIdentity.From(item);
        Assert.False(identity.ContentDiffers(item with { ModifiedTime = item.ModifiedTime.AddDays(1) }));
        Assert.True(identity.ContentDiffers(item with { Md5Checksum = "m2" }));
        var noMd5 = PlaceholderIdentity.From(item with { Md5Checksum = null });
        Assert.True(noMd5.ContentDiffers(item with { Md5Checksum = null, Size = 999 }));
    }
}

public class LogRedactorTests
{
    [Theory]
    [InlineData("Authorization: Bearer ya29.a0AfH6SMB-xyz", "Bearer [redacted]")]
    [InlineData("token ya29.abc_DEF-123 leaked", "token [redacted] leaked")]
    [InlineData("refresh 1//0gAbC-xyz", "refresh [redacted]")]
    [InlineData("GET /?code=4/0AY0e-g7&state=x", "code=[redacted]")]
    [InlineData("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=ADPycd", "upload_id=[redacted]")]
    [InlineData("{\"refresh_token\":\"1//abc\",\"x\":1}", "\"refresh_token\":\"[redacted]\"")]
    public void Secrets_are_masked(string input, string expectedFragment)
    {
        var output = LogRedactor.Redact(input);
        Assert.Contains(expectedFragment, output, StringComparison.Ordinal);
        Assert.DoesNotContain("ya29.a", output, StringComparison.Ordinal);
        Assert.DoesNotContain("1//0g", output, StringComparison.Ordinal);
    }

    [Fact]
    public void Plain_text_is_untouched() => Assert.Equal("Uploaded 3 files", LogRedactor.Redact("Uploaded 3 files"));
}

public class UploadStabilityTests
{
    [Fact]
    public void File_must_be_unchanged_for_the_window()
    {
        var t0 = DateTimeOffset.UnixEpoch;
        var tracker = new UploadStabilityTracker(TimeSpan.FromSeconds(3));
        var e = new LocalEntry { Path = "a.mp4", Length = 1, LastWriteTimeUtc = t0 };
        Assert.False(tracker.IsStable(e, t0));
        Assert.False(tracker.IsStable(e, t0.AddSeconds(2)));
        Assert.True(tracker.IsStable(e, t0.AddSeconds(3)));

        var grown = e with { Length = 2 };
        Assert.False(tracker.IsStable(grown, t0.AddSeconds(4)));
        Assert.True(tracker.IsStable(grown, t0.AddSeconds(7)));
    }
}

public class SyncPathTests
{
    [Theory]
    [InlineData("a/b", "a", true)]
    [InlineData("A/b", "a", true)]
    [InlineData("ab/c", "a", false)]
    [InlineData("a", "a", false)]
    [InlineData("a", "", true)]
    public void IsUnder(string path, string ancestor, bool expected) => Assert.Equal(expected, SyncPath.IsUnder(path, ancestor));

    [Fact]
    public void Parent_and_name()
    {
        Assert.Equal(("a/b", "c.txt"), (SyncPath.Parent("a/b/c.txt"), SyncPath.Name("a/b/c.txt")));
        Assert.Equal((string.Empty, "x"), (SyncPath.Parent("x"), SyncPath.Name("x")));
    }
}
