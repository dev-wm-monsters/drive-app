using System.Security.Cryptography;
using DriveSync.Core.Drive;
using DriveSync.Core.Sync;
using Microsoft.Extensions.Logging;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Storage.CloudFilters;

namespace DriveSync.Windows.CloudFiles;

/// <summary>
/// Serves FETCH_DATA: downloads the requested range with an HTTP Range request (files.get alt=media) and hands it to
/// the platform with CfExecute(TRANSFER_DATA) in 1 MiB chunks whose offsets/lengths are 4 KiB aligned (except at EOF).
/// Mid-stream failures resume from the last transferred chunk (RetryPolicy); a full-file download is checked against
/// Drive's md5Checksum and the last chunk is failed if it does not match. Cancellation (CANCEL_FETCH_DATA) stops work.
/// </summary>
internal sealed class HydrationService
{
    private readonly Func<IDriveService?> _drive;
    private readonly ILogger _logger;
    private readonly RetryPolicy _retry;

    public HydrationService(Func<IDriveService?> drive, ILogger logger, RetryPolicy? retry = null)
    {
        _drive = drive;
        _logger = logger;
        _retry = retry ?? RetryPolicy.Default;
    }

    public async Task ServeAsync(FetchRequest request, CancellationToken cancellationToken)
    {
        var (start, end) = HydrationMath.ComputeRange(request.RequiredOffset, request.RequiredLength, request.OptionalOffset, request.OptionalLength, request.FileSize);
        var drive = _drive();
        if (request.Identity is null || drive is null || end <= start)
        {
            Fail(request with { RequiredOffset = start, RequiredLength = Math.Max(end - start, HydrationMath.Alignment) }, NTSTATUS.STATUS_CLOUD_FILE_UNSUCCESSFUL);
            return;
        }

        var identity = request.Identity;
        var verifyMd5 = start == 0 && end == request.FileSize && identity.Md5 is not null;
#pragma warning disable CA5351 // integrity check against Drive's md5Checksum, not a security boundary
        using var md5 = verifyMd5 ? IncrementalHash.CreateHash(HashAlgorithmName.MD5) : null;
#pragma warning restore CA5351
        var buffer = new byte[HydrationMath.DefaultChunkSize];
        var position = start;
        var failures = 0;
        while (position < end)
        {
            try
            {
                await using var stream = await drive.OpenRangeAsync(identity.FileId, position, end - position, cancellationToken).ConfigureAwait(false);
                while (position < end)
                {
                    var want = (int)Math.Min(buffer.Length, end - position);
                    var filled = await FillAsync(stream, buffer, want, cancellationToken).ConfigureAwait(false);
                    if (filled < want)
                    {
                        throw new IOException("Download ended early.");
                    }

                    md5?.AppendData(buffer, 0, filled);
                    var status = NTSTATUS.STATUS_SUCCESS;
                    if (md5 is not null && position + filled == end)
                    {
                        var actual = Convert.ToHexString(md5.GetHashAndReset()).ToLowerInvariant();
                        if (!string.Equals(actual, identity.Md5, StringComparison.OrdinalIgnoreCase))
                        {
                            _logger.LogWarning("Checksum mismatch while hydrating; failing the request");
                            status = NTSTATUS.STATUS_CLOUD_FILE_UNSUCCESSFUL;
                        }
                    }

                    Transfer(request, buffer, position, filled, status);
                    position += filled;
                    failures = 0;
                    ReportProgress(request, end - start, position - start);
                    if (status != NTSTATUS.STATUS_SUCCESS)
                    {
                        return;
                    }
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                // CANCEL_FETCH_DATA: the platform already failed the I/O; nothing more to send.
                return;
            }
            catch (Exception ex) when (ex is IOException or HttpRequestException or DriveException)
            {
                failures++;
                var retryable = ex is not DriveException de || de.Kind is DriveErrorKind.Network or DriveErrorKind.Server or DriveErrorKind.RateLimited;
                if (!retryable || !_retry.CanRetry(failures))
                {
                    _logger.LogWarning("Hydration failed after {Failures} attempt(s): {Error}", failures, ex.GetType().Name);
                    var code = ex is DriveException { Kind: DriveErrorKind.Forbidden or DriveErrorKind.NotFound or DriveErrorKind.NeedsLogin }
                        ? NTSTATUS.STATUS_CLOUD_FILE_ACCESS_DENIED
                        : NTSTATUS.STATUS_CLOUD_FILE_NETWORK_UNAVAILABLE;
                    Fail(request with { RequiredOffset = position, RequiredLength = end - position }, code);
                    return;
                }

                md5?.Dispose();
                if (md5 is not null)
                {
                    // Can't resume an incremental hash mid-way after a retry; finish without verification.
                    verifyMd5 = false;
                }

                await Task.Delay(_retry.ComputeDelay(failures, null, Random.Shared.NextDouble), cancellationToken).ConfigureAwait(false);
            }
        }
    }

    /// <summary>Completes a FETCH_DATA with a failure status so the opening app gets an error instead of hanging.</summary>
    public static void Fail(FetchRequest request, NTSTATUS status)
    {
        var offset = HydrationMath.AlignDown(Math.Max(0, request.RequiredOffset));
        var length = Math.Max(request.RequiredOffset + request.RequiredLength - offset, 1);
        if (offset + length < request.FileSize)
        {
            length = HydrationMath.AlignUp(length);
        }

        Transfer(request, null, offset, length, status);
    }

    private static async Task<int> FillAsync(Stream stream, byte[] buffer, int count, CancellationToken ct)
    {
        var total = 0;
        while (total < count)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(total, count - total), ct).ConfigureAwait(false);
            if (n == 0)
            {
                break;
            }

            total += n;
        }

        return total;
    }

    private static unsafe void Transfer(FetchRequest request, byte[]? data, long offset, long length, NTSTATUS status)
    {
        var opInfo = new CF_OPERATION_INFO
        {
            StructSize = (uint)sizeof(CF_OPERATION_INFO),
            Type = CF_OPERATION_TYPE.CF_OPERATION_TYPE_TRANSFER_DATA,
            ConnectionKey = request.ConnectionKey,
            TransferKey = request.TransferKey,
            RequestKey = request.RequestKey,
        };
        var opParams = default(CF_OPERATION_PARAMETERS);
        opParams.ParamSize = (uint)((byte*)&opParams.Anonymous - (byte*)&opParams)
                             + (uint)sizeof(CF_OPERATION_PARAMETERS._Anonymous_e__Union._TransferData_e__Struct);
        fixed (byte* p = data)
        {
            opParams.TransferData.CompletionStatus = status;
            opParams.TransferData.Buffer = p;
            opParams.TransferData.Offset = offset;
            opParams.TransferData.Length = length;
            var hr = PInvoke.CfExecute(&opInfo, &opParams);
            if (hr.Failed && status == NTSTATUS.STATUS_SUCCESS)
            {
                // The platform rejected the data (request cancelled, file closed...). Surface as cancellation.
                throw new OperationCanceledException($"TRANSFER_DATA failed (HRESULT 0x{hr.Value:X8}).");
            }
        }
    }

    private static void ReportProgress(FetchRequest request, long total, long completed)
    {
        // Best effort; the filter also tracks transferred ranges itself.
        _ = PInvoke.CfReportProviderProgress(request.ConnectionKey, request.TransferKey, total, completed);
    }
}
