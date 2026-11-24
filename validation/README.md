# Validation evidence

Draft v0.2 | 24 November 2026 | Branch `claude/shared-drive-sync`

Saved results of the manual acceptance tests SD-AT01…SD-AT15 in [14 Shared-drive sync](../docs/14-shared-drive-sync.md#manual-acceptance-tests). Nothing has been recorded yet.

## Layout

```
validation/
  result.schema.json        JSON Schema (Draft 2020-12) for every result.json
  <BUILD>/<OS>/<TEST_ID>/
    result.json             status, expected, observed, procedure, timestamps
    logs/…                  redacted app logs for the test window
    …                       screenshots, timings, checksums (listed in "artifacts")
```

| Part | Value |
| --- | --- |
| BUILD | App version and build, e.g. `0.1.0-12`. Same on Mac and Windows for one pipeline run. |
| OS | `macos-<productVersion>-<buildVersion>` (e.g. `macos-15.1-24B83`), `windows-<version>-<build>` (e.g. `windows-11-26100`), `ios-<version>`, `android-<version>` |
| TEST_ID | `SD-AT01` … `SD-AT15` from doc 14. A test run on Mac and Windows gets one directory per OS. |

## result.json

| Field | Meaning |
| --- | --- |
| `testId`, `gate`, `title` | e.g. `SD-AT05`, `SD`, "Phone upload appears" |
| `requirements` | SD-FR IDs the test covers (doc 14 traceability table) |
| `status` | `pass`, `fail` or `blocked`. Blocked means it could not run. It never counts as pass. |
| `reason` | Required for `fail` and `blocked` |
| `expected` / `observed` | Pass criterion / what actually happened (`null` if nothing could be observed) |
| `command` | Command or manual steps, enough to repeat |
| `build`, `os`, `startedAt`, `finishedAt` | Reproducibility |
| `artifacts` | Files next to `result.json`, as relative paths |
| `recordedBy` | Who ran a manual test |

Example:

```json
{
  "schemaVersion": 1, "testId": "SD-AT05", "gate": "SD", "title": "Phone upload appears",
  "requirements": ["SD-FR10"], "status": "pass", "reason": null,
  "expected": "Photo uploaded from iPhone visible in Finder within 60 s",
  "observed": { "secondsToVisible": 34 },
  "command": "Manual: upload IMG_0001.jpg with Drive app on iPhone, start stopwatch at 'Upload complete', stop when it appears in Finder",
  "build": { "id": "0.1.0-12" }, "os": { "id": "macos-15.1-24B83" },
  "startedAt": "2026-12-01T10:00:00Z", "finishedAt": "2026-12-01T10:01:00Z",
  "recordedBy": "tester-a"
}
```

To validate every result:

```sh
python3 -m pip install jsonschema   # once
python3 - <<'EOF'
import glob, json
from jsonschema import Draft202012Validator
v = Draft202012Validator(json.load(open("validation/result.schema.json")))
for f in sorted(glob.glob("validation/*/*/*/result.json")):
    errors = [e.message for e in v.iter_errors(json.load(open(f)))]
    print("OK " if not errors else "ERR", f, *errors)
EOF
```

## Rules

- Commit evidence; never commit apps, DMGs, installers, certificates, keys or tokens.
- Redact logs before committing: home paths, e-mail addresses, tokens, upload URLs. Use test files, not personal ones.
- Do not edit a `result.json` to change its status. Rerun the test and record the new result.
- A Linux cloud session cannot run any SD-AT test. Do not record them there as pass.
