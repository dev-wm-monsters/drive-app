#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Every failure that crosses the StorageCore / IPC boundary.
///
/// The FSKit extension maps these to POSIX errors with `posixErrorCode`, so a failure
/// is always a controlled filesystem error rather than stale success (FR03).
public enum StorageError: Error, Codable, Hashable, Sendable, CustomStringConvertible {
    /// Negative offset/length, offset+length overflow, bad cursor, limit out of range, malformed message.
    case invalidArgument(String)
    case unknownItem
    case unknownAccount
    case notDirectory
    case isDirectory
    /// The caller pinned `expected`; the item is now at `actual`. Never splice revisions (FR05).
    case revisionChanged(expected: String, actual: String)
    case cancelled
    /// The service connection is interrupted/invalidated. Maps to ENOTCONN.
    case serviceUnavailable
    case timedOut
    case readOnly
    case messageTooLarge(limit: Int, actual: Int)

    /// POSIX errno to return to the kernel / FSKit for this error.
    ///
    /// | case | errno |
    /// | --- | --- |
    /// | invalidArgument | EINVAL |
    /// | unknownItem, unknownAccount | ENOENT |
    /// | notDirectory | ENOTDIR |
    /// | isDirectory | EISDIR |
    /// | revisionChanged | ESTALE |
    /// | cancelled | ECANCELED |
    /// | serviceUnavailable | ENOTCONN |
    /// | timedOut | ETIMEDOUT |
    /// | readOnly | EROFS |
    /// | messageTooLarge | EMSGSIZE |
    public var posixErrorCode: Int32 {
        switch self {
        case .invalidArgument: return EINVAL
        case .unknownItem, .unknownAccount: return ENOENT
        case .notDirectory: return ENOTDIR
        case .isDirectory: return EISDIR
        case .revisionChanged: return ESTALE
        case .cancelled: return ECANCELED
        case .serviceUnavailable: return ENOTCONN
        case .timedOut: return ETIMEDOUT
        case .readOnly: return EROFS
        case .messageTooLarge: return EMSGSIZE
        }
    }

    public var description: String {
        switch self {
        case .invalidArgument(let why): return "invalid argument: \(why)"
        case .unknownItem: return "unknown item"
        case .unknownAccount: return "unknown account"
        case .notDirectory: return "not a directory"
        case .isDirectory: return "is a directory"
        case .revisionChanged(let expected, let actual): return "revision changed (expected \(expected), actual \(actual))"
        case .cancelled: return "cancelled"
        case .serviceUnavailable: return "storage service unavailable"
        case .timedOut: return "timed out"
        case .readOnly: return "read-only volume"
        case .messageTooLarge(let limit, let actual): return "message too large (\(actual) > \(limit) bytes)"
        }
    }
}
