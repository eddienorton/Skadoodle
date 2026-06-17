# Skadoodle — Project Context for Claude

## About the Developer
Eddie Brayman, 72, independent iOS developer, East Village NYC. 50+ years coding experience. Works solo with Claude as primary coding partner. Philosophy: one price, no ads, ever. Ship-ready every build. Direct about uncertainty rather than guessing.

---

## What This App Is
**Skadoodle** (Xcode project name: `snoodle`) is a social doodling app for iPhone and iPad. Users draw, get AI-generated captions and tags, save to a private local gallery, and optionally post to a community world gallery backed by Firebase.

**App Store ID:** 6771497563  
**App Store URL:** https://apps.apple.com/us/app/skadoodle/id6771497563  
**Bundle ID:** maxsdad.skadoodle  
**Firebase project:** snoodle-68bfc  
**Current version at last session:** 2.1 build 4 (June 2026)
**Last released to App Store:** 2.1 build 4 (June 2026)

---

## Architecture

### Stack
- **SwiftUI** with UIKit bridges where needed
- **Drawing engine:** custom UIKit canvas (`DrawingEngine.swift`)
- **Stamps:** UIKit layer (`StampCanvas.swift`) embedded in SwiftUI via `UIViewRepresentable`
- **Auth:** Sign In with Apple via `SnoodleAuthManager`
- **Backend:** Firebase Firestore, Firebase Storage, FCM push notifications

### Backend
- **Firebase Firestore** — community gallery (`world_gallery` collection), user profiles (`users`), follows, likes, comments, notifications
- **Firebase Storage** — doodle images at `world_doodles/`, profile photos at `profile_photos/`
- **Firebase Auth** — Apple Sign-In only

### Key Singletons (ObservableObject)
- `WorldGalleryManager.shared` — all community feed state, pagination, queries
- `SnoodleAuthManager.shared` — auth state, Apple Sign-In
- `SnoodleStore.shared` — local private doodle persistence (UserDefaults metadata + disk image files)
- `UserProfileManager.shared` — fetches/caches user profiles in batches of 30
- `FollowManager.shared` — follow/unfollow, feed
- `NotificationManager.shared` — FCM push notifications

### Tab Structure (ContentView.swift)
0. Gallery (GalleryTab) — community + private gallery
1. Calendar (CalendarTab) — private doodles by date
2. New (DrawScreen) — drawing canvas
3. Settings (SettingsTab)
4. Profile (ProfileTab → PublicProfileView)

### Key Files
| File | Lines | Notes |
|------|-------|-------|
| `GalleryTab.swift` | ~1779 | Main gallery UI, WorldSnoodleDetailView, comment sheets |
| `SnoodleFirebase.swift` | ~1819 | All Firebase logic, WorldGalleryManager, auth, managers |
| `DrawScreen.swift` | ~2127 | Main canvas, stamp placement, gesture handling, AI caption flow |
| `DrawingEngine.swift` | ~1494 | Pen rendering (pencil/ink/brush/marker/chalk/neon/spray/watercolor/dotted/dualTone) |
| `StampCanvas.swift` | ~556 | UIKit stamp rendering, hit testing (pixel-accurate scaleAspectFit fix) |
| `StampTools.swift` | ~1200 | PlacedStamp model, stamp picker, renderCanvasWithStamps, TextStampComposer |
| `ProfileView.swift` | ~1002 | PublicProfileView, follow lists, profile editing |
| `SettingsTab.swift` | ~801 | Settings, account delete, download my doodles |
| `Models.swift` | ~300 | SnoodleEntry, SnoodleStore, share card generation |
| `ContentView.swift` | ~376 | Root TabView, onboarding, version check |
| `CalendarTab.swift` | ~215 | Calendar grid view |
| `SnoodleAuth.swift` | ~122 | SignInView, ImagePickerView |

---

## Pagination & Filtering

### FeedQuery enum (WorldGalleryManager)
```swift
enum FeedQuery { case everyone, artist(String), following([String]), search(String) }
```

