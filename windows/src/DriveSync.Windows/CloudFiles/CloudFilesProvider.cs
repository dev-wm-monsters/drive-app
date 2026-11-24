using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using DriveSync.Core.Sync;
using Microsoft.Extensions.Logging;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Storage.CloudFilters;

namespace DriveSync.Windows.CloudFiles;

/// <summary>A FETCH_DATA request copied out of the callback so it can be served asynchronously.</summary>
internal sealed record FetchRequest(
    CF_CONNECTION_KEY ConnectionKey,
    long TransferKey,
    long RequestKey,
    string NormalizedPath,
    string FullPath,
    long FileSize,
    PlaceholderIdentity? Identity,
    long RequiredOffset,
    long RequiredLength,
    long OptionalOffset,
    long OptionalLength);

/// <summary>
/// Connects to the sync root (CfConnectSyncRoot) and handles cfapi callbacks. Callbacks run on cfapi threads and must
/// return quickly: FETCH_DATA is copied and handed to <see cref="HydrationService"/> on the thread pool; delete/rename
/// decisions are cheap and acknowledged inline. Every callback that requires an answer always gets one (CfExecute),
/// with a STATUS_CLOUD_FILE_* failure when something goes wrong.
/// </summary>
public sealed unsafe partial class CloudFilesProvider : IDisposable
{
    private static readonly uint OwnProcessId = (uint)Environment.ProcessId;

    private readonly ILogger _logger;
    private readonly HydrationService _hydration;
    // Several FETCH_DATA requests can be outstanding for one TransferKey (one per open handle) at the same time, so
    // in-flight work is tracked per request and CANCEL_FETCH_DATA cancels the ones whose range overlaps.
    private readonly ConcurrentDictionary<long, InFlightFetch> _transfers = new();
    private long _nextFetchId;
    private CallbackRegistration* _table;
    private GCHandle _self;
    private CF_CONNECTION_KEY _connectionKey;
    private bool _connected;

    internal CloudFilesProvider(HydrationService hydration, ILogger logger)
    {
        _hydration = hydration;
        _logger = logger;
    }

    /// <summary>Raised (rate-limited by the app) when a user tried to delete/rename/move an existing item.</summary>
    public event EventHandler<string>? ModificationRejected;

    /// <summary>Another process closed a file under the root: a cue for a local reconcile pass.</summary>
    public event EventHandler? LocalActivity;

    public void Connect(string syncRootPath)
    {
        if (_connected)
        {
            return;
        }

        // CsWin32 projects CF_CALLBACK as a marshaled delegate; the table we hand to cldapi uses a blittable twin with
        // an unmanaged function pointer. Guard the layout against the metadata-generated struct.
        if (Marshal.SizeOf<CF_CALLBACK_REGISTRATION>() != sizeof(CallbackRegistration))
        {
            throw new InvalidOperationException("CF_CALLBACK_REGISTRATION layout mismatch.");
        }

        _self = GCHandle.Alloc(this);
        const int count = 6;
        _table = (CallbackRegistration*)NativeMemory.AllocZeroed((nuint)(count * sizeof(CallbackRegistration)));
        _table[0] = new CallbackRegistration { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_FETCH_DATA, Callback = &OnFetchData };
        _table[1] = new CallbackRegistration { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_CANCEL_FETCH_DATA, Callback = &OnCancelFetchData };
        _table[2] = new CallbackRegistration { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_DELETE, Callback = &OnNotifyDelete };
        _table[3] = new CallbackRegistration { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_RENAME, Callback = &OnNotifyRename };
        _table[4] = new CallbackRegistration { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION, Callback = &OnFileCloseCompletion };
        _table[5] = new CallbackRegistration { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NONE, Callback = null }; // CF_CALLBACK_REGISTRATION_END

        long key;
        HRESULT hr;
        fixed (char* path = syncRootPath)
        {
            hr = new HRESULT(CfConnectSyncRoot(
                path,
                _table,
                (void*)GCHandle.ToIntPtr(_self),
                (int)(CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO
                      | CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH
                      | CF_CONNECT_FLAGS.CF_CONNECT_FLAG_BLOCK_SELF_IMPLICIT_HYDRATION),
                &key));
        }

        if (hr.Failed)
        {
            FreeTable();
            throw new IOException($"CfConnectSyncRoot failed (HRESULT 0x{hr.Value:X8}).", hr.Value);
        }

        _connectionKey = (CF_CONNECTION_KEY)key;
        _connected = true;
        _logger.LogInformation("Connected to the sync root");
    }

    public void Disconnect()
    {
        if (!_connected)
        {
            return;
        }

        foreach (var fetch in _transfers.Values)
        {
            fetch.TryCancel();
        }

        var hr = PInvoke.CfDisconnectSyncRoot(_connectionKey);
        if (hr.Failed)
        {
            _logger.LogWarning("CfDisconnectSyncRoot failed: 0x{Hr:X8}", hr.Value);
        }

        _connected = false;
        FreeTable();
        _logger.LogInformation("Disconnected from the sync root");
    }

