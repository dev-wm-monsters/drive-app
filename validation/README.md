# Validation evidence

Draft v0.1 | 16 November 2026 | Evidence store

Saved results for gate tests and test-plan runs. The layout follows [05 Test plan › Evidence layout](../docs/05-test-plan.md#evidence-layout). The G0 procedure is in [13 B01 G0 runbook](../docs/13-b01-g0-runbook.md).

## Layout

```
validation/
  result.schema.json                 JSON Schema (Draft 2020-12) for every result.json
  <BUILD>/<OS>/
    g0-summary.json                  per-criterion roll-up and G0 decision (scripts/b01-spike.sh collect)
    <TEST_ID>/
      result.json                    status, expected, observed, command, timestamps
      fixture-manifest.json          fixture-check manifest (paths, sizes, SHA-256, generator seed)
      logs/driveapp.log.txt          redacted: log show --predicate 'subsystem BEGINSWITH "com.wakeupmonster.driveapp"'
      logs/fskit.log.txt             redacted FSKit/fskitd log for the same time window
      …                              test-specific artifacts listed in result.json "artifacts"
```

| Part | Value |
| --- | --- |
| BUILD | `<CFBundleShortVersionString>-<CFBundleVersion>` of the tested app, e.g. `0.0.1-1`. `linux-cloud-session` marks runs with no app. |
| OS | `macos-<productVersion>-<buildVersion>`, e.g. `macos-26.1-<build>`. Off macOS: `linux-<id>-<version>`. |
| TEST_ID | `G0-ENV`, `G0-SIGN`, `G0-EXT-ACTIVATE`, `G0-MOUNT`, `G0-LIST`, `G0-READ-RANGE`, `G0-EOF`, `G0-CANCEL`, `G0-READONLY`, `G0-IPC-AUTH`, `G0-SERVICE-RESTART`, `G0-UNMOUNT`. Later gates use `G1-…` or test-plan IDs `T01…T16`. |

## result.json

| Field | Meaning |
| --- | --- |
| `status` | `pass`, `fail` or `blocked`. Blocked means the test could not run. It never counts as pass. |
| `reason` | Required for `fail` and `blocked` |
| `expected` / `observed` | Pass criterion as text / raw observed values (`null` when nothing could be observed) |
| `command` | Reproducible command, or manual procedure |
| `build`, `os`, `startedAt`, `finishedAt`, `exitCode` | Reproducibility (NFR10) |
| `artifacts`, `fixtureManifest` | Files next to `result.json`, as relative paths |
| `g0Verify` | Platform assumptions this test has to confirm |

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

- Commit evidence; never commit DMGs, apps, certificates, keys or tokens.
- Logs are redacted automatically: `$HOME` paths, user names, e-mail addresses, bearer tokens, key-value secrets, long hex/base64 strings and certificate holder names. Review them anyway before committing.
- Do not edit a machine-written `result.json` to change its status. Rerun the test, or add a manual result with `recordedBy` set to the person and the procedure in `command`.
- `linux-cloud-session/linux-ubuntu-24.04/` holds the honest record from the Linux cloud session. Every G0 test there is blocked. Its `fixture-manifest.json` files are real `fixture-check manifest` output.
