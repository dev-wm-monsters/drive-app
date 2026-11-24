using DriveSync.Core.Config;

namespace DriveSync.Windows.Storage;

/// <summary>Well-known locations. Sync root: %USERPROFILE%\&lt;Sync:RootFolderName&gt;; app data: %LOCALAPPDATA%\WakeupMonster\DriveApp.</summary>
public static class AppPaths
{
    public static string DataDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WakeupMonster", "DriveApp");

    public static string TokenFile => Path.Combine(DataDirectory, "token.bin");

    public static string LogDirectory => Path.Combine(DataDirectory, "logs");

    public static string SyncRoot(DriveAppConfig config)
    {
        ArgumentNullException.ThrowIfNull(config);
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), config.RootFolderName);
    }

    /// <summary>Converts a '/'-separated sync-relative path to a full Windows path.</summary>
    public static string Full(string syncRoot, string relativePath) =>
        relativePath.Length == 0 ? syncRoot : Path.Combine(syncRoot, relativePath.Replace('/', '\\'));
}
