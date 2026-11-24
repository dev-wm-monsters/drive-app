using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using DriveSync.Core.Config;
using DriveSync.Windows.Interop;
using Microsoft.Extensions.Logging;
using Microsoft.Win32;
using Windows.Win32;
using Windows.Win32.Storage.CloudFilters;
using WinRtProvider = global::Windows.Storage.Provider;

namespace DriveSync.Windows.Registration;

public enum RegistrationMode
{
    /// <summary>StorageProviderSyncRootManager.Register (WinRT): sync root + Explorer nav-pane node in one call.</summary>
    StorageProviderSyncRootManager,

    /// <summary>Fallback: CfRegisterSyncRoot + the documented HKCU namespace-extension keys for the nav pane.</summary>
    CfRegisterSyncRootWithNavPaneKeys,
}

/// <summary>
/// Registers %USERPROFILE%\WakeupMonster as a Cloud Files sync root for an UNPACKAGED app.
/// Primary: Windows.Storage.Provider.StorageProviderSyncRootManager.Register (what Microsoft's CloudMirror sample
/// uses; it needs no package identity for the registration itself — package identity is only needed for manifest-
/// declared shell extensions we don't ship). Fallback if Register throws: CfRegisterSyncRoot plus the nav-pane keys
/// from "Integrate a Cloud Storage Provider" (HKCU only, no admin). Sync-root ID: &lt;App:Id&gt;!&lt;user SID&gt;!&lt;account&gt;.
/// </summary>
public sealed class SyncRootRegistrar
{
    public const string AccountId = "default";

    private const string NavPaneClsidRoot = @"Software\Classes\CLSID\";
    private const string DesktopNameSpace = @"Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\";
    private const string HideDesktopIcons = @"Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel";
    private const string ShellFolderInstanceClsid = "{0E5AAE11-A475-4c5b-AB00-C66DE400274E}";

    private readonly DriveAppConfig _config;
    private readonly string _syncRootPath;
    private readonly string _iconResource;
    private readonly ILogger _logger;

    public SyncRootRegistrar(DriveAppConfig config, string syncRootPath, string iconResource, ILogger logger)
    {
        _config = config;
        _syncRootPath = syncRootPath;
        _iconResource = iconResource;
        _logger = logger;
    }

    public static string UserSid => WindowsIdentity.GetCurrent().User?.Value ?? "S-1-0-0";

    public string IdPrefix => _config.AppId + "!" + UserSid + "!";

    public string SyncRootId => IdPrefix + AccountId;

    /// <summary>Stable per user + app: lets --unregister find the nav-pane CLSID without stored state.</summary>
    public Guid NavPaneClsid => DeterministicGuid("navpane:" + SyncRootId);

    public Guid ProviderId => DeterministicGuid("provider:" + _config.AppId);

    public static string ProviderVersion =>
        typeof(SyncRootRegistrar).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0.0.1";

    public async Task<RegistrationMode> RegisterAsync()
    {
        Directory.CreateDirectory(_syncRootPath);
        try
        {
            if (IsRegisteredWithWinRt())
            {
                _logger.LogInformation("Sync root already registered");
                return RegistrationMode.StorageProviderSyncRootManager;
            }

            await RegisterWithWinRtAsync().ConfigureAwait(false);
            _logger.LogInformation("Registered sync root with StorageProviderSyncRootManager");
            return RegistrationMode.StorageProviderSyncRootManager;
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or ArgumentException or PlatformNotSupportedException or InvalidOperationException)
        {
            _logger.LogWarning("StorageProviderSyncRootManager.Register failed ({Error} 0x{Hr:X8}); falling back to CfRegisterSyncRoot", ex.GetType().Name, ex.HResult);
            RegisterWithCfApi();
            RegisterNavigationPane();
            return RegistrationMode.CfRegisterSyncRootWithNavPaneKeys;
        }
    }