### How pagination works
- **everyone / artist**: cursor-based using `lastDocumentSnapshot` + `start(afterDocument:)`
- **following**: timestamp-based (`whereField("timestamp", isLessThan: lastTimestamp)`) because batched `in` queries can't share a single Firestore cursor. Fetches in batches of 30 userIds.

### Firestore composite index (already exists, sufficient for all queries)
`world_gallery`: `userId ASC, timestamp DESC, __name__ DESC` — Status: Enabled

### searchIndex field
All `world_gallery` docs have a `searchIndex` array field (lowercased caption words + keywords combined). Search routes through Firebase `array-contains` on the first query term; additional words are filtered client-side from results. Backfill of old docs was run once via SettingsTab Debug button (b4).

### Search pagination
`.search(String)` uses cursor-based pagination (`lastDocumentSnapshot` + `start(afterDocument:)`), same as `.everyone` and `.artist`.

### Firestore composite indexes (both enabled)
- `world_gallery`: `userId ASC, timestamp DESC, __name__ DESC`
- `world_gallery`: `searchIndex ARRAYS, timestamp DESC` — for search queries

---

## Bugs Fixed in v1.9

### 1. Following feed pagination stopped at 20
**Root cause:** `fetchFollowing()` never stored `lastDocumentSnapshot`, so `fetchNextPage()` had no cursor.  
**Fix:** Switched following pagination to timestamp-based (`timestamp < lastTimestamp`) in `fetchNextPage()`.

### 2. Search detail view showed everything
**Root cause:** `WorldSnoodleDetailView.entries` overrode `initialEntries` with unfiltered `worldManager.sortedEntries`.  
**Fix:** Added `textFilter: String?` param to `WorldSnoodleDetailView`; `entries` computed property applies it. `GalleryTab` passes the active query text when opening detail.

### 3. searchIndex added to submit()
New submissions now write `searchIndex` to Firestore for future scalable text search.

---

## Bugs Fixed in v1.9 b4

### 1. Search detail view total count changed mid-swipe
**Root cause:** `WorldSnoodleDetailView.entries` used `worldManager.sortedEntries` as base even when `textFilter` was active. As swiping triggered pagination, newly loaded entries matching the search term were added to the filtered set, changing the count (e.g. 5 → 8 → 9).  
**Fix:** When `textFilter` is set, lock to `initialEntries` instead of live manager entries. Live entries are only used for the unfiltered case.

### 2. Stamp drag not undoable
**Root cause:** `handleDrag` in `StampCanvas.swift` updated stamp position directly with no undo snapshot.  
**Fix:** Push undo snapshot on the first drag event (when `draggingId` is nil), before any position change.

### 3. Search was client-side only (saw 3 results instead of full database)
**Root cause:** Search filtered only the 20 loaded entries, not the full Firestore collection.  
**Fix:** Added `FeedQuery.search(String)` case routed through Firebase `array-contains` on `searchIndex`. Added Firestore composite index (`searchIndex ARRAYS + timestamp DESC`). Backfilled `searchIndex` on all 141 existing docs via one-time admin function. `GalleryTab` debounces 400ms then fires Firebase query; clears back to prior feed mode when search is cleared.

### 4. Provisioning profile conflict
**Root cause:** Old provisioning profile "Skadoodle Development" for `com.eddiebrayman.skadoodle` was cached and blocked Debug builds after bundle ID changed to `maxsdad.skadoodle`.  
**Fix:** Deleted old profile from developer.apple.com, downloaded fresh profiles in Xcode Settings → Accounts, re-enabled Automatically manage signing.

---

## New in v2.0

### Text Stamp Overhaul
- **12 fonts** — Default, Rounded, Serif, Mono, Handwriting, Futura, Typewriter, Avenir, Chalkboard, Didot, Marker, Gill Sans
- **Bold / Italic toggles** — independent B and I buttons; combining both gives bold italic. Replaces old R/B/I/BI radio.
- **Text alignment** — left / center / right per stamp
- **WYSIWYG composer** — combined input/preview: TextEditor styled with the selected font/color/background, always visible above the keyboard. Controls scroll below; Place button pinned via `.safeAreaInset`.
- **`PlacedStamp` new fields:** `fontStyle: String` ("regular"/"bold"/"italic"/"bolditalic"), `textAlignment: String` ("left"/"center"/"right")
- All four render paths updated: live UILabel (`StampCanvas.updateVisual`), cached UIImage (`StampCanvas.renderImage`), final export (`renderCanvasWithStamps`), share card (`DrawScreen`)
- Cache key includes `fontStyle` and `textAlignment` to prevent stale cache hits

