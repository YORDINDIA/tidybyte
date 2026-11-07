# App Store Connect Listing — TidyByte

> **HISTORICAL (2026-08):** 1.1.1 (build 8) had shipped and 1.1.3 (build 10)
> was in review; 1.1.2 never shipped. A fresh App Store Connect check on
> 2026-11-01 shows 1.1.3 is **READY_FOR_SALE** with no editable version.
> The site's `/changelog` is the canonical version history.

Paste-ready copy for App Store Connect. Char-count annotations are inline. Anything marked **TODO** needs a human decision before submission.

> **Bundle ID (confirmed):** The app ships as **`com.sakshammittal.tidybyte`** (widget: `com.sakshammittal.tidybyte.widget`, tests: `com.sakshammittal.tidybyte.tests`). This matches `AppGroupStore.swift`'s App Group (`group.com.sakshammittal.tidybyte.shared`), both `.entitlements` files, and `project.yml`. Use `com.sakshammittal.tidybyte` when creating the App Store Connect app record, registered to Team **HMWGCVU4SV**.

---

## 1. App Name & Subtitle

**App Name** (max 30 chars):

```
TidyByte: Photo Cleaner
```
23 chars. ✅ This keeps the TidyByte brand and adds the high-intent "Photo
Cleaner" phrase. The same title is used in all 21 storefront localizations.

**Subtitle options** (max 30 chars each — pick one):

| Option | Text | Chars | Notes |
|---|---|---|---|
| **New** | `Swipe to free up storage` | 24 ✅ | **Approved candidate.** Pairs the swipe loop with the storage outcome. |
| I | `Clean photos, free up storage` | 29 ✅ | Previous subtitle. |
| H | `Photo cleaner, free space` | 25 ✅ | Shortest phrase carrying both intents, but noun-form and weaker on storage. |
| A | `Swipe to clean your photos` | 26 ✅ | Strong on the swipe hook, weak on storage intent. |
| B | `Declutter photos, free space` | 28 ✅ | Balanced. |
| C | `Photo cleaner & storage saver` | 29 ✅ | Names both the cleaner and the storage outcome. |
| E | `Storage cleaner, photo cleaner` | 30 ✅ | At the limit. Leads with the storage problem. |
| D | `Storage cleaner & photo cleaner` | 31 ❌ | Too long by one character. |
| F | `Clean storage & compress images` | 31 ❌ | Too long by one character. |
| G | `Free storage cleaner & compressor` | 33 ❌ | Too long — listed to show the ceiling. |

Character counts above are measured, not estimated: `[...text].length` in JavaScript.
An earlier revision of this table listed E as 31 characters and marked it too long;
it is 30 and fits. D and F were each overstated by one character. The counts are
what App Store Connect enforces, so they are worth re-measuring after any edit.

**Selected candidate:** `TidyByte: Photo Cleaner` / `Swipe to free up storage`.
The English subtitle is 24 characters. All 21 subtitle localizations are
machine-drafted and have not had a native-speaker review. This is a directional
listing change, not a randomized title test; compare performance to the prior
baseline after release.

Neither option fits the word "compressor" alongside "cleaner" within 30
characters, so the App Store keyword field is where that term belongs.

---

## 2. Promotional Text (max 170 chars)

```
Free up storage with a swipe. Find duplicates and blurry shots, and compress videos. Cleanup runs on your device. No ads or TidyByte account.
```
Length: **141 chars** ✅ (Promotional text can be updated without a new version.)

---

## 3. Description

