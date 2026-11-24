// Thumbnails from Drive's thumbnailLink, fetched with the user's token.

import DriveCore
import Foundation

extension ProviderCore {
    /// Largest thumbnail response accepted.
    static let maxThumbnailBytes = 4 * 1024 * 1024

    /// Thumbnail bytes for an item, or nil when Drive has none.
    func thumbnail(identifier: String, maxPixels: Int) async throws -> Data? {
        let root = try await root()
        let id = Self.driveID(for: identifier, root: root)
        guard id != root.id else { return nil }
        let file = try await services.client.file(id: id)
        guard !file.isFolder, let link = file.thumbnailLink else { return nil }

        var request = URLRequest(url: Self.sized(link, maxPixels: maxPixels))
        request.timeoutInterval = 20
        let token = try await services.auth.accessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await services.transport.data(for: request)
        guard response.statusCode == 200 else {
            Log.transfer.debug("Thumbnail HTTP \(response.statusCode, privacy: .public) for \(id, privacy: .private)")
            return nil
        }
        if let type = response.value(forHTTPHeaderField: "Content-Type"), !type.lowercased().hasPrefix("image/") {
            return nil
        }
        guard !data.isEmpty, data.count <= Self.maxThumbnailBytes else { return nil }
        return data
    }

    /// Drive thumbnail links end in "=s<px>" (e.g. "=s220"); ask for the
    /// requested size instead, clamped to 32...1600.
    static func sized(_ link: URL, maxPixels: Int) -> URL {
        let px = min(max(maxPixels, 32), 1600)
        let s = link.absoluteString
        guard let range = s.range(of: "=s[0-9]+$", options: .regularExpression) else { return link }
        return URL(string: s.replacingCharacters(in: range, with: "=s\(px)")) ?? link
    }
}