    /// <summary>
    /// Removes every trace: WinRT registrations with our ID prefix, the cfapi sync root, the nav-pane keys.
    /// Never throws; safe when nothing is registered. CfUnregisterSyncRoot fails while a provider is connected, so
    /// callers must disconnect (or the app must not be running) first.
    /// </summary>
    public void UnregisterAll()
    {
        try
        {
            foreach (var root in WinRtProvider.StorageProviderSyncRootManager.GetCurrentSyncRoots())
            {
                if (root.Id.StartsWith(IdPrefix, StringComparison.OrdinalIgnoreCase))
                {
                    WinRtProvider.StorageProviderSyncRootManager.Unregister(root.Id);
                    _logger.LogInformation("Unregistered sync root (WinRT)");
                }
            }
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or ArgumentException or PlatformNotSupportedException)
        {
            _logger.LogWarning("WinRT unregister: {Error} 0x{Hr:X8}", ex.GetType().Name, ex.HResult);
        }

        if (Directory.Exists(_syncRootPath))
        {
            var hr = PInvoke.CfUnregisterSyncRoot(_syncRootPath);
            if (hr.Failed && hr.Value != CfInterop.ErrorNotACloudFile)
            {
                _logger.LogInformation("CfUnregisterSyncRoot: 0x{Hr:X8} (not registered or already removed)", hr.Value);
            }
        }

        UnregisterNavigationPane();
    }