    public void Dispose() => Disconnect();

    [LibraryImport("cldapi.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static partial int CfConnectSyncRoot(char* syncRootPath, CallbackRegistration* callbackTable, void* callbackContext, int connectFlags, long* connectionKey);

    /// <summary>Blittable CF_CALLBACK_REGISTRATION: { CF_CALLBACK_TYPE Type; CF_CALLBACK Callback; }.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct CallbackRegistration
    {
        public CF_CALLBACK_TYPE Type;
        public delegate* unmanaged[Stdcall]<CF_CALLBACK_INFO*, CF_CALLBACK_PARAMETERS*, void> Callback;
    }

    private void Completed(long fetchId)
    {
        if (_transfers.TryRemove(fetchId, out var fetch))
        {
            fetch.Cancellation.Dispose();
        }
    }

    private sealed record InFlightFetch(long TransferKey, long Start, long End, CancellationTokenSource Cancellation)
    {
        public bool Overlaps(long transferKey, long offset, long length) =>
            TransferKey == transferKey && offset < End && (length <= 0 || offset + length > Start);

        public void TryCancel()
        {
            try
            {
                Cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // completed meanwhile
            }
        }
    }

    private void FreeTable()
    {
        if (_table is not null)
        {
            NativeMemory.Free(_table);
            _table = null;
        }

        if (_self.IsAllocated)
        {
            _self.Free();
        }
    }

    private static CloudFilesProvider? From(CF_CALLBACK_INFO* info) =>
        info->CallbackContext is null ? null : GCHandle.FromIntPtr((nint)info->CallbackContext).Target as CloudFilesProvider;

    private static uint CallerPid(CF_CALLBACK_INFO* info) => info->ProcessInfo is null ? 0 : info->ProcessInfo->ProcessId;

    private static string PathOf(CF_CALLBACK_INFO* info) => info->NormalizedPath.Value is null ? string.Empty : new string(info->NormalizedPath.Value);

    /// <summary>NormalizedPath is relative to the volume root ("\Users\me\..."); prefix the volume ("C:").</summary>
    private static string FullPathOf(CF_CALLBACK_INFO* info)
    {
        var volume = info->VolumeDosName.Value is not null ? new string(info->VolumeDosName.Value)
            : info->VolumeGuidName.Value is not null ? new string(info->VolumeGuidName.Value).TrimEnd('\\')
            : null;
        var path = PathOf(info);
        return volume is null || path.Length == 0 ? string.Empty : volume + path;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static void OnFetchData(CF_CALLBACK_INFO* info, CF_CALLBACK_PARAMETERS* parameters)
    {
        CloudFilesProvider? provider = null;
        var fetch = parameters->FetchData;
        try
        {
            provider = From(info);
            var identity = PlaceholderIdentity.TryDecode(new ReadOnlySpan<byte>(info->FileIdentity, (int)info->FileIdentityLength));
            var request = new FetchRequest(
                info->ConnectionKey,
                info->TransferKey,
                info->RequestKey,
                PathOf(info),
                FullPathOf(info),
                info->FileSize,
                identity,
                fetch.RequiredFileOffset,
                fetch.RequiredLength,
                fetch.OptionalFileOffset,
                fetch.OptionalLength);
            if (provider is null)
            {
                HydrationService.Fail(request, NTSTATUS.STATUS_CLOUD_FILE_UNSUCCESSFUL);
                return;
            }

            var id = Interlocked.Increment(ref provider._nextFetchId);
            var cts = new CancellationTokenSource();
            provider._transfers[id] = new InFlightFetch(request.TransferKey, request.RequiredOffset, request.RequiredOffset + request.RequiredLength, cts);
            // Never block the cfapi thread: download + TRANSFER_DATA happen on the thread pool. ServeAsync completes
            // the request itself (success or STATUS_CLOUD_FILE_*), so nothing here may complete it a second time.
            // (No await here: the class is an unsafe context.)
            _ = Task.Run(() => provider._hydration.ServeAsync(request, cts.Token)).ContinueWith(
                t =>
                {
                    _ = t.Exception; // observed; ServeAsync already answered the request
                    provider.Completed(id);
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }
#pragma warning disable CA1031 // must not throw across the native boundary; the request still gets an answer
        catch (Exception ex)
#pragma warning restore CA1031
        {
            try
            {
                provider?._logger.LogError("FETCH_DATA dispatch failed: {Error}", ex.GetType().Name);
                HydrationService.Fail(
                    new FetchRequest(info->ConnectionKey, info->TransferKey, info->RequestKey, string.Empty, string.Empty, info->FileSize, null, fetch.RequiredFileOffset, fetch.RequiredLength, 0, 0),
                    NTSTATUS.STATUS_CLOUD_FILE_UNSUCCESSFUL);
            }
#pragma warning disable CA1031
            catch (Exception)
#pragma warning restore CA1031
            {
                // nothing else can be done; the platform times the request out after 60 s
            }
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static void OnCancelFetchData(CF_CALLBACK_INFO* info, CF_CALLBACK_PARAMETERS* parameters)
    {
        try
        {
            var provider = From(info);
            if (provider is null)
            {
                return;
            }

            var cancel = parameters->Cancel.FetchData;
            foreach (var fetch in provider._transfers.Values)
            {
                if (fetch.Overlaps(info->TransferKey, cancel.FileOffset, cancel.Length))
                {
                    fetch.TryCancel();
                }
            }
        }
        catch (Exception)
        {
            // Must not throw across the native boundary.
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static void OnNotifyDelete(CF_CALLBACK_INFO* info, CF_CALLBACK_PARAMETERS* parameters) =>
        AcknowledgeChange(info, CF_OPERATION_TYPE.CF_OPERATION_TYPE_ACK_DELETE);

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static void OnNotifyRename(CF_CALLBACK_INFO* info, CF_CALLBACK_PARAMETERS* parameters) =>
        AcknowledgeChange(info, CF_OPERATION_TYPE.CF_OPERATION_TYPE_ACK_RENAME);

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvStdcall) })]
    private static void OnFileCloseCompletion(CF_CALLBACK_INFO* info, CF_CALLBACK_PARAMETERS* parameters)
    {
        try
        {
            if (CallerPid(info) != OwnProcessId)
            {
                var provider = From(info);
                provider?.LocalActivity?.Invoke(provider, EventArgs.Empty);
            }
        }
        catch (Exception)
        {
            // Must not throw across the native boundary.
        }
    }

    /// <summary>Only this process (the sync engine applying Drive changes) may delete/rename/move placeholders.</summary>
    private static void AcknowledgeChange(CF_CALLBACK_INFO* info, CF_OPERATION_TYPE type)
    {
        var allow = false;
        CloudFilesProvider? provider = null;
        try
        {
            allow = CallerPid(info) == OwnProcessId;
            provider = From(info);
        }
#pragma warning disable CA1031 // must not throw across the native boundary; reject instead
        catch (Exception)
#pragma warning restore CA1031
        {
            allow = false;
        }

        Acknowledge(info, type, allow, provider);
        if (!allow)
        {
            try
            {
                provider?.RaiseRejected(PathOf(info));
            }
#pragma warning disable CA1031
            catch (Exception)
#pragma warning restore CA1031
            {
                // ignore
            }
        }
    }

    /// <summary>
    /// ACK_DELETE / ACK_RENAME. Rejections must use a STATUS_CLOUD_FILE_* code (others are mapped to
    /// STATUS_CLOUD_FILE_UNSUCCESSFUL); ACCESS_DENIED matches the read-only product rule.
    /// </summary>
    private static void Acknowledge(CF_CALLBACK_INFO* info, CF_OPERATION_TYPE type, bool allow, CloudFilesProvider? provider)
    {
        try
        {
            var opInfo = new CF_OPERATION_INFO
            {
                StructSize = (uint)sizeof(CF_OPERATION_INFO),
                Type = type,
                ConnectionKey = info->ConnectionKey,
                TransferKey = info->TransferKey,
                RequestKey = info->RequestKey,
            };
            var opParams = default(CF_OPERATION_PARAMETERS);
            var status = allow ? NTSTATUS.STATUS_SUCCESS : NTSTATUS.STATUS_CLOUD_FILE_ACCESS_DENIED;
            var unionOffset = (uint)((byte*)&opParams.Anonymous - (byte*)&opParams);
            if (type == CF_OPERATION_TYPE.CF_OPERATION_TYPE_ACK_DELETE)
            {
                opParams.ParamSize = unionOffset + (uint)sizeof(CF_OPERATION_PARAMETERS._Anonymous_e__Union._AckDelete_e__Struct);
                opParams.AckDelete.CompletionStatus = status;
            }
            else
            {
                opParams.ParamSize = unionOffset + (uint)sizeof(CF_OPERATION_PARAMETERS._Anonymous_e__Union._AckRename_e__Struct);
                opParams.AckRename.CompletionStatus = status;
            }

            var hr = PInvoke.CfExecute(&opInfo, &opParams);
            if (hr.Failed)
            {
                provider?._logger.LogWarning("{Type} failed: 0x{Hr:X8}", type, hr.Value);
            }
        }
        catch (Exception)
        {
            // Must not throw across the native boundary.
        }
    }

    private void RaiseRejected(string path)
    {
        try
        {
            ModificationRejected?.Invoke(this, path);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            _logger.LogWarning("Rejection handler failed: {Error}", ex.GetType().Name);
        }
    }
}
