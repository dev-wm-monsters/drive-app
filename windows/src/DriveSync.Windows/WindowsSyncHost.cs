using DriveSync.Core.Auth;
using DriveSync.Core.Config;
using DriveSync.Core.Drive;
using DriveSync.Core.Sync;
using DriveSync.Windows.CloudFiles;
using DriveSync.Windows.Registration;
using DriveSync.Windows.Storage;
using Google.Apis.Auth.OAuth2;
using Microsoft.Extensions.Logging;

namespace DriveSync.Windows;

/// <summary>
/// Composition root for the Windows client (no UI): auth → Drive client → sync-root registration → cfapi connection
/// → initial sync → 30 s change polling + file-system watcher. The tray app drives it.
/// </summary>
public sealed class WindowsSyncHost : IAsyncDisposable
{
    private readonly DriveAppConfig _config;
    private readonly ILoggerFactory _loggers;
    private readonly ILogger _logger;
    private readonly GoogleAuthService _auth;
    private readonly SyncRootRegistrar _registrar;
    private readonly CloudFilesPlaceholderSystem _placeholders;
    private readonly CloudFilesProvider _provider;
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private UserCredential? _credential;
    private GoogleDriveService? _drive;
    private SyncEngine? _engine;
    private LocalChangeWatcher? _watcher;
    private CancellationTokenSource? _running;
    private Task? _pollLoop;
    private DateTimeOffset _lastRejectNotice = DateTimeOffset.MinValue;

    public WindowsSyncHost(DriveAppConfig config, ILoggerFactory loggers, Func<Uri, Task> openBrowser, string iconResource)
    {
        _config = config;
        _loggers = loggers;
        _logger = loggers.CreateLogger("Sync");
        SyncRootPath = AppPaths.SyncRoot(config);
        _auth = new GoogleAuthService(config, new DpapiTokenStore(AppPaths.TokenFile, config.AppId), openBrowser, loggers.CreateLogger("Auth"));
        _registrar = new SyncRootRegistrar(config, SyncRootPath, iconResource, loggers.CreateLogger("Registration"));
        _placeholders = new CloudFilesPlaceholderSystem(SyncRootPath, AppPaths.PreservedEditsFolder(config), loggers.CreateLogger("Placeholders"));
        var hydration = new HydrationService(() => _drive, loggers.CreateLogger("Hydration"))
        {
            // Bad bytes must not stay in the local cache: flag the file so the next pass dehydrates it.
            ChecksumMismatch = path =>
            {
                _placeholders.MarkNotInSync(path);
                _watcher?.Poke();
            },
        };
        _provider = new CloudFilesProvider(hydration, loggers.CreateLogger("CloudFiles"));
        _provider.ModificationRejected += (_, _) => OnRejected();
        _provider.LocalActivity += (_, _) => _watcher?.Poke();
    }

    public string SyncRootPath { get; }

    public string? Email { get; private set; }

    public bool IsRunning => _engine is not null;

    public SyncStatus Status => _engine?.Status ?? new SyncStatus(SyncState.NeedsLogin, "Not signed in");

    public event EventHandler<SyncStatus>? StatusChanged;

    public event EventHandler<string>? Notice;

    /// <summary>Starts silently with a saved token. Returns false when the user must sign in.</summary>
    public async Task<bool> TryResumeAsync(CancellationToken ct)
    {
        var credential = await _auth.TryRestoreAsync(ct).ConfigureAwait(false);
        if (credential is null)
        {
            return false;
        }

        await StartAsync(credential, ct).ConfigureAwait(false);
        return true;
    }

    public async Task SignInAsync(CancellationToken ct)
    {
        await StopAsync().ConfigureAwait(false);
        var credential = await _auth.SignInAsync(ct).ConfigureAwait(false);
        await StartAsync(credential, ct).ConfigureAwait(false);
    }

