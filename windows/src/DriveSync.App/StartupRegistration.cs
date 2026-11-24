using Microsoft.Win32;

namespace DriveSync.App;

/// <summary>"Start at login": HKCU\Software\Microsoft\Windows\CurrentVersion\Run\&lt;App:Name&gt;.</summary>
internal static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool IsEnabled(string appName)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(appName) is string;
    }

    public static void Set(string appName, bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled)
        {
            key.SetValue(appName, $"\"{Environment.ProcessPath}\" {Program.BackgroundSwitch}", RegistryValueKind.String);
        }
        else
        {
            key.DeleteValue(appName, throwOnMissingValue: false);
        }
    }
}