### Other 2.0 fixes (carried from 1.9.x work)
- Artist strip no longer flickers — `topArtistEntries` only written by `fetchTopArtistEntries()`, not reset on refresh
- Profile grid raised from 50 to 200 doodle limit; blank tiles fixed by switching to `RetryAsyncImage`
- World gallery share card always saves correct doodle (cleared `loadedWorldImage` on swipe)
- Update alert false-suppression fixed — dismissal key is now `"current->store"` pair
- Text stamp padding tightened: `hPadding: 10, vPadding: 5`

---

## New in v2.1

### Fixes
- **Artist strip showing only 2 artists** — `appendNextPage()` was overwriting `topArtistEntries` with the narrow paginated window on every page load, stomping the stable "top 100 by likes" dataset. Removed that line; `topArtistEntries` is now exclusively owned by `fetchTopArtistEntries()`.
- **Background picker redesign** — Color swatches moved to top of tray. Recent backgrounds now display in a uniform 3-column square grid (was adaptive columns with varying cell heights). Long-press any background thumbnail to remove it from the list. Added `remove(at:)` to `BackgroundPhotoHistory`.

### New Feature: Image Backgrounds with Effects (v2.1 b2)
- **`BackgroundPhotoHistory`** — persists up to 20 recent background photos (full + thumbnail) in UserDefaults. `add()` and `moveToTop()` are async (background thread) to avoid main thread blocking. `remove(at:)` is synchronous (low impact, user-initiated).
- **`BackgroundEditorView`** — Effects panel with Opacity, Blur, Brightness, Saturation sliders. Embedded in a `NavigationStack` sheet (picker → effects horizontal push, no double-animation). Also presented standalone (long-press on existing background) with Cancel button.
- **`CanvasColorPickerView` redesign** — new UX: tap thumbnail = select/preview (red border + "Tap for Effects" hint), tap again = push Effects panel, Apply = commit + undo point, Cancel = restore all. Swipe-to-dismiss acts as Cancel (`bgPickerWasApplied` flag + `onDismiss` handler).
- **Canvas background layer** — rendered as a SwiftUI layer in DrawScreen `ZStack` so `.blur`, `.brightness`, `.saturation`, `.opacity` modifiers apply cleanly. `DrawingCanvas` receives `canvasColor: .clear` when a background image is set; `.contentShape(Rectangle())` added to keep pen hittable on transparent canvas.
- **Export** — `applyBgEffectsForExport()` in `StampTools.swift` applies CIColorControls + CIGaussianBlur + alpha compositing for the flattened image. `renderCanvasWithStamps` accepts all effect params and calls it when needed.
- **`renderCanvasWithStamps` call in `handleDone()`** moved to background thread; `BackgroundPhotoHistory.add()` and `moveToTop()` made async — eliminates 2-second delay before sheet appeared.

---

## New in v2.1 b3

### Fixes
- **Extract Objects auto-extraction not running on screen entry** — `.task` fired when `backgroundImage` was nil because the image arrives slightly after the view appears (during nav transition). Fixed by switching to `.task(id: backgroundImage != nil)` so the task re-fires the moment the image lands.
- **Sliders affecting full image while extraction in progress** — Wrapped the four effect sliders in a `Group` with `.disabled` and `.opacity(0.4)` while `extractionEnabled && extraction.isExtracting`. Prevents slider interaction before extracted subject layer is ready.

