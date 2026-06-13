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
**Current version at last session:** 1.9 build 2 (submitted June 2026)

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
| `StampTools.swift` | ~1064 | PlacedStamp model, stamp picker, renderCanvasWithStamps |
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
enum FeedQuery { case everyone, artist(String), following([String]) }
```

### How pagination works
- **everyone / artist**: cursor-based using `lastDocumentSnapshot` + `start(afterDocument:)`
- **following**: timestamp-based (`whereField("timestamp", isLessThan: lastTimestamp)`) because batched `in` queries can't share a single Firestore cursor. Fetches in batches of 30 userIds.

### Firestore composite index (already exists, sufficient for all queries)
`world_gallery`: `userId ASC, timestamp DESC, __name__ DESC` — Status: Enabled

### searchIndex field
New doodles get a `searchIndex` array field (lowercased caption words + keywords combined). Groundwork for future Firebase `array-contains-any` text search. Current search is still client-side (filters the loaded page).

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

## Outstanding Items (for next version)

### Recommended fixes
1. **`@StateObject` on singletons** — Multiple views use `@StateObject` with `.shared` singletons. Should be `@ObservedObject`. Affects: `DrawScreen`, `GalleryTab` (5 places), `ProfileView`, `StampTools`.
2. **`fetchCommunityCount()` in SettingsTab** — Downloads all documents to count; should use Firestore `.count.getAggregation()` instead.
3. **`deleteAccount()` swallows all errors silently** — User sees success even if Firebase deletes partially fail.

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
