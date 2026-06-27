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
**Current version at last session:** 2.3 b3 (in development)
**Last released to App Store:** 2.2 (June 26, 2026 — Ready for Distribution)

---

## In Progress — v2.3 b3 (not yet submitted)

### New Features

#### Recent Colors System (all color pickers)
Every horizontal color picker now uses a shared persistent recent-colors list instead of the fixed palette.

- **`RecentColors`** (DrawingEngine.swift) — static struct; key `"recentColors_v1"`; max 20; seeded from `paletteColors` on first run; `load()` / `add(_:)` / `save(_:)`; `add` deduplicates with 0.002 RGBA tolerance before prepending.
- **`RecentCanvasColors`** (DrawingEngine.swift) — same pattern for canvas background; key `"recentCanvasColors_v1"` + separate `"selectedCanvasColor_v1"` for the most-recently-chosen canvas color. `loadSelected()` migrates from old `"lastCanvasColorIndex"` AppStorage key on first run.
- **`Color.isApproximatelyEqual(to:)`** (DrawingEngine.swift) — 0.002 RGBA tolerance; used for dedup and swatch selection highlighting.
- **`ColorSwatchView`** (DrawingEngine.swift) — circular swatch of given size; shows `CheckerboardView` behind color when alpha < 1 (standard iOS transparency convention); draws selection ring when `isSelected`.
- **`CheckerboardView`** (DrawingEngine.swift) — `Canvas`-based gray/white tiled checkerboard; was previously duplicated in `CustomStampViews.swift` (removed there).

Color pickers upgraded to recent-colors + `+` button:
- **Pen color row** (DrawScreen.swift) — `+` → `ColorPickerSheet`; `ColorSwatchView` replaces raw `Circle`; `isApproximatelyEqual` for selection.
- **Pen studio second color** (DrawScreen.swift `PenStudioSheet`) — same upgrade.
- **Canvas background color row** (`CanvasColorPickerView` in DrawScreen.swift) — `+` → `ColorPickerSheet`; `ColorSwatchView` with 42pt size; `RecentCanvasColors` list.
- **Text stamp foreground, background, shadow color rows** (StampTools.swift `TextStampComposer`) — all three rows upgraded.
- **Doodle stamp canvas pen color row** (CustomStampViews.swift `DoodleStampCreatorView`) — upgraded; `colorCircle()` rewritten to use `ColorSwatchView` + `isApproximatelyEqual`; `+` button added.

