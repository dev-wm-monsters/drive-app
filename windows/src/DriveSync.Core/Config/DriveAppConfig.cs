using Microsoft.Extensions.Configuration;

namespace DriveSync.Core.Config;

/// <summary>
/// Windows app configuration (Contract v2, "Identity / config"): appsettings.json keys
/// Google:ClientId, Google:ClientSecret, Drive:SharedDriveName, Drive:FolderId, Sync:RootFolderName, App:Name, App:Id.
/// </summary>
public sealed record DriveAppConfig
{
    public const string DefaultSharedDriveName = "WakeupMonster";

    public string GoogleClientId { get; init; } = string.Empty;
    public string GoogleClientSecret { get; init; } = string.Empty;
    public string SharedDriveName { get; init; } = DefaultSharedDriveName;
    public string FolderId { get; init; } = string.Empty;
    public string RootFolderName { get; init; } = DefaultSharedDriveName;
    public string AppName { get; init; } = "DriveApp";
    public string AppId { get; init; } = "WakeupMonster.DriveApp.Dev";
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(30);

    public static IReadOnlyList<string> Scopes { get; } =
        new[] { "https://www.googleapis.com/auth/drive", "openid", "email" };

    /// <summary>A non-empty FolderId overrides the shared-drive name.</summary>
    public bool UsesFolderId => !string.IsNullOrWhiteSpace(FolderId);

    public static DriveAppConfig FromConfiguration(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        static string Get(IConfiguration c, string key, string fallback) =>
            c[key] is { } v ? v.Trim() : fallback;

        return new DriveAppConfig
        {
            GoogleClientId = Get(configuration, "Google:ClientId", string.Empty),
            GoogleClientSecret = Get(configuration, "Google:ClientSecret", string.Empty),
            SharedDriveName = Get(configuration, "Drive:SharedDriveName", DefaultSharedDriveName),
            FolderId = Get(configuration, "Drive:FolderId", string.Empty),
            RootFolderName = Get(configuration, "Sync:RootFolderName", DefaultSharedDriveName),
            AppName = Get(configuration, "App:Name", "DriveApp"),
            AppId = Get(configuration, "App:Id", "WakeupMonster.DriveApp.Dev"),
        };
    }

    /// <summary>Returns human-readable problems; empty when the config is usable.</summary>
    public IReadOnlyList<string> Validate()
    {
        var errors = new List<string>();
        if (string.IsNullOrWhiteSpace(GoogleClientId))
        {
            errors.Add("Google:ClientId is empty. Create a 'Desktop app' OAuth client and put its ID in appsettings.json.");
        }
        else if (!GoogleClientId.EndsWith(".apps.googleusercontent.com", StringComparison.Ordinal))
        {
            errors.Add("Google:ClientId does not look like a Google OAuth client ID (*.apps.googleusercontent.com).");
        }

        if (string.IsNullOrWhiteSpace(GoogleClientSecret))
        {
            errors.Add("Google:ClientSecret is empty. Desktop OAuth clients have a (non-confidential) secret; it is required at token exchange.");
        }

        if (!UsesFolderId && string.IsNullOrWhiteSpace(SharedDriveName))
        {
            errors.Add("Set Drive:SharedDriveName or Drive:FolderId.");
        }

        if (UsesFolderId && FolderId.Any(c => !(char.IsAsciiLetterOrDigit(c) || c is '-' or '_')))
        {
            errors.Add("Drive:FolderId contains characters that are not valid in a Drive ID.");
        }

        if (string.IsNullOrWhiteSpace(RootFolderName) || RootFolderName.IndexOfAny(InvalidFolderNameChars) >= 0
            || RootFolderName.EndsWith('.') || RootFolderName.EndsWith(' '))
        {
            errors.Add("Sync:RootFolderName must be a valid single Windows folder name.");
        }

        if (string.IsNullOrWhiteSpace(AppId) || AppId.Contains('!', StringComparison.Ordinal) || AppId.Any(char.IsWhiteSpace))
        {
            errors.Add("App:Id must be non-empty and contain no '!' or whitespace (it prefixes the sync-root ID).");
        }

        if (string.IsNullOrWhiteSpace(AppName))
        {
            errors.Add("App:Name must not be empty.");
        }

        return errors;
    }

    private static readonly char[] InvalidFolderNameChars = { '/', '\\', ':', '*', '?', '"', '<', '>', '|', '\0' };
}
