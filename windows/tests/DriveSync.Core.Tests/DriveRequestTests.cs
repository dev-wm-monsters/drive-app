using System.Net;
using System.Text.Json;
using DriveSync.Core.Config;
using DriveSync.Core.Drive;
using DriveSync.Core.Model;
using DriveSync.Core.Tests.Fakes;
using Microsoft.Extensions.Logging.Abstractions;

namespace DriveSync.Core.Tests;

/// <summary>Verifies the exact Drive API parameters the contract requires, through the real Google client.</summary>
public class DriveRequestTests
{
    private const string FileJson =
        """{"id":"%ID%","name":"%NAME%","mimeType":"video/mp4","size":"42","createdTime":"2026-01-02T03:04:05.678Z","modifiedTime":"2026-01-03T00:00:00Z","md5Checksum":"abc","parents":["drive1"],"trashed":false,"capabilities":{"canDownload":true}}""";

    private readonly List<TimeSpan> _delays = new();

    private (GoogleDriveService Service, FakeHttpHandler Http) Create(Func<HttpRequestMessage, string?, HttpResponseMessage> respond, DriveAppConfig? config = null)
    {
        var http = new FakeHttpHandler(respond);
        var service = GoogleDriveService.Create(
            config ?? new DriveAppConfig { GoogleClientId = "x.apps.googleusercontent.com", GoogleClientSecret = "s" },
            credential: null,
            NullLogger.Instance,
            RetryPolicy.Default,
            new FakeHttpClientFactory(http),
            delay: (d, _) =>
            {
                _delays.Add(d);
                return Task.CompletedTask;
            },
            random: () => 0.5);
        return (service, http);
    }

    private static string File(string id, string name) => FileJson.Replace("%ID%", id, StringComparison.Ordinal).Replace("%NAME%", name, StringComparison.Ordinal);

    [Fact]
    public async Task ListChildren_sets_shared_drive_parameters_and_follows_pages()
    {
        var (svc, http) = Create((req, _) =>
        {
            var q = QueryString.Parse(req.RequestUri!);
            return q.TryGetValue("pageToken", out var t) && t == "p2"
                ? FakeHttpHandler.Json("{\"files\":[" + File("b", "b.mp4") + "]}")
                : FakeHttpHandler.Json("{\"nextPageToken\":\"p2\",\"files\":[" + File("a", "a.mp4") + ",{\"id\":\"d\",\"name\":\"Doc\",\"mimeType\":\"application/vnd.google-apps.document\",\"createdTime\":\"2026-01-01T00:00:00Z\",\"modifiedTime\":\"2026-01-01T00:00:00Z\"}]}");
        });

        var items = await svc.ListChildrenAsync("folder'1", new DriveRoot("drive1", "WakeupMonster", "drive1", RootKind.SharedDrive), CancellationToken.None);

        Assert.Equal(new[] { "a", "b" }, items.Select(i => i.Id));
        Assert.Equal(2, http.Requests.Count);
        var first = http.Requests[0];
        Assert.Equal(HttpMethod.Get, first.Method);
        Assert.Equal("/drive/v3/files", first.Uri.AbsolutePath);
        var query = QueryString.Parse(first.Uri);
        Assert.Equal("true", query["supportsAllDrives"]);
        Assert.Equal("true", query["includeItemsFromAllDrives"]);
        Assert.Equal("drive", query["corpora"]);
        Assert.Equal("drive1", query["driveId"]);
        Assert.Equal("1000", query["pageSize"]);
        Assert.Equal(DriveFields.List, query["fields"]);
        Assert.Equal("'folder\\'1' in parents and trashed = false", query["q"]);
        Assert.Equal("p2", QueryString.Parse(http.Requests[1].Uri)["pageToken"]);
    }

