using Google.Apis.Http;
using Microsoft.Extensions.Logging;

namespace DriveSync.Core.Drive;

/// <summary>
/// Plugs <see cref="RetryPolicy"/> into the Google client pipeline (ConfigurableMessageHandler).
/// The client's own default back-off is disabled (ExponentialBackOffPolicy.None) so only these rules apply.
/// 401 is NOT handled here: the UserCredential handler refreshes the token once; a second 401 surfaces as needsLogin.
/// </summary>
public sealed class RetryHandler : IHttpUnsuccessfulResponseHandler, IHttpExceptionHandler
{
    private readonly RetryPolicy _policy;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly Func<double> _random;
    private readonly Func<DateTimeOffset> _now;
    private readonly ILogger _logger;

    public RetryHandler(
        RetryPolicy policy,
        ILogger logger,
        Func<TimeSpan, CancellationToken, Task>? delay = null,
        Func<double>? random = null,
        Func<DateTimeOffset>? now = null)
    {
        _policy = policy;
        _logger = logger;
        _delay = delay ?? Task.Delay;
        _random = random ?? Random.Shared.NextDouble;
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public async Task<bool> HandleResponseAsync(HandleUnsuccessfulResponseArgs args)
    {
        ArgumentNullException.ThrowIfNull(args);
        if (!args.SupportsRetry || !_policy.CanRetry(args.CurrentFailedTry))
        {
            return false;
        }

        string? reason = null;
        if ((int)args.Response.StatusCode == 403)
        {
            // Buffer so the client can still read the body to build its exception if we decline to retry.
            await args.Response.Content.LoadIntoBufferAsync().ConfigureAwait(false);
            reason = RetryPolicy.ParseErrorReason(await args.Response.Content.ReadAsStringAsync(args.CancellationToken).ConfigureAwait(false));
        }

        if (!RetryPolicy.IsRetryable(args.Response.StatusCode, reason))
        {
            return false;
        }

        var retryAfter = RetryPolicy.ParseRetryAfter(args.Response.Headers.RetryAfter, _now());
        var delay = _policy.ComputeDelay(args.CurrentFailedTry, retryAfter, _random);
        _logger.LogInformation(
            "Drive request failed with HTTP {Status}{Reason}; retry {Try}/{Max} in {Delay:0.0}s",
            (int)args.Response.StatusCode,
            reason is null ? string.Empty : " (" + reason + ")",
            args.CurrentFailedTry,
            _policy.MaxAttempts - 1,
            delay.TotalSeconds);
        await _delay(delay, args.CancellationToken).ConfigureAwait(false);
        return true;
    }

    public async Task<bool> HandleExceptionAsync(HandleExceptionArgs args)
    {
        ArgumentNullException.ThrowIfNull(args);
        if (!args.SupportsRetry || !_policy.CanRetry(args.CurrentFailedTry) || args.CancellationToken.IsCancellationRequested)
        {
            return false;
        }

        if (args.Exception is not (HttpRequestException or IOException or TaskCanceledException))
        {
            return false;
        }

        var delay = _policy.ComputeDelay(args.CurrentFailedTry, null, _random);
        _logger.LogInformation(
            "Drive request failed ({Error}); retry {Try}/{Max} in {Delay:0.0}s",
            args.Exception.GetType().Name,
            args.CurrentFailedTry,
            _policy.MaxAttempts - 1,
            delay.TotalSeconds);
        await _delay(delay, args.CancellationToken).ConfigureAwait(false);
        return true;
    }
}