### New Features
- **`extractionFailed` flag on `ExtractionModel`** — `@Published var extractionFailed: Bool` is set when Vision finds no objects. The Extract Objects toggle is disabled (`extraction.extractionFailed`) so the user can't retry on an image with no detectable subjects.
- **Effect slider values now persist across sessions** — `bgOpacity`, `bgBlur`, `bgBrightness`, `bgSaturation` changed from `@State` to `@AppStorage` in `DrawScreen`. Supports creative theme workflows (e.g. black-and-white with object extraction stays configured). Cancel still correctly rolls back via `restoreSavedBgState()`.
- **Reset button in Effects screen** — Resets all four sliders to neutral defaults (opacity 1.0, blur 0, brightness 0, saturation 1.0). Positioned to the right of the Extract Objects label on iPhone; below the sliders on iPad.
- **Extract Objects toggle repositioned (iPhone)** — Toggle now sits immediately right of the label with no Spacer. Spinner appears between label and toggle while extracting.
- **Camera roll → Effects direct navigation** — Selecting a photo via the + button in the background picker now navigates straight to the Effects screen (same as tapping an existing thumbnail), instead of returning to the picker. Uses 0.35s delay to allow sheet transition to complete.

### iPad Effects Screen Redesign
- On iPad, `BackgroundEditorView` uses a side-by-side layout: preview constrained to 280×260pt on the left, Extract Objects toggle (with icon, label, spinner, and toggle control) on the right.
- Sliders fill remaining space below with a Reset button at bottom right.
- iPhone layout is completely unchanged.
- Note: SwiftUI `.sheet` on iPad is locked to a "form sheet" container with a fixed max height (~715pt). `.presentationDetents` with `.fraction()` measures against that container, not the screen — `.large` and `.fraction(0.99)` are equivalent. Sheet stays at `.large` on both devices; the iPad layout redesign works within the fixed container.

### Fix: Multi-line text stamp clipped in flattened export
- **Root cause:** `naturalTextStampSize` measured each line with `str.size(withAttributes:)`, but the render call used `boundingRect` with `.usesLineFragmentOrigin | .usesFontLeading` — these APIs report different heights. For multi-line text (explicit CR), the stamp rect was sized too short, clipping the first line at the top and last line at the bottom.
- **Fix (DrawScreen.swift):** Switched `naturalTextStampSize` to use `boundingRect` with the same options as the render call, plus `ceil()` on each measurement, so the stamp rect is always sized correctly.
- **Fix (StampCanvas.swift):** Draw rect now uses full available height (`dh - vPad * 2`) instead of `br.height`, so any remaining fractional discrepancy can't clip the bottom line.

---

## Scaling / Render Bug — Resolved (v2.1 b2)
Investigated and tested extensively. Pen lines and stamp positions are geometrically consistent between live canvas and the flattened export. Could not reproduce the previously observed offset. Likely resolved as a side effect of the background feature work (coordinate space cleanup). Closed.

---

## New in v2.1 b4

### New Features
- **Doodle Stamps** (`CustomStampViews.swift`, `CustomStampManager.swift`) — `DoodleStampCreatorView` lets users draw on a transparent canvas using all pen types, colors, thickness, text stamps, and emoji stamps, then extract the drawing as a reusable stamp via Vision instance segmentation. Single-object extractions place immediately; multi-object extractions show a picker sheet. Doodle stamps appear in their own "Doodles" tab in the stamp picker (`StampToolButton`). `CustomStamp.source: StampSource` (.photo / .doodle) distinguishes the two types; `photoStamps` and `doodleStamps` are computed filters on `CustomStampManager.stamps`.
- **Tracing Background in Doodle Canvas** — Photo picker button (left of eraser in `DoodleStampCreatorView` toolbar) loads any photo as a faint B&W reference layer (25% opacity, full grayscale) behind the drawing canvas. Canvas color switches to `.clear` when active so the layer shows through. The tracing image is never passed to `renderCanvasWithStamps` or Vision — the export path remains white + drawing only. Tap the photo icon to pick or swap; red ✕ badge to clear.
- **Extracted Subject → Stamp** — Background photo subjects extracted via `BackgroundEditorView` now land on the main canvas as moveable, resizable `PlacedStamp` entries instead of being locked into the background layer. Uses `croppedToContentWithOrigin()` to find the subject's bounding box and project it to canvas coordinates. `inlineImage` (in-memory fast path) + `customImageId` (disk-backed dupe/undo fallback) dual render path.
- **Precision Tweak panel** (`StampTools.swift`, `StampMagicMenu`) — "Precision Tweak" button in the stamp magic menu opens a side-by-side panel: left column = SIZE (−/+) + ROTATE (↺/↻); right column = MOVE cross D-pad (↑←↓→). All 8 buttons use `TweakRepeatButton` — fires immediately on press, then repeats every 0.12s via `Timer` + `DragGesture(minimumDistance:0)` until release. `onNudge`, `onResizeBy`, `onRotateBy` callbacks wired in `DrawScreen.stampMagicMenuView(id:stamp:)`.

