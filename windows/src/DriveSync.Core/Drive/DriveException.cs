namespace DriveSync.Core.Drive;

/// <summary>Mirrors DriveError in the Swift DriveCore so both clients report the same categories.</summary>
public enum DriveErrorKind
{
    NeedsLogin,
    Unauthorized,
    RateLimited,
    NotFound,
    RootNotFound,
    RootAmbiguous,
    QuotaExceeded,
    Forbidden,
    ChecksumMismatch,
    Network,
    Server,
    InvalidResponse,
    Cancelled,
    NotConfigured,
}

public sealed class DriveException : Exception
{
    public DriveException(DriveErrorKind kind, string message, Exception? inner = null)
        : base(message, inner)
    {
        Kind = kind;
    }

    public DriveException()
        : this(DriveErrorKind.InvalidResponse, "Drive error")
    {
    }

    public DriveException(string message)
        : this(DriveErrorKind.InvalidResponse, message)
    {
    }

    public DriveException(string message, Exception innerException)
        : this(DriveErrorKind.InvalidResponse, message, innerException)
    {
    }

    public DriveErrorKind Kind { get; }

    /// <summary>Candidate IDs when <see cref="Kind"/> is <see cref="DriveErrorKind.RootAmbiguous"/>.</summary>
    public IReadOnlyList<string> Candidates { get; init; } = Array.Empty<string>();

    public int? HttpStatus { get; init; }
}
