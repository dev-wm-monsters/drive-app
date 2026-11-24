# Architecture decision records

Draft v0.2 | 24 November 2026 | Branch `claude/shared-drive-sync`

The summary table in [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) holds the original R1 decisions. On this branch [ADR09](ADR09-file-provider-and-cloud-files.md) changes several of them; the **This branch** column wins where it differs.

| ADR | Decision | Status | This branch | Record |
| --- | --- | --- | --- | --- |
| ADR01 | Native Swift and FSKit | Proposed | Changed by ADR09: File Provider (Mac), Cloud Files (Windows) | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR02 | One Drive account first | Proposed | Changed by ADR09: `drive.file` → `drive` scope, Internal app, Shared Drive root | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR03 | Single storage service | Superseded by ADR09 | No XPC service; the extension owns its Drive client | [ADR03 G0 service and XPC](ADR03-g0-service-xpc.md) |
| ADR04 | Read-only Finder beta | Proposed | Changed by ADR09: read-only existing items + add new files | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR05 | No encryption in R1 | Proposed | Unchanged | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR06 | No commercial backend in R1 | Proposed | Unchanged | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR07 | New objects only | Proposed | Kept: uploads pick a free name; display names add ` (n)` | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR08 | Apple Silicon first | Proposed | Mac arm64 only; Windows x64 | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR09 | File Provider on Mac, Cloud Files on Windows, Drive REST, 30 s polling, read-only + add-new | Accepted (founder-directed, 24 Nov 2026) | — | [ADR09](ADR09-file-provider-and-cloud-files.md) |

The FSKit design (ADR01, ADR03 as written) is kept on branch `claude/beautiful-goldberg-dr7wlu`.

## Writing a detail record

- File name: `ADRnn-short-topic.md`, with the same `Draft | date | Status` line as the other docs.
- Sections: Context, Decision, Alternatives and their consequences, Consequences, Evidence (with test IDs).
- Status values: Proposed, Spike required, Accepted, Rejected, Superseded by ADRnn. Mark a record Accepted only when its evidence is saved under `validation/`, or when the founder directs it; then say so in the status line.
