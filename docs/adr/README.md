# Architecture decision records

Draft v0.1 | 16 November 2026 | Proposed product design

The summary table in [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) holds all decisions. A decision gets its own file only when a gate needs more detail. If a detail record changes a decision, update the summary row too.

| ADR | Decision | Status | Record |
| --- | --- | --- | --- |
| ADR01 | Native Swift and FSKit | Proposed | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR02 | One Drive account first | Proposed | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR03 | Single storage service | Spike required | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow); detail: [ADR03 G0 service and XPC](ADR03-g0-service-xpc.md) (Proposed — pending G0 evidence) |
| ADR04 | Read-only Finder beta | Proposed | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR05 | No encryption in R1 | Proposed | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR06 | No commercial backend in R1 | Proposed | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR07 | New objects only | Proposed | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |
| ADR08 | Apple Silicon first | Proposed | [04 Architecture](../04-architecture.md#architecture-decisions-and-product-flow) |

## Writing a detail record

- File name: `ADRnn-short-topic.md`, with the same `Draft | date | Status` line as the other docs.
- Sections: Context, Decision or proposal, Alternatives and their consequences, what evidence proves it (with test IDs), Decision rule, Evidence.
- Status values: Proposed, Spike required, Accepted, Rejected, Superseded by ADRnn. Do not mark a record Accepted until its evidence is saved under `validation/`.