### Fixes (b4)
- **Artist strip showing only a small number of artists** — `appendNextPage()` was overwriting `topArtistEntries` with the narrow paginated window. Removed that line; `topArtistEntries` is exclusively owned by `fetchTopArtistEntries()`.
- **Profile → detail view showed entire world gallery** — `WorldSnoodleDetailView` was ignoring the artist filter when opened from a profile. Fixed.
- **Artist name missing in detail view** — Fixed display when navigating from profile grid.
- **Background picker redesign** — Color swatches at top; recent backgrounds in uniform 3-column grid; long-press to remove.
- **Effects screen** — Extract Objects auto-activates on re-entry (`.task(id: backgroundImage != nil)`); effect slider values persist via `@AppStorage`; Reset button added; improved iPad layout.
- **Multi-line text stamp clipped in export** — `naturalTextStampSize` switched to `boundingRect` with matching options; draw rect uses full available height.
- **Stamp sizes increased** — Custom stamps: 158pt, emoji stamps: 126pt (both auto-place and tap-to-place paths in `DrawScreen` and `DoodleStampCreatorView`).
- **Magic menu raised** — `.position(y: canvasSize.height - 100)` clears the color palette row.
- **Precision Tweak panel height** — Replaced `Spacer()` in d-pad HStacks with `Color.clear` (fixed size, no vertical expansion); added `.fixedSize(horizontal: false, vertical: true)`.

---

## Outstanding Items (for next version)

### Recommended fixes
1. **`@StateObject` on singletons** — Multiple views use `@StateObject` with `.shared` singletons. Should be `@ObservedObject`. Affects: `DrawScreen`, `GalleryTab` (5 places), `ProfileView`, `StampTools`.
2. **`deleteAccount()` swallows all errors silently** — User sees success even if Firebase deletes partially fail.
3. **`CanvasSnapshot` doesn't capture bg effect params** — Undo restores background image but not blur/brightness/saturation/opacity values. Requires adding fields to `CanvasSnapshot` and updating all callsites (~8 places). Medium refactor, defer to next version.
4. **`BackgroundPhotoHistory.remove(at:)` is synchronous** — `add()` and `moveToTop()` are async; `remove()` isn't. Low impact (user-initiated), but inconsistent. Easy fix when touching that file next.

### Low priority / style
- `ProfileView.swift:409-410` — `.presentationDetents` / `.presentationDragIndicator` after `.fullScreenCover` are dead code.
- `fetchPublicDoodles` does redundant client-side sort after ordered Firebase query.
- APNs watchdog timer in `snoodleApp.swift` captures `self` without `[weak self]` (benign since AppDelegate has app lifetime).

---

## Architecture Rules (critical — follow strictly)
- **NEVER touch working code** unless it is directly related to the bug or feature being worked on
- **Always ask before making changes outside the stated scope**
- **Every build is treated as final/shippable** — no speculative changes
- **All data operations must be scalable** — no loading entire collections into memory
- **Firestore queries only** — never filter server data client-side
- Pagination page size: **20**
- WorldSnoodle images are stored in Firebase Storage; URLs stored as `imageURL` in Firestore docs
- Private doodles use `SnoodleStore` (UserDefaults metadata + `Documents/Doodles/` image files on disk)

---

## Development Workflow
- Project folder connected at `/Users/edwardbrayman/Development/Active/Skadoodle`
- Eddie works in Claude Desktop / Cowork mode (moved away from zip file workflow due to code regression issues)
- Single-file edits preferred; always verify changes compile before flagging as done
- Be direct about uncertainty rather than guessing
