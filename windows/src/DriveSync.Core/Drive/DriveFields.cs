namespace DriveSync.Core.Drive;

/// <summary>Field masks exactly as the contract specifies ("Google API facts").</summary>
public static class DriveFields
{
    public const string File =
        "id,name,mimeType,size,createdTime,modifiedTime,md5Checksum,parents,trashed,thumbnailLink,hasThumbnail,iconLink,"
        + "lastModifyingUser(displayName,emailAddress),videoMediaMetadata(durationMillis,width,height),"
        + "imageMediaMetadata(width,height),capabilities(canDownload)";

    public const string List = "nextPageToken,files(" + File + ")";

    public const string Changes = "nextPageToken,newStartPageToken,changes(fileId,removed,file(" + File + "))";

    public const string Drives = "nextPageToken,drives(id,name)";

    /// <summary>Used once to resolve a configured folder ID (needs driveId to pick list/changes parameters).</summary>
    public const string RootFolder = "id,name,mimeType,driveId,trashed";

    public const string About = "user(emailAddress,displayName)";

    public const int PageSize = 1000;
}
