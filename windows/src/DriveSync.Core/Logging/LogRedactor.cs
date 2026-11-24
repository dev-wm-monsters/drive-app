using System.Text.RegularExpressions;

namespace DriveSync.Core.Logging;

/// <summary>
/// Last line of defence for log files: masks OAuth tokens, auth codes and resumable-upload session IDs if they ever
/// end up in a message (exception texts can contain request URLs). Contract: never log tokens, codes, upload URLs.
/// </summary>
public static partial class LogRedactor
{
    public const string Mask = "[redacted]";

    public static string Redact(string? message)
    {
        if (string.IsNullOrEmpty(message))
        {
            return message ?? string.Empty;
        }

        var s = BearerRegex().Replace(message, "Bearer " + Mask);
        s = AccessTokenRegex().Replace(s, Mask);
        s = RefreshTokenRegex().Replace(s, Mask);
        s = QueryParamRegex().Replace(s, m => m.Groups[1].Value + "=" + Mask);
        s = JsonTokenRegex().Replace(s, m => "\"" + m.Groups[1].Value + "\":\"" + Mask + "\"");
        return s;
    }

    [GeneratedRegex(@"Bearer\s+[A-Za-z0-9\-._~+/]+=*", RegexOptions.CultureInvariant)]
    private static partial Regex BearerRegex();

    [GeneratedRegex(@"ya29\.[A-Za-z0-9\-._~+/]+", RegexOptions.CultureInvariant)]
    private static partial Regex AccessTokenRegex();

    [GeneratedRegex(@"\b1//[A-Za-z0-9\-._~+/]+", RegexOptions.CultureInvariant)]
    private static partial Regex RefreshTokenRegex();

    [GeneratedRegex(@"\b(code|access_token|refresh_token|id_token|upload_id|client_secret|code_verifier)=[^&\s""']+", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex QueryParamRegex();

    [GeneratedRegex(@"""(access_token|refresh_token|id_token|client_secret)""\s*:\s*""[^""]*""", RegexOptions.CultureInvariant)]
    private static partial Regex JsonTokenRegex();
}
