using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Google.Apis.Auth.OAuth2;
using Google.Apis.Auth.OAuth2.Requests;
using Google.Apis.Auth.OAuth2.Responses;

namespace DriveSync.Core.Auth;

/// <summary>
/// Loopback redirect receiver for Google "Desktop app" OAuth clients: listens on http://127.0.0.1:&lt;random port&gt;/
/// (a raw TcpListener, so no http.sys URL ACL / admin rights are needed), adds a random <c>state</c> to the
/// authorization request and rejects a redirect whose state does not match. PKCE (S256) is added by
/// <see cref="Google.Apis.Auth.OAuth2.Flows.PkceGoogleAuthorizationCodeFlow"/> before the URL reaches us.
/// </summary>
public sealed class LoopbackCodeReceiver : ICodeReceiver, IDisposable
{
    public const string InvalidStateError = "invalid_state";

    private const string SuccessPage =
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>DriveApp</title></head>"
        + "<body style=\"font-family:Segoe UI,sans-serif;margin:3em\"><h2>Signed in.</h2><p>You can close this tab and return to DriveApp.</p></body></html>";

    private const string FailurePage =
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>DriveApp</title></head>"
        + "<body style=\"font-family:Segoe UI,sans-serif;margin:3em\"><h2>Sign-in failed.</h2><p>Return to DriveApp and try again.</p></body></html>";

    private readonly TcpListener _listener;
    private readonly Func<Uri, Task> _openBrowser;
    private readonly TimeSpan _timeout;

    public LoopbackCodeReceiver(Func<Uri, Task> openBrowser, TimeSpan? timeout = null)
    {
        _openBrowser = openBrowser;
        _timeout = timeout ?? TimeSpan.FromMinutes(5);
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        RedirectUri = "http://127.0.0.1:" + Port.ToString(System.Globalization.CultureInfo.InvariantCulture) + "/";
    }

    public int Port { get; }

    public string RedirectUri { get; }

    /// <summary>The state sent with the last authorization request (exposed for tests).</summary>
    public string? ExpectedState { get; private set; }

    public async Task<AuthorizationCodeResponseUrl> ReceiveCodeAsync(AuthorizationCodeRequestUrl url, CancellationToken taskCancellationToken)
    {
        ArgumentNullException.ThrowIfNull(url);
        ExpectedState = Base64Url(RandomNumberGenerator.GetBytes(32));
        url.State = ExpectedState;
        await _openBrowser(url.Build()).ConfigureAwait(false);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(taskCancellationToken);
        timeout.CancelAfter(_timeout);
        while (true)
        {
            using var client = await _listener.AcceptTcpClientAsync(timeout.Token).ConfigureAwait(false);
            var stream = client.GetStream();
            var target = await ReadRequestTargetAsync(stream, timeout.Token).ConfigureAwait(false);
            var query = ExtractCallbackQuery(target);
            if (query is null)
            {
                // favicon.ico, probes, etc.
                await WriteResponseAsync(stream, "404 Not Found", string.Empty, timeout.Token).ConfigureAwait(false);
                continue;
            }

            var response = new AuthorizationCodeResponseUrl(ParseQuery(query));
            if (!string.Equals(response.State, ExpectedState, StringComparison.Ordinal))
            {
                await WriteResponseAsync(stream, "400 Bad Request", FailurePage, timeout.Token).ConfigureAwait(false);
                return new AuthorizationCodeResponseUrl
                {
                    Error = InvalidStateError,
                    ErrorDescription = "The OAuth redirect carried an unexpected state parameter.",
                };
            }

            var ok = string.IsNullOrEmpty(response.Error) && !string.IsNullOrEmpty(response.Code);
            await WriteResponseAsync(stream, ok ? "200 OK" : "400 Bad Request", ok ? SuccessPage : FailurePage, timeout.Token).ConfigureAwait(false);
            return response;
        }
    }

    /// <summary>Returns the query string (without '?') when the request is for the redirect path "/", else null.</summary>
    internal static string? ExtractCallbackQuery(string? requestTarget)
    {
        if (string.IsNullOrEmpty(requestTarget) || !requestTarget.StartsWith('/'))
        {
            return null;
        }

        var q = requestTarget.IndexOf('?', StringComparison.Ordinal);
        var path = q < 0 ? requestTarget : requestTarget[..q];
        if (!string.Equals(path, "/", StringComparison.Ordinal) || q < 0)
        {
            return null;
        }

        return requestTarget[(q + 1)..];
    }

    /// <summary>Decodes application/x-www-form-urlencoded pairs (codes look like "4/0A…" and arrive as "4%2F0A…").</summary>
    internal static Dictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var kv = pair.Split('=', 2);
            static string Decode(string s) => Uri.UnescapeDataString(s.Replace('+', ' '));
            result[Decode(kv[0])] = kv.Length > 1 ? Decode(kv[1]) : string.Empty;
        }

        return result;
    }

    public void Dispose() => _listener.Stop();

    internal static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static async Task<string?> ReadRequestTargetAsync(NetworkStream stream, CancellationToken ct)
    {
        var buffer = new byte[8192];
        var total = 0;
        while (total < buffer.Length)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(total), ct).ConfigureAwait(false);
            if (n == 0)
            {
                break;
            }

            total += n;
            if (Encoding.ASCII.GetString(buffer, 0, total).Contains("\r\n\r\n", StringComparison.Ordinal))
            {
                break;
            }
        }

        var text = Encoding.ASCII.GetString(buffer, 0, total);
        var firstLine = text.Split("\r\n", 2)[0];
        var parts = firstLine.Split(' ');
        return parts.Length >= 2 && parts[0] == "GET" ? parts[1] : null;
    }

    private static async Task WriteResponseAsync(NetworkStream stream, string status, string body, CancellationToken ct)
    {
        var bodyBytes = Encoding.UTF8.GetBytes(body);
        var header = "HTTP/1.1 " + status + "\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: "
            + bodyBytes.Length.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\r\nConnection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(header), ct).ConfigureAwait(false);
        await stream.WriteAsync(bodyBytes, ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }
}
