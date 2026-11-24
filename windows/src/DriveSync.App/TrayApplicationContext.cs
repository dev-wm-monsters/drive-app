using System.Diagnostics;
using DriveSync.Core.Config;
using DriveSync.Core.Drive;
using DriveSync.Core.Sync;
using DriveSync.Windows;
using Microsoft.Extensions.Logging;

namespace DriveSync.App;

/// <summary>
/// Tray UI: status line, Sign in with Google, Open folder, Upload files…, Sync now, Sign out, Start at login, Quit.
/// All work runs in <see cref="WindowsSyncHost"/>; handlers await on the UI thread's synchronization context.
/// </summary>
internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly DriveAppConfig _config;
    private readonly ILogger _logger;
    private readonly WindowsSyncHost _host;
    private readonly NotifyIcon _tray;
    private readonly ToolStripMenuItem _status = new() { Enabled = false };
    private readonly ToolStripMenuItem _signIn = new("Sign in with Google…");
    private readonly ToolStripMenuItem _openFolder = new("Open folder");
    private readonly ToolStripMenuItem _upload = new("Upload files…");
    private readonly ToolStripMenuItem _syncNow = new("Sync now");
    private readonly ToolStripMenuItem _signOut = new("Sign out…");
    private readonly ToolStripMenuItem _startAtLogin = new("Start at login") { CheckOnClick = true };
    private readonly ToolStripMenuItem _quit = new("Quit");
    private readonly SynchronizationContext _ui;
    private bool _busy;

    public TrayApplicationContext(DriveAppConfig config, ILoggerFactory loggers, bool background)
    {
        _config = config;
        _logger = loggers.CreateLogger("Tray");
        var menu = new ContextMenuStrip(); // creating a control installs the WinForms SynchronizationContext
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        _host = new WindowsSyncHost(config, loggers, Program.OpenInShellAsync, Program.IconResource());
        _host.StatusChanged += (_, s) => _ui.Post(_ => Refresh(s), null);
        _host.Notice += (_, m) => _ui.Post(_ => Balloon(m, ToolTipIcon.Info), null);

        menu.Items.AddRange(new ToolStripItem[]
        {
            _status, new ToolStripSeparator(), _signIn, _openFolder, _upload, _syncNow, new ToolStripSeparator(),
            _startAtLogin, _signOut, new ToolStripSeparator(), _quit,
        });
        _signIn.Click += async (_, _) => await SignInAsync();
        _openFolder.Click += (_, _) => OpenFolder();
        _upload.Click += (_, _) => UploadFiles();
        _syncNow.Click += async (_, _) => await GuardAsync("Sync", ct => _host.SyncNowAsync(ct));
        _signOut.Click += async (_, _) => await SignOutAsync();
        _startAtLogin.Checked = StartupRegistration.IsEnabled(config.AppName);
        _startAtLogin.CheckedChanged += (_, _) => StartupRegistration.Set(config.AppName, _startAtLogin.Checked);
        _quit.Click += async (_, _) => await QuitAsync();

        _tray = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = config.AppName,
            ContextMenuStrip = menu,
            Visible = true,
        };
        _tray.DoubleClick += (_, _) => OpenFolder();
        Refresh(new SyncStatus(SyncState.Starting, "Starting…"));
        _ = ResumeAsync(background);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }

        base.Dispose(disposing);
    }

    private async Task ResumeAsync(bool background)
    {
        await GuardAsync("Resume", async ct =>
        {
            if (await _host.TryResumeAsync(ct))
            {
                if (!background)
                {
                    OpenFolder();
                }
            }
            else
            {
                Refresh(new SyncStatus(SyncState.NeedsLogin, "Not signed in"));
                if (!background)
                {
                    Balloon("Sign in with Google to show " + _config.RootFolderName + " in File Explorer.", ToolTipIcon.Info);
                }
            }
        });
    }

    private async Task SignInAsync()
    {
        await GuardAsync("Sign in", async ct =>
        {
            Refresh(new SyncStatus(SyncState.Starting, "Waiting for Google sign-in in your browser…"));
            await _host.SignInAsync(ct);
            OpenFolder();
        });
    }

    private async Task SignOutAsync()
    {
        var answer = MessageBox.Show(
            $"Sign out and remove the {_config.RootFolderName} folder from this PC?\n\n"
            + "Everything stays in Google Drive. Downloaded copies are removed from this PC. "
            + "Files you added that were not uploaded yet are moved to your Documents folder.",
            _config.AppName,
            MessageBoxButtons.OKCancel,
            MessageBoxIcon.Question);
        if (answer != DialogResult.OK)
        {
            return;
        }

        await GuardAsync("Sign out", async ct =>
        {
            var rescued = await _host.SignOutAsync(ct);
            if (rescued is not null)
            {
                Balloon("Files that were not uploaded were moved to " + rescued, ToolTipIcon.Warning);
            }
        });
    }

    private void UploadFiles()
    {
        if (!_host.IsRunning)
        {
            Balloon("Sign in first.", ToolTipIcon.Warning);
            return;
        }

        using var dialog = new OpenFileDialog
        {
            Multiselect = true,
            Title = "Upload files to " + _config.RootFolderName,
            CheckFileExists = true,
        };
        if (dialog.ShowDialog() == DialogResult.OK)
        {
            try
            {
                _host.ImportFiles(dialog.FileNames);
                Balloon($"Uploading {dialog.FileNames.Length} file(s)…", ToolTipIcon.Info);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                _logger.LogWarning("Import failed: {Error}", ex.Message);
                Balloon("Could not add the files: " + ex.Message, ToolTipIcon.Error);
            }
        }
    }

    private void OpenFolder()
    {
        if (Directory.Exists(_host.SyncRootPath))
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{_host.SyncRootPath}\"") { UseShellExecute = true })?.Dispose();
        }
    }

    private async Task QuitAsync()
    {
        _tray.Visible = false;
        await _host.DisposeAsync();
        ExitThread();
    }

    private async Task GuardAsync(string what, Func<CancellationToken, Task> action)
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        Refresh(_host.Status);
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(10));
            await action(cts.Token);
        }
        catch (DriveException ex)
        {
            _logger.LogWarning("{What} failed: {Kind}", what, ex.Kind);
            var message = ex.Kind switch
            {
                DriveErrorKind.NeedsLogin => "Please sign in with Google again.",
                DriveErrorKind.RootNotFound => $"No shared drive named '{_config.SharedDriveName}' is visible to this account.",
                DriveErrorKind.RootAmbiguous => $"Several shared drives are named '{_config.SharedDriveName}'. Set Drive:FolderId in appsettings.json.",
                DriveErrorKind.Network or DriveErrorKind.Server => "Can't reach Google Drive right now.",
                _ => ex.Message,
            };
            Balloon(message, ToolTipIcon.Error);
        }
        catch (OperationCanceledException)
        {
            Balloon(what + " was cancelled.", ToolTipIcon.Warning);
        }
