# DriveApp (working name)

Mac and Windows client for the Google Workspace Shared Drive **`WakeupMonster`**. Every file shows in Finder / File Explorer without downloading. Opening a file downloads it. Existing items are read-only; new files upload. Phones use the Google Drive app.

| Read | For |
| --- | --- |
| [docs/00-start-here.md](docs/00-start-here.md) | Overview and status |
| [docs/14-shared-drive-sync.md](docs/14-shared-drive-sync.md) | What the app does, limits, acceptance tests |
| [docs/15-google-cloud-setup.md](docs/15-google-cloud-setup.md) | Founder: Google Cloud, OAuth clients, Shared Drive, admin checks |
| [docs/12-pipeline-usage.md](docs/12-pipeline-usage.md) | Building the Mac DMG and Windows package |
| [AI-HANDOFF.md](AI-HANDOFF.md) | Rules for coding agents |

| Part | Path | Status (24 Nov 2026) |
| --- | --- | --- |
| Shared Drive logic (Swift) | `Packages/DriveCore` | Written; unit tests run on Linux |
| Mac app + File Provider extension | `App/`, `FileProviderExtension/`, `project.yml` | Written; **not built or run** (needs Xcode) |
| Windows app (.NET 8, Cloud Files) | `windows/` | Written; Linux build and unit tests only; **not run on Windows** |
| Pipelines | `.github/`, `scripts/` | Written; not run |
| Device acceptance tests | `validation/` | None yet |

Still needed from the founder: Google OAuth clients and the Shared Drive ([docs/15](docs/15-google-cloud-setup.md#what-we-need-back-from-you)).

The earlier FSKit read-only volume spike (B01) lives on branch `claude/beautiful-goldberg-dr7wlu`.