    [Fact]
    public async Task Field_mask_matches_contract_exactly()
    {
        Assert.Equal(
            "id,name,mimeType,size,createdTime,modifiedTime,md5Checksum,parents,trashed,thumbnailLink,hasThumbnail,iconLink,lastModifyingUser(displayName,emailAddress),videoMediaMetadata(durationMillis,width,height),imageMediaMetadata(width,height),capabilities(canDownload)",
            DriveFields.File);
        Assert.Equal("nextPageToken,newStartPageToken,changes(fileId,removed,file(" + DriveFields.File + "))", DriveFields.Changes);
        await Task.CompletedTask;
    }

    [Fact]
    public async Task Mapping_parses_size_times_and_flags()
    {
        var (svc, _) = Create((_, _) => FakeHttpHandler.Json(File("a", "a.mp4")));
        var item = await svc.GetFileAsync("a", CancellationToken.None);
        Assert.Equal(42, item.Size);
        Assert.Equal(new DateTimeOffset(2026, 1, 2, 3, 4, 5, 678, TimeSpan.Zero), item.CreatedTime);
        Assert.Equal("abc", item.Md5Checksum);
        Assert.Equal("drive1", item.ParentId);
    }

    [Fact]
    public async Task Changes_use_driveId_for_shared_drive_and_map_removals()
    {
        var (svc, http) = Create((_, _) => FakeHttpHandler.Json(
            "{\"newStartPageToken\":\"t9\",\"changes\":[{\"fileId\":\"gone\",\"removed\":true},{\"fileId\":\"a\",\"removed\":false,\"file\":" + File("a", "a.mp4") + "}]}"));

        var batch = await svc.GetChangesAsync("t1", new DriveRoot("drive1", "W", "drive1", RootKind.SharedDrive), CancellationToken.None);

        Assert.Equal("t9", batch.NewStartPageToken);
        Assert.IsType<DriveChange.Removed>(batch.Changes[0]);
        Assert.Equal("a", Assert.IsType<DriveChange.Upsert>(batch.Changes[1]).Item.Id);
        var q = QueryString.Parse(http.Requests[0].Uri);
        Assert.Equal("/drive/v3/changes", http.Requests[0].Uri.AbsolutePath);
        Assert.Equal("t1", q["pageToken"]);
        Assert.Equal("drive1", q["driveId"]);
        Assert.Equal("true", q["supportsAllDrives"]);
        Assert.Equal("true", q["includeItemsFromAllDrives"]);
        Assert.Equal(DriveFields.Changes, q["fields"]);
    }

    [Fact]
    public async Task Changes_in_my_drive_folder_mode_omit_driveId()
    {
        var (svc, http) = Create((_, _) => FakeHttpHandler.Json("{\"newStartPageToken\":\"t2\",\"changes\":[]}"));
        await svc.GetChangesAsync("t1", new DriveRoot("f", "Folder", null, RootKind.Folder), CancellationToken.None);
        Assert.False(QueryString.Parse(http.Requests[0].Uri).ContainsKey("driveId"));
    }

    [Fact]
    public async Task ResolveRoot_by_name_queries_drives_list()
    {
        var (svc, http) = Create((_, _) => FakeHttpHandler.Json("{\"drives\":[{\"id\":\"0AAA\",\"name\":\"WakeupMonster\"}]}"));
        var root = await svc.ResolveRootAsync(CancellationToken.None);
        Assert.Equal(new DriveRoot("0AAA", "WakeupMonster", "0AAA", RootKind.SharedDrive), root);
        Assert.Equal("/drive/v3/drives", http.Requests[0].Uri.AbsolutePath);
        Assert.Equal("name = 'WakeupMonster'", QueryString.Parse(http.Requests[0].Uri)["q"]);
    }

    [Theory]
    [InlineData("{\"drives\":[]}", DriveErrorKind.RootNotFound)]
    [InlineData("{\"drives\":[{\"id\":\"1\",\"name\":\"WakeupMonster\"},{\"id\":\"2\",\"name\":\"WakeupMonster\"}]}", DriveErrorKind.RootAmbiguous)]
    public async Task ResolveRoot_reports_missing_or_ambiguous(string body, DriveErrorKind kind)
    {
        var (svc, _) = Create((_, _) => FakeHttpHandler.Json(body));
        var ex = await Assert.ThrowsAsync<DriveException>(() => svc.ResolveRootAsync(CancellationToken.None));
        Assert.Equal(kind, ex.Kind);
        if (kind == DriveErrorKind.RootAmbiguous)
        {
            Assert.Equal(new[] { "1", "2" }, ex.Candidates);
        }
    }

