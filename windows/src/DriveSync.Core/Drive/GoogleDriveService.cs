using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using Google;
using Google.Apis.Auth.OAuth2.Responses;
using Google.Apis.Drive.v3;
using Google.Apis.Http;
using Google.Apis.Services;
using Google.Apis.Upload;
using DriveSync.Core.Config;
using DriveSync.Core.Model;
using Microsoft.Extensions.Logging;
using DriveFile = Google.Apis.Drive.v3.Data.File;

namespace DriveSync.Core.Drive;

/// <summary>
/// <see cref="IDriveService"/> on top of the official Google.Apis.Drive.v3 client.
/// Every call sets supportsAllDrives=true; list/changes also includeItemsFromAllDrives=true and, for a shared
/// drive, corpora=drive + driveId (list) / driveId (changes). Field masks come from <see cref="DriveFields"/>.
/// </summary>
public sealed class GoogleDriveService : IDriveService, IDisposable
{
    /// <summary>8 MiB, a multiple of the 256 KiB granularity resumable uploads require.</summary>
    public const int UploadChunkSize = 8 * 1024 * 1024;

    private readonly DriveService _service;
    private readonly DriveAppConfig _config;
    private readonly ILogger _logger;

    public GoogleDriveService(DriveService service, DriveAppConfig config, ILogger logger)
    {
        _service = service;
        _config = config;
        _logger = logger;
    }

    public DriveService Service => _service;

    /// <summary>
    /// Builds the client with our retry policy. <paramref name="credential"/> is the UserCredential (adds the bearer
    /// token and refreshes once on 401). <paramref name="httpClientFactory"/> lets tests inject a fake transport.
    /// </summary>
    public static GoogleDriveService Create(
        DriveAppConfig config,
        IConfigurableHttpClientInitializer? credential,
        ILogger logger,
        RetryPolicy? policy = null,
        Google.Apis.Http.IHttpClientFactory? httpClientFactory = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null,
        Func<double>? random = null)
    {
        ArgumentNullException.ThrowIfNull(config);
        policy ??= RetryPolicy.Default;
        var initializer = new BaseClientService.Initializer
        {
            HttpClientInitializer = credential,
            ApplicationName = config.AppName,
            DefaultExponentialBackOffPolicy = ExponentialBackOffPolicy.None,
            GZipEnabled = true,
        };
        if (httpClientFactory is not null)
        {
            initializer.HttpClientFactory = httpClientFactory;
        }

        var service = new DriveService(initializer);
        var handler = new RetryHandler(policy, logger, delay, random);
        var messageHandler = service.HttpClient.MessageHandler;
        // One extra try is reserved for the credential's single refresh-on-401.
        messageHandler.NumTries = policy.MaxAttempts + 1;
        messageHandler.AddUnsuccessfulResponseHandler(handler);
        messageHandler.AddExceptionHandler(handler);
        return new GoogleDriveService(service, config, logger);
    }

    public async Task<DriveRoot> ResolveRootAsync(CancellationToken cancellationToken)
    {
        if (_config.UsesFolderId)
        {
            var get = _service.Files.Get(_config.FolderId);
            get.SupportsAllDrives = true;
            get.Fields = DriveFields.RootFolder;
            DriveFile folder;
            try
            {
                folder = await RunAsync(() => get.ExecuteAsync(cancellationToken)).ConfigureAwait(false);
            }
            catch (DriveException ex) when (ex.Kind == DriveErrorKind.NotFound)
            {
                throw new DriveException(DriveErrorKind.RootNotFound, "Configured Drive:FolderId was not found or is not shared with you.", ex);
            }

            if (!string.Equals(folder.MimeType, DriveMimeTypes.Folder, StringComparison.Ordinal) || folder.Trashed == true)
            {
                throw new DriveException(DriveErrorKind.RootNotFound, "Configured Drive:FolderId is not an active folder.");
            }

            var isDriveRoot = folder.DriveId is not null && string.Equals(folder.DriveId, folder.Id, StringComparison.Ordinal);
            return new DriveRoot(folder.Id, folder.Name ?? _config.RootFolderName, folder.DriveId, isDriveRoot ? RootKind.SharedDrive : RootKind.Folder);
        }

        var matches = new List<Google.Apis.Drive.v3.Data.Drive>();
        string? pageToken = null;
        do
        {
            var list = _service.Drives.List();
            list.Q = "name = '" + EscapeQueryLiteral(_config.SharedDriveName) + "'";
            list.PageSize = 100;
            list.PageToken = pageToken;
            list.Fields = DriveFields.Drives;
            var page = await RunAsync(() => list.ExecuteAsync(cancellationToken)).ConfigureAwait(false);
            matches.AddRange((page.Drives ?? Enumerable.Empty<Google.Apis.Drive.v3.Data.Drive>())
                .Where(d => string.Equals(d.Name, _config.SharedDriveName, StringComparison.Ordinal)));
            pageToken = page.NextPageToken;
        }
        while (pageToken is not null);

        return matches.Count switch
        {
            0 => throw new DriveException(DriveErrorKind.RootNotFound, $"No shared drive named '{_config.SharedDriveName}' is visible to this account."),
            1 => new DriveRoot(matches[0].Id, matches[0].Name, matches[0].Id, RootKind.SharedDrive),
            _ => throw new DriveException(DriveErrorKind.RootAmbiguous, $"{matches.Count} shared drives are named '{_config.SharedDriveName}'. Set Drive:FolderId to the one to use.")
            {
                Candidates = matches.Select(d => d.Id).ToList(),
            },
        };
    }

