# B01: host app entitlement and Info.plist additions

Agent A owns `App/DriveApp.entitlements` and the DriveApp `info:` block in `project.yml`. B01 needs
the additions below. Apply them when merging `docs/integration/b01-project-yml.md`. Nothing else in
the app's entitlements changes. Do not add hardened-runtime exceptions or temporary sandbox
exceptions.

## `App/DriveApp.entitlements`

Add the App Group. Keep the App Sandbox on.

```xml
<key>com.apple.security.application-groups</key>
<array>
	<string>$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID)</string>
</array>
```

Why: the sandboxed app may look up a Mach service only if the service name starts with an App
Group it belongs to. The StorageService name is `$(DEVELOPMENT_TEAM).$(APP_BUNDLE_ID).storage`,
which starts with this group. This is a G0 assumption to verify on macOS 26
(`Ping Service` in the menu proves it, or fails with `ENOTCONN`).

Not needed:

- No entitlement for `SMAppService.agent(plistName:).register()`.
- No `com.apple.security.temporary-exception.mach-lookup.global-name`. Do not add it to work around
  a failed lookup. Record the failure in the G0 ADR instead.
- No FSKit entitlement in the app. `FSClient.shared.installedExtensions` is only used to show
  whether the module is enabled. G0-VERIFY: this call works from the sandboxed app.

## DriveApp Info.plist (`info: properties:` in project.yml)

`DriveAppStorageMachService` is already there. Add:

```yaml
DriveAppTeamID: $(DEVELOPMENT_TEAM)
DriveAppBaseBundleID: $(APP_BUNDLE_ID)
```

`StorageServiceClient` builds the peer requirement from these keys:
`anchor apple generic and certificate leaf[subject.OU] = "<TEAM>" and (identifier "<APP_BUNDLE_ID>.storageservice")`.

## Signing consequences

- With `DEVELOPMENT_TEAM` empty (ad-hoc, `CODE_SIGN_IDENTITY: "-"`):
  - Debug builds skip the XPC peer check and log a fault.
  - Release builds refuse to connect, and StorageService refuses to start.
  - The FSKit module does not load at all, because fskitd rejects ad-hoc modules.
  G0 therefore needs a team-signed build.
- `com.apple.developer.fskit.fsmodule` on DriveAppFS needs a provisioning profile, for example from
  `xcodebuild -allowProvisioningUpdates`.