#### `ColorPickerSheet` (StampTools.swift)
Wraps SwiftUI's `ColorPicker` in a sheet with a large tappable row ("Open Color Wheel / Tap to pick any color"). Uses SwiftUI's internal `ColorPicker` — **not** `UIColorPickerViewController` directly (attempting to present `UIColorPickerViewController` as sheet content crashes with "tried to present a nil modal view controller" because it tries to present sub-controllers on SwiftUI's presentation host). The `ColorPicker` row shows the current color swatch + instructions + chevron. Done button commits and dismisses.

#### Text Stamp Shadow (PlacedStamp)
- **`PlacedStamp` new fields** (StampTools.swift): `shadowEnabled: Bool = false`, `shadowColor: Color = .black`, `shadowBlur: Double = 4.0`, `shadowOffsetX: Double = 2.0`, `shadowOffsetY: Double = 2.0`.
- **Shadow in all 4 render paths:**
  - **Live canvas** (`StampTextRenderView.updateUIView` in StampCanvas.swift) — `label.layer.shadowColor/Opacity/Radius/Offset`; `container.layer.masksToBounds = false` when shadow enabled (must not clip shadow).
  - **UIKit image cache** (`StampCanvas.emojiImage(for:)`) — `NSShadow` added to `NSAttributedString` attrs; cache key includes shadow params; `fmt.opaque = false` when shadow enabled.
  - **Export** (`renderCanvasWithStamps` in StampTools.swift) — SwiftUI `.shadow()` modifier on text stamp view.
  - **Layers panel / StampRenderView** (StampCanvas.swift) — SwiftUI `.shadow()` modifier on `StampTextRenderView`.
- **Shadow UI in `TextStampComposer`** — Toggle (on/off) + color row + Blur slider (0–20) + Offset X/Y sliders (−15 to 15) appear when enabled.
- **`DoodleFormat.swift`** — 5 new `CodingKeys` (`shadowEnabled/Color/Blur/OffsetX/OffsetY`); encode writes all 5; decode uses `decodeIfPresent` with defaults for backward compat with old `.skadoodle` files.

#### Canvas Background Color — Color-based (not index-based)
- Removed `@AppStorage("lastCanvasColorIndex")` and dead `lastNonWhiteColorIndex` from DrawScreen.
- Added `@State private var selectedCanvasColor: Color = RecentCanvasColors.loadSelected()`.
- `var canvasColor: Color { selectedCanvasColor }`.
- `SkadoodleDocument` (DoodleFormat.swift) — added `canvasColorRGBA: CodableColor? = nil`; `canvasColorIndex: Int = 0` kept with default for backward-compat decode. New saves write `canvasColorRGBA`; old files fall back to `canvasColorOptions[canvasColorIndex]`.
- `CanvasColorPickerView` interface changed: `currentIndex: Int` / `onSelect: (Int)` → `currentColor: Color` / `onSelectColor: (Color)`.

### Compiler fixes (v2.3 b1)
- **`CheckerboardView` redeclaration** — removed duplicate from `CustomStampViews.swift`; canonical definition in `DrawingEngine.swift`.
- **`DoodleStampCreatorView` type-check timeouts** — extracted `doodleToolbarRow2()` `@ViewBuilder` func and `handleDoodleTextPlace(...)` + `doodleTextComposerSheet()` helpers to break up expressions the Swift compiler couldn't type-check in reasonable time.
- **`ColorPickerSheet(selection:)` wrong param name** — correct param is `color:`.

#### Doodle Timelapse Video Export (new file: `DoodleVideoExport.swift`)
Fully self-contained. Reads `SkadoodleDocument`, generates an MP4 timelapse, and presents it via share sheet or inline player. No changes to any other existing file except two additive lines in `GalleryTab.swift`.

**Video structure:**
1. Drawing revealed stroke-by-stroke (point-by-point in chunks of `pointsPerFrame = max(3, totalPoints/300)` — ~300 render steps; simple doodles are short, complex ones longer)
2. Stamps fade in over 8 frames each
3. 2-second hold on finished doodle (60 frames)
4. Outro: dark overlay dissolves in (24f), branding card holds centered (45f) — app icon + "Skadoodle" + "skadoodle.nyc" + doodle date — then shrinks/slides to small footer at bottom (36f), footer zooms from scale 0.28 → 0.44 over 15f then holds (30f total)

**Key classes/structs:**
- `DoodleTimelapseExporter` (`@MainActor` class) — builds state list, drives AVAssetWriter loop, yields every 10 frames to avoid watchdog kill
- `OutroFrameView` — SwiftUI view rendered via `ImageRenderer` for each outro frame; uses `smoothstep` easing for shrink animation
- `TimelapseButton` — in `SnoodleDetailView` action bar (film icon); exports → iOS share sheet
- `TilePlayBadge` — in `SnoodleTile` bottom-right corner (play circle); exports → full-screen `AVPlayerViewController` auto-play
- `VideoPlayerView` — `UIViewControllerRepresentable` wrapping `AVPlayerViewController`

**Canvas size:** saved JPEG has `scale=1`, so `img.size` is physical pixels. Divide by `currentScreenScale()` to get point size for `renderCanvasWithStamps`; multiply back for pixel buffer dimensions.

**Pixel buffer:** `kCVPixelFormatType_32BGRA` + `noneSkipFirst | byteOrder32Little`. No coordinate flip — CVPixelBuffer-backed CGBitmapContext stores row 0 at the top of the visual frame; `ctx.draw(cgImage, in:)` maps correctly without any additional transform.

**`UIScreen.main` deprecation fixed** — uses `currentScreenScale()` / `currentScreenBounds()` helpers that go through `UIWindowScene`.

**GalleryTab.swift changes (additive only):**
- `SnoodleTile`: `.overlay(alignment: .bottomTrailing)` with `TilePlayBadge` when `entry.hasSkadoodleFile`
- `SnoodleDetailView.card(for:)`: `TimelapseButton(entry: entry)` added to action bar HStack

### Fixes — v2.3 b2
- **Timelapse outro zoom pop** — after branding card shrinks to footer position (scale 0.28), it zooms to 0.44 over 15 frames with smoothstep easing, then holds. (`DoodleVideoExport.swift`)
- **Eraser thickness independent from pen** — `otherWidth: CGFloat` state (persisted as `"lastEraserWidth"`, default 20) swaps with `lineWidth` when toggling eraser on/off. `ThicknessPanel` gains `storageKey` param and saves to the correct key. (`DrawScreen.swift`, `StampTools.swift`)
- **Eraser chip in layers panel** — drawing layers whose lines are all eraser strokes show a faded `eraser.fill` icon in their chip thumbnail instead of a blank white rectangle. (`DrawScreen.swift`)

### Fixes — v2.3 b3
- **Eraser now covers stamps** — `drawEraserLine` changed from `.clear` blend mode (punches transparent holes) to normal blend painting solid `canvasColor`. The eraser now works exactly like the pen but paints the canvas background color — covering stamps and anything below. (`DrawingEngine.swift`)
- **`EraserSolidView`** added to `DrawingEngine.swift` — transparent-background Canvas that renders eraser paths as solid canvasColor strokes. Available for future use.
- **Drawing after stamp now creates new layer above it** — `appendStampToLayer` now sets `userSelectedLayerId = nil` after placing a stamp. On the next stroke, `needsNewLayer` evaluates true (topIsStamp && userSelectedLayerId == nil) and a fresh drawing layer is created above the stamp. Previously this only worked when the layers panel was open. (`DrawScreen.swift`)

### Pending — v2.3 b3
- **Website git push** — Skadoodle website (skadoodle.nyc, Firebase Hosting) was updated this session with v2.2 marketing content and committed to GitHub (username: `eddienorton`, repo: `skadoodle-website`). Firebase deploy must be run from Eddie's terminal (`npx firebase deploy --only hosting` from `/Users/edwardbrayman/Development/Website/skadoodle`).

---

## In Progress — v2.2 (in review, not yet released)

### New Features
- **6 new Dual Tone pen styles** — Braid, Hairy, Thorns, Zigzag, Bubble, Stars. All pressure-sensitive. Added to `DualToneStyle` enum in `DrawingEngine.swift`; icons in `DualToneStyleChip` in `DrawScreen.swift`.
  - **Braid** — two sinusoidal strands weave over/under each other. Pressure scales strand width and amplitude (heavier = wider braid). Arc-length based, alternating half-period draw order for over/under illusion.
  - **Hairy** — core stroke with perpendicular hairs of varying length/angle both sides. Pressure scales core width and hair size. Deterministic pseudo-random variation per hair.
  - **Thorns** — core stroke with alternating backward-angled spikes like a bramble. Pressure scales core and thorn size. `backLean: 0.45` gives natural rearward angle.
  - **Zigzag** — sharp V-path snapping ±amplitude perpendicular at regular intervals. No core — zigzag IS the stroke. Alternating colorA/colorB per zig/zag.
  - **Bubble** — filled circles strung along path, alternating colorA/colorB. Pressure scales radius.
  - **Stars** — filled 5-pointed stars along path, alternating colorA/colorB. Pressure scales size. Deterministic rotation variation per star via `starPath()` free function.
- **Pen studio scrolls to selected style** — `ScrollViewReader` wraps the dual-tone style chip row; `.onAppear` scrolls to the active chip. (`DrawScreen.swift`)
- **"+" button in layers panel header** — creates a new blank drawing layer at top, selects it immediately. (`DrawScreen.swift`)
- **Pencil badge on active drawing chip** — small blue circle with pencil icon appears in bottom-left of the active drawing layer chip while `currentLine != nil` (stroke in progress). (`DrawScreen.swift`)

### Layer Architecture Overhaul (v2.2)
- **Lazy drawing layer creation** — app starts with `drawingLayers = []`, `layerOrder = []`. No blank layer on fresh canvas or after Clear. First stroke lazily creates the drawing layer via `onBeforeDraw`.
- **`onBeforeDraw`** — `needsNewLayer = drawingLayers.isEmpty || (topIsStamp && (userSelectedLayerId == nil || selectedStampId != nil)) || pendingInsertAboveStampId != nil`. No prune. New layer appended to top unless `pendingInsertAboveStampId` is set, in which case it inserts just above that stamp. (`DrawScreen.swift`)
- **`pendingInsertAboveStampId`** — set by `activateStamp` when the immediate entry above the selected stamp is another stamp (not a draw layer). `onBeforeDraw` inserts the new layer between the two stamps. Cleared on canvas tap. (`DrawScreen.swift`)
- **`activateStamp(id:)`** — replaces bare `selectedStampId = id` at all user-tap sites. Sets `selectedStampId`, opens magic menu, and either (a) activates the draw layer immediately above the stamp, or (b) sets `pendingInsertAboveStampId` if another stamp is directly above. (`DrawScreen.swift`)
- **Stamps obey selected layer** — `appendStampToLayer` inserts above the selected stamp (if one is selected) or above `userSelectedLayerId`. Falls back to append at top. (`DrawScreen.swift`)
- **Canvas tap → topmost layer** — `onCanvasTap` calls `ensureLayerSelection()` after deselecting, snapping `userSelectedLayerId` to the topmost drawing layer. `pendingInsertAboveStampId` also cleared. (`DrawScreen.swift`)
- **Two-finger gestures respect selection** — pinch and rotation in `WindowPinchView` now check `selectedStampId` first; if set, the selected stamp is operated on directly without hit testing. Fixes manipulation of stamps buried under other stamps. (`DrawScreen.swift`)
- **Layers panel gestures blocked** — `shouldReceive` in `WindowPinchView.Coordinator` now checks `v is UICollectionView || v is UITableView` for ALL recognizers (not just tap), blocking two-finger canvas gestures from passing through the panel. (`DrawScreen.swift`)
- **Clear paths all lazy** — Clear Drawing, Clear All, and single-item clears all set `drawingLayers = []` and remove drawing entries from `layerOrder`. No blank created. First stroke after clear lazily creates the layer.
- **Clear respects hidden layers** — all clear paths remove hidden drawing layer IDs from `hiddenLayerIds`; Clear Stamps removes hidden stamp IDs.
- **Undo/redo revalidate selection** — after restore, stale `selectedStampId` is cleared if the stamp no longer exists; `ensureLayerSelection()` ensures a drawing layer is always selected. (`DrawScreen.swift`)

### .skadoodle Re-editable Format (v2.2)

#### New file: `DoodleFormat.swift`
All Codable conformances and format infrastructure live here. Nothing in the existing model files was restructured — conformances are added via extensions.

- **`CodableColor`** — bridges `SwiftUI.Color` ↔ JSON as four RGBA doubles via `UIColor.getRed(_:green:blue:alpha:)`.
- **`DualToneStyle: Codable`** — added to declaration in `DrawingEngine.swift` (free via `String` raw value).
- **`DrawingLayer: Codable`** — added to struct declaration in `DrawingEngine.swift` (synthesized; `DrawingLine` conformance is in extension in `DoodleFormat.swift` so synthesis must be in same file).
- **`PenType: Codable`** — custom encode/decode; `dualTone` case encodes style rawValue under key `"style"`.
- **`DrawingLine: Codable`** — custom encode/decode; points stored as parallel `px`/`py` Double arrays for compactness; `Color` fields via `CodableColor`; `CGFloat` fields as `Double`.
- **`LayerEntry: Codable`** — custom encode/decode; stored as `{type: "drawing"|"stamp", id: UUID}`.
- **`PlacedStamp: Codable`** — custom encode/decode; `inlineImage` serialized as PNG data under key `inlineImageData`; all `Color` fields via `CodableColor`; `position` as `px`/`py` doubles. `var id: UUID = UUID()` (changed from `let` to allow decode assignment).
- **`SkadoodleDocument`** — top-level Codable struct: `version`, `drawingLayers`, `placedStamps`, `layerOrder`, `hiddenLayerIds` (as `[UUID]`), `canvasColorIndex`, `backgroundImageData` (JPEG at 0.85 quality), `backgroundOffset[X/Y]`, `bgOpacity/Blur/Brightness/Saturation`.
- **`FileManager.currentSkadoodleURL`** — `Documents/current.skadoodle` — the auto-save slot for the current in-progress session.
- **`Notification.Name.snoodleReEditEntry`** — posted by `SnoodleDetailView` to trigger re-edit from ContentView.

#### Save / Load (DrawScreen.swift)
- **`saveSkadoodleData() -> Data?`** — encodes current canvas state to JSON. Only called when canvas has content. Prints `[Skadoodle] saved N layers, N stamps, N bytes` to console.
- **`restoreSkadoodleData(_ data: Data)`** — decodes and restores full canvas state. Guards against empty docs (deletes file if empty). Calls `ensureLayerSelection()` after restore. Pushes undo snapshot only if canvas was non-empty before restore.

#### Auto-save / Resume
- **Auto-save on Cancel** — `isPresented = false` path in Cancel button writes `current.skadoodle` if canvas has content.
- **Auto-save on background** — `UIApplication.didEnterBackgroundNotification` writes `current.skadoodle` if canvas has content (safety net for app kill).
- **Resume alert** — `.onAppear` checks for `current.skadoodle` when canvas is empty; shows "Resume Last Doodle?" alert with **Resume** / **Discard** buttons (no Cancel). Discard deletes the file.
- **Cleanup on Done** — `saveEntry(post:)` deletes `current.skadoodle` after saving to gallery.

#### Gallery Re-edit
- **`SnoodleEntry.skadoodleURL`** — `Documents/Doodles/<id>.skadoodle` — paired file for each gallery entry.
- **`SnoodleEntry.hasSkadoodleFile`** — checks if `.skadoodle` exists on disk.
- **`saveEntry(post:)`** — writes `.skadoodle` to `entry.skadoodleURL` before saving to gallery (both private and world).
- **Re-edit button** — pencil icon (`pencil.and.scribble`) in `SnoodleDetailView.card(for:)` action bar. Dismisses detail view, then posts `snoodleReEditEntry` notification with the `SnoodleEntry` as object (0.35s delay for sheet transition).
- **ContentView** — listens for `snoodleReEditEntry`, sets `@State var entryToEdit: SnoodleEntry?`, opens DrawScreen. Clears `entryToEdit` in `onDismiss`.
- **DrawScreen `entryToEdit: SnoodleEntry?`** — non-binding `let` parameter (default `nil`). `.onAppear` checks:
  - If `entryToEdit != nil` + `.skadoodle` exists → full `restoreSkadoodleData`
  - If `entryToEdit != nil` + no `.skadoodle` → load flat JPEG as `canvasBackgroundImage` (legacy path)
  - If `entryToEdit == nil` → check `current.skadoodle` for resume prompt
- **Legacy import banner** — orange banner at top of canvas: *"Original layers aren't available — opened as background image."* Shown for pre-v2.2 doodles. Dismissed by tapping ✕, by first stroke (`onBeforeDraw`), or by first stamp placement (`appendStampToLayer`). No auto-timer.
- **World gallery** — Re-edit button intentionally not added to `WorldSnoodleDetailView`. Other users' public doodles have no `.skadoodle` file. Your own posted doodles could theoretically be re-edited (file exists locally) but button is not wired up yet.

### Fixes
- **Layer always highlighted** — `ensureLayerSelection()` called on layers panel `.onAppear`. Sets `userSelectedLayerId` to topmost drawing layer if nil or stale. No-op when a stamp is selected. (`DrawScreen.swift`)
- **Delete for drawing layers** — "Delete Layer" (destructive) added to drawing layer `···` menu. (`DrawScreen.swift`)
- **Delete for stamps via ··· menu** — "Delete Stamp" (destructive) added to stamp `···` menu for consistency with swipe-to-delete. (`DrawScreen.swift`)
- **Hiding a layer deselects it** — hiding a drawing layer moves `userSelectedLayerId` to next visible drawing layer; hiding a selected stamp closes the magic menu. (`DrawScreen.swift`)
- **Layers panel iPhone sizing** — chips reduced from 112pt to 84pt, panel from 160pt to 122pt on iPhone only. iPad unchanged. (`DrawScreen.swift`)
- **Layers panel header cleanup** — removed decorative icon before "Layers" title; added `lineLimit(1)` to prevent wrapping; background changed from `.ultraThinMaterial` to `.thinMaterial`. (`DrawScreen.swift`)

---

## New in v2.1 b13 (continued — same build, additional fixes)

### Fixes
- **Magic menu invisible in DoodleStampCreatorView on iPad** — root cause: `doodleMenuOffsetX/Y` AppStorage values were persisted from a previous session where the user had dragged the panel. On a larger iPad canvas, the restored offset pushed the menu 161pt below the bottom edge. Fix: `initialOffset: .zero` in DoodleStampCreatorView's StampMagicMenu call — menu always opens at default position in the doodle canvas (still draggable per-session).
- **Tapping transparent area around selected stamp didn't deselect** — `StampContainerView.hitTest` used `bounds.contains` (full bounding box) for the selected stamp, swallowing taps in transparent padding. Fix: use snug rect as the hit area when a stamp is selected, matching the visible selection indicator exactly. Outside snug rect → touch falls through to canvas → deselects. Non-selected stamps unchanged (still alpha-aware via `point(inside:)`).
- **TweakRepeatButton long-press dismissing magic menu** — window-level `UILongPressGestureRecognizer` (0.4s) fired when holding a tweak button. On `.ended` it unconditionally called `onCanvasTap?()` → deselect. Fix: `handleLongPress` now only calls `onCanvasTap` if `longPressStampId != nil` (i.e., a stamp drag was actually in progress). Holding a UI control no longer dismisses the panel.
- **Layers panel close button enlarged** — bumped from 15pt to 22pt for easier tapping.

### Architecture note
- `shouldReceive touch` in `WindowPinchView.Coordinator` now also walks the view hierarchy for the tap recognizer, rejecting taps on Button/Control/Collection/ScrollView class names. Added during iPad magic menu debugging; ultimately not the root fix but harmless. Revert first if unexpected tap behavior appears.
- `onCanvasTap: nil` in DoodleStampCreatorView's WindowPinchView call — deselect is handled solely by `SpatialTapGesture` in the doodle canvas (correct; picker taps don't reach SpatialTapGesture since picker is on top).

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