    [Fact]
    public async Task ResolveRoot_by_folder_id_uses_files_get_with_supportsAllDrives()
    {
        var config = new DriveAppConfig { GoogleClientId = "x.apps.googleusercontent.com", GoogleClientSecret = "s", FolderId = "fold1" };
        var (svc, http) = Create((_, _) => FakeHttpHandler.Json("{\"id\":\"fold1\",\"name\":\"Shared\",\"mimeType\":\"application/vnd.google-apps.folder\",\"driveId\":\"0DRV\"}"), config);
        var root = await svc.ResolveRootAsync(CancellationToken.None);
        Assert.Equal(new DriveRoot("fold1", "Shared", "0DRV", RootKind.Folder), root);
        Assert.Equal("/drive/v3/files/fold1", http.Requests[0].Uri.AbsolutePath);
        Assert.Equal("true", QueryString.Parse(http.Requests[0].Uri)["supportsAllDrives"]);
    }

    [Fact]
    public async Task OpenRange_requests_alt_media_with_range_header()
    {
        var payload = Enumerable.Range(0, 100).Select(i => (byte)i).ToArray();
        var (svc, http) = Create((req, _) =>
        {
            var r = req.Headers.Range!.Ranges.Single();
            var slice = payload[(int)r.From!.Value..((int)r.To!.Value + 1)];
            return new HttpResponseMessage(HttpStatusCode.PartialContent) { Content = new ByteArrayContent(slice) };
        });

        await using var stream = await svc.OpenRangeAsync("file 1", 10, 20, CancellationToken.None);
        using var ms = new MemoryStream();
        await stream.CopyToAsync(ms);

        Assert.Equal(payload[10..30], ms.ToArray());
        var req = http.Requests[0];
        Assert.Equal("/drive/v3/files/file%201", req.Uri.AbsolutePath);
        var q = QueryString.Parse(req.Uri);
        Assert.Equal("media", q["alt"]);
        Assert.Equal("true", q["supportsAllDrives"]);
        Assert.Equal("bytes=10-29", req.Request.Headers.Range!.ToString());
    }