    public async Task<IReadOnlyList<DriveItem>> ListChildrenAsync(string folderId, DriveRoot root, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(root);
        var result = new List<DriveItem>();
        string? pageToken = null;
        do
        {
            var list = _service.Files.List();
            list.Q = "'" + EscapeQueryLiteral(folderId) + "' in parents and trashed = false";
            list.PageSize = DriveFields.PageSize;
            list.PageToken = pageToken;
            list.Fields = DriveFields.List;
            list.SupportsAllDrives = true;
            list.IncludeItemsFromAllDrives = true;
            if (root.DriveId is not null)
            {
                list.Corpora = "drive";
                list.DriveId = root.DriveId;
            }
            else
            {
                list.Corpora = "user";
            }

            var page = await RunAsync(() => list.ExecuteAsync(cancellationToken)).ConfigureAwait(false);
            foreach (var f in page.Files ?? Enumerable.Empty<DriveFile>())
            {
                var item = Map(f);
                if (!item.IsHidden)
                {
                    result.Add(item);
                }
            }

            pageToken = page.NextPageToken;
        }
        while (pageToken is not null);

        return result;
    }

    public async Task<DriveItem> GetFileAsync(string fileId, CancellationToken cancellationToken)
    {
        var get = _service.Files.Get(fileId);
        get.SupportsAllDrives = true;
        get.Fields = DriveFields.File;
        return Map(await RunAsync(() => get.ExecuteAsync(cancellationToken)).ConfigureAwait(false));
    }

    public async Task<Stream> OpenRangeAsync(string fileId, long offset, long length, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(length);
        using var request = new HttpRequestMessage(HttpMethod.Get, BuildMediaUri(fileId));
        request.Headers.Range = new RangeHeaderValue(offset, offset + length - 1);
        HttpResponseMessage response;
        try
        {
            response = await _service.HttpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            throw Map(ex);
        }

        if (response.StatusCode == HttpStatusCode.PartialContent)
        {
            return new ResponseStream(response, await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false), skip: 0, limit: length);
        }

