using System.Net;
using System.Text;
using Google.Apis.Http;

namespace DriveSync.Core.Tests.Fakes;

/// <summary>Records every request and answers from a scripted responder. Plugged in via Google's HttpClientFactory.</summary>
internal sealed class FakeHttpHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, string?, HttpResponseMessage> _respond;

    public FakeHttpHandler(Func<HttpRequestMessage, string?, HttpResponseMessage> respond) => _respond = respond;

    public List<(HttpMethod Method, Uri Uri, string? Body, HttpRequestMessage Request)> Requests { get; } = new();

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        string? body = null;
        if (request.Content is not null)
        {
            var bytes = await request.Content.ReadAsByteArrayAsync(cancellationToken);
            if (request.Content.Headers.ContentEncoding.Contains("gzip"))
            {
                using var gz = new System.IO.Compression.GZipStream(new MemoryStream(bytes), System.IO.Compression.CompressionMode.Decompress);
                using var plain = new MemoryStream();
                await gz.CopyToAsync(plain, cancellationToken);
                bytes = plain.ToArray();
            }

            body = Encoding.UTF8.GetString(bytes);
        }

        Requests.Add((request.Method, request.RequestUri!, body, request));
        var response = _respond(request, body);
        response.RequestMessage ??= request;
        return response;
    }

    public static HttpResponseMessage Json(string json, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
}

internal sealed class FakeHttpClientFactory : HttpClientFactory
{
    private readonly HttpMessageHandler _handler;

    public FakeHttpClientFactory(HttpMessageHandler handler) => _handler = handler;

    protected override HttpMessageHandler CreateHandler(CreateHttpClientArgs args) => _handler;
}

internal static class QueryString
{
    public static Dictionary<string, string> Parse(Uri uri) =>
        uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Split('=', 2))
            .ToDictionary(p => Uri.UnescapeDataString(p[0]), p => p.Length > 1 ? Uri.UnescapeDataString(p[1].Replace('+', ' ')) : string.Empty);
}
