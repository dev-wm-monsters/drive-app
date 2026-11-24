using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;

namespace DriveSync.Core.Drive;

/// <summary>
/// Contract retry rules: retry 429, 5xx and 403 with reason rateLimitExceeded/userRateLimitExceeded using
/// exponential backoff with FULL jitter (base 1 s, cap 32 s), at most 5 attempts in total, honouring Retry-After.
/// </summary>
public sealed record RetryPolicy(int MaxAttempts, TimeSpan BaseDelay, TimeSpan MaxDelay)
{
    public static RetryPolicy Default { get; } = new(5, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(32));

    /// <summary>Upper bound for a server-provided Retry-After so a bad header cannot stall sync forever.</summary>
    public static TimeSpan MaxRetryAfter { get; } = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Delay before retry number <paramref name="failedAttempt"/> (1 = after the first failure).
    /// Full jitter: uniform in [0, min(cap, base * 2^(n-1))]. A Retry-After value wins when present.
    /// </summary>
    public TimeSpan ComputeDelay(int failedAttempt, TimeSpan? retryAfter, Func<double> random)
    {
        ArgumentNullException.ThrowIfNull(random);
        if (retryAfter is { } ra)
        {
            return ra < TimeSpan.Zero ? TimeSpan.Zero : (ra > MaxRetryAfter ? MaxRetryAfter : ra);
        }

        return TimeSpan.FromTicks((long)(random() * Ceiling(failedAttempt).Ticks));
    }

    /// <summary>The exponential ceiling (before jitter) for a given failed attempt.</summary>
    public TimeSpan Ceiling(int failedAttempt)
    {
        var exponent = Math.Clamp(failedAttempt - 1, 0, 30);
        var ticks = BaseDelay.Ticks * Math.Pow(2, exponent);
        return ticks >= MaxDelay.Ticks ? MaxDelay : TimeSpan.FromTicks((long)ticks);
    }

    /// <summary>True when another attempt is allowed after <paramref name="failedAttempts"/> failures.</summary>
    public bool CanRetry(int failedAttempts) => failedAttempts < MaxAttempts;

    public static bool IsRetryable(HttpStatusCode status, string? reason)
    {
        var code = (int)status;
        if (code == 429 || code >= 500)
        {
            return true;
        }

        return code == 403 && reason is "rateLimitExceeded" or "userRateLimitExceeded";
    }

    public static TimeSpan? ParseRetryAfter(RetryConditionHeaderValue? header, DateTimeOffset now)
    {
        if (header is null)
        {
            return null;
        }

        if (header.Delta is { } delta)
        {
            return delta;
        }

        return header.Date is { } date ? date - now : null;
    }

    /// <summary>Extracts the first error reason from a Google JSON error body ({"error":{"errors":[{"reason":..}]}}).</summary>
    public static string? ParseErrorReason(string? body)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return null;
        }

        try
        {
            using var doc = JsonDocument.Parse(body);
            if (!doc.RootElement.TryGetProperty("error", out var error) || error.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            if (error.TryGetProperty("errors", out var errors) && errors.ValueKind == JsonValueKind.Array)
            {
                foreach (var e in errors.EnumerateArray())
                {
                    if (e.TryGetProperty("reason", out var reason) && reason.ValueKind == JsonValueKind.String)
                    {
                        return reason.GetString();
                    }
                }
            }

            if (error.TryGetProperty("details", out var details) && details.ValueKind == JsonValueKind.Array)
            {
                foreach (var d in details.EnumerateArray())
                {
                    if (d.TryGetProperty("reason", out var reason) && reason.ValueKind == JsonValueKind.String)
                    {
                        // ErrorInfo uses SCREAMING_CASE (RATE_LIMIT_EXCEEDED); map to the v3 spelling.
                        return reason.GetString() switch
                        {
                            "RATE_LIMIT_EXCEEDED" => "rateLimitExceeded",
                            "USER_RATE_LIMIT_EXCEEDED" => "userRateLimitExceeded",
                            var other => other,
                        };
                    }
                }
            }
        }
        catch (JsonException)
        {
            return null;
        }

        return null;
    }
}
