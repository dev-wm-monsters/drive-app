# B01 integration: project.yml and App edits

Agent C wrote this for the orchestrator. It lists the exact XcodeGen changes that wire the B01
spike into `project.yml`, plus one small edit to Agent A's app entry point. Nothing here has been
built: this Linux session has no Xcode or macOS SDK. All native checks are **blocked** until a
macOS build runs.

Sources:

- XcodeGen ProjectSpec: https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md.
  `extensionkit-extension` and `tool` are valid product types. Dependency `copy.destination` accepts
  `productsDirectory` and `executables`. `postBuildScripts` accepts `inputFiles` and `outputFiles`.
- ExtensionKit embedding uses the "Embed ExtensionKit Extensions" location:
  `productsDirectory` + `$(EXTENSIONS_FOLDER_PATH)`, which is `DriveApp.app/Contents/Extensions`.
  This matches a working FSKit XcodeGen spec (mkmik/fs9kit `macos/project.yml`).
- SMAppService looks for the agent plist in `Contents/Library/LaunchAgents`, and the plist's
  `BundleProgram` path is relative to the bundle:
  https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:).

## 1. Package

Uncomment the existing `packages:` block, or add it:

```yaml
packages:
  StorageCore:
    path: Packages/StorageCore
```

## 2. DriveApp target: merge into the existing target

```yaml
  DriveApp:
    sources:
      - path: App
        excludes:
          - "B01/*.md"            # keep the notes file out of Copy Bundle Resources
      - path: Shared
    info:
      path: App/Info.plist
      properties:
        # ...existing keys, including DriveAppStorageMachService, unchanged...
        DriveAppTeamID: $(DEVELOPMENT_TEAM)
        DriveAppBaseBundleID: $(APP_BUNDLE_ID)
    dependencies:
      - package: StorageCore
      - target: DriveAppFS
        embed: true
        codeSign: true
        copy:
          destination: productsDirectory
          subpath: $(EXTENSIONS_FOLDER_PATH)      # DriveApp.app/Contents/Extensions
      - target: DriveAppStorageService
        embed: true
        codeSign: true
        copy:
          destination: executables                # DriveApp.app/Contents/MacOS
    postBuildScripts:
      - path: StorageService/generate-launchagent-plist.sh
        name: Generate StorageService LaunchAgent plist
        shell: /bin/sh
        outputFiles:
          - $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/$(APP_BUNDLE_ID).storageservice.plist
```

Notes:

- `App/DriveApp.entitlements` needs the App Group. See `App/B01/B01-entitlements-notes.md`.
- XcodeGen inlines the contents of `path:` scripts into the build phase, so the script file itself
  does not need to be an input under `ENABLE_USER_SCRIPT_SANDBOXING: YES`.
- Post-build scripts run after the copy phases. Xcode signs the app after every phase, so the
  generated plist is sealed into the signature.
- G0-VERIFY: if the user-script sandbox blocks `mkdir` of `Contents/Library/LaunchAgents`, set
  `ENABLE_USER_SCRIPT_SANDBOXING: "NO"` on the DriveApp target only.
- G0-VERIFY: check that XcodeGen generates a Copy Files phase with "Code Sign On Copy" for the
  `tool` dependency (destination Executables). After a build, check that
  `DriveApp.app/Contents/MacOS/DriveAppStorageService` exists and that
  `codesign -dv --verbose=4` shows `Identifier=$(APP_BUNDLE_ID).storageservice` and the team.

## 3. New target: DriveAppFS (FSKit module, ExtensionKit)

```yaml
  DriveAppFS:
    type: extensionkit-extension
    platform: macOS
    sources:
      - path: FileSystemExtension
        excludes:
          - "Info.plist"
          - "*.entitlements"
      - path: Shared
    dependencies:
      - package: StorageCore
    settings:
      base:
        PRODUCT_NAME: DriveAppFS
        PRODUCT_BUNDLE_IDENTIFIER: $(APP_BUNDLE_ID).fsext
        GENERATE_INFOPLIST_FILE: "NO"
        INFOPLIST_FILE: FileSystemExtension/Info.plist
        CODE_SIGN_ENTITLEMENTS: FileSystemExtension/DriveAppFS.entitlements
        ENABLE_APP_SANDBOX: "YES"
        SKIP_INSTALL: "YES"
```

Do not use an `info:` block here. `FileSystemExtension/Info.plist` is a hand-written file that
carries `EXAppExtensionAttributes`, and an `info:` block would make XcodeGen overwrite it.
`extensionkit-extension` is listed under Product Type in the current ProjectSpec. G0-VERIFY: the
installed XcodeGen version accepts it. fs9kit pins `minimumXcodeGenVersion: "2.38.0"` for it.

## 4. New target: DriveAppStorageService (LaunchAgent tool)

