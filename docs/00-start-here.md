# Mac Cloud Drive development pack

Draft v0.1 | 16 November 2026 | Proposed product design

Working product name: Mac Cloud Drive. Draft v0.1 prepared for the founder and implementation engineer. These documents describe an independent product inspired by Feather Drive. They are planning inputs, not evidence that software has been built or tested.

## The proposed first release

Build a macOS 26+ Apple Silicon app that connects one Google Drive account, imports new files through the menu bar, and exposes committed files in a read-only Finder volume. Opening a file fetches the byte ranges needed. Keep local originals untouched. Measure cache usage honestly.

This narrower beta establishes the storage engine before Finder writes, additional providers and encryption. The full product roadmap retains those capabilities. Scope and numeric targets below are proposed defaults that the founder can change.

| Document | Purpose |
| --- | --- |
| 01 PRD | Users, value, release scope and acceptance outcomes |
| 02 SRD | Software requirements with stable IDs and measurable limits |
| 03 TRD | Implementation contracts, state machines and persistence |
| 04 Architecture | Process ownership, boundaries, diagrams and decisions |
| 05 Test and release plan | Requirement coverage and release evidence |
| 06 Build plan | Ordered implementation tasks and AI handoff |
| 07 Setup and costs | Hardware, accounts, tools and spending categories |
| 08 Sources and decisions | Evidence, assumptions and unresolved questions |
| 11 DMG pipeline brief | Current task: GitHub Actions pipeline that builds a DMG (do not run) |
| 12 Pipeline usage | Secrets, running Build DMG, where the DMG appears |
| 13 B01 G0 runbook | macOS 26 test procedure, evidence and G0 decision table |
| 10 Repo, CI and test builds | GitHub setup, building DMGs on macOS runners, where to test (macOS 26), multiple GitHub accounts |

## Read and implement in this order

Read the PRD, SRD and architecture first. Begin with task B01 and gate G0. Do not start payment integration or broad provider support before the filesystem and read path work on the minimum supported OS.

The competitor audit is kept outside this repo. A source check returned the same latest listed release, 1.1.0 dated 11 November 2026. This was a documentation refresh, not a fresh binary or runtime audit. [S1]

