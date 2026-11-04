# Google Photos source: OAuth setup and integration

This guide is for the TidyByte maintainer. You do this setup once, for all users. App users do no setup. They tap **Sign in with Google** and approve Google's consent page.

The time needed is about 30 minutes for setup. Google verification takes from a few days to a few weeks.

## 1. What the feature can and cannot do

Google changed the Photos APIs on 2025-03-31. These limits are Google's. TidyByte cannot change them.

| Need | Status | Why |
|---|---|---|
| Read the user's whole library | Not possible | The Library API now returns only items the app uploaded. |
| Read items the user picks | Yes | Google Photos Picker API. The limit is 2,000 items per pick. |
| Delete from Google Photos | Not possible | No Google Photos API deletes media. TidyByte gives a review list and opens the Google Photos app, and the user deletes there. |
| Google account storage used and total | Yes | Drive API `about.get` with the `drive.file` scope. |

References:
- [Updates to the Google Photos APIs](https://developers.google.com/photos/support/updates)
- [Picker API](https://developers.google.com/photos/picker/guides/get-started-picker)
- [OAuth for iOS and desktop apps](https://developers.google.com/identity/protocols/oauth2/native-app)

## 2. Create the Google Cloud project

1. Go to <https://console.cloud.google.com/> and sign in with the account that will own the app. Use a shared or business account, not a personal one.
2. In the project picker, click **New Project**.
   - **Project name:** `TidyByte`
   - **Organization / Location:** your organization, or "No organization".
3. Click **Create**, then select the new project.

## 3. Enable the APIs

Go to **APIs & Services → Library**. Search for each API, open it, and click **Enable**:

1. **Photos Picker API** (`photospicker.googleapis.com`)
2. **Google Drive API** (`drive.googleapis.com`). It is used only to read the storage quota.

Do **not** enable the "Photos Library API". TidyByte does not use it.

## 4. Configure the OAuth consent screen

Go to **APIs & Services → OAuth consent screen**. In newer consoles this is **Google Auth Platform → Branding / Audience / Data Access**.

### 4.1 App information (Branding)

| Field | Value |
|---|---|
| App name | `TidyByte` |
| User support email | the support email from `docs/APP_STORE_LISTING.md` |
| App logo | the 1024 px app icon, scaled to 120×120 PNG. A logo needs extra review; you can skip it to verify faster. |
| Application home page | `https://tidybyte.yord.si` |
| Application privacy policy link | `https://tidybyte.yord.si/privacy`. It is required, and it must mention Google data (see §8). |
| Application terms of service link | the terms URL, if you have one |
| Authorized domains | `yord.si` — the parent domain of `tidybyte.yord.si`. Google requires verifying the parent domain in Google Search Console; subdomains cannot be verified separately. |
| Developer contact email | your email |

### 4.2 Audience

- **User type:** **External**.
- **Publishing status:** start in **Testing**. Add up to 100 **test users** (Gmail addresses). Only test users can sign in until Google verifies the app.
- When the build is ready for everyone, click **Publish app**, then submit for verification (§7).

### 4.3 Scopes (Data Access)

Click **Add or remove scopes** and add exactly these two:

| Scope | Class | Used for |
|---|---|---|
| `https://www.googleapis.com/auth/photospicker.mediaitems.readonly` | Check the label the console shows (expected: sensitive) | read the items the user picks |
| `https://www.googleapis.com/auth/drive.file` | Non-sensitive | `about.get`, which returns the storage quota |

If the Picker scope is not in the list, paste it into **Manually add scopes**.

Do **not** add `drive.readonly`, `drive.metadata.readonly`, or any `photoslibrary.*` scope. They are restricted or not needed, and a restricted scope requires a paid yearly security assessment.

## 5. Create the iOS OAuth client

Go to **APIs & Services → Credentials → Create credentials → OAuth client ID**.

| Field | Value |
|---|---|
| Application type | **iOS** |
| Name | `TidyByte iOS` |
| Bundle ID | `com.sakshammittal.tidybyte` (must match `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml`) |
| App Store ID | the numeric App Store ID (optional; add it after release) |
| Team ID | `HMWGCVU4SV` |

Click **Create** and copy the **Client ID**. It looks like `1234567890-abcdefg.apps.googleusercontent.com`.

- An iOS client has **no client secret**. TidyByte uses PKCE instead, so there is no secret to keep out of the app.
- The client ID is not a secret. It ships inside the app.
- Leave **App Check** off. TidyByte does not use Firebase.

## 6. Integrate the client ID

1. Open `ios/project.yml` and set the build setting:
   ```yaml
   settings:
     base:
       GOOGLE_IOS_CLIENT_ID: "1234567890-abcdefg.apps.googleusercontent.com"
   ```
2. Regenerate the project and build:
   ```sh
   cd ios
   xcodegen generate
   xcodebuild build -scheme Tidybyte -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
   ```

How the build uses the client ID:

| Piece | Where |
|---|---|
| `GoogleClientID` Info.plist key = `$(GOOGLE_IOS_CLIENT_ID)` | `ios/Tidybyte/Info.plist` |
| `LSApplicationQueriesSchemes: googlephotos` (detects the Google Photos app) | `ios/Tidybyte/Info.plist` |
| Redirect URI `com.googleusercontent.apps.<id>:/oauth2redirect`, derived from the client ID | `GoogleAuthService.redirectScheme` |
| Sign-in: `ASWebAuthenticationSession` + PKCE (S256); tokens in the Keychain, this device only | `ios/Tidybyte/Services/Google/GoogleAuthService.swift` |
| Picker sessions, media items, storage quota, HEAD sizes, 512 px previews | `ios/Tidybyte/Services/Google/GooglePhotosAPI.swift` |
| On-device analysis (duplicates, similar, blurry, screenshots, large videos) | `ios/Tidybyte/Features/GooglePhotos/GooglePhotosScanner.swift` |
| "iPhone / Google Photos" switch, results, review sheet | `ios/Tidybyte/Features/GooglePhotos/GooglePhotosHomeView.swift` |

You do not need a URL type in Info.plist for the redirect. `ASWebAuthenticationSession` catches the callback scheme itself.

When `GOOGLE_IOS_CLIENT_ID` is empty:
- **Debug builds:** the switch is shown, and Google mode says "Not Set Up".
- **Release builds:** the switch is hidden, and the app looks the same as before.

## 7. Google verification (needed before public release)

The Picker scope reads user photos, so expect Google to classify it as **sensitive**. Confirm the label in the console. If it is sensitive, Google must verify the app before users outside the test list can sign in. Users who sign in before verification see an "unverified app" warning.

Submit from **OAuth consent screen → Verification center**. Prepare:

1. **Scope justification**, one paragraph per scope. For example:
   - *photospicker.mediaitems.readonly:* "TidyByte lets users pick photos and videos from Google Photos with the Google Photos Picker. It analyzes them on the device to find duplicates, blurry photos, screenshots and large videos. It reads only the picked items. No data is sent to our servers; we have none."
   - *drive.file:* "Used only to call `about.get` and show the user their Google account storage usage. TidyByte creates and opens no Drive files."
2. **Demo video**, unlisted on YouTube. Show:
   - the consent screen, with the app name and the scopes visible in the URL
   - picking items
   - the results
   - the review sheet
   - sign out
3. **A verified domain** for the home page and privacy policy links: `yord.si` verified in Google Search Console, which covers `https://tidybyte.yord.si` and `https://tidybyte.yord.si/privacy`.
4. **Privacy policy** with the Google API Services User Data Policy statement (§8).

A CASA security assessment is needed only for **restricted** scopes. If the console marks either scope as restricted, stop and re-check the scope list in §4.3.

## 8. Privacy policy and App Store text

Add to the privacy policy:

> TidyByte's use of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements. TidyByte connects to Google only if you choose to connect Google Photos. Then it reads only the items you pick, analyzes them on your device, and stores nothing on any server. Your Google sign-in token is stored only in your device's Keychain. Sign out in TidyByte, or remove access at <https://myaccount.google.com/permissions>.

In App Store Connect:
- **App Privacy:** "Data Not Collected" still applies, because no data reaches the developer.
- **Review notes:** say that the Google Photos source is optional and talks only to Google. Give the reviewer a test Google account that is on the test-user list.

## 9. Test checklist

1. With an empty client ID, a release build shows no switch.
2. With the client ID set: Cleanup tab → **Google Photos** → **Sign in with Google**. The consent page lists the two scopes, and after approval the storage card shows usage.
3. Tap **Pick Photos to Scan** and pick about 20 items: one duplicate pair, a blurry shot, a screenshot, and a video over the large-file threshold. Tap Done. Each item appears in the right section.
4. Select items → **Review** → **Open Google Photos** opens the app (or photos.google.com) → **Mark as Deleted** removes the items from the list.
5. **Account → Sign Out**. The tokens are revoked, the Keychain item is gone, and the app shows the sign-in screen again.
6. Run `xcodebuild test -only-testing:TidybyteTests/GooglePhotosTests`.

## 10. Known limits

- Picked items' `baseUrl` links expire about 60 minutes after the pick. Pick again for a new scan.
- The Picker does not report file size. TidyByte sends one HEAD request per item. Items with no reported size count as 0 in "can be freed".
- "Photos & Gmail" is combined because Google does not split Photos usage from Gmail usage.