    private bool IsRegisteredWithWinRt()
    {
        foreach (var root in WinRtProvider.StorageProviderSyncRootManager.GetCurrentSyncRoots())
        {
            if (!string.Equals(root.Id, SyncRootId, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (string.Equals(root.Path?.Path?.TrimEnd('\\'), _syncRootPath.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            // Same ID, different folder (Sync:RootFolderName changed): replace it.
            WinRtProvider.StorageProviderSyncRootManager.Unregister(root.Id);
        }

        return false;
    }

    private async Task RegisterWithWinRtAsync()
    {
        if (!WinRtProvider.StorageProviderSyncRootManager.IsSupported())
        {
            throw new PlatformNotSupportedException("Cloud Files sync roots are not supported on this system.");
        }

        var folder = await global::Windows.Storage.StorageFolder.GetFolderFromPathAsync(_syncRootPath).AsTask().ConfigureAwait(false);
        var info = new WinRtProvider.StorageProviderSyncRootInfo
        {
            Id = SyncRootId,
            Path = folder,
            DisplayNameResource = _config.RootFolderName,
            IconResource = _iconResource,
            HydrationPolicy = WinRtProvider.StorageProviderHydrationPolicy.Full,
            HydrationPolicyModifier = WinRtProvider.StorageProviderHydrationPolicyModifier.AutoDehydrationAllowed,
            PopulationPolicy = WinRtProvider.StorageProviderPopulationPolicy.AlwaysFull,
            InSyncPolicy = WinRtProvider.StorageProviderInSyncPolicy.FileReadOnlyAttribute
                           | WinRtProvider.StorageProviderInSyncPolicy.FileLastWriteTime
                           | WinRtProvider.StorageProviderInSyncPolicy.PreserveInsyncForSyncEngine,
            HardlinkPolicy = WinRtProvider.StorageProviderHardlinkPolicy.None,
            ShowSiblingsAsGroup = false,
            Version = ProviderVersion,
            AllowPinning = true,
            ProviderId = ProviderId,
            Context = global::Windows.Security.Cryptography.CryptographicBuffer.ConvertStringToBinary(
                SyncRootId, global::Windows.Security.Cryptography.BinaryStringEncoding.Utf8),
        };
        WinRtProvider.StorageProviderSyncRootManager.Register(info);
    }

    private unsafe void RegisterWithCfApi()
    {
        var identity = Encoding.UTF8.GetBytes(SyncRootId);
        fixed (char* name = _config.AppName)
        fixed (char* version = ProviderVersion)
        fixed (byte* id = identity)
        {
            var registration = new CF_SYNC_REGISTRATION
            {
                StructSize = (uint)sizeof(CF_SYNC_REGISTRATION),
                ProviderName = name,
                ProviderVersion = version,
                SyncRootIdentity = id,
                SyncRootIdentityLength = (uint)identity.Length,
                ProviderId = ProviderId,
            };
            var policies = new CF_SYNC_POLICIES
            {
                StructSize = (uint)sizeof(CF_SYNC_POLICIES),
                Hydration = new CF_HYDRATION_POLICY
                {
                    Primary = CF_HYDRATION_POLICY_PRIMARY.CF_HYDRATION_POLICY_FULL,
                    Modifier = CF_HYDRATION_POLICY_MODIFIER.CF_HYDRATION_POLICY_MODIFIER_AUTO_DEHYDRATION_ALLOWED,
                },
                Population = new CF_POPULATION_POLICY { Primary = CF_POPULATION_POLICY_PRIMARY.CF_POPULATION_POLICY_ALWAYS_FULL },
                InSync = CF_INSYNC_POLICY.CF_INSYNC_POLICY_TRACK_FILE_READONLY_ATTRIBUTE
                         | CF_INSYNC_POLICY.CF_INSYNC_POLICY_TRACK_FILE_LAST_WRITE_TIME
                         | CF_INSYNC_POLICY.CF_INSYNC_POLICY_PRESERVE_INSYNC_FOR_SYNC_ENGINE,
                HardLink = CF_HARDLINK_POLICY.CF_HARDLINK_POLICY_NONE,
            };
            CfInterop.Check(
                PInvoke.CfRegisterSyncRoot(_syncRootPath, registration, policies, CF_REGISTER_FLAGS.CF_REGISTER_FLAG_UPDATE | CF_REGISTER_FLAGS.CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT),
                "CfRegisterSyncRoot");
        }

        _logger.LogInformation("Registered sync root with CfRegisterSyncRoot");
    }

    /// <summary>Steps 1–12 of learn.microsoft.com/windows/win32/shell/integrate-cloud-storage, under HKCU.</summary>
    private void RegisterNavigationPane()
    {
        var clsid = NavPaneClsid.ToString("B");
        using (var key = Registry.CurrentUser.CreateSubKey(NavPaneClsidRoot + clsid))
        {
            key.SetValue(string.Empty, _config.RootFolderName, RegistryValueKind.String);
            key.SetValue("System.IsPinnedToNameSpaceTree", 1, RegistryValueKind.DWord);
            key.SetValue("SortOrderIndex", 0x42, RegistryValueKind.DWord);
            using (var icon = key.CreateSubKey("DefaultIcon"))
            {
                icon.SetValue(string.Empty, _iconResource, RegistryValueKind.ExpandString);
            }

            using (var server = key.CreateSubKey("InProcServer32"))
            {
                server.SetValue(string.Empty, @"%systemroot%\system32\shell32.dll", RegistryValueKind.ExpandString);
            }

            using (var instance = key.CreateSubKey("Instance"))
            {
                instance.SetValue("CLSID", ShellFolderInstanceClsid, RegistryValueKind.String);
                using var bag = instance.CreateSubKey("InitPropertyBag");
                bag.SetValue("Attributes", 0x11, RegistryValueKind.DWord);
                bag.SetValue("TargetFolderPath", _syncRootPath, RegistryValueKind.ExpandString);
            }

            using (var shellFolder = key.CreateSubKey("ShellFolder"))
            {
                shellFolder.SetValue("FolderValueFlags", 0x28, RegistryValueKind.DWord);
                shellFolder.SetValue("Attributes", unchecked((int)0xF080004D), RegistryValueKind.DWord);
            }
        }

        using (var ns = Registry.CurrentUser.CreateSubKey(DesktopNameSpace + clsid))
        {
            ns.SetValue(string.Empty, _config.RootFolderName, RegistryValueKind.String);
        }

        using (var hide = Registry.CurrentUser.CreateSubKey(HideDesktopIcons))
        {
            hide.SetValue(clsid, 1, RegistryValueKind.DWord);
        }

        _logger.LogInformation("Added the Explorer navigation-pane entry (HKCU)");
    }

    private void UnregisterNavigationPane()
    {
        var clsid = NavPaneClsid.ToString("B");
        try
        {
            Registry.CurrentUser.DeleteSubKeyTree(NavPaneClsidRoot + clsid, throwOnMissingSubKey: false);
            Registry.CurrentUser.DeleteSubKeyTree(DesktopNameSpace + clsid, throwOnMissingSubKey: false);
            using var hide = Registry.CurrentUser.OpenSubKey(HideDesktopIcons, writable: true);
            hide?.DeleteValue(clsid, throwOnMissingValue: false);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            _logger.LogWarning("Nav-pane cleanup: {Error}", ex.GetType().Name);
        }
    }

    private static Guid DeterministicGuid(string seed)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(seed));
        var bytes = hash.AsSpan(0, 16).ToArray();
        bytes[7] = (byte)((bytes[7] & 0x0F) | 0x50); // version 5-style marker
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80); // RFC 4122 variant
        return new Guid(bytes);
    }
}
