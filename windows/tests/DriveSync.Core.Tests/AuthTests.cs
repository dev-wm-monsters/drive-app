using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using DriveSync.Core.Auth;
using DriveSync.Core.Config;
using DriveSync.Core.Tests.Fakes;
using Google.Apis.Auth.OAuth2.Requests;
using Microsoft.Extensions.Logging.Abstractions;

namespace DriveSync.Core.Tests;

public class AuthTests
{
    private static readonly DriveAppConfig Config = new()
    {
        GoogleClientId = "123-abc.apps.googleusercontent.com",
        GoogleClientSecret = "desktop-secret",
    };

    [Fact]
    public void Authorization_url_uses_pkce_s256_scopes_and_offline_access()
    {
        var auth = new GoogleAuthService(Config, new InMemoryTokenStore(), _ => Task.CompletedTask, NullLogger.Instance);
        var flow = auth.CreateFlow();
        var request = flow.CreateAuthorizationCodeRequest("http://127.0.0.1:5555/", out var verifier);
        var url = request.Build();
        var q = QueryString.Parse(url);

        Assert.Equal("accounts.google.com", url.Host);
        Assert.Equal("S256", q["code_challenge_method"]);
        var expectedChallenge = LoopbackCodeReceiver.Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        Assert.Equal(expectedChallenge, q["code_challenge"]);
        Assert.InRange(verifier.Length, 43, 128);
        Assert.Equal("code", q["response_type"]);
        Assert.Equal("http://127.0.0.1:5555/", q["redirect_uri"]);
        Assert.Equal("offline", q["access_type"]);
        Assert.Equal(new[] { "email", "https://www.googleapis.com/auth/drive", "openid" }, q["scope"].Split(' ').Order(StringComparer.Ordinal));
    }

    [Fact]
    public async Task Code_exchange_sends_verifier_secret_and_redirect_and_persists_token()
    {
        var http = new FakeHttpHandler((_, _) => FakeHttpHandler.Json(
            "{\"access_token\":\"ya29.A\",\"refresh_token\":\"1//R\",\"expires_in\":3600,\"token_type\":\"Bearer\",\"id_token\":\"" + IdToken("me@example.com") + "\"}"));
        var store = new InMemoryTokenStore();
        var auth = new GoogleAuthService(Config, store, _ => Task.CompletedTask, NullLogger.Instance, new FakeHttpClientFactory(http));
        var flow = auth.CreateFlow();

        var token = await flow.ExchangeCodeForTokenAsync(GoogleAuthService.UserKey, "the-code", "verifier-123", "http://127.0.0.1:5555/", CancellationToken.None);

        var form = QueryString.Parse(new Uri("http://x/?" + http.Requests.Single().Body));
        Assert.Equal("https://oauth2.googleapis.com/token", http.Requests[0].Uri.GetLeftPart(UriPartial.Path));
        Assert.Equal("the-code", form["code"]);
        Assert.Equal("verifier-123", form["code_verifier"]);
        Assert.Equal("desktop-secret", form["client_secret"]);
        Assert.Equal("authorization_code", form["grant_type"]);
        Assert.Equal("http://127.0.0.1:5555/", form["redirect_uri"]);
        Assert.Equal("me@example.com", GoogleAuthService.EmailFromIdToken(token.IdToken));
        Assert.Contains("1//R", store.Load(), StringComparison.Ordinal);

        var restored = await auth.TryRestoreAsync(CancellationToken.None);
        Assert.NotNull(restored);
        Assert.Equal("1//R", restored!.Token.RefreshToken);
    }

    [Fact]
    public async Task TryRestore_without_token_returns_null()
    {
        var auth = new GoogleAuthService(Config, new InMemoryTokenStore(), _ => Task.CompletedTask, NullLogger.Instance);
        Assert.Null(await auth.TryRestoreAsync(CancellationToken.None));
    }

    [Fact]
    public async Task Loopback_receiver_returns_code_when_state_matches()
    {
        using var receiver = new LoopbackCodeReceiver(uri => SimulateBrowserAsync(uri, tamperState: false));
        Assert.StartsWith("http://127.0.0.1:", receiver.RedirectUri, StringComparison.Ordinal);
        var response = await receiver.ReceiveCodeAsync(new AuthorizationCodeRequestUrl(new Uri("https://accounts.google.com/o/oauth2/v2/auth")) { RedirectUri = receiver.RedirectUri }, CancellationToken.None);
        Assert.Equal("4/abc", response.Code);
        Assert.Null(response.Error);
    }

    [Fact]
    public async Task Loopback_receiver_rejects_wrong_state()
    {
        using var receiver = new LoopbackCodeReceiver(uri => SimulateBrowserAsync(uri, tamperState: true));
        var response = await receiver.ReceiveCodeAsync(new AuthorizationCodeRequestUrl(new Uri("https://accounts.google.com/o/oauth2/v2/auth")) { RedirectUri = receiver.RedirectUri }, CancellationToken.None);
        Assert.Equal(LoopbackCodeReceiver.InvalidStateError, response.Error);
        Assert.Null(response.Code);
    }

    [Theory]
    [InlineData("/?code=1&state=2", "code=1&state=2")]
    [InlineData("/favicon.ico", null)]
    [InlineData("/", null)]
    [InlineData("/other?code=1", null)]
    public void Callback_path_parsing(string target, string? expected) =>
        Assert.Equal(expected, LoopbackCodeReceiver.ExtractCallbackQuery(target));

    [Fact]
    public void Email_from_malformed_id_token_is_null()
    {
        Assert.Null(GoogleAuthService.EmailFromIdToken("nope"));
        Assert.Null(GoogleAuthService.EmailFromIdToken(null));
    }

    private static string IdToken(string email)
    {
        static string B64(string s) => LoopbackCodeReceiver.Base64Url(Encoding.UTF8.GetBytes(s));
        return B64("{\"alg\":\"RS256\"}") + "." + B64("{\"email\":\"" + email + "\"}") + ".sig";
    }

    /// <summary>Plays the browser: reads the authorization URL's redirect_uri/state and calls the loopback server.</summary>
    private static Task SimulateBrowserAsync(Uri authorizationUrl, bool tamperState)
    {
        var q = QueryString.Parse(authorizationUrl);
        var redirect = new Uri(q["redirect_uri"]);
        var state = tamperState ? "evil" : q["state"];
        _ = Task.Run(async () =>
        {
            using var client = new TcpClient();
            await client.ConnectAsync(IPAddress.Loopback, redirect.Port);
            var stream = client.GetStream();
            // A stray favicon request first, on its own connection, must not break the flow.
            var req = $"GET /?code=4%2Fabc&state={Uri.EscapeDataString(state)} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
            await stream.WriteAsync(Encoding.ASCII.GetBytes(req));
            var buffer = new byte[4096];
            _ = await stream.ReadAsync(buffer);
        });
        return Task.CompletedTask;
    }
}