#pragma warning disable CA1031 // Tray handlers must never crash the app; the error is logged and shown.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            _logger.LogError(ex, "{What} failed", what);
            Balloon(what + " failed: " + ex.Message, ToolTipIcon.Error);
        }
        finally
        {
            _busy = false;
            Refresh(_host.Status);
        }
    }

    private void Refresh(SyncStatus status)
    {
        var signedIn = _host.IsRunning && _host.Email is not null;
        _status.Text = signedIn
            ? $"Connected to {_config.RootFolderName} as {_host.Email}" + (status.State == SyncState.Idle ? string.Empty : " — " + status.Message)
            : status.Message;
        _signIn.Visible = !signedIn;
        _signOut.Enabled = signedIn && !_busy;
        _openFolder.Enabled = Directory.Exists(_host.SyncRootPath);
        _upload.Enabled = signedIn;
        _syncNow.Enabled = signedIn && !_busy;
        var tip = $"{_config.AppName}: {status.Message}";
        _tray.Text = tip.Length > 63 ? tip[..63] : tip;
    }

    private void Balloon(string message, ToolTipIcon icon)
    {
        _tray.BalloonTipTitle = _config.AppName;
        _tray.BalloonTipText = message;
        _tray.BalloonTipIcon = icon;
        _tray.ShowBalloonTip(5000);
    }

    private static Icon LoadIcon()
    {
        try
        {
            return (Environment.ProcessPath is { } exe ? Icon.ExtractAssociatedIcon(exe) : null) ?? SystemIcons.Application;
        }
        catch (ArgumentException)
        {
            return SystemIcons.Application;
        }
    }
}