        if (response.StatusCode == HttpStatusCode.OK)
        {
            // Server ignored the Range header: skip to the requested offset ourselves.
            return new ResponseStream(response, await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false), skip: offset, limit: length);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            throw FromStatus(response.StatusCode, RetryPolicy.ParseErrorReason(body), "download");
        }
    }

    public async Task<string> GetStartPageTokenAsync(DriveRoot root, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(root);
        var req = _service.Changes.GetStartPageToken();
        req.SupportsAllDrives = true;
        if (root.DriveId is not null)
        {
            req.DriveId = root.DriveId;
        }

        var token = await RunAsync(() => req.ExecuteAsync(cancellationToken)).ConfigureAwait(false);
        return token.StartPageTokenValue ?? throw new DriveException(DriveErrorKind.InvalidResponse, "Drive returned no start page token.");
    }

    public async Task<ChangeBatch> GetChangesAsync(string pageToken, DriveRoot root, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(root);
        var req = _service.Changes.List(pageToken);
        req.SupportsAllDrives = true;
        req.IncludeItemsFromAllDrives = true;
        req.PageSize = DriveFields.PageSize;
        req.Fields = DriveFields.Changes;
        if (root.DriveId is not null)
        {
            req.DriveId = root.DriveId;
        }

        var page = await RunAsync(() => req.ExecuteAsync(cancellationToken)).ConfigureAwait(false);
        var changes = new List<DriveChange>();
        foreach (var c in page.Changes ?? Enumerable.Empty<Google.Apis.Drive.v3.Data.Change>())
        {
            if (c.Removed == true && c.FileId is not null)
            {
                changes.Add(new DriveChange.Removed(c.FileId));
            }
            else if (c.File is not null)
            {
                changes.Add(new DriveChange.Upsert(Map(c.File)));
            }
        }

        return new ChangeBatch(changes, page.NextPageToken, page.NewStartPageToken);
    }

    public async Task<DriveItem> UploadAsync(Stream content, string name, string parentId, IProgress<long>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(content);
        var metadata = new DriveFile { Name = name, Parents = new[] { parentId } };
        var upload = _service.Files.Create(metadata, content, MimeTypes.FromFileName(name));
        upload.SupportsAllDrives = true;
        upload.Fields = DriveFields.File;
        upload.ChunkSize = UploadChunkSize;
        if (progress is not null)
        {
            upload.ProgressChanged += p => progress.Report(p.BytesSent);
        }

        // ResumableUpload (uploadType=resumable) re-queries the session with "Content-Range: bytes */<total>" after a
        // server error or dropped connection and continues from the committed offset (HTTP 308 + Range).
        IUploadProgress result;
        try
        {
            result = await upload.UploadAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            throw Map(ex);
        }

        if (result.Status != UploadStatus.Completed || upload.ResponseBody is null)
        {
            if (result.Exception is OperationCanceledException oce)
            {
                throw oce;
            }

            throw result.Exception is null
                ? new DriveException(DriveErrorKind.InvalidResponse, "Upload did not complete.")
                : Map(result.Exception);
        }

        return Map(upload.ResponseBody);
    }

    public async Task<string?> GetUserEmailAsync(CancellationToken cancellationToken)
    {
        var req = _service.About.Get();
        req.Fields = DriveFields.About;
        var about = await RunAsync(() => req.ExecuteAsync(cancellationToken)).ConfigureAwait(false);
        return about.User?.EmailAddress;
    }

    public void Dispose() => _service.Dispose();

    internal Uri BuildMediaUri(string fileId) =>
        new(_service.BaseUri + "files/" + Uri.EscapeDataString(fileId) + "?alt=media&supportsAllDrives=true");

    /// <summary>Escapes a value for a single-quoted Drive query literal.</summary>
    public static string EscapeQueryLiteral(string value) =>
        (value ?? string.Empty).Replace("\\", "\\\\", StringComparison.Ordinal).Replace("'", "\\'", StringComparison.Ordinal);

    public static DriveItem Map(DriveFile f)
    {
        ArgumentNullException.ThrowIfNull(f);
        return new DriveItem
        {
            Id = f.Id ?? throw new DriveException(DriveErrorKind.InvalidResponse, "Drive returned a file without an id."),
            Name = f.Name ?? string.Empty,
            MimeType = f.MimeType ?? "application/octet-stream",
            Size = f.Size,
            CreatedTime = ParseTime(f.CreatedTimeRaw),
            ModifiedTime = ParseTime(f.ModifiedTimeRaw),
            Md5Checksum = f.Md5Checksum,
            Parents = f.Parents is null ? Array.Empty<string>() : f.Parents.ToArray(),
            Trashed = f.Trashed ?? false,
            CanDownload = f.Capabilities?.CanDownload ?? true,
            LastModifyingUserName = f.LastModifyingUser?.DisplayName,
            ThumbnailLink = f.ThumbnailLink,
            VideoDurationMillis = f.VideoMediaMetadata?.DurationMillis,
            Width = f.VideoMediaMetadata?.Width ?? f.ImageMediaMetadata?.Width,
            Height = f.VideoMediaMetadata?.Height ?? f.ImageMediaMetadata?.Height,
        };
    }

    internal static DateTimeOffset ParseTime(string? raw) =>
        string.IsNullOrEmpty(raw)
            ? DateTimeOffset.UnixEpoch
            : DateTimeOffset.Parse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);

    private static async Task<T> RunAsync<T>(Func<Task<T>> call)
    {
        try
        {
            return await call().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException and not DriveException)
        {
            throw Map(ex);
        }
    }

    public static DriveException Map(Exception ex) => ex switch
    {
        DriveException d => d,
        TokenResponseException t when string.Equals(t.Error?.Error, "invalid_grant", StringComparison.Ordinal)
            => new DriveException(DriveErrorKind.NeedsLogin, "Google sign-in expired or was revoked.", t),
        TokenResponseException t => new DriveException(DriveErrorKind.Unauthorized, "Token request failed: " + t.Error?.Error, t),
        GoogleApiException g => FromStatus(g.HttpStatusCode, g.Error?.Errors?.FirstOrDefault()?.Reason, g.Error?.Message ?? g.Message, g),
        HttpRequestException or IOException or TaskCanceledException => new DriveException(DriveErrorKind.Network, ex.Message, ex),
        _ => new DriveException(DriveErrorKind.InvalidResponse, ex.Message, ex),
    };

    private static DriveException FromStatus(HttpStatusCode status, string? reason, string message, Exception? inner = null)
    {
        var code = (int)status;
        var kind = code switch
        {
            401 => DriveErrorKind.NeedsLogin,
            404 => DriveErrorKind.NotFound,
            429 => DriveErrorKind.RateLimited,
            403 when reason is "rateLimitExceeded" or "userRateLimitExceeded" => DriveErrorKind.RateLimited,
            403 when reason is "storageQuotaExceeded" or "quotaExceeded" or "teamDriveFileLimitExceeded" => DriveErrorKind.QuotaExceeded,
            403 => DriveErrorKind.Forbidden,
            >= 500 => DriveErrorKind.Server,
            _ => DriveErrorKind.InvalidResponse,
        };
        return new DriveException(kind, $"Drive HTTP {code}{(reason is null ? string.Empty : " (" + reason + ")")}: {message}", inner) { HttpStatus = code };
    }

    /// <summary>Wraps a response body stream, owning the response; optionally skips a prefix and caps the length.</summary>
    private sealed class ResponseStream : Stream
    {
        private readonly HttpResponseMessage _response;
        private readonly Stream _inner;
        private long _skip;
        private long _remaining;

        public ResponseStream(HttpResponseMessage response, Stream inner, long skip, long limit)
        {
            _response = response;
            _inner = inner;
            _skip = skip;
            _remaining = limit;
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

        public override int Read(byte[] buffer, int offset, int count) =>
            ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            while (_skip > 0)
            {
                var scratch = new byte[(int)Math.Min(_skip, 81920)];
                var n = await _inner.ReadAsync(scratch, cancellationToken).ConfigureAwait(false);
                if (n == 0)
                {
                    return 0;
                }

                _skip -= n;
            }

            if (_remaining <= 0)
            {
                return 0;
            }

            var max = (int)Math.Min(buffer.Length, _remaining);
            var read = await _inner.ReadAsync(buffer[..max], cancellationToken).ConfigureAwait(false);
            _remaining -= read;
            return read;
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _inner.Dispose();
                _response.Dispose();
            }

            base.Dispose(disposing);
        }
    }
}

