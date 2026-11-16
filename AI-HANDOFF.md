# First implementation task

Read docs/01-prd.md, docs/02-srd.md, docs/03-trd.md, docs/04-architecture.md and docs/05-test-plan.md before coding. Treat this pack as draft requirements, not recovered Feather Drive source.

Implement B01 only: a signed macOS 26+ feasibility spike with an empty app, a read-only FSKit test volume and an authenticated host/service/extension IPC proof. Validate the current machine and SDK first. Do not upgrade the OS, change security settings, connect a real cloud account or spend money without the needed authorization.

Use a distinct temporary bundle identity. Prove mount, directory listing, a deterministic local byte-range fixture, EOF, cancellation, unmount and service-restart failure handling. If the proposed service/XPC arrangement is unavailable, record evidence and an ADR rather than claiming success or weakening permissions.

Return changed files, exact build/test commands, actual results, platform blockers and the G0 decision. Native checks that cannot run must be marked blocked. Do not add cloud integration, encryption, payments, extra providers or broad architecture abstractions in this task.

Build environment: read docs/10-repo-ci-and-test-builds.md. If you are running in a Linux cloud environment you cannot run xcodebuild, sign, notarise or mount FSKit volumes. Write the code, run any pure-Swift package tests you can, push, and mark every native check as blocked pending the macOS CI build or a macOS 26 test machine. Never commit DMGs, certificates or keys.

After G0 passes, follow B02 through B12 in order. Every requirement must map to saved test evidence. Keep the user’s originals and credentials safe; use disposable fixtures and accounts.