## New in v2.1 b5–b7

### New Features
- **Full Photo Import** — After selecting photos from camera or library, an `.alert` (centered, not action sheet) asks "Extract Objects" or "Use Full Photo". Multi-select supported for both paths. Full photos skip extraction and land directly on canvas as `PlacedStamp` entries staggered from center (20pt diagonal cascade). Singular/plural button labels based on count.
- **Snug Rect selection indicator** (`PlacedStamp.snugSize`, `PlacedStamp.computeSnugRatios`) — When a stamp is selected and the magic menu is open, a tight bounding rectangle is drawn around it (black 3pt outer + white 1pt inner, always legible on any canvas color). Replaces the old pulsing crosshair.
  - **Text stamps**: snug rect = `stampWidth - 2×hPadding` by `stampHeight - 2×vPadding` (immediate, no scan needed).
  - **Custom/doodle stamps**: alpha-channel pixel scan (`computeSnugRatios`) runs on `DispatchQueue.global(.utility)`, finds first/last non-transparent column and row (threshold alpha > 8), stores result as `snugWidthRatio`/`snugHeightRatio` (relative to `size`, so ratios survive resize). Falls back to aspect-fit from image pixel dims until scan completes.
  - Scan is scheduled via `scheduleSnugScan(for:image:)` in `DrawScreen` after every stamp placement path: `autoPlaceStamp()`, `placeFullPhotoStamps()`, both extracted-subject-to-canvas paths.
