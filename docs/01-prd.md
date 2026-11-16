# Product requirements document

Draft v0.1 | 16 November 2026 | Proposed product design

Purpose: make remote files usable from familiar Mac apps without a mandatory whole-file download. The first beta targets people with small SSDs and large media archives. It prioritizes correct reads and recoverable uploads over provider count.

## User and problem

Primary user: an individual Mac user who stores videos, PDFs and images in the cloud, wants to browse in Finder and has reliable internet. Secondary user: a media creator opening original footage while keeping project files, render caches and databases local.

## Product promise

Your files remain in your Google Drive. Finder exposes their names, sizes and folders. The app fetches content as applications read it. Storage is bounded for cached reads, while uploads require separate temporary staging space. Internet remains necessary for uncached data.

| Release | Included |
| --- | --- |
| R0 feasibility | Test volume, one range-read path, FSKit lifecycle and signing feasibility |
| R1 private beta | One Drive account; app-created root; read-only Finder volume; menu-bar import; durable resumable uploads; local filename search; cache and queue settings |
| R2 reliable editing | Finder writes, atomic-save behavior, rename, trash, revision conflicts and optional access to existing files |
| R3 wider product | Dropbox, SFTP, reviewed encryption and recovery, browser sharing, optional MCP connector, paid licenses and polished distribution |

## Not in the first beta

No writable Finder volume, automated source deletion, full-drive OAuth scope, shared drives, Google Docs editing, multi-user collaboration, offline pinning, encrypted storage format, public share links or payment backend. These are staged work, not removed from the product vision.

## Commercial positioning

Use storage the user already owns. Do not bundle a storage subscription. Pricing and license terms remain undecided; prototype and private-beta access are free. R3 commercial operations must not become a prerequisite for retrieving a user’s own data.


# Product journeys and success criteria

## Connect and open

Install the app, connect Google, approve the filesystem extension and open the Finder volume. R1 only shows files created by this app in its managed root. Existing cloud files are not automatically included; make that limitation visible during onboarding.

## Import and recover

Choose a local file from the menu-bar palette. The app checks space, stages a stable copy and persists the queue. It uploads in the background. After server confirmation, the item appears in Finder. Closing the lid or losing connectivity preserves the job. The original local file stays untouched.

## Use and understand storage

Open a committed file in the usual app. Show separate values for read cache, pending-upload storage and metadata. Clearing the read cache must never discard pending uploads. If offline content is missing, show an actionable connection error.

| Outcome | Beta acceptance |
| --- | --- |
| Correctness | All committed file fixtures match expected SHA-256; no source deletion; no acknowledged queued import lost in the fault suite |
| First open | Proposed p95 first-frame target at most 3 seconds under the benchmark in NFR02; publish actual results |
| Onboarding | At least 4 of 5 pilot testers connect and open a sample without direct assistance |
| Storage clarity | Every tester can distinguish cache from pending uploads; cache-clear preserves all queued jobs |
| Trust | No credentials or file content in logs; readable permission explanation; reliable disconnect |

## Required screens

Onboarding checklist; provider connection and extension status; search palette; import and upload queue; storage settings; error details with redacted diagnostics. Each job exposes staging, queued, uploading, verifying, complete, retrying or cancelled state.

## Dependencies and release decision

A compatible test Mac, Apple signing configuration and working Google OAuth credentials are required. Founder accepts scope and benchmark fixtures; engineer demonstrates the gates; QA reviews saved test evidence. The beta does not promise compatibility with live databases, project libraries, disk images or every video codec.

