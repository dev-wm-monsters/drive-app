# Google Cloud and Workspace setup

Draft v0.1 | 24 November 2026 | For the founder (Workspace admin) | ~30 minutes

What you click in Google so the Mac and Windows apps can sign in and see the `WakeupMonster` Shared Drive. Product spec: [14](14-shared-drive-sync.md). Console labels were checked against Google's docs on 24 November 2026 (sources at the end); Google renames things often, so look for the nearest match.

Never paste client IDs or secrets into chat, issues or committed files. They go into GitHub repo settings only (step 7).

## 1. Create the Google Cloud project

1. Sign in to <https://console.cloud.google.com> with your **Workspace admin** account (not a personal Gmail).
2. Project picker › **New project**. Name: `WakeupMonster DriveApp`. Organization: your Workspace domain. **Create**.
3. **APIs & Services › Library** › search **Google Drive API** › **Enable**.

No billing account is needed today. Google says charges past the free thresholds are planned "later in 2026" with 90 days' notice ([limits page](https://developers.google.com/workspace/drive/api/guides/limits)); we are far below them (step 6).

## 2. OAuth consent screen (Google Auth Platform)

1. Menu › **Google Auth Platform** › **Branding**. If it says "Google Auth platform not configured yet", click **Get Started**.
2. **App Information:** App name `DriveApp`, User support email = you. **Next**.
3. **Audience:** choose **Internal**. **Next**. (Internal = only accounts in your Workspace can sign in, and Google does not need to review the `drive` scope.)
4. **Contact Information:** your e-mail. **Next**. **Finish:** accept the User Data Policy › **Continue** › **Create**.
5. **Data Access** › **Add or Remove Scopes**: tick or paste `https://www.googleapis.com/auth/drive`, `openid`, `.../auth/userinfo.email`. **Update** › **Save**.

For Internal apps the scopes are not shown on the consent screen and need no verification. Adding them still documents what the app asks for.

## 3. Create the two OAuth clients

Google Auth Platform › **Clients** › **Create client**.

| Client | Application type | Fields | You get |
| --- | --- | --- | --- |
| Mac | **iOS** | Name `DriveApp Mac`. **Bundle ID** = `APP_BUNDLE_ID` from `project.yml` (now `com.wakeupmonster.driveapp.dev`). App Store ID: empty. Team ID: your Apple team ID if you have one (optional). | **Client ID** and the **iOS URL scheme** (= reversed client ID, `com.googleusercontent.apps.…`). No secret. |
| Windows | **Desktop app** | Name `DriveApp Windows`. Nothing else. | **Client ID** and **Client secret**. The secret is shown in full **only once**: download the JSON right away. |

Why iOS for a Mac app: Google's Sign-In guide says "For iOS and macOS apps the OAuth client ID application type must be configured as iOS", with the reversed client ID as the URL scheme. Google's general native-app page instead recommends a Desktop client with a loopback redirect for macOS and says custom URI schemes are "no longer supported" there. Those two statements apply to different client types: the iOS client keeps the reversed-client-ID scheme; Desktop clients must use loopback. We follow the Sign-In guide (iOS client + `<reversed client id>:/oauth2redirect`). Fallback if Google ever refuses it: a Desktop client with loopback on the Mac too (code change in the Mac app, see [ADR09](adr/ADR09-file-provider-and-cloud-files.md)).

If you change `APP_BUNDLE_ID` later (e.g. drop `.dev`), edit the Mac client's Bundle ID to match.

## 4. Workspace admin checks

At <https://admin.google.com>:

| Check | Where | Set to |
| --- | --- | --- |
| Shared Drive creation allowed | Apps › Google Workspace › Drive and Docs › Sharing settings › **Shared drive creation** | "Prevent users … from creating new shared drives" **unticked** (at least for you) |
| App access to Drive | Security › Access and data control › **API controls** | If **Unconfigured third-party apps** is "Allow any third-party apps" and Drive is **Unrestricted** under Manage Google Services, nothing to do. |
| If Drive is Restricted or apps are blocked | API controls › **Manage App Access** › Configured apps › **Configure new app** › search the client ID › select › all users › **Trusted** | Do this for **both** client IDs. Or tick **Trust internal apps**. |

Restricted Drive blocks untrusted apps from high-risk scopes, including full `drive`, and revokes their tokens. If sign-in works but every Drive call fails with 403, this is the first thing to check.

## 5. Create the Shared Drive and add members

1. <https://drive.google.com> › **Shared drives** › **New** › name exactly `WakeupMonster`. The name must be unique among drives the users can see, or the app reports "ambiguous" and you must set `DRIVE_ROOT_FOLDER_ID`.
2. **Manage members** › add the 4 users:

| Role | Can do in our app | Also can in Google Drive itself |
| --- | --- | --- |
| **Content manager** (default for the 4 users) | Browse, download, add new files | Edit, move, move to trash |
| Contributor | Browse, download, add new files via the API (untested) | Edit; cannot trash. Google Drive for desktop treats Contributors as read-only. |
| Viewer | Browse and download only | Nothing else |
| Manager | Everything above | Manage members, delete permanently. Keep to yourself. |

Our app never edits, moves or deletes, whatever the role. Phones upload through the Drive app, which needs Contributor or higher.

To use one shared **folder** instead of a Shared Drive: share the folder with the 4 users, open it in drive.google.com, and copy the ID from the URL (`…/folders/<ID>`) into `DRIVE_ROOT_FOLDER_ID`.

## 6. Quotas

From Google's [Drive API limits](https://developers.google.com/workspace/drive/api/guides/limits) (updated 1 May 2026, read 24 November 2026):

| Limit | Value | Our use (4 users) |
| --- | --- | --- |
| Per user per minute (per project) | 325,000 quota units | Polling: 2 × `changes.list` (100 units each) = ~200/min/user |
| Per project per minute | 1,000,000 quota units | ~800/min idle |
| Per project per day | 400,000,000 quota units (charges planned beyond) | ~1.2 M/day idle |
| Egress per project per day | 1 TB (charges planned beyond) | Only what people open |
| Method costs | read 5, list 100, edit/upload 50, download 200 | First full listing: 100 per folder |
| Upload per user per day | 750 GB | — |
| Max file size | 5 TB | — |

Nothing to request. If needed later: Cloud console › **Quotas & System Limits**.

## 7. Where each value goes

GitHub › repo › **Settings › Secrets and variables › Actions**. The build pipeline ([12](12-pipeline-usage.md)) injects them; they are never committed.

| Name | Kind | Value |
| --- | --- | --- |
| `GOOGLE_CLIENT_ID_MAC` | Variable | Mac (iOS) client ID |
| `GOOGLE_REVERSED_CLIENT_ID` | Variable | Mac client's iOS URL scheme |
| `GOOGLE_CLIENT_ID_WINDOWS` | Variable | Windows (Desktop) client ID |
| `GOOGLE_CLIENT_SECRET_WINDOWS` | **Secret** | Windows client secret |
| `DRIVE_ROOT_SHARED_DRIVE_NAME` | Variable | `WakeupMonster` |
| `DRIVE_ROOT_FOLDER_ID` | Variable | Empty, or a folder / drive ID to override the name |

Google treats a Desktop client secret as not truly confidential (it ships inside the app), but keep it in Secrets anyway.

## What we need back from you

- [ ] Project created, Drive API enabled
- [ ] Consent screen **Internal**, scopes added
- [ ] Mac iOS client created with the right Bundle ID; `GOOGLE_CLIENT_ID_MAC` and `GOOGLE_REVERSED_CLIENT_ID` set
- [ ] Windows Desktop client created; `GOOGLE_CLIENT_ID_WINDOWS` variable and `GOOGLE_CLIENT_SECRET_WINDOWS` secret set
- [ ] Shared Drive `WakeupMonster` exists; 4 members added with roles (tell us who is Viewer)
- [ ] Admin console: Drive Unrestricted, or both clients marked **Trusted**
- [ ] Final `APP_BUNDLE_ID` (keep `com.wakeupmonster.driveapp.dev` for testing?)
- [ ] Two disposable test accounts for automated/agent testing, if you want any (never your own)

## Sources

- OAuth for native apps (Desktop client, loopback, custom schemes no longer supported): <https://developers.google.com/identity/protocols/oauth2/native-app>
- Google Sign-In for iOS and macOS (iOS client type for macOS, reversed client ID): <https://developers.google.com/identity/sign-in/ios/start-integrating>
- Manage OAuth clients (iOS fields, Desktop fields, secret shown once): <https://support.google.com/cloud/answer/15549257>
- Configure the OAuth consent screen: <https://developers.google.com/workspace/guides/configure-oauth-consent>
- Control which apps access Workspace data (API controls, Trusted, Trust internal apps): <https://knowledge.workspace.google.com/admin/apps/control-which-apps-access-google-workspace-data>
- Allow users to create shared drives: <https://support.google.com/a/answer/12374228>
- Shared drive roles: <https://support.google.com/a/users/answer/12380484>
- Drive API usage limits: <https://developers.google.com/workspace/drive/api/guides/limits>