    public async Task SyncNowAsync(CancellationToken ct)
    {
        if (_engine is { } engine)
        {
            await engine.PollAsync(ct).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Sign out: stop syncing, rescue files that were never uploaded, unregister the sync root and nav-pane entry and
    /// delete the local folder (everything else lives in Drive), then revoke and forget the token.
    /// Returns the folder that received rescued files, if any.
    /// </summary>
    public async Task<string?> SignOutAsync(CancellationToken ct)
    {
        await StopAsync().ConfigureAwait(false);
        // Any failure before UnregisterAll (a file in use, a read error) aborts the sign-out with nothing deleted.
        var rescued = RescueUnuploadedFiles();
        // Decide what to delete while the placeholders can still be identified; anything else stays on disk.
        var placeholderFiles = Directory.Exists(SyncRootPath)
            ? _placeholders.Scan().Where(e => e.IsPlaceholder && !e.IsDirectory).Select(e => AppPaths.Full(SyncRootPath, e.Path)).ToHashSet(StringComparer.OrdinalIgnoreCase)
            : new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        _registrar.UnregisterAll();
        TryDeleteSyncRootFolder(placeholderFiles);
        await _auth.SignOutAsync(_credential, ct).ConfigureAwait(false);
        _credential = null;
        Email = null;
        RaiseStatus(new SyncStatus(SyncState.NeedsLogin, "Signed out"));
        return rescued;
    }

    /// <summary>"Upload files…": copies files into the root; the normal new-file path uploads and converts them.</summary>
    public void ImportFiles(IEnumerable<string> paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        foreach (var source in paths)
        {
            var name = Path.GetFileName(source);
            var target = Path.Combine(SyncRootPath, name);
            var (stem, ext) = (Path.GetFileNameWithoutExtension(name), Path.GetExtension(name));
            for (var n = 2; File.Exists(target) || Directory.Exists(target); n++)
            {
                target = Path.Combine(SyncRootPath, $"{stem} ({n}){ext}");
            }

            File.Copy(source, target);
        }

        _watcher?.Poke();
    }

    /// <summary>Quit: disconnect but stay registered, so the folder and nav-pane entry remain in Explorer.</summary>
    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _lifecycle.Dispose();
    }

    private async Task StartAsync(UserCredential credential, CancellationToken ct)
    {
        await _lifecycle.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await StartCoreAsync(credential, ct).ConfigureAwait(false);
        }
        catch
        {
            // Leave a clean "not running" state; the caller shows the error and the user can retry.
            _running?.Cancel();
            _watcher?.Dispose();
            _watcher = null;
            _provider.Disconnect();
            _engine?.Dispose();
            _engine = null;
            _drive?.Dispose();
            _drive = null;
            throw;
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    private async Task StartCoreAsync(UserCredential credential, CancellationToken ct)
    {
        {
            _credential = credential;
            _drive = GoogleDriveService.Create(_config, credential, _loggers.CreateLogger("Drive"));
            Email = GoogleAuthService.EmailFromIdToken(credential.Token.IdToken)
                    ?? await _drive.GetUserEmailAsync(ct).ConfigureAwait(false);

            await _registrar.RegisterAsync().ConfigureAwait(false);
            _provider.Connect(SyncRootPath);

            var engine = new SyncEngine(_drive, _placeholders, _loggers.CreateLogger("Engine"));
            engine.StatusChanged += (_, s) => RaiseStatus(s);
            engine.Notice += (_, m) => Notice?.Invoke(this, m);
            _engine = engine;
            _running = new CancellationTokenSource();
            var token = _running.Token;

            _watcher = new LocalChangeWatcher(SyncRootPath, () => _ = RunSafeAsync(async () =>
            {
                await engine.ReconcileAsync(token).ConfigureAwait(false);
                if (engine.HasFilesWaitingToSettle)
                {
                    _watcher?.Poke(); // re-check after the debounce so stable files upload without waiting for the 30 s poll
                }
            }));
            await engine.InitializeAsync(ct).ConfigureAwait(false);
            _placeholders.MarkRootInSync();
            _watcher.Start();
            _pollLoop = PollLoopAsync(engine, token);
        }
    }

    private async Task StopAsync()
    {
        await _lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            _running?.Cancel();
            if (_pollLoop is not null)
            {
                await _pollLoop.ConfigureAwait(false);
            }

            if (_engine is not null)
            {
                await _engine.WhenUploadsIdleAsync().ConfigureAwait(false);
            }

            _watcher?.Dispose();
            _watcher = null;
            _provider.Disconnect();
            _engine?.Dispose();
            _engine = null;
            _drive?.Dispose();
            _drive = null;
            _running?.Dispose();
            _running = null;
            _pollLoop = null;
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    private async Task PollLoopAsync(SyncEngine engine, CancellationToken token)
    {
        using var timer = new PeriodicTimer(_config.PollInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false))
            {
                await RunSafeAsync(() => engine.PollAsync(token)).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // stopping
        }
    }

    private async Task RunSafeAsync(Func<Task> pass)
    {
        try
        {
            await pass().ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // stopping
        }
        catch (DriveException ex)
        {
            _logger.LogWarning("Sync pass: {Kind}", ex.Kind);
            if (ex.Kind == DriveErrorKind.NeedsLogin)
            {
                Notice?.Invoke(this, "Your Google sign-in expired. Choose \"Sign in with Google\" to continue syncing.");
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            _logger.LogWarning("Sync pass failed: {Error} (0x{HResult:X8})", ex.GetType().Name, ex.HResult);
            _logger.LogDebug("Sync pass failed: {Message}", ex.Message);
        }
    }

    private string? RescueUnuploadedFiles()
    {
        if (!Directory.Exists(SyncRootPath))
        {
            return null;
        }

        string? target = null;
        var local = _placeholders.Scan();
        // Placeholders edited in place (not in sync) keep their bytes too.
        foreach (var entry in local.Where(e => e.IsPlaceholder && !e.IsDirectory && !e.InSync))
        {
            if (_placeholders.PreserveLocalChanges(entry) is { } saved)
            {
                target ??= Path.GetDirectoryName(saved);
            }
        }

        foreach (var entry in local.Where(e => !e.IsPlaceholder && !e.IsDirectory))
        {
            target ??= Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                $"{_config.RootFolderName} - not uploaded {DateTime.Now:yyyy-MM-dd HHmmss}");
            var destination = AppPaths.Full(target, entry.Path);
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Move(AppPaths.Full(SyncRootPath, entry.Path), destination);
        }

        return target;
    }

    /// <summary>Deletes the placeholder files found before unregistering and every folder left empty; keeps the rest.</summary>
    private void TryDeleteSyncRootFolder(IReadOnlySet<string> placeholderFiles)
    {
        try
        {
            if (Directory.Exists(SyncRootPath))
            {
                var kept = CloudFilesPlaceholderSystem.DeletePlaceholderTree(SyncRootPath, placeholderFiles.Contains);
                if (kept > 0)
                {
                    _logger.LogWarning("Kept {Count} local file(s) that were not Drive placeholders in the sync folder", kept);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _logger.LogWarning("Could not delete the local folder: {Error}", ex.Message);
        }
    }

    private void OnRejected()
    {
        var now = DateTimeOffset.UtcNow;
        if (now - _lastRejectNotice < TimeSpan.FromSeconds(10))
        {
            return;
        }

        _lastRejectNotice = now;
        Notice?.Invoke(this, $"Items in {_config.RootFolderName} can't be renamed, moved or deleted here. You can add new files.");
    }

    private void RaiseStatus(SyncStatus status) => StatusChanged?.Invoke(this, status);
}