```
TidyByte is the fastest, most private way to clean up your iPhone photo library — and it's completely free.

TidyByte runs on iPhone, iPad, and iPhone Duo — and stays out of your way while it cleans.

Tired of "Storage Almost Full"? TidyByte turns photo cleanup into something you'll actually finish. Swipe left to delete, swipe right to keep — review your whole library one photo at a time, just like a dating app, and reclaim gigabytes in minutes.

Beyond swiping, TidyByte packs a full toolkit of smart cleanup tools that surface exactly what's wasting your space: exact and visual duplicates, near-identical similar shots, blurry or poorly-lit photos, screenshots, screen recordings, chat media saved by messaging apps, burst sequences, and your largest files. Convert Live Photos to stills and compress videos and photos to save even more — without deleting your memories.

Your iPhone photo library stays on your device. TidyByte analyzes and cleans photos on-device with Apple's Vision and Photos frameworks, including local AI search that finds photos from a plain-language description. There is no TidyByte backend or account, no ads, and no tracking. If you choose to connect Google Photos, you sign in with Google, and TidyByte reads only the items you select directly from Google. Your iPhone photo library is never uploaded to TidyByte.

TidyByte is free, with no in-app purchases and no paywalls. Every feature is available to everyone.

Features:
• Tinder-style swipe to review photos and videos — swipe to delete or keep
• Duplicate finder — exact (SHA-256) and visually similar duplicates
• Similar photos — group near-identical shots taken close together
• Blurry photo detection — find out-of-focus and poorly-exposed shots
• Screenshot cleaner — round up and clear screenshots
• Screen recording cleaner — clear forgotten screen recordings, largest first
• Chat media cleaner — review what WhatsApp, Telegram and other messengers saved
• Burst cleaner — pick the best from burst sequences
• Smart Categories — sort photos by content type, with on-device AI search in plain words
• Large file finder — surface the biggest files in your library
• Live Photo converter — turn Live Photos into stills to save space
• Video compression — shrink videos while keeping them watchable
• Photo compression — re-encode photos to reclaim space
• Storage dashboard — see what's using your space at a glance
• Activity & savings — track everything you've cleaned and total space freed
• Home Screen widget and Siri shortcuts for one-tap cleanups
• Optional cleanup reminders via local notifications

Free up space. Keep your privacy. Clean with a swipe.
```

All listed features map to shipping tools (see verification at bottom). No fabricated features.

---

## 4. Keywords (max 100 chars, comma-separated, no spaces after commas)

Apple indexes the app name, subtitle and keyword field together, so words already present in the name or subtitle must not be repeated here. The field therefore depends on which subtitle ships.

**Approved candidate: `TidyByte: Photo Cleaner` / `Swipe to free up storage`.**
The name and subtitle already index "tidybyte", "photo", "cleaner", "swipe",
"free", "up", and "storage", so the field targets other intents. This is the
current candidate in `docs/appstore/listings.json` (93 chars ✅):

```
duplicate,image compressor,compress video,screenshot,blurry,declutter,junk,similar,ai,gallery
```

`cleaner` was removed because the new app name indexes it; `gallery` is back in
the field. This is a **hypothesis, not measurement** — no App Store search-term
or ranking data was inspected:

- `gallery` is assumed to be browsing intent rather than cleanup intent, and the
  app is assumed to rank poorly (or not at all) on it.
- Three of the ten apps in TidyByte's own "You Might Also Like" row carry "AI" in
  the name — AI Duplicate Photo Remover, Photo Cleaner - Cleaner AI, and Cleaner
  AI: Free Up Space — which suggests the token matters, but a competitor's name
  is not evidence about this app's ranking.
- TidyByte ships an on-device AI search without naming it anywhere Apple indexes,
  so the token is cheap to try.
- `gallery` may be less valuable than an alternative term; validate with search
  term data before treating this as settled.

The localized keyword fields were adjusted where the new subtitle created an
exact repeated term. The translations and the full keyword strategy still need
a native ASO review per language.

The following field was for the previous subtitle I. It repeated "storage" and
"clean", both already indexed, and is retained here as a historical example:

```
storage,duplicate,image compressor,compress video,screenshot,blurry,declutter,gallery,clean
```

**If a different subtitle ships**, re-derive the field from that subtitle's words:

Subtitle A (`Swipe to clean your photos`) — 95 chars ✅:

```
storage cleaner,duplicate photo,compress video,image compressor,screenshot,blurry,free up space
```

Subtitle B (`Declutter photos, free space`) — 98 chars ✅:

```
storage cleaner,duplicate photo,image compressor,compress video,screenshot,blurry,clean up,gallery
```

Subtitle C (`Photo cleaner & storage saver`) — the words "photo", "cleaner", "storage" and "saver" are already indexed, so the field targets the remaining intents. 91 chars ✅:

```
duplicate,image compressor,compress video,screenshot,blurry,free up space,declutter,gallery
```

Subtitle H (`Photo cleaner, free space`) — "photo", "cleaner", "free" and "space" are already indexed. 91 chars ✅:

```
storage,duplicate,image compressor,compress video,screenshot,blurry,declutter,gallery,clean
```

**What changed from the previous 93-char field.** `cleaner` moved into the app
name, and `gallery` returned to the field. The current subtitle indexes
`swipe`, `free`, `up`, and `storage`; the remaining terms are candidates, not
measured winners.

**TODO (human):** final keyword tuning is an ASO call. Validate against your App Store Connect search-term data before shipping, and re-check the character count after any subtitle change: 100 characters is a hard limit, and spaces after commas waste them.

