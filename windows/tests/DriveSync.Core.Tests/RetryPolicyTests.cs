using System.Net;
using System.Net.Http.Headers;
using DriveSync.Core.Drive;

namespace DriveSync.Core.Tests;

public class RetryPolicyTests
{
    [Fact]
    public void Ceiling_doubles_from_one_second_and_caps_at_32()
    {
        var p = RetryPolicy.Default;
        Assert.Equal(new[] { 1d, 2, 4, 8, 16, 32, 32 }, Enumerable.Range(1, 7).Select(n => p.Ceiling(n).TotalSeconds));
    }

    [Fact]
    public void Full_jitter_spans_zero_to_ceiling()
    {
        var p = RetryPolicy.Default;
        Assert.Equal(TimeSpan.Zero, p.ComputeDelay(4, null, () => 0));
        Assert.Equal(TimeSpan.FromSeconds(4), p.ComputeDelay(4, null, () => 0.5));
        Assert.True(p.ComputeDelay(9, null, () => 0.999999) <= TimeSpan.FromSeconds(32));
    }

    [Fact]
    public void Retry_after_wins_and_is_bounded()
    {
        var p = RetryPolicy.Default;
        Assert.Equal(TimeSpan.FromSeconds(3), p.ComputeDelay(1, TimeSpan.FromSeconds(3), () => 0.9));
        Assert.Equal(RetryPolicy.MaxRetryAfter, p.ComputeDelay(1, TimeSpan.FromHours(2), () => 0.9));
        var now = DateTimeOffset.UtcNow;
        Assert.Equal(TimeSpan.FromSeconds(10), RetryPolicy.ParseRetryAfter(new RetryConditionHeaderValue(now.AddSeconds(10)), now));
    }

    [Fact]
    public void Five_attempts_total()
    {
        var p = RetryPolicy.Default;
        Assert.True(p.CanRetry(4));
        Assert.False(p.CanRetry(5));
    }

    [Theory]
    [InlineData(429, null, true)]
    [InlineData(500, null, true)]
    [InlineData(503, null, true)]
    [InlineData(403, "rateLimitExceeded", true)]
    [InlineData(403, "userRateLimitExceeded", true)]
    [InlineData(403, "storageQuotaExceeded", false)]
    [InlineData(401, null, false)]
    [InlineData(404, null, false)]
    [InlineData(400, null, false)]
    public void Retryable_statuses(int status, string? reason, bool expected) =>
        Assert.Equal(expected, RetryPolicy.IsRetryable((HttpStatusCode)status, reason));

    [Theory]
    [InlineData("{\"error\":{\"errors\":[{\"reason\":\"rateLimitExceeded\"}]}}", "rateLimitExceeded")]
    [InlineData("{\"error\":{\"details\":[{\"reason\":\"RATE_LIMIT_EXCEEDED\"}]}}", "rateLimitExceeded")]
    [InlineData("not json", null)]
    [InlineData("", null)]
    public void Error_reason_parsing(string body, string? expected) =>
        Assert.Equal(expected, RetryPolicy.ParseErrorReason(body));
}