- **Multi-select in Stamp Picker** (`StampToolButton`) — All 3 tabs (Emoji, Photos, Doodles) have a "Select" toggle button in the upper-right of the picker. In multi-select mode: cells show purple checkmark badges, tapping toggles selection. "Done (N)" button places all selected stamps staggered on canvas. Trash icon (left side, photos/doodles only) deletes all selected stamps. "Select" button re-tap cancels multi-select without placing.
  - Per-tab select mode persists via `@AppStorage` (`stampPickerMultiSelect_0/1/2`) — emoji, photos, and doodles each remember their own Select state independently across sessions.
  - Active tab persists via `@AppStorage("stampPickerTab")`.
  - In-progress selections (`multiSelectedEmojis`, `multiSelectedCustomIds`) clear on tab switch and on Done/cancel, but Select mode itself stays on.
  - New callback `onPlaceMultipleEmojis: ([String]) -> Void` wired to `placeMultipleEmojis()` in DrawScreen (mirrors `placeFullPhotoStamps` for emoji).
- **Precision Tweak increments** — Move: 4pt, Size: ±3pt, Rotate: ±3° per tick.

### Fixes (b5–b7)
- **Camera emoji in StampMagicMenu header** — Custom stamps (photo/doodle) showed "📷" as panel header. Fixed to render actual stamp thumbnail for custom stamps, falling back to emoji text only for built-in emoji stamps.
- **Panel 2 reverted to panel 1 on stamp switch** — `.onChange(of: selectedStampId) { showMenuTweak = false }` in both `DrawScreen` and `DoodleStampCreatorView` was resetting the tweak panel. Removed from both.
- **First drag after panel open was frozen** — Inherited SwiftUI animation context from tap gesture caused `liveDrag` updates to animate (deferred positions). Fixed with `withAnimation(.none)` in `.onAppear` and both gesture callbacks in `StampMagicMenu`.
- **Doodle extraction not auto-placing on main canvas** — `onPlace?()` was missing from doodle and photo segmentation completion handlers in `StampToolButton`. Added to both.
- **Multi-extract placing wrong number of stamps** — Completion handler called `onPlace?()` regardless of object count. Fixed to call `onPlaceMultipleStamps?` when multiple objects extracted.
- **Import mode alert was bottom sheet** — Was using `.confirmationDialog` (always bottom). Replaced with `.alert` (centered). Title removed; button labels are singular/plural based on photo count.
- **Pulsing crosshair removed** — Selection now shown via snug bounding rect only. `PulsingCrosshair` struct is dead code (can be deleted).