**Caveat on localized keywords.** The strict validator removes exact name/subtitle
overlaps. It does not infer stemming, transliteration, or how each storefront
tokenizes a script, so these machine-drafted fields still need native ASO review.

---

## 5. Categories

- **Primary: Utilities** — recommended.
- **Secondary: Photo & Video** — recommended.

**Reasoning:** TidyByte's core value is freeing up device storage and decluttering — a maintenance/utility job — which aligns with how comparable "phone cleaner / storage" apps are categorized and ranked. Photo & Video is the natural secondary since the app operates entirely on the photo library and includes compression/conversion. If ASO data later shows the app ranks better under Photo & Video, the two can be swapped; Utilities is the safer primary for discoverability of cleanup intent.

---

## 6. URLs

| Field | Value | Required? |
|---|---|---|
| Support URL | `https://tidybyte.yord.si/support` | Required |
| Marketing URL | `https://tidybyte.yord.si` | Optional |
| Privacy Policy URL | `https://tidybyte.yord.si/privacy` | **Required** |
| Terms of Service (EULA) link | `https://tidybyte.yord.si/terms` | Required |

The Terms of Service page incorporates Apple's standard EULA by reference for App Store downloads. Leave App Store Connect's custom EULA fields empty (select "Apple's standard EULA"); the link satisfies the "public terms of service" field.

The production site is live at `https://tidybyte.yord.si`. Support and privacy
routes were checked after deployment; verify the terms route before submitting
a new app version. Search Console and Bing sitemap submission were not checked.

---

## 7. Age Rating

**Recommended rating: 4+** (no objectionable content).

Answer the App Store Connect age-rating questionnaire as follows (all "None"/"No"):

- Cartoon or Fantasy Violence: **None**
- Realistic Violence: **None**
- Sexual Content or Nudity: **None**
- Profanity or Crude Humor: **None**
- Alcohol, Tobacco, or Drug Use: **None**
- Mature/Suggestive Themes: **None**
- Horror/Fear Themes: **None**
- Gambling, Contests: **None / No**
- Unrestricted Web Access: **No**
- User-generated content / messaging: **No**

This yields a **4+** rating. Note: the app displays the user's own photos, which may include personal content, but the app itself ships no objectionable content — 4+ is correct.

---

## 8. App Privacy — "Data Not Collected"

In **App Store Connect → your app → App Privacy**:

1. Under "Data Collection," select **"Data is not collected from this app."**
2. This produces a **"Data Not Collected"** privacy label with no data-type details required.

**Rationale (truthful and verifiable):**
- TidyByte has **no backend**. It makes no network connections unless the user connects the optional Google Photos source. Only then does it connect, and only to Google APIs, with the user's own sign-in. Nothing goes to the developer, and nothing from the iPhone library leaves the device.
- All photo analysis (Vision feature prints, blur/exposure detection, SHA-256 hashing) and all cleanup run **100% on-device**.
- There is **no account/login, no analytics SDK, no ad SDK, and no tracking**.
- This is reflected in `Tidybyte/Resources/PrivacyInfo.xcprivacy`: `NSPrivacyTracking = false`, empty `NSPrivacyTrackingDomains`, and an **empty `NSPrivacyCollectedDataTypes` array**. (The file declares only required-reason API usage: DiskSpace, UserDefaults, and FileTimestamp — these are API-usage declarations, not data collection.)

---

## 9. Export Compliance

- The app uses **no encryption** beyond what is exempt (standard OS/HTTPS usage). HTTPS is used only if the user connects Google Photos.
- `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption` is set to **`NO`** in `project.yml`, so the value is baked into the build's Info.plist. App Store Connect should **not** show a "Missing Compliance" prompt.
- If a compliance question does appear, answer: **"No"** (the app does not use non-exempt encryption). No CCATS / self-classification report is needed.

---

## 10. App Review Notes

Paste into the **App Review Information → Notes** field:

```
TidyByte cleans up the device photo library. To review it properly:

- Use a PHYSICAL iPhone with REAL photos and videos in the library. The iOS Simulator has a small fake photo library and will not exercise most tools meaningfully.
- On first launch, the app requests Photo Library access — please grant FULL access (read & write). Without it, the Swipe screen and Cleanup tools have nothing to operate on.
- Optionally, the app requests Notifications permission only if "Cleanup Reminders" is enabled in Settings; it is not required to review the app.
- No TidyByte account or login is needed for the core app. Google Photos is optional and requires Google sign-in.
- The app is free with no in-app purchases. All processing is on-device. The app goes online only if the user connects Google Photos. That optional source (Cleanup tab → Google Photos) signs in with Google and reads only the items the user picks. Add a test Google account (on the OAuth test-user list) to the review notes before submitting.
- Write actions (deleting photos, saving compressed videos/converted Live Photos) go through the standard iOS PhotoKit confirmation prompts.
```

