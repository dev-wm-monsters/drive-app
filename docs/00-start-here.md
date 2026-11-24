# Start here

Draft v0.2 | 24 November 2026 | Branch `claude/shared-drive-sync`

## What this branch builds

A Mac and Windows client for one Google Workspace Shared Drive, `WakeupMonster`, used by 4+ people:

- Finder (Mac) and File Explorer (Windows) show the whole drive with sizes and dates, **without downloading**.
- Opening a file downloads it from Drive.
- Existing files and folders are **read-only**. Dropping in a **new** file uploads it.
- Same-name files are shown as `name (2).ext`.
- Changes appear within about 30–60 s (polling every 30 s while the app runs).
- Phones use the Google Drive app.

How: Apple File Provider on Mac, Windows Cloud Files API, Google Drive REST. Why: [ADR09](adr/ADR09-file-provider-and-cloud-files.md).

## Status (24 November 2026)

| Done | Not done |
| --- | --- |
| Spec, limits and acceptance tests ([14](14-shared-drive-sync.md)) | Any native build: no Xcode or Windows in the cloud session |
| Swift `DriveCore` and Windows core code with Linux unit tests | Any run on a real Mac, Windows PC or phone |
| Mac app, File Provider extension, Windows app source | Google OAuth clients and the Shared Drive ([15](15-google-cloud-setup.md)) |
| Build pipelines ([12](12-pipeline-usage.md)) | Signing (test builds are unsigned) |

## Documents

| Doc | Purpose | Current? |
| --- | --- | --- |
| [14 Shared-drive sync](14-shared-drive-sync.md) | Product + behaviour spec for this branch, requirements SD-FR, acceptance tests SD-AT | **Yes** |
| [15 Google Cloud setup](15-google-cloud-setup.md) | Founder steps: project, consent screen, OAuth clients, Shared Drive, admin checks | **Yes** |
| [12 Pipeline usage](12-pipeline-usage.md) | Repo variables and secrets, building test builds | **Yes** |
| [ADR09](adr/ADR09-file-provider-and-cloud-files.md), [ADR index](adr/README.md) | Decisions and what changed | **Yes** |
| [validation/README](../validation/README.md) | Where test evidence goes | **Yes** |
| 01 PRD, 02 SRD, 03 TRD, 04 Architecture, 05 Test plan, 06 Build plan | Original FSKit-era R1 design | Background. 14 supersedes their R1 scope on this branch. |
| 07 Setup and costs, 08 Sources, 10 Repo and CI, 11 DMG brief | Supporting notes | Background |

## Next steps

1. Founder: do [15](15-google-cloud-setup.md) and send back the checklist.
2. Run the pipeline to get an unsigned Mac DMG and Windows package ([12](12-pipeline-usage.md)).
3. Run SD-AT01–SD-AT15 ([14](14-shared-drive-sync.md#manual-acceptance-tests)) with the 4 users and save results under `validation/`.
