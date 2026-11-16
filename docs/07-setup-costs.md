# Development setup and spending checklist

Draft v0.1 | 16 November 2026 | Proposed product design

Prepare these before implementation. The existing host was observed on macOS 15.7.1 during the earlier audit; confirm current hardware and OS before scheduling a native spike. No purchases or account changes are made by this document.

| Requirement | When | Cost basis |
| --- | --- | --- |
| Compatible Apple Silicon Mac and macOS 26+ | Before G0 | Use existing compatible hardware or budget for a test machine |
| Xcode and command-line tools | Before G0 | No separate tool purchase |
| Apple Developer Program | Signing and distribution spike | US$99 per year; regional currency/pricing may differ [S7] |
| Google Cloud project and OAuth configuration | Before B03 | Set up credentials, consent and quota monitoring; no fixed spend assumed |
| Disposable Google account and enough storage | Before integration tests | Storage plan or existing quota; large fixture testing may need paid capacity |
| SQLite GRDB and Swift tooling | Implementation | Open-source/platform tools; review licenses and pin dependencies |
| Domain hosting email and license database | Commercial release | Usage-based recurring costs; unnecessary for R0 private spike |
| Payment gateway | Commercial release | Transaction/platform fees and merchant onboarding; verify chosen plan then |
| Dropbox and SFTP test environments | R3 | Existing accounts or paid storage/server use |
| Security review and QA time | Before sensitive feature release | Budget professional time; not replaced by AI-generated tests |

## Account configuration checklist

Choose a distinct product name, bundle IDs, app/service/extension signing identities and shared Keychain/App Group policy. Configure Google consent and native-client redirects. Separate development and production credentials. Keep secrets out of source and logs; document who owns release signing and recovery.

## Decisions to confirm before coding

Founder: product name, R1 managed-root scope, read-only beta, Apple Silicon first and no beta encryption. Engineer: G0 service model, FSKit availability, source staging limits and revision-safe read policy. No answer is required to read this pack; these become explicit implementation decisions at the relevant gate.