---

## 11. Screenshots

**Current assets:** `docs/screenshots/iphone/` and `docs/screenshots/ipad/`, seven PNGs each, regenerated by `npm run screenshots`. The legacy flat `docs/screenshots/*.png` files (1206 × 2622, RGBA) are superseded and must not be uploaded — they carry an alpha channel App Store Connect rejects.

**Requirements (verified against Apple, 2026-10):** App Store Connect requires **one iPhone screenshot for "iPhone with Dynamic Island (medium display)"** — accepted sizes **1179 × 2556** or **1206 × 2622** portrait. The 6.9" set (1320 × 2868) is accepted but **optional**; Apple scales the medium set down for larger displays. Because the app ships iPad (`TARGETED_DEVICE_FAMILY: "1,2"`), an **iPad 13-inch screenshot is also mandatory** — accepted sizes **2064 × 2752** or **2048 × 2732** portrait. Minimum 1, maximum 10 screenshots per device size. PNG/JPEG only, and **no alpha channel** — `simctl` output is RGBA and must be flattened. Regenerate with `npm run screenshots`, which writes `docs/screenshots/<iphone|ipad>/` at the exact accepted sizes with alpha stripped and prints a verification table. Source: <https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications>

Suggested upload order, per device (from `docs/screenshots/<device>/`): `01-swipe-home`, `02-cleanup-tools`, `06-storage-dashboard`, `03-cleanup-duplicates`, `07-activity-savings`, then `04-cleanup-screenshots` and `05-cleanup-blurry-photos`. Up to 10 allowed per device size. The legacy `05-swipe-session`, `06-album-picker` and `07-session-complete` shots need manual taps to reach and are not produced by the automated pipeline.

**iPhone Duo (foldable, shipping 23 October 2026 with iOS 27.1):** App Store Connect grades the two Duo displays as **one row** — a single "iPhone Duo" entry that carries both displays' sizes under one heading — and supplying it earns the **"optimized for iPhone Duo" badge** on the product page. The default model is therefore one Duo row with one group id, `IPHONE_DUO_PROFILE`.

| Row | Accepted sizes (portrait) | Accepted sizes (landscape) | Captured to |
|---|---|---|---|
| iPhone Duo (one row, both displays) | **1398 × 2034** (outer) and **2007 × 2853** (inner) | 2034 × 1398 (outer), 2853 × 2007 (inner) | `docs/screenshots/duo-outer/` and `docs/screenshots/duo-inner/` |

Both are fixed sizes — the 1179-vs-1206 slack the iPhone row allows does not apply — and both are exactly 3× the display's point size. Capture with `node scripts/growth/shoot-screenshots.mjs --duo`, which needs the **iOS 27.1 simulator runtime** (the `--duo` flag checks for it before building), writes the two directories above with alpha stripped, and verifies the dimensions. Both directories feed the single Duo row; capture stays per display, the upload collapses both into one row. Same rules as every other row: PNG/JPEG, no alpha channel, 1-10 per row.

**Status: captured; upload pending the 1.1.1 submission.** Both directories exist — 5 PNGs at 1398 × 2034 and 5 at 2007 × 2853, captured 2026-10-18 on the iOS 27.1 runtime. The App Store Connect group id for the single Duo row is **`IPHONE_DUO_PROFILE`**, read from the live catalog by `npm run publish:verify`; `plan.mjs` pins it as the default, so `npm run publish:media -- --duo` needs no environment variable. A two-group split — setting both `TIDYBYTE_DUO_OUTER_GROUP_ID` and `TIDYBYTE_DUO_INNER_GROUP_ID`, one directory each — remains a **fallback only**, for the case where the catalog really does show two `APP_SCREENSHOT` groups; the published spec says one and the live catalog agrees, so one is the default. Setting only one of the two now throws rather than silently falling back to the single group. See `docs/duo-readiness.md` for the claims ledger and the open items. From **April 2027** the Duo screenshots become **mandatory** for apps built with the iOS 27.1 SDK, so this row stops being optional then.

---

## 12. What's New (v1.1.3 release notes)

