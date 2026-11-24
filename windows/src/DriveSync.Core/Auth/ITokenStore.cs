using Google.Apis.Json;
using Google.Apis.Util.Store;

namespace DriveSync.Core.Auth;

/// <summary>
/// Persists ONE serialized OAuth token (Google TokenResponse JSON: access/refresh/id token, expiry).
/// Windows: DpapiTokenStore (CurrentUser DPAPI) at %LOCALAPPDATA%\WakeupMonster\DriveApp\token.bin.
/// </summary>
public interface ITokenStore
{
    string? Load();

    void Save(string serializedToken);

    void Clear();
}

/// <summary>Process-local store for tests and for "don't remember me" scenarios.</summary>
public sealed class InMemoryTokenStore : ITokenStore
{
    private readonly object _gate = new();
    private string? _value;

    public string? Load()
    {
        lock (_gate)
        {
            return _value;
        }
    }

    public void Save(string serializedToken)
    {
        lock (_gate)
        {
            _value = serializedToken;
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            _value = null;
        }
    }
}

/// <summary>
/// Adapts <see cref="ITokenStore"/> to Google's <see cref="IDataStore"/> so the Google auth flow (refresh, persistence)
/// writes through our protected store instead of its default plaintext FileDataStore. Single-user: keys are ignored.
/// </summary>
public sealed class TokenStoreDataStore : IDataStore
{
    private readonly ITokenStore _store;

    public TokenStoreDataStore(ITokenStore store) => _store = store;

    public Task StoreAsync<T>(string key, T value)
    {
        _store.Save(NewtonsoftJsonSerializer.Instance.Serialize(value));
        return Task.CompletedTask;
    }

    public Task DeleteAsync<T>(string key)
    {
        _store.Clear();
        return Task.CompletedTask;
    }

    public Task<T> GetAsync<T>(string key)
    {
        var json = _store.Load();
        return Task.FromResult(json is null ? default! : NewtonsoftJsonSerializer.Instance.Deserialize<T>(json));
    }

    public Task ClearAsync()
    {
        _store.Clear();
        return Task.CompletedTask;
    }
}
