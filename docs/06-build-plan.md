# Implementation backlog and engineering handoff

Draft v0.1 | 16 November 2026 | Proposed product design

Work in vertical slices. Finish a gate before expanding scope. Each task must include a runnable demonstration or recorded test result; code generation alone is not completion.

| Task | Gate | Deliverable |
| --- | --- | --- |
| B01 | G0 | Signed empty app, FSKit test volume and service/XPC proof |
| B02 | G0 | Fake provider with deterministic range fixtures and typed errors |
| B03 | G1 | Google OAuth and app-managed root with least privilege |
| B04 | G1 | Metadata index, paged directory listing and stable item IDs |
| B05 | G1 | Checksummed byte reads, EOF, cancellation and revision invalidation |
| B06 | G1 | Bounded cache, read coalescing and restrained read-ahead |
| B07 | G2 | Staging admission, free-space check, snapshot and durable queue |
| B08 | G2 | Resumable upload and server-offset recovery |
| B09 | G2 | Commit verification, duplicate reconciliation and cancel race |
| B10 | G3 | Menu-bar palette, search, storage controls and actionable errors |
| B11 | G3 | Crash, network, performance, privacy and accessibility matrix |
| B12 | G3 | Signed beta installer, update/manual recovery and pilot review |

## Suggested repository

App/ for UI; FileSystemExtension/ for FSKit; StorageService/ for the data owner; Packages/StorageCore/ for domain types, range math and persistence; Tests/ for deterministic and integration suites; docs/ for this pack; validation/ for evidence. Add a backend directory only when commercial service work begins.

## First agent handoff

The included AI-HANDOFF.md directs the coding agent to B01 only, read PRD/SRD/architecture, validate prerequisites and implement the smallest signed spike. It requires reporting blocked hardware tests honestly and forbids adding payments or extra providers to bypass the core work.

## Planning estimate

A read-only feasibility prototype is roughly 2 to 5 person-weeks. A focused full-feature beta remains roughly 14 to 24 person-weeks including later capabilities, depending on platform experience and test results. These are planning judgments, not delivery commitments. Do not convert AI-assisted coding speed directly into a shorter recovery-validation schedule.