```
Faster on large libraries: the first swipe card now appears in about a second, photos load while the app scans, and Storage and Cleanup open much sooner. If your photos did not load, or albums looked empty, TidyByte now tells you why. When iOS shares no photos with the app, or a permission is stuck, you get the exact steps to fix it, with buttons for Settings, choosing photos, and trying again. The Recently Deleted notice no longer hides under the tab bar. Everything still runs on your device: no account, no ads, no subscription.
```
Length: 535 chars. Translated into all 21 storefront locales by `scripts/localization/translations/_notes-1.1.3.mjs`, which reuses the 1.1.2 photo-access text verbatim.

### v1.1.2 release notes, never shipped

1.1.2 (build 9) was withdrawn from review before review started, and the version was renamed to 1.1.3. These notes are kept because 1.1.3 reuses them.

```
If your photos did not load, or albums looked empty, TidyByte now tells you why. When iOS shares no photos with the app, or a permission is stuck, you get the exact steps to fix it, with buttons for Settings, choosing photos, and trying again. Everything still runs on your device: no account, no ads, no subscription.
```
Length: 318 chars. Translated into all 21 storefront locales by `scripts/localization/translations/_notes-1.1.2.mjs`.

### v1.1.1 release notes, for the record

```
Now built for iPhone Duo: same cleanup, adapted to both displays. This update also fixes what a full review found: in Arabic and Hebrew a swipe could show Keep while deleting the photo, switching language mid-session could discard deletions you had not confirmed, and several labels stayed in English. Everything still runs on your device: no account, no ads, no subscription.
```
Length: 376 chars (well under the 4000-char release-notes limit). Translated into all 21 storefront locales by `scripts/localization/translations/_notes-1.1.1.mjs`.

### v1.1.0 release notes, for the record

What users on 1.1.0 can actually see. The Duo sentence in the 1.1.0 draft never went live: build 7 was uploaded before the Duo work landed, so 1.1.0 shipped the language release and nothing else.

```
TidyByte now speaks 20 languages, with full right-to-left layout for Arabic and Hebrew. Dates, sizes and counts follow your region, and Siri shortcuts work in your language. Everything still runs on your device: no account, no ads, no subscription.
```
Length: 268 chars. Source: `scripts/localization/translations/_notes-1.1.0.mjs`.

---

## 12b. Version history for App Store Connect

