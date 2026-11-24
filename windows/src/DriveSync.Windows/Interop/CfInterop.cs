using System.Runtime.InteropServices;
using DriveSync.Core.Model;
using Microsoft.Win32.SafeHandles;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Storage.CloudFilters;
using Windows.Win32.Storage.FileSystem;

namespace DriveSync.Windows.Interop;

/// <summary>Thin helpers over the CsWin32-generated cfapi bindings.</summary>
internal static class CfInterop
{
    // HRESULT_FROM_WIN32 values we branch on.
    public const int ErrorNotACloudFile = unchecked((int)0x80070178);       // ERROR_NOT_A_CLOUD_FILE (376)
    public const int ErrorCloudFilePinned = unchecked((int)0x80070185);     // ERROR_CLOUD_FILE_PINNED (389)
    public const int ErrorCloudFileNotInSync = unchecked((int)0x80070179);  // ERROR_CLOUD_FILE_NOT_IN_SYNC (377)
    public const int ErrorCloudFileInUse = unchecked((int)0x80070187);      // ERROR_CLOUD_FILE_IN_USE (391)

    public const uint WriteDac = 0x00040000;

    public const FileAttributes Pinned = (FileAttributes)0x00080000;            // FILE_ATTRIBUTE_PINNED
    public const FileAttributes Unpinned = (FileAttributes)0x00100000;          // FILE_ATTRIBUTE_UNPINNED
    public const FileAttributes RecallOnDataAccess = (FileAttributes)0x00400000; // FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS

    /// <summary>Attributes a caller may set with SetFileAttributes; cloud/reparse bits are owned by the filter.</summary>
    public const FileAttributes Settable = FileAttributes.ReadOnly | FileAttributes.Hidden | FileAttributes.System | FileAttributes.Archive
                                           | FileAttributes.Temporary | FileAttributes.Offline | FileAttributes.NotContentIndexed | Pinned | Unpinned;

    /// <summary>
    /// Opens a handle for placeholder management without reading data (so no hydration). WRITE_DAC satisfies cfapi's
    /// "WRITE_DATA or WRITE_DAC" requirement and works on read-only files. <paramref name="exclusive"/> is required
    /// when dehydrating (CfUpdatePlaceholder docs).
    /// </summary>
    public static SafeFileHandle Open(string fullPath, bool write, bool exclusive)
    {
        var access = (uint)FILE_ACCESS_RIGHTS.FILE_READ_ATTRIBUTES | (write ? (uint)FILE_ACCESS_RIGHTS.FILE_WRITE_ATTRIBUTES | WriteDac : 0);
        var share = exclusive
            ? FILE_SHARE_MODE.FILE_SHARE_NONE
            : FILE_SHARE_MODE.FILE_SHARE_READ | FILE_SHARE_MODE.FILE_SHARE_WRITE | FILE_SHARE_MODE.FILE_SHARE_DELETE;
        var handle = PInvoke.CreateFile(
            fullPath,
            access,
            share,
            null,
            FILE_CREATION_DISPOSITION.OPEN_EXISTING,
            FILE_FLAGS_AND_ATTRIBUTES.FILE_FLAG_BACKUP_SEMANTICS,
            null);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastPInvokeError();
            handle.Dispose();
            throw new IOException($"Cannot open item (Win32 error {error}).", Marshal.GetHRForLastWin32Error());
        }

        return handle;
    }

    public static void Check(HRESULT hr, string operation)
    {
        if (hr.Failed)
        {
            throw new IOException($"{operation} failed (HRESULT 0x{hr.Value:X8}).", hr.Value);
        }
    }

    /// <summary>Reads CF_PLACEHOLDER_BASIC_INFO. Returns false for a normal (non-placeholder) file or folder.</summary>
    public static unsafe bool TryGetPlaceholderInfo(SafeFileHandle handle, out CF_IN_SYNC_STATE inSync, out byte[] identity)
    {
        var buffer = new byte[CF_PLACEHOLDER_BASIC_INFO.SizeOf(DriveSync.Core.Sync.PlaceholderIdentity.MaxBytes)];
        var hr = PInvoke.CfGetPlaceholderInfo(handle, CF_PLACEHOLDER_INFO_CLASS.CF_PLACEHOLDER_INFO_BASIC, buffer, out _);
        if (hr.Value == ErrorNotACloudFile)
        {
            inSync = CF_IN_SYNC_STATE.CF_IN_SYNC_STATE_NOT_IN_SYNC;
            identity = Array.Empty<byte>();
            return false;
        }

        Check(hr, "CfGetPlaceholderInfo");
        fixed (byte* p = buffer)
        {
            var info = (CF_PLACEHOLDER_BASIC_INFO*)p;
            inSync = info->InSyncState;
            var length = (int)Math.Min(info->FileIdentityLength, (uint)DriveSync.Core.Sync.PlaceholderIdentity.MaxBytes);
            identity = new ReadOnlySpan<byte>(&info->FileIdentity, length).ToArray();
        }

        return true;
    }

    /// <summary>Metadata for a placeholder: Drive times; read-only for files. Attributes 0 = leave unchanged.</summary>
    public static CF_FS_METADATA Metadata(DriveItem item, bool setAttributes)
    {
        var modified = item.ModifiedTime.UtcDateTime.ToFileTimeUtc();
        uint attributes = 0;
        if (setAttributes)
        {
            attributes = item.IsFolder ? (uint)FileAttributes.Directory : (uint)FileAttributes.ReadOnly;
        }

        return new CF_FS_METADATA
        {
            BasicInfo = new FILE_BASIC_INFO
            {
                CreationTime = item.CreatedTime.UtcDateTime.ToFileTimeUtc(),
                LastWriteTime = modified,
                ChangeTime = modified,
                LastAccessTime = modified,
                FileAttributes = attributes,
            },
            FileSize = item.IsFolder ? 0 : item.Size ?? 0,
        };
    }
}
