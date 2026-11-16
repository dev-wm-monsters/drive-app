// DriveAppFSExtension.swift
// Entry point of the DriveAppFS ExtensionKit extension (FSKit module, FSShortName `driveappspike`).
//
// Docs / interface relied on:
// - https://developer.apple.com/documentation/fskit/unaryfilesystemextension
//   (`associatedtype FileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations`; `var fileSystem { get }`)
// - macOS 26.5 SDK FSKit.swiftmodule/arm64e-apple-macos.swiftinterface (FSKit re-exports ExtensionFoundation)
// G0-VERIFY: Apple's template and samples return the file system from a computed property; a stored
// `let` is used here so FSKit always sees one instance. Confirm the extension launches with it.

import Foundation
@preconcurrency import FSKit

@main
struct DriveAppFSExtension: UnaryFileSystemExtension {
    let fileSystem = SpikeFileSystem()
}