```yaml
  DriveAppStorageService:
    type: tool
    platform: macOS
    sources:
      - path: StorageService
        excludes:
          - "Info.plist"
          - "*.entitlements"
          - "*.sh"
      - path: Shared
    dependencies:
      - package: StorageCore
    settings:
      base:
        PRODUCT_NAME: DriveAppStorageService     # BundleProgram = Contents/MacOS/DriveAppStorageService
        PRODUCT_BUNDLE_IDENTIFIER: $(APP_BUNDLE_ID).storageservice
        GENERATE_INFOPLIST_FILE: "NO"
        INFOPLIST_FILE: StorageService/Info.plist
        CREATE_INFOPLIST_SECTION_IN_BINARY: "YES"
        CODE_SIGN_ENTITLEMENTS: StorageService/DriveAppStorageService.entitlements
        ENABLE_APP_SANDBOX: "NO"                 # justified in the entitlements file header
        SKIP_INSTALL: "YES"
```

The project-level settings already supply hardened runtime, `ARCHS: arm64`, Swift 6 and
macOS 26.0. Do not rename `PRODUCT_NAME`: the LaunchAgent plist script hard-codes
`Contents/MacOS/DriveAppStorageService`.

## 5. Identity values derived from `settings.base`

Nothing is hard-coded. Every value derives from `APP_BUNDLE_ID` and `DEVELOPMENT_TEAM`.

| Thing | Value |
| --- | --- |
| App | `$(APP_BUNDLE_ID)` |
| FSKit module | `$(APP_BUNDLE_ID).fsext`, FSShortName `driveappspike`, URL scheme `driveappspike` |
| Service | `$(APP_BUNDLE_ID).storageservice` at `Contents/MacOS/DriveAppStorageService` |
| LaunchAgent plist | `Contents/Library/LaunchAgents/$(APP_BUNDLE_ID).storageservice.plist` (generated) |
| Label | `$(APP_BUNDLE_ID).storageservice` |
| Mach service | `$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID).storage` (all three Info.plists and the agent plist) |
| App Group | `$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID)` (app, extension, service) |
| Info.plist keys in all three targets | `DriveAppStorageMachService`, `DriveAppTeamID`, `DriveAppBaseBundleID` |

Renaming the bundle ID needs no file renames. The LaunchAgent plist is generated at build time,
so a checked-in file named `com.wakeupmonster.driveapp.dev.storageservice.plist` would be one more
place to keep in sync.

## 6. Scheme

Building the `DriveApp` scheme builds its target dependencies, so this is optional. To make the
dependencies explicit, list them:

```yaml
schemes:
  DriveApp:
    build:
      targets:
        DriveApp: all
        DriveAppFS: all
        DriveAppStorageService: all
```

## 7. Edit to Agent A's `App/DriveAppMain.swift`

Do not change anything else. Add one `@State` property and one `SpikeStatusView` call between the
version line and Quit:

```swift
@main
struct DriveAppMain: App {
    @State private var spike = SpikeController()          // B01

    var body: some Scene {
        MenuBarExtra(AppInfo.name, systemImage: "externaldrive") {
            Text(AppInfo.name)
            Text(AppInfo.versionLine)
            Divider()
            SpikeStatusView(controller: spike)            // B01
            Divider()
            Button("Quit \(AppInfo.name)") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
```

`SpikeController` is `@MainActor @Observable`. `@State` keeps one instance for the app's lifetime,
which needs macOS 14 or later; the deployment target is 26.0.

## 8. Manual G0 flow (for the runbook owner, Agent D)

1. Build signed with a real team. The FSKit entitlement needs a provisioning profile:
   `xcodebuild ... DEVELOPMENT_TEAM=<TEAM> -allowProvisioningUpdates`.
2. Copy `DriveApp.app` to `/Applications` and launch it.
3. In the menu, choose **Register Storage Service**. If it shows "Needs approval", choose
   **Approve in Login Items…** and turn on DriveApp.
4. Choose **Ping Service**, then **Read Sample Range**. The read result must say "matches fixture".
5. Turn the module on in System Settings › General › Login Items & Extensions › File System
   Extensions, then choose **Check FS Extension**.
6. Mount from Terminal with `mkdir -p ~/DriveAppSpike && mount -F -t driveappspike driveappspike://spike ~/DriveAppSpike`.
   G0-VERIFY: whether this needs `sudo`, and whether the mount point must be under `/Volumes`.
7. Unmount with `umount ~/DriveAppSpike`.
8. Test service restart while the volume is mounted:
   `launchctl kill SIGKILL gui/$(id -u)/$(APP_BUNDLE_ID).storageservice`. In-flight reads fail with
   `ENOTCONN`. The next read relaunches the agent through its Mach service.

Logs:

```sh
log stream --predicate 'subsystem BEGINSWITH "<APP_BUNDLE_ID>" OR process == "fskitd"'
```
