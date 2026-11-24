using System.Diagnostics;
using DriveSync.Core.Config;
using DriveSync.Windows.Registration;
using DriveSync.Windows.Storage;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace DriveSync.App;

internal static class Program
{
    /// <summary>Used by the HKCU Run entry: start in the tray without opening Explorer.</summary>
    public const string BackgroundSwitch = "--background";

    /// <summary>Used by the uninstaller (after taskkill): remove sync root + nav-pane entry, no UI, always exit 0.</summary>
    public const string UnregisterSwitch = "--unregister";

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains(UnregisterSwitch, StringComparer.OrdinalIgnoreCase))
        {
            return RunUnregister();
        }

        DriveAppConfig config;
        try
        {
            config = DriveAppConfig.FromConfiguration(LoadConfiguration());
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or FormatException or UnauthorizedAccessException)
        {
            // A hand-edited appsettings.json with a JSON error: say so instead of crashing silently.
            MessageBox.Show("appsettings.json next to DriveSync.App.exe could not be read:\n\n" + ex.Message, "DriveApp", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        using var loggers = CreateLoggers();
        var logger = loggers.CreateLogger("App");

        using var mutex = new Mutex(initiallyOwned: true, $@"Local\{config.AppId}.SingleInstance", out var isFirst);
        if (!isFirst)
        {
            logger.LogInformation("Another instance is already running; exiting");
            return 0;
        }

        ApplicationConfiguration.Initialize();
        var problems = config.Validate();
        if (problems.Count > 0)
        {
            logger.LogError("Invalid configuration: {Problems}", string.Join(" | ", problems));
            MessageBox.Show(
                "DriveApp is not configured:\n\n• " + string.Join("\n• ", problems) + "\n\nEdit appsettings.json next to DriveSync.App.exe.",
                config.AppName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }

        logger.LogInformation("Starting {App} {Version}", config.AppName, SyncRootRegistrar.ProviderVersion);
        using var context = new TrayApplicationContext(config, loggers, background: args.Contains(BackgroundSwitch, StringComparer.OrdinalIgnoreCase));
        Application.Run(context);
        return 0;
    }

    private static int RunUnregister()
    {
        try
        {
            DriveAppConfig config;
            try
            {
                config = DriveAppConfig.FromConfiguration(LoadConfiguration());
            }
            catch (Exception ex) when (ex is IOException or InvalidDataException or FormatException or UnauthorizedAccessException)
            {
                config = new DriveAppConfig();
            }

            using var loggers = CreateLoggers();
            var logger = loggers.CreateLogger("Unregister");
            logger.LogInformation("Unregistering sync root (uninstall)");
            var root = AppPaths.SyncRoot(config);
            new SyncRootRegistrar(config, root, IconResource(), logger).UnregisterAll();
            StartupRegistration.Set(config.AppName, enabled: false);
        }
#pragma warning disable CA1031 // The uninstaller needs exit code 0 no matter what.
        catch (Exception)
#pragma warning restore CA1031
        {
            // swallow: nothing registered, registry locked, etc.
        }

        return 0;
    }

    internal static IConfiguration LoadConfiguration() =>
        new ConfigurationBuilder()
            .SetBasePath(AppContext.BaseDirectory)
            .AddJsonFile("appsettings.json", optional: true, reloadOnChange: false)
            .AddEnvironmentVariables("DRIVEAPP_") // e.g. DRIVEAPP_Google__ClientId for local testing
            .Build();

    internal static string IconResource() => (Environment.ProcessPath ?? "DriveSync.App.exe") + ",0";

    internal static Task OpenInShellAsync(Uri uri)
    {
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true })?.Dispose();
        return Task.CompletedTask;
    }

    private static ILoggerFactory CreateLoggers()
    {
        var minimum = Environment.GetEnvironmentVariable("DRIVEAPP_DEBUG") == "1" ? LogLevel.Debug : LogLevel.Information;
        return LoggerFactory.Create(b => b.SetMinimumLevel(minimum).AddProvider(new FileLoggerProvider(AppPaths.LogDirectory, minimum)));
    }
}