/// <summary>Content types for uploads; Drive keeps whatever we send, so map the common phone/desktop formats.</summary>
public static class MimeTypes
{
    private static readonly Dictionary<string, string> Map = new(StringComparer.OrdinalIgnoreCase)
    {
        [".mp4"] = "video/mp4",
        [".m4v"] = "video/x-m4v",
        [".mov"] = "video/quicktime",
        [".avi"] = "video/x-msvideo",
        [".mkv"] = "video/x-matroska",
        [".webm"] = "video/webm",
        [".jpg"] = "image/jpeg",
        [".jpeg"] = "image/jpeg",
        [".png"] = "image/png",
        [".gif"] = "image/gif",
        [".heic"] = "image/heic",
        [".heif"] = "image/heif",
        [".webp"] = "image/webp",
        [".mp3"] = "audio/mpeg",
        [".m4a"] = "audio/mp4",
        [".wav"] = "audio/wav",
        [".pdf"] = "application/pdf",
        [".txt"] = "text/plain",
        [".csv"] = "text/csv",
        [".json"] = "application/json",
        [".zip"] = "application/zip",
    };

    public static string FromFileName(string name)
    {
        var ext = Path.GetExtension(name ?? string.Empty);
        return Map.TryGetValue(ext, out var type) ? type : "application/octet-stream";
    }
}
