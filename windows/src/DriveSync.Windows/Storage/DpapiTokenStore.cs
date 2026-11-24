using System.Security.Cryptography;
using System.Text;
using DriveSync.Core.Auth;

namespace DriveSync.Windows.Storage;

/// <summary>
/// Token store encrypted with DPAPI (CurrentUser scope + app-specific entropy) at
/// %LOCALAPPDATA%\WakeupMonster\DriveApp\token.bin. Only this Windows user can decrypt it.
/// </summary>
public sealed class DpapiTokenStore : ITokenStore
{
    private readonly string _path;
    private readonly byte[] _entropy;
    private readonly object _gate = new();

    public DpapiTokenStore(string path, string appId)
    {
        _path = path;
        _entropy = Encoding.UTF8.GetBytes("WakeupMonster.DriveApp.token:" + appId);
    }

    public string? Load()
    {
        lock (_gate)
        {
            if (!File.Exists(_path))
            {
                return null;
            }

            try
            {
                var plain = ProtectedData.Unprotect(File.ReadAllBytes(_path), _entropy, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(plain);
            }
            catch (CryptographicException)
            {
                // Copied from another user/machine or corrupted: behave as signed out.
                return null;
            }
        }
    }

    public void Save(string serializedToken)
    {
        lock (_gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var cipher = ProtectedData.Protect(Encoding.UTF8.GetBytes(serializedToken), _entropy, DataProtectionScope.CurrentUser);
            var temp = _path + ".tmp";
            File.WriteAllBytes(temp, cipher);
            File.Move(temp, _path, overwrite: true);
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            if (File.Exists(_path))
            {
                File.Delete(_path);
            }
        }
    }
}
