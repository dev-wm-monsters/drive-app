// SpikeFileSystem.swift
// FSUnaryFileSystem for the B01 spike. The resource is a generic URL, `driveappspike://spike`
// (no block device, no path). The single volume is served by StorageService over XPC.
//
// Docs / headers relied on:
// - https://developer.apple.com/documentation/fskit/fsunaryfilesystem
// - https://developer.apple.com/documentation/fskit/fsunaryfilesystemoperations
// - https://developer.apple.com/documentation/fskit/fsunaryfilesystemoperations/loadresource(resource:options:replyhandler:)
//   (options: `-f` force, `--rdonly` read-only)
// - https://developer.apple.com/documentation/fskit/fsgenericurlresource  (macOS 26.0; FSSupportedSchemes)
// - https://developer.apple.com/documentation/fskit/fsproberesult  (name and containerID non-nil unless notRecognized)
// - https://developer.apple.com/documentation/fskit/fscontainerstatus
// - https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system
// - macOS 26.5 SDK FSKit.framework/Headers/FSUnaryFileSystem.h, FSResource.h, FSContainer.h
// - Field notes (not Apple): https://github.com/mkmik/fs9kit/blob/main/docs/research/fskit-api.md §2.1, §4
//   (mount(8) builds an FSGenericURLResource from the URL string and skips probe for it; the
//   probe containerID must equal the volume ID; containerStatus must be .ready before replying
//   from loadResource and reset to .ready on unload, or the next mount reports "Resource busy").
// G0-VERIFY: the containerStatus rules above come from third-party field reports, not Apple docs.

import Foundation
@preconcurrency import FSKit
import os
import StorageCore

/// `@unchecked Sendable`: no mutable Swift state; `containerStatus` is owned by FSKit.
final class SpikeFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    static let urlScheme = "driveappspike"
    static let catalogHost = "spike"
    static let volumeName = "DriveApp Spike"
    /// Fixed so the probe container ID always equals the volume ID (one spike volume only).
    static let containerUUID = UUID(uuid: (0x5D, 0x1B, 0x0A, 0x7E, 0x3C, 0x41, 0x4E, 0x2F,
                                           0x9A, 0x61, 0xB0, 0x01, 0xD7, 0x1F, 0x5A, 0x01))

    private let client = StorageServiceClient()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DriveAppFS", category: "filesystem")

    private static func spikeURL(of resource: FSResource) -> URL? {
        guard let resource = resource as? FSGenericURLResource else { return nil }
        let url = resource.url
        guard url.scheme?.lowercased() == urlScheme, url.host()?.lowercased() == catalogHost else { return nil }
        return url
    }

    func probeResource(resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        // mount(8) skips probe for generic URL resources; answer correctly if anything else asks.
        guard Self.spikeURL(of: resource) != nil else { return reply(FSProbeResult.notRecognized, nil) }
        reply(FSProbeResult.usable(name: Self.volumeName, containerID: FSContainerIdentifier(uuid: Self.containerUUID)), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard Self.spikeURL(of: resource) != nil else {
            logger.error("loadResource: not a \(Self.urlScheme, privacy: .public)://\(Self.catalogHost, privacy: .public) URL resource")
            return reply(nil, fs_errorForPOSIXError(EINVAL))
        }
        if options.taskOptions.contains("-f") {
            return reply(nil, fs_errorForPOSIXError(ENOTSUP)) // Nothing to format.
        }
        // The volume is read-only whether or not `--rdonly` was passed (FR12).
        let readOnlyRequested = options.taskOptions.contains("--rdonly")
        logger.info("loadResource: rdonly option \(readOnlyRequested, privacy: .public)")

        containerStatus = .ready
        let volume = SpikeVolume(client: client,
                                 volumeID: FSVolume.Identifier(uuid: Self.containerUUID),
                                 name: Self.volumeName,
                                 logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "DriveAppFS", category: "volume"))
        reply(volume, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        containerStatus = .ready
        logger.info("unloadResource")
        reply(nil)
    }

    func didFinishLoading() {
        logger.info("FSKit module loaded")
    }
}