---

## New in v2.1 b11–b12

### Stamp Interaction Overhaul
- **Tap to select** — `SpatialTapGesture` (iOS 16+) as `.simultaneousGesture` on `DrawingCanvas` replaces the old window-level `UITapGestureRecognizer` (which SwiftUI's DragGesture was consuming). Tap fires `stampHitTest` (alpha-aware, rotation-aware) and sets `selectedStampId` + `showStampMagicMenu = true`.
- **Long press to drag** — `UILongPressGestureRecognizer` (0.4s, 30pt allowable movement) highlights the stamp on `.began` (`isLongPressing = true`, `showStampMagicMenu = false`). `.changed` moves the stamp using delta from start position (not raw touch location — that was the 8pt jump bug). On `.ended`/`.cancelled`, all state clears and `selectedStampId` is nil. Long press works with the layers panel open.
- **Draw-through non-selected stamps** — `StampContainerView.hitTest` returns nil for all non-selected stamps; selected stamp uses `bounds.contains` (solid bounding box) instead of per-pixel alpha test. Non-selected stamps still use alpha-aware `point(inside:)` for tap selection.
- **Alpha-aware tap selection** — `stampHitTest` (module-level free function, shared by `SpatialTapGesture` and `Coordinator.stampHit`) does rotation math, letterbox rejection, and per-pixel alpha test. Tapping transparent area of front stamp correctly selects the stamp behind it. `_stampHitImageCache` is a module-level cache; `Coordinator.stampHit` is now a one-line delegate.
- **Z-order-correct hit testing** — All stamp hit tests (tap, long press, pinch) now walk `layerOrder.reversed()` via module-level `topmostStampHit(at:layerOrder:stamps:)`. Previous code iterated `placedStamps.reversed()` (insertion order), which could select a behind stamp instead of the front one.
- **Snug rect shown during long press** — `snugRectOverlay` shows when `showStampMagicMenu || isLongPressing`.
- **State cleanup hardened** — `.ended`/`.cancelled` in `handleLongPress` runs before the canvas-bounds guard, so dragging off the canvas edge no longer leaves `isLongPressing` stuck.

### Layers Panel
- **Drag-to-reorder** — Up/down arrow buttons replaced with SwiftUI `List` + `.onMove` + `.environment(\.editMode, .constant(.active))`. Panel widened to 160pt.
- **Scroll to selected chip** — `ScrollViewReader` wraps the List; `.onChange(of: selectedStampId)` scrolls selected chip to center.
- **Selected chip inner border** — Dark gray inner stroke inside the yellow outer border for clearer selection state.
- **Long press leak fixed** — `guard !parent.showLayersPanel` removed from long press handler (was blocking stamp long press when panel was open, and was only needed for the now-removed stamp auto-placement).
- **Scroll position jump fixed** — Removed `.id(refreshId)` that was destroying/recreating the List on every stroke.

### Lazy Drawing Layer Creation
- **No empty layers ever** — `appendStampToLayer` no longer creates a blank drawing layer after placing a stamp. Layers only exist when they have content.
- **`activeLayerLinesBinding`** — Custom `Binding<[DrawingLine]>` on `DrawScreen` evaluates `activeDrawingLayerIndex` at access time (not render time). Closures capture `@State` heap references so they always see current state.
- **`onBeforeDraw` lazy creation** — Fires synchronously before the first stroke point. If `userSelectedLayerId == nil` and `layerOrder.last` is a `.stamp`, creates a new `DrawingLayer`, appends it to `drawingLayers` and `layerOrder`, and sets `userSelectedLayerId` to it. The binding's `set` then routes the stroke to the brand-new top layer.

## New in v2.1 b13

### New Feature: Drawing Layer Toggle (Doodle Stamp Canvas)
- **`drawingOnTop` toggle** — `@AppStorage("doodleDrawingOnTop") private var drawingOnTop: Bool = true` persists preference across sessions. Button in Row 1 toolbar (between eraser and color palette) uses `square.2.layers.3d` SF symbol; blue when stamps are on top, gray when drawing is on top (default).
- **ZStack conditional ordering** — `if drawingOnTop { ForEach(StampRenderView) }` before `DrawingCanvas`, `if !drawingOnTop { ForEach(StampRenderView) }` after. No duplication of `DrawingCanvas` code; rendering and gestures unchanged regardless of mode.
- **`DrawingCanvas` extracted to `@ViewBuilder`** — `doodleDrawingCanvas()` function on `DoodleStampCreatorView` pulls the canvas + all modifiers out of the deeply-nested ZStack closure to fix Swift compiler type-check timeout errors.

### Fixes (b13)
- **Pencil deselect-tap leaving a dot mark** — When stamp is selected and pencil tap deselects it, the tap (which can move 3–12pt) was crossing the draw threshold and leaving a dot. Fix: `PencilTouchView` defers `onBegan` when `touchBeganWithStampSelected`; fires only if movement ≥ 12pt. iPhone `DragGesture` threshold raised to 12pt when stamp selected. (`DrawingEngine.swift`)
- **Deselect-then-reselect flicker on transparent-pixel tap** — Tapping inside a stamp's bounding box on a transparent pixel: `StampContainerView.canvasTap` fired immediately (deselecting), then `StampItemUIView.singleTap` fired ~350ms later (after double-tap-fail wait) and re-selected because `selectedStampId` was already nil. Fix: `handleSingleTap` now guards with `point(inside: pt, with: nil)` before calling `onTap()` — transparent-pixel taps skip `onTap` entirely. (`StampCanvas.swift`)
- **Magic panel not opening in doodle stamp canvas** — `WindowPinchView` in `DoodleStampCreatorView` was missing `onStampTap` callback (nil). `handleWindowTap` found a hit → called nil → nothing; if it fired after `SpatialTapGesture` had already selected, the else branch called `onCanvasTap` and deselected. Fix: added `onStampTap: { id in selectedStampId = id; showStampMagicMenu = true }` to match `DrawScreen`. (`CustomStampViews.swift`)
- **Compiler type-check timeouts in `CustomStampViews.swift`** — Three separate expressions were too complex for Swift to check inside deeply nested closures: (1) `PlacedStamp(...)` with nested `CGPoint` → hoisted `dupePosX/Y` as explicit `CGFloat` locals; (2) `DrawingCanvas` + modifiers chain → extracted to `doodleDrawingCanvas()` `@ViewBuilder`.

## New in v2.1 b16

### Bug Fixes
- **iPad Share Skadoodle crash** — `UIActivityViewController` requires a `popoverPresentationController` source on iPad or it crashes. Fixed by setting `sourceView` and `sourceRect` to the center of the root view with no arrow. (`SettingsTab.swift`)
- **Portrait-only orientation** — locked both iPhone and iPad to portrait in Xcode target settings. Landscape was never tested or designed for; artists rotate the device, not the app.
- **Layer merge on stamp delete** — removed `consolidateDrawingLayers()` from `deleteLayerEntry` and `removeStampFromLayerOrder`. Deleting a stamp between two drawing layers no longer merges them. Adjacent drawing layers are valid state everywhere. (`DrawScreen.swift`)
- **Layers panel drag-to-reorder now selects dragged chip** — after reordering, the moved stamp becomes selected (magic menu opens) or the moved drawing layer becomes the active layer. (`DrawScreen.swift`)
- **Text stamp edit reset size** — editing a text stamp via the magic panel was resetting `size` back to the base font size (48pt), discarding any user resize. Fix: preserve `existingSize`, scale recomputed `stampWidth`/`stampHeight` proportionally. (`DrawScreen.swift`)

---

## New in v2.1 b15

### New Features
- **Extract All Layers as Stamps** — flattens all visible drawing layers + stamps into a single image, runs Vision instance segmentation, and places each extracted object as a doodle stamp at its original canvas coordinates. Triggered via `···` menu on the **BG chip** in the Layers panel ("Extract All as Stamps"). Undo/redo supported (single undo removes all placed stamps). Last extracted stamp is auto-selected with snug rect + magic menu open. `extractAllLayersAsStamps()` in `DrawScreen.swift`.
  - Note: was initially wired as a canvas double-tap (`UITapGestureRecognizer` with `numberOfTapsRequired = 2` in `WindowPinchView`) but moved to the BG chip menu due to gesture conflicts.
- **Per-layer opacity** — `DrawingLayer` now has `var opacity: Double = 1.0`. `PlacedStamp` already had `opacity`. Both drawing and stamp layer `···` menus now include an **Opacity** option that opens `LayerOpacitySheet` — a `.height(180)` sheet with a 0–100% slider. Changes apply immediately; undo snapshot pushed on first slider drag. Export path (`renderCanvasWithStamps`) applies `.opacity(layer.opacity)` to drawing layer canvases. Stamp opacity already applied inside `StampRenderView`.
- **Stamp layer `···` menu** — stamp chips in the Layers panel now have a `···` menu (matching drawing layer chips) with: Hide/Show Stamp, Opacity, Duplicate Stamp. Eye-slash badge + white wash overlay on hidden stamp chips.
- **`···` dots white with shadow** — all layer chip ellipsis buttons changed from `.primary.opacity(0.7)` to `.white` + `.shadow(color: .black.opacity(0.7), radius: 1)` for legibility on dark/black canvas thumbnails.
- **Drawing layer Duplicate** — `duplicateDrawingLayer(layerId:)` copies lines into a new `DrawingLayer` inserted immediately above the source in `layerOrder`. Available via drawing layer `···` menu.
- **Layer drag-to-reorder no longer merges adjacent drawing layers** — `consolidateDrawingLayers()` removed from `onMove` and `moveLayerEntry`. Adjacent drawing layers are valid state.
- **Ghost empty layer fix** — empty drawing layer pruning moved from `appendStampToLayer` (which broke pen flow) to inside `onBeforeDraw`'s `if needsNewLayer` block. Pruning only runs when a new layer is being created.
- **Draw-above-stamp fix** — `needsNewLayer` in `onBeforeDraw` now also triggers when `selectedStampId != nil`, so drawing after selecting a stamp always creates a new layer above all stamps.

### Bug Fixes
- **TweakRepeatButton timer leak** — holding a tweak button (rotate, move, resize) while the precision panel is dismissed left an orphaned `Timer` firing indefinitely, causing stamps to rotate/move uncontrollably. Fix: `.onDisappear { timer?.invalidate(); timer = nil }` added to `TweakRepeatButton`. (`StampTools.swift`)
- **Duplicate stamp compile errors** — `isTextStamp` is computed (not settable); correct field is `stampText` not `textContent`; `flatMap` closure fixed to `{ _ in ... }`. (`DrawScreen.swift`)

---

## New in v2.1 b14

### New Features
- **Layer visibility toggle** — `···` menu on drawing layer chips in the Layers panel. "Hide Layer" / "Show Layer" toggles visibility. Hidden layer IDs stored in `@State private var hiddenLayerIds: Set<UUID>`. Hidden layers are excluded from the live render (`layerDrawingView` checks `hiddenLayerIds`) and from the final export (`handleDone` filters them). The drawing layer selection is unchanged by hiding.
- **Extract Drawing Layer as Stamp** — second option in the `···` chip menu. Renders the layer's lines to a white-background `UIImage`, runs Vision instance segmentation (`extractObjectsWithOrigins(from:)`), and places each extracted object as a `PlacedStamp` immediately above the source layer in `layerOrder`. Uses `croppedToContentWithOrigin()` to find each object's bounding box and project it to canvas coordinates. `isExtractingLayer: Bool` state drives a progress indicator. New free function `extractObjectsWithOrigins(from:)` lives before `topmostStampHit` in `DrawScreen.swift`.
- **Always-selected drawing layer model** — There is always a currently selected drawing layer (`userSelectedLayerId` never nil when drawing layers exist). Drawing chip tap always selects that layer (no toggle-to-nil). Stamp chip tap keeps `userSelectedLayerId` unchanged — no dual highlight because `isActive` for a drawing chip requires `selectedStampId == nil`. Color, eraser, and pen studio buttons no longer clear `selectedStampId` (they're just settings). `onBeforeDraw` handles `drawingLayers.isEmpty` case by creating a new layer. `activeLayerLinesBinding` guarded against empty `drawingLayers`.
- **Layer chip `···` menu** — 14pt bold, `.primary.opacity(0.7)`, overlaid on drawing layer chips. Presents "Hide/Show Layer" and "Extract as Stamp" actions.
- **Layers panel title enlarged** — 13pt → 16pt.
- **All layers deletable** — `canDeleteLayerEntry` always returns `true`. On deletion, the next available drawing layer is selected.

### Bug Fixes (b14)
- **Photo stamp picker "+" button flicker** — selecting photo source (camera / library) from the "+" button caused dismiss → reappear → dismiss flicker. Root cause: `.confirmationDialog` inside a `.sheet` triggers a system-level iOS presentation conflict. Fix: replaced `showSourcePicker` state + `.confirmationDialog` with a `Menu` containing "Take Photo" and "Choose from Library" actions directly on the button. Applies to both the grid "+" button and `addPhotoButton` in `StampTools.swift`.
- **`@StateObject` on singletons** — `DrawScreen`, `ContentView`, `ProfileView`, `StampTools`, and `SettingsTab` all used `@StateObject` with `.shared` singletons. Changed to `@ObservedObject` in all places. (`DrawScreen.swift`, `ContentView.swift`, `ProfileView.swift`, `StampTools.swift`, `SettingsTab.swift`)
- **`deleteAccount()` swallowed all errors silently** — user saw success even if Firebase deletes partially failed. Fixed: errors collected via `NSLock`, fatal errors surfaced via new `deleteAccountErrorMessage` state + alert. (`SettingsTab.swift`)
- **`CanvasSnapshot` didn't capture bg effect params** — undo restored background image but not blur/brightness/saturation/opacity. Fixed: added `bgOpacity`, `bgBlur`, `bgBrightness`, `bgSaturation` fields to `CanvasSnapshot`; all 11 callsites updated; undo/redo restore blocks updated. (`DrawingEngine.swift`, `DrawScreen.swift`)
- **`BackgroundPhotoHistory.remove(at:)` was synchronous** — `add()` and `moveToTop()` are async; `remove()` wasn't. Made async for consistency. (`DrawScreen.swift`)
- **`appendStampToLayer` cleared `userSelectedLayerId`** — placing a stamp was deselecting the active drawing layer. Removed that line. (`DrawScreen.swift`)
- **`PulsingCrosshair` dead code** — struct removed from `DrawScreen.swift` (was dead since b7).

---

## New in v2.1 b8–b10

### New Feature: Autograph Stamp
- **Autograph button** — leftmost button in the second toolbar row (before "T"). Shows the user's circular profile photo; falls back to a purple `person.circle` icon with first initial if no photo set. Disabled/dimmed if no username is set.
- **Badge generation** — `generateAutographBadge()` in `DrawScreen` renders a pill-shaped `UIImage`: circular profile photo (or purple initial fallback) + username text on a flat white rounded-rect background. Reads directly from `UserDefaults` (`snoodleUsername`, `snoodleProfilePhoto`) — no network call.
- **Placement** — `placeAutographStamp()` drops the badge quietly into the bottom-right corner of the canvas (16pt margin). No selection highlight, no magic menu — it just appears. Behaves as a normal `PlacedStamp` with `inlineImage` set: drag, resize, rotate, delete, precision tweak all work for free.
- **Hit testing fix** — `stampHit()` in `WindowPinchView.Coordinator` now checks `stamp.inlineImage` first before falling back to emoji rendering. Previously, autograph stamps (and extracted-subject stamps) used the emoji glyph for pixel hit testing, making them nearly impossible to pinch. Fix applies to all `inlineImage`-backed stamps.
- **Pencil fix (b8)** — Window-level gesture recognizers (`shouldReceive`) now reject all pencil/stylus touches, not just long press. Prevents pinch/rotation recognizers from intercepting Apple Pencil input before it reaches `DrawingCanvas`.

### Low priority / style (added)
- `PulsingCrosshair` struct in `DrawScreen.swift` — dead code since b7. Safe to delete.

---

## Outstanding Items

### v2.3 b1 — must fix before submit
- **`ColorPickerSheet` UX** — the two-step "open wheel then hit Done" flow is confusing. Need a single-tap flow: tap `+` → color wheel immediately → done. Options to explore: (a) use SwiftUI `ColorPicker` as a full-row button that auto-fires on appear, (b) find a way to present `UIColorPickerViewController` via UIKit without crashing (key constraint: cannot present it as SwiftUI sheet root content — it crashes with nil modal presentation). This is the top priority for the next session.

### Carry-forward bugs (from v2.2 work)
- **`consolidateDrawingLayers()` still called in delete paths** — `deleteLayerEntry` and `removeStampFromLayerOrder` both call it, so deleting a stamp between two drawing layers merges them. Should be removed from both paths; adjacent drawing layers are valid state everywhere.
- **Empty layers** — mechanism not yet confirmed. Suspected paths: eraser removing all lines from a layer (layer stays), or `onBeforeDraw` creating a layer that gets cancelled before any point lands. Needs repro to confirm.

### Low priority / style
- `ProfileView.swift:409-410` — `.presentationDetents` / `.presentationDragIndicator` after `.fullScreenCover` are dead code.
- `fetchPublicDoodles` does redundant client-side sort after ordered Firebase query.
- APNs watchdog timer in `snoodleApp.swift` captures `self` without `[weak self]` (benign since AppDelegate has app lifetime).
- `GalleryTab.swift` still uses `@StateObject` with `.shared` singletons (5 places) — lower priority since it's a presentation-only view, but should be `@ObservedObject` for correctness.

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