| Version | Build | Release notes source |
|---|---|---|
| 1.1.3 | 10 | §12 above. The photo-access recovery (#11), the large-library speed fixes (#6-#8), the Storage first-load fix (#9) and the Recently Deleted notice fix (#10). |
| 1.1.2 | 9 | Never shipped. Withdrawn from review and renamed to 1.1.3; build 9 is unused. |
| 1.1.1 | 8 | §12 (for the record). The iPhone Duo work and the review fixes, neither of which build 7 carried. |
| 1.1.0 | 7 | The 20-language release: RTL, region-aware formatting, localized Siri phrases. Build 7 is what is live; build 8 was never uploaded for this version. |
| 1.0.5 | 6 | On-device AI search, Screen Recordings tool, Chat Media tool, smarter reminders. |
| 1.0.4 | — | Cleanup tools refresh: UI, honest savings numbers, keep-choices preserved across scans. (1.0.3 was skipped.) |
| 1.0.2 | — | Storage dashboard redesign, cross-tab deep links, cleanup-tool fixes. |
| 1.0.1 | — | Native iPad support, album picker fix, settings layout. |
| 1.0 | 1 | Initial release. |

The same table appears on the site at `https://tidybyte.yord.si/changelog`, which is the canonical version history. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` are the source of truth for the app binary.

---

## 13. Website landing pages (per-feature URLs)

The marketing site now has one landing page per cleanup tool, each targeting its own search intent. Use these as the Marketing URL for App Store Connect promotional links, or in review notes, rather than linking everything to the home page:

| Tool | URL |
|---|---|
| All cleanup tools (hub) | https://tidybyte.yord.si/photo-cleaner |
| Storage cleaner | https://tidybyte.yord.si/storage-cleaner |
| Duplicate photos | https://tidybyte.yord.si/duplicate-photo-cleaner |
| Similar photos | https://tidybyte.yord.si/similar-photo-cleaner |
| Screenshots | https://tidybyte.yord.si/screenshot-cleaner |
| Screen recordings | https://tidybyte.yord.si/screen-recording-cleaner |
| Chat media | https://tidybyte.yord.si/chat-media-cleaner |
| Blurry photos | https://tidybyte.yord.si/blurry-photo-cleaner |
| Large files | https://tidybyte.yord.si/large-file-cleaner |
| Burst photos | https://tidybyte.yord.si/burst-photo-cleaner |
| Live Photo converter | https://tidybyte.yord.si/live-photo-converter |
| Video compression | https://tidybyte.yord.si/video-compression |
| Image compression | https://tidybyte.yord.si/image-compression |
| Photo organizer | https://tidybyte.yord.si/photo-organizer |
| AI photo search | https://tidybyte.yord.si/on-device-ai-photo-search |
| Free, no subscription | https://tidybyte.yord.si/free-photo-cleaner-no-subscription |

---

## Verification Summary

| Item | Limit | Value | Count | OK |
|---|---|---|---|---|
| App Name | 30 | `TidyByte` | 8 | ✅ |
| Subtitle A | 30 | `Swipe to clean your photos` | 26 | ✅ |
| Subtitle B | 30 | `Declutter photos, free space` | 28 | ✅ |
| Subtitle C | 30 | `Photo cleaner & storage saver` | 29 | ✅ |
| Subtitle H | 30 | `Photo cleaner, free space` | 25 | ✅ |
| Promotional Text | 170 | (see §2) | 157 | ✅ |
| Keywords (any subtitle) | 100 | (see §4) | 90–98 | ✅ |

**Shipping cleanup tools** (verified against `Tidybyte/Features/Cleanup/CleanupTool.swift` enum + view directories): Duplicates, Similar Photos, Screenshots, Screen Recordings, Chat Media, Blurry Photos, Smart Categories, Large Files, Burst Photos, Live Photos, Video Compression, Photo Compression — twelve tools, plus on-device AI photo search inside Smart Categories, the Swipe review flow, the Storage dashboard, and the Activity & Savings ledger. **RecentlyDeleted was removed and is intentionally NOT listed.**

**Every claim in §3 maps to shipped functionality.** The "on-device AI search" line describes `Tidybyte/Services/LocalPhotoIntelligence.swift`: FoundationModels when available, keyword label matching otherwise, both local. The "chat media" line describes `ChatAlbumSelection` in `Tidybyte/Features/Cleanup/ChatAlbumSelection.swift`. If a future release removes either, update §3 and the site's tool pages together.

---

## 14. Localized listings (20 languages)

The app ships 20 languages, so the store listing is localized too. The machine-readable
copy lives in **`docs/appstore/listings.json`** — one entry per storefront language, with
App Store Connect's field limits recorded in `_limits` so they cannot drift from this doc.

| Command | Purpose |
|---|---|
| `node scripts/localization/make-listings.mjs` | Regenerates `listings.json` from the English copy in this document. Run it after editing §1–§4 or §12. |
| `node scripts/localization/check-listings.mjs` | Validates every field: character limits, empty values, keyword hygiene (no space after a comma, no term repeated from the name or subtitle), and a shared name across storefronts. |
| `node scripts/localization/check-listings.mjs --strict` | The same, but also fails while any language is untranslated. All 20 languages are translated, and this is what CI runs. |

**Subtitle and keywords carry the ASO weight:**

1. **Subtitle** — the selected candidate is `Swipe to free up storage` (24 chars).
   It is in `listings.json` for all 21 locales as a machine-drafted translation;
   native-speaker review is still needed. Apple indexes the app name, subtitle,
   and keyword field together, so a subtitle change can make keyword terms
   redundant.
2. **Keywords** — tuned against the selected candidate, but not against App Store
   search-term data. See §4 for the hypothesis and review caveats.

**What is deliberately *not* localized:**

- `name` stays `TidyByte: Photo Cleaner` in every storefront to keep the brand and
  shared English search phrase consistent. The subtitle, promotional text, and
  description are localized; those machine-drafted translations still need review.
- **Screenshots** are captured in English only (`npm run screenshots`). App Store Connect
  accepts a localized set per language, but Apple does not require one: if a localization
  has no screenshots, the next best available language is shown. Localized screenshots
  remain a design task rather than a translation one — see §11.
- **Growth assets are localized.** In-App Events, Custom Product Pages, Asset Library
  creatives, Product Page Optimization treatments, and the header/search creatives are all
  rendered in all 20 languages by `npm run growth`. That is a hard requirement, not a
  choice: Apple requires text inside a creative asset to be localized for every language
  the app supports. See §15.

**Shipping order:** submit the localized listings after the app binary that contains the
translations is approved, so a storefront never promises a language the binary cannot
render.