    [Fact]
    public async Task OpenRange_skips_prefix_when_server_ignores_range()
    {
        var payload = Enumerable.Range(0, 50).Select(i => (byte)i).ToArray();
        var (svc, _) = Create((_, _) => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(payload) });
        await using var stream = await svc.OpenRangeAsync("f", 5, 10, CancellationToken.None);
        using var ms = new MemoryStream();
        await stream.CopyToAsync(ms);
        Assert.Equal(payload[5..15], ms.ToArray());
    }

    [Fact]
    public async Task Server_error_is_retried_with_jittered_backoff()
    {
        var calls = 0;
        var (svc, http) = Create((_, _) => ++calls < 3
            ? FakeHttpHandler.Json("{\"error\":{\"code\":503,\"message\":\"x\"}}", HttpStatusCode.ServiceUnavailable)
            : FakeHttpHandler.Json(File("a", "a.mp4")));

        await svc.GetFileAsync("a", CancellationToken.None);

        Assert.Equal(3, http.Requests.Count);
        Assert.Equal(new[] { TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(1) }, _delays);
    }

    [Fact]
    public async Task Rate_limited_403_is_retried_but_plain_403_is_not()
    {
        var calls = 0;
        var (svc, http) = Create((_, _) => ++calls == 1
            ? FakeHttpHandler.Json("{\"error\":{\"code\":403,\"message\":\"slow down\",\"errors\":[{\"reason\":\"userRateLimitExceeded\"}]}}", HttpStatusCode.Forbidden)
            : FakeHttpHandler.Json(File("a", "a.mp4")));
        await svc.GetFileAsync("a", CancellationToken.None);
        Assert.Equal(2, http.Requests.Count);

        var (svc2, http2) = Create((_, _) => FakeHttpHandler.Json("{\"error\":{\"code\":403,\"message\":\"no\",\"errors\":[{\"reason\":\"insufficientFilePermissions\"}]}}", HttpStatusCode.Forbidden));
        var ex = await Assert.ThrowsAsync<DriveException>(() => svc2.GetFileAsync("a", CancellationToken.None));
        Assert.Equal(DriveErrorKind.Forbidden, ex.Kind);
        Assert.Single(http2.Requests);
    }

    [Fact]
    public async Task Retry_after_header_is_honoured()
    {
        var calls = 0;
        var (svc, _) = Create((_, _) =>
        {
            if (++calls > 1)
            {
                return FakeHttpHandler.Json(File("a", "a.mp4"));
            }

            var r = FakeHttpHandler.Json("{\"error\":{\"code\":429,\"message\":\"x\"}}", (HttpStatusCode)429);
            r.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(7));
            return r;
        });
        await svc.GetFileAsync("a", CancellationToken.None);
        Assert.Equal(new[] { TimeSpan.FromSeconds(7) }, _delays);
    }

    [Fact]
    public async Task Gives_up_after_five_attempts()
    {
        var (svc, http) = Create((_, _) => FakeHttpHandler.Json("{\"error\":{\"code\":500,\"message\":\"x\"}}", HttpStatusCode.InternalServerError));
        var ex = await Assert.ThrowsAsync<DriveException>(() => svc.GetFileAsync("a", CancellationToken.None));
        Assert.Equal(DriveErrorKind.Server, ex.Kind);
        Assert.Equal(5, http.Requests.Count);
    }

    [Fact]
    public async Task Not_found_maps_to_NotFound()
    {
        var (svc, _) = Create((_, _) => FakeHttpHandler.Json("{\"error\":{\"code\":404,\"message\":\"nope\"}}", HttpStatusCode.NotFound));
        var ex = await Assert.ThrowsAsync<DriveException>(() => svc.GetFileAsync("a", CancellationToken.None));
        Assert.Equal(DriveErrorKind.NotFound, ex.Kind);
    }

    [Fact]
    public async Task Upload_is_resumable_with_supportsAllDrives_and_parent()
    {
        var (svc, http) = Create((req, _) =>
        {
            if (req.Method == HttpMethod.Post)
            {
                var r = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(string.Empty) };
                r.Headers.Location = new Uri("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=SESSION");
                return r;
            }

            return FakeHttpHandler.Json(File("new1", "clip.mp4"));
        });

        using var content = new MemoryStream(new byte[1234]);
        var item = await svc.UploadAsync(content, "clip.mp4", "drive1", null, CancellationToken.None);

        Assert.Equal("new1", item.Id);
        var init = http.Requests[0];
        Assert.Equal(HttpMethod.Post, init.Method);
        Assert.Equal("/upload/drive/v3/files", init.Uri.AbsolutePath);
        var q = QueryString.Parse(init.Uri);
        Assert.Equal("resumable", q["uploadType"]);
        Assert.Equal("true", q["supportsAllDrives"]);
        using var meta = JsonDocument.Parse(init.Body!);
        Assert.Equal("clip.mp4", meta.RootElement.GetProperty("name").GetString());
        Assert.Equal("drive1", meta.RootElement.GetProperty("parents")[0].GetString());
        Assert.Equal("video/mp4", init.Request.Headers.GetValues("X-Upload-Content-Type").Single());
        Assert.Equal(HttpMethod.Put, http.Requests[1].Method);
        Assert.Equal(8 * 1024 * 1024, GoogleDriveService.UploadChunkSize);
        Assert.Equal(0, GoogleDriveService.UploadChunkSize % (256 * 1024));
    }
}
