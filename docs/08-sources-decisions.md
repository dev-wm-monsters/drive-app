# Sources assumptions and open decisions

Draft v0.1 | 16 November 2026 | Proposed product design

Evidence checked or reused as of 16 November 2026. External statements support platform constraints and vendor observations. Product scope, architecture, requirements, numeric budgets and estimates are our proposals.

## S1 Feather Drive changelog

https://featherdrive.app/changelog

Source check returned release 1.1.0 dated 11 November 2026. Reuse the prior 12 November artifact audit; no newly downloaded binary was inspected.

## S2 Google OAuth for desktop apps

https://developers.google.com/identity/protocols/oauth2/native-app

Browser-based installed-app flow, PKCE and public-client assumptions.

## S3 Google Drive scopes

https://developers.google.com/workspace/drive/api/guides/api-specific-auth

Least-privilege drive.file access and the implications of broader access.

## S4 Google Drive downloads

https://developers.google.com/workspace/drive/api/guides/manage-downloads

Binary range downloads; Workspace exports are a separate capability.

## S5 Google Drive resumable uploads

https://developers.google.com/workspace/drive/api/guides/manage-uploads

Provider-confirmed offsets, transport alignment and expiring sessions.

## S6 Apple FSKit documentation

https://developer.apple.com/documentation/fskit/

Platform design reference. Exact API availability, mount resource and IPC deployment require a macOS 26 spike.

## S7 Apple Developer enrollment

https://developer.apple.com/programs/enroll/

Membership price checked 16 November 2026; regional price varies.

## S8 Apple partial content fetching

https://developer.apple.com/documentation/fileprovider/nsfileproviderpartialcontentfetching

File Provider can support partial reads; do not claim only FSKit can do so.

## S9 Feather Drive security

https://featherdrive.app/security

Prior audit records the vendor encryption design. Our encryption implementation remains deferred and must be reviewed independently.

## Unresolved items

Track G0 deployment, immutable revision reads, benchmark baselines, source snapshotting and later feature gates in the architecture decision log.

No native runtime tests are claimed. Observed Feather Drive components come from the earlier static 1.1.0 audit; private implementation and reliability remain unknown.

