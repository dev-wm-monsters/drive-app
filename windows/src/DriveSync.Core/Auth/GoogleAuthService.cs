using System.Text;
using System.Text.Json;
using DriveSync.Core.Config;
using Google.Apis.Auth.OAuth2;
using Google.Apis.Auth.OAuth2.Flows;
using Microsoft.Extensions.Logging;

namespace DriveSync.Core.Auth;

/// <summary>
/// Google OAuth for the Windows "Desktop app" client: authorization code + PKCE (S256, via Google.Apis.Auth's
/// <see cref="PkceGoogleAuthorizationCodeFlow"/>) + state (our <see cref="LoopbackCodeReceiver"/>), loopback redirect
/// http://127.0.0.1:&lt;port&gt;/, client secret sent at token exchange. Tokens persist only through <see cref="ITokenStore"/>.
/// </summary>
public sealed class GoogleAuthService
{
    public const string UserKey = "user";

    private readonly DriveAppConfig _config;
    private readonly ITokenStore _store;
    private readonly Func<Uri, Task> _openBrowser;
    private readonly ILogger _logger;
    private readonly Google.Apis.Http.IHttpClientFactory? _httpClientFactory;

    public GoogleAuthService(
        DriveAppConfig config,
        ITokenStore store,
        Func<Uri, Task> openBrowser,
        ILogger logger,
        Google.Apis.Http.IHttpClientFactory? httpClientFactory = null)
    {
        _config = config;
        _store = store;
        _openBrowser = openBrowser;
        _logger = logger;
        _httpClientFactory = httpClientFactory;
    }

    public PkceGoogleAuthorizationCodeFlow CreateFlow()
    {
        var initializer = new GoogleAuthorizationCodeFlow.Initializer
        {
            ClientSecrets = new ClientSecrets { ClientId = _config.GoogleClientId, ClientSecret = _config.GoogleClientSecret },
            Scopes = DriveAppConfig.Scopes,
            DataStore = new TokenStoreDataStore(_store),
            Prompt = "select_account consent",
        };
        if (_httpClientFactory is not null)
        {
            initializer.HttpClientFactory = _httpClientFactory;
        }

        return new PkceGoogleAuthorizationCodeFlow(initializer);
    }

    /// <summary>Restores a saved session without UI; null when there is nothing usable (then show "Sign in").</summary>
    public async Task<UserCredential?> TryRestoreAsync(CancellationToken cancellationToken)
    {
        var flow = CreateFlow();
        var token = await flow.LoadTokenAsync(UserKey, cancellationToken).ConfigureAwait(false);
        if (token is null || string.IsNullOrEmpty(token.RefreshToken))
        {
            return null;
        }

        return new UserCredential(flow, UserKey, token);
    }

    /// <summary>Interactive sign-in in the default browser. Replaces any stored token.</summary>
    public async Task<UserCredential> SignInAsync(CancellationToken cancellationToken)
    {
        _store.Clear();
        var flow = CreateFlow();
        using var receiver = new LoopbackCodeReceiver(_openBrowser);
        var app = new AuthorizationCodeInstalledApp(flow, receiver);
        var credential = await app.AuthorizeAsync(UserKey, cancellationToken).ConfigureAwait(false);
        _logger.LogInformation("Signed in to Google");
        return credential;
    }

    /// <summary>Revokes the refresh token (best effort) and forgets it locally.</summary>
    public async Task SignOutAsync(UserCredential? credential, CancellationToken cancellationToken)
    {
        if (credential is not null)
        {
            try
            {
                await credential.RevokeTokenAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogWarning("Token revocation failed ({Error}); clearing the local token anyway", ex.GetType().Name);
            }
        }

        _store.Clear();
    }

    /// <summary>
    /// Reads the "email" claim of an ID token received directly from Google's token endpoint over TLS
    /// (OIDC Core 3.1.3.7 allows skipping signature validation in that case). Display only.
    /// </summary>
    public static string? EmailFromIdToken(string? idToken)
    {
        if (string.IsNullOrEmpty(idToken))
        {
            return null;
        }

        var parts = idToken.Split('.');
        if (parts.Length < 2)
        {
            return null;
        }

        try
        {
            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + ((4 - (payload.Length % 4)) % 4), '=');
            using var doc = JsonDocument.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(payload)));
            return doc.RootElement.TryGetProperty("email", out var email) && email.ValueKind == JsonValueKind.String ? email.GetString() : null;
        }
        catch (Exception ex) when (ex is FormatException or JsonException)
        {
            return null;
        }
    }
}
