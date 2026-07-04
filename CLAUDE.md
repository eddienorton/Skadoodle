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
**Current version at last session:** 2.4 b7 (submitted June 30, 2026)
**Last released to App Store:** 2.2 (June 26, 2026 — Ready for Distribution)
**Last released to App Store:** 2.3 (June 29, 2026 — Ready for Distribution)

---

## In Progress — Daily Doodle Feature (not yet built/submitted)

Replaces the old Calendar tab with a **Today** tab (`TodayTab.swift`, new file). This is meant to become the flashiest part of the app — a daily drawing prompt everyone competes on, with a celebration moment for whoever's on top. Currently mid-implementation: functionality first, visual polish ("skin") later — Eddie's explicit call.

### Concept
- Every day (in `DailyEntry.contestTimeZone`) has one shared prompt (`DailyPrompt.today`, picked deterministically by day-of-year so all users see the same word).
- **Day boundary is anchored to America/New_York, not UTC.** Originally implemented as UTC; switched deliberately (skadoodle.nyc, and most current users are US-based). A single global synchronized cutoff is required either way — the blind-submission/timed-reveal/voting-window mechanic can't work with a per-user-local rollover (unlike, say, Wordle, which has no such requirement and rolls over at each player's own local midnight). `DailyEntry.contestTimeZone` (`TimeZone(identifier: "America/New_York")`) is the single source of truth for this; `TimeZone` handles the EST/EDT shift automatically, no manual DST logic needed. `DailyEntry.contestDateString(for:)` (was `utcDateString`) is the one function everything hangs off of — never format/parse a `daily_gallery` `date` string with any other time zone (see the "past winners showed the wrong dates" bug below for what happens when parse/display time zones drift apart).
- Each user can post one entry per day to `daily_gallery` (doc id `"{YYYY-MM-DD}_{userId}"`, using the contest-day string above, so posting again with a different image just replaces/overwrites your own entry — no duplicates).
- **Today's contest is blind.** While a day is still in progress, nobody — not even the poster — sees anyone else's entries. You only ever see your own (if you've posted) plus the prompt.
- Once a day rolls over (midnight in `DailyEntry.contestTimeZone`, matching `DailyEntry.contestDateString()`), it's "concluded": all of yesterday's entries become visible, sorted by votes, with the top entry called out as the winner.
- **Terminology: "votes," not "likes."** Deliberately named and coded differently from World Gallery's "likes" (separate field, separate subcollection, separate Swift identifiers — `votes`/`isVotedByMe`/`toggleVote` vs. World Gallery's `likes`/`isLikedByMe`/`toggleLike`) so the two systems can never be confused for each other in code — and now in icon too, since every vote display uses `checkmark.seal` instead of a heart (see "Heart icon → checkmark.seal" under the Today tab redesign notes below; this was flagged here as deferred and has since been fixed). **Renamed from `likes` mid-build** — any hand-edited test docs in the console from before this rename still have a `likes` field, which the app now ignores (`d["votes"] as? Int ?? 0` reads 0 for them); redo test data under the `votes` field name (and a `votes` subcollection, not `likes`) going forward.

#### Submission / voting window model (confirmed design, no extra code needed — this already falls out of the current implementation)
Two 24-hour windows are always running at once, offset by one day, e.g. (all times in `DailyEntry.contestTimeZone` / America/New_York):
- **July 4, 00:00–24:00** — submission window for July 4 is open. Entries are blind (nobody sees anyone else's).
- **July 5, 00:00** — July 4 submissions close and July 4 voting opens, at the exact same instant July 5 submissions open. This is the "reveal": July 4's entries all become visible together, sorted, winner spotlighted.
- **July 5, 00:00–24:00** — July 4 is votable (it's "yesterday" relative to "today" = July 5). Simultaneously, July 5 submissions are being collected blind, same as July 4 was.
- **July 6, 00:00** — July 4 ages out: `fetchYesterday()`'s `date == today - 1` query no longer includes it, so it silently becomes unreachable in the UI. July 5 voting opens (the new "yesterday"). July 6 submissions open.

So voting is never literally "closed" by an explicit flag — it stops being possible because the query window moves on and the entry is no longer fetched. This is functionally identical to a hard 24-hour voting window today, **but it's a side effect of there being no archive feature yet, not an enforced rule.** Two follow-ups this implies for later:
- **Now that the "browse further back than yesterday" archive is built** (`PastWinnersView`/`DailyContestDayView`, see below), voting on older days is blocked client-side: `toggleVote(_:)` checks `entry.date` against `currentVotableDate` (`"yesterday"` relative to now) and no-ops (returns `false`, logs a warning) if they don't match; `DailyEntryDetailSheet`'s `canVote` computed property hides the Vote button entirely for non-votable days and shows a static "Voting has closed for this day" count instead. Still client-side only — a Firestore security rule rejecting `votes` subcollection writes outside the allowed window is the real, un-bypassable version, and is the same deferred bucket as the blind-submission read rule below.
- **This same fix doubles as the permanent winner record.** Once voting on expired days is actually blocked (either way above), every past day's `votes` count freezes the moment it ages out — the `daily_gallery` docs themselves become the durable historical record, no separate snapshot doc needed.
- **Known minor edge case, deferred:** no automatic midnight-rollover refresh exists. If the Today tab is left open straight through a day boundary without backgrounding/reopening/pulling to refresh, it can keep showing (and allow voting against) stale in-memory data from the now-expired day until the next fetch. Low priority — we'll notice if it happens and can add a "this contest has ended, pull to refresh" message at that point rather than solving it preemptively.

#### Scalability: composite Firestore index required
`fetchYesterday()` and `fetchEntries(for:)` sort server-side (`.whereField("date", isEqualTo:).order(by: "votes", descending: true).order(by: "timestamp")`) instead of fetching a flat batch and sorting client-side, so a single day doesn't silently truncate once it gets more than ~200 entries. `fetchPastWinners()` uses the *same* index with a range filter on `date` instead of equality (see below). This requires a composite index on `daily_gallery`:
- Fields: `date` (Ascending), `votes` (Descending), `timestamp` (Ascending)
- **Created and confirmed working** (console-managed, same as the existing `world_gallery` indexes documented below — this repo has no `firestore.indexes.json`). Created manually via Firestore Console → Indexes → Composite → Add Index, since the "requires an index" error link Firestore throws in Xcode's console doesn't actually create the index by itself — you still have to click Create on the pre-filled form it opens, or add it manually as above.

#### Past Winners archive — one range query, no summary collection needed
`DailyManager.fetchPastWinners(lookbackDays:)` populates the whole archive list with a **single** Firestore query, not one query per day and not a separate denormalized collection:
```
.whereField("date", isGreaterThanOrEqualTo: earliest)
.whereField("date", isLessThanOrEqualTo: anchor)      // anchor = 2 days ago
.order(by: "date").order(by: "votes", descending: true).order(by: "timestamp")
```
Same composite index as above, just a range instead of an equality filter on `date`. Because results are sorted by date first and votes-descending second, every date's highest-voted entry is guaranteed to be the *first* one encountered in that date's group — so a single client-side pass (`winnerByDate[entry.date] == winnerByDate[entry.date] ?? entry`, first-write-wins) pulls out one winner per day, plus a per-day entry count, with no GROUP BY needed (Firestore doesn't have one) and no extra collection to keep in sync. The trade-off: this fetches every entry in the date range, not just winners — fine at this app's scale, would only be worth revisiting (a real `daily_summaries` collection) if a single day routinely got hundreds of entries. Starts 2 days ago rather than yesterday, since yesterday already has its own dedicated section higher up on the Today tab. Fixed lookback window (default 60 days) rather than paginated — revisit if history ever outgrows it. Days where nobody voted for anything are omitted from the list entirely (same zero-engagement rule as `yesterdayWinner`).

### Current implementation
- **`DailyEntry`** (`SnoodleFirebase.swift`) — model for one `daily_gallery` doc. `contestDateString(for:)` / `docId(date:userId:)` are the two static helpers everything hangs off of. `username`/`avatar`/`photoURL` are **not** stored on the Firestore doc and not read by `parse()` — they're defaulted fields resolved live after fetch via `applyProfile(_:)` / `DailyManager.resolveProfiles(for:completion:)` (batched through the existing `UserProfileManager.fetchProfiles`), mirroring `WorldSnoodle.applyProfile`. This was a deliberate fix: the original implementation denormalized username/avatar/photoURL onto the doc at submission time, so a user changing their name or photo later would leave every past `daily_gallery` entry showing stale info forever. `post()` only ever writes `userId`, `date`, `imageURL`, `caption`, `timestamp`, `votes` — never profile fields. `caption` is always `DailyPrompt.today` at post time (`TodayTab.postEntry()`), never the source private-gallery entry's own AI-generated caption — Daily Doodle entries are labeled by the theme they're answering, not by whatever Vision/Gemini captioned the original doodle.
- **`DailyPrompt`** (`SnoodleFirebase.swift`) — static list of 40 prompts, `today` picks by day-of-year (in `DailyEntry.contestTimeZone`) mod count. Only ever used now as the **fallback** value inside `DailyManager.todaySubject` (see below) — no other call site should reference `DailyPrompt.today` directly anymore. **Known limitation of the mod-cycle formula itself:** repeats every 40 days guaranteed, and because it's computed live from `dayOfYear % prompts.count`, growing the array shifts every future date's assignment from that point on — you can't pin a specific subject to a specific future date (e.g. "Turkey" near Thanksgiving) without the formula reshuffling every day after it. This is the actual reason the fix has to be an explicit stored per-date assignment, not just a bigger array.
- **`DailyManager.todaySubject` / `fetchTodaySubject()`** (`SnoodleFirebase.swift`) — first step of moving subjects server-side. New Firestore collection `daily_prompts`, one doc per calendar date (doc ID = the same `contestDateString` used everywhere, field `subject: String`) — an explicit stored mapping, not a formula, so adding to the pool later never disturbs a date that's already been assigned. `todaySubject` is `@Published`, initialized synchronously to the legacy `DailyPrompt.today` fallback so it's never blank, then `fetchTodaySubject()` checks a same-day UserDefaults cache first (the assignment for a given date never changes once fetched, so no need to re-hit Firestore on every tab switch), then reads `daily_prompts/{date}` and silently upgrades to the real value if that doc exists — falls back to the local mod-cycle if it doesn't (e.g. before any admin tooling exists, or a gap day nobody's assigned yet). Called defensively from both `TodayTab`'s `.onAppear`/`.refreshable` and `DrawScreen`'s `.onAppear`, so it's virtually always resolved before it's actually needed for a post's caption. All four places that used to read `DailyPrompt.today` directly (`TodayTab.promptCard`, `TodayTab.postEntry()`, `DrawScreen.saveResult()`, `DrawScreen`'s canvas `.navigationTitle`) now read `daily.todaySubject` instead.
  - **The UserDefaults cache is only written on a real Firestore-sourced assignment, never on the fallback.** If it cached the fallback too, seeding `daily_prompts/{date}` by hand mid-day — the current workflow, decided against building the admin panel for now (see below) — would never show up on a device that had already fetched today once; it'd be stuck on the fallback until the date rolled over. Leaving fallback days uncached costs one extra cheap Firestore read per app open on any date nobody's seeded yet, which is a fine trade.
  - **Decided: no website admin panel for now.** Bulk-seeding happens via a DEBUG-only in-app tool instead (see `SettingsTab.seedDailyPromptsIfDebug()` below); one-off manual edits/overrides for a single date can still be done by hand via Firebase Console the same way as `daily_gallery` test data — collection `daily_prompts`, doc ID `YYYY-MM-DD` (the same `contestDateString`, America/New_York), fields `subject: String` and `category: String`. Every date without a doc silently falls back to the old local list — no regression, just no growth until seeded. **Confirmed design for whenever the website admin panel does get built:** pool + auto-fill, not a fully hand-picked calendar — Eddie wants the day-to-day assignment random/unplanned ("let it surprise me as well as others"), with manual override only for specific dates that matter (e.g. a holiday). `category` was added to the schema now specifically so it's there for that future UI to group/filter the pool by — nothing in the app reads `category` today. Still needs, whenever it's picked back up: a **website admin panel** (separate repo, `skadoodle-website`, not connected to this workspace) gated by real Firestore security rules restricting writes to `daily_prompts` (and whatever pool/tracking collection backs it) to a specific authenticated admin UID — not just a client-side hidden page, since anyone could otherwise write directly to Firestore.
  - **`SettingsTab.seedDailyPromptsIfDebug()` (DEBUG-only)** — new "📝 Daily Subjects" section in Settings' debug tools. `debugSeedSubjects` is a hardcoded 102-item `[(subject, category)]` list (the original 40 from `DailyPrompt.prompts`, plus 62 newly drafted, across 8 categories: Animals & Creatures, Fantasy & Magic, Space & Sci-Fi, Everyday & Whimsical, Vehicles, Places, Characters & Occupations, Food & Treats — no duplicates, checked programmatically). Tapping "Seed daily_prompts now" reads the whole `daily_prompts` collection first, walks forward day-by-day from today (up to a 400-day horizon) collecting dates that don't have a doc yet, shuffles `debugSeedSubjects` for randomness, and batch-writes one subject per empty date — **never overwrites an already-assigned date**, so it's always safe to re-run after adding more subjects to the list (new entries just continue filling the calendar forward from wherever it left off). This is meant to be edited directly in code (add/remove tuples in `debugSeedSubjects`) rather than through any UI — the "manual process of coming up with more" Eddie flagged is genuinely just editing this Swift array and re-tapping the button.
- **`DailyManager`** (`SnoodleFirebase.swift`, singleton) —
  - `fetchMyEntryToday()` — fetches **only** the signed-in user's own doc for today by known `docId` (a direct `document(docId).getDocument`, not a collection query). This is the privacy mechanism for "blind" submissions: the client never requests other users' entries for an in-progress day in the first place, rather than fetching-then-hiding them in the UI. (Real enforcement would also need Firestore security rules restricting reads on today's docs to their owner — not yet configured; client-side omission is the current safeguard.)
  - `fetchYesterday()` — thin wrapper around `fetchEntries(for:)` (below) for the specific date "yesterday"; the only place that writes to `yesterdayEntries`, the one published property for "yesterday" specifically (not any arbitrary day). **Blind-reveal voting (confirmed design, changed mid-build):** originally this also computed a live `yesterdayWinner` and displayed vote counts during the active voting window — like Wordle showing everyone's guess distribution live. Changed deliberately, closer to how political voting works: results stay sealed until the window closes, not a live leaderboard that invites bandwagon voting and gives away the ending before the actual reveal. `fetchYesterday()` now discards the query's vote-sorted order and re-sorts the fetched entries by `timestamp` before publishing — display order itself would leak ranking even without printing a number, since first-in-list reads as "winning." No winner is computed or shown anywhere during this window; that only happens once the day ages out into the Past Winners archive, which is fully revealed (see below).
  - `fetchEntries(for date:completion:)` — the shared single-day fetch: queries `daily_gallery` where `date == <date>`, sorted server-side by `votes` descending then `timestamp` ascending (tiebreaker — earliest submission wins a tie), resolves each entry's `isVotedByMe` via `fetchVotedIds(for:)` (batched subcollection existence check — mirrors `WorldGalleryManager.fetchLikedIds`). Used by both `fetchYesterday()` and `DailyContestDayView` (archive drill-in) — same query shape, just a different date string and a completion closure instead of publishing to instance state. Requires a composite index — see below.
  - `fetchPastWinners(lookbackDays:completion:)` — populates the Past Winners archive list. See "Past Winners archive" above for how one range query does this without per-day queries or a summary collection.
  - `post(imageData:caption:completion:)` — uploads to Storage at `daily_gallery/{docId}.jpg`, then `setData` (merge-free overwrite) to the Firestore doc with only `userId`/`date`/`imageURL`/`caption`/`timestamp`/`votes: 0` — no profile fields (see `DailyEntry` note above). Re-posting the same day just calls this again with the same `docId`, replacing the old entry. Repeat submissions of the same doodle across different days are fine — each day's doc starts fresh at `votes: 0`, no accumulation carries over.
  - `resolveProfiles(for:completion:)` — resolves `username`/`avatar`/`photoURL` for a batch of entries via `UserProfileManager.shared.fetchProfiles(userIds:completion:)` (batched, cached), then `applyProfile(_:)` onto each entry. Called from `fetchMyEntryToday()`, `fetchEntries(for:)`, and `fetchPastWinners()` — every read path — before publishing/returning results.
  - `fetchTodaySubmissionCount()` / `todaySubmissionCount` — a Firestore **count aggregation query** (`.count.getAggregation(source: .server)`), never a document fetch, so it preserves the same blind-submission privacy guarantee as `fetchMyEntryToday()`: a raw number can't reveal who's posted or what they drew. Bumped optimistically by 1 in `post()`'s completion when `myEntryToday` was nil beforehand (so replacing an existing entry doesn't double-count), and decremented in `withdrawToday()`'s completion. Displayed in `TodayTab.promptCard`.
  - `yesterdayTotalVotes` — computed property, `yesterdayEntries.reduce(0) { $0 + $1.votes }`. No extra query — `yesterdayEntries` is already fully fetched (see `fetchYesterday()` above), just not displayed per-entry. **Does not violate blind-reveal**: a single combined total can't be used to infer which entry is leading, unlike a per-entry tally or vote-sorted list order — the same distinction as an election turnout counter vs. live per-candidate results. Displayed in `TodayTab.yesterdaySection`'s header alongside the existing entry count ("8 entries · 42 votes cast").
  - `yesterdayUniqueVoterCount` / `fetchUniqueVoterCount(for:)` — **distinct people who voted, not total votes cast** — a deliberately different number from `yesterdayTotalVotes`, since voting is unlimited (one person can vote for several entries, so vote count and voter count diverge). Reads every one of yesterday's entries' `votes` subcollections in full (not just an existence check for one uid, unlike `fetchVotedIds`) and unions the doc IDs (each is a voter's uid) into a `Set`. Bounded by entry count × votes-per-entry — fine at current scale, would need a `collectionGroup` query instead if a single day's entry/vote count ever got large. Called automatically at the end of `fetchYesterday()`.
  - `totalUserCount` / `fetchTotalUserCount()` — count aggregation query on `users`. Denominator for `yesterdayVoterTurnoutPercent` (`yesterdayUniqueVoterCount / totalUserCount`, rounded). **Deliberately a soft/shifting denominator** — includes every account ever created (inactive/test/phantom accounts included) and grows as people sign up, so the percentage is shown alongside the raw voter count rather than replacing it ("6 of 40 users voted (15%)"), not as a standalone number.
  - `withdrawToday(completion:)` — deletes the signed-in user's own today-doc (derived from current uid + today's date, never from whatever's cached in `myEntryToday`) plus a best-effort Storage image cleanup, then sets `myEntryToday = nil`. Safe as a clean delete since today's entry is guaranteed still-blind/unvoted — no `votes` subcollection to reconcile. **Scoped to today only** — withdrawing a revealed/already-voted entry is explicitly not supported (would need vote cleanup + raises fairness questions about pulling out mid-contest); once an entry is revealed it's locked.
  - **Found while adding `daily_prompts` security rules: the live Firestore rules had no `votes` subcollection rule.** The `daily_gallery` rules block only had a `match /likes/{userId}` rule (leftover from before the `likes`→`votes` rename documented above), never updated to also match `daily_gallery/{docId}/votes/{uid}`, and there's no top-level catch-all rule in this project's ruleset — anything unmatched is denied by default. If those were the actual live rules, voting would have been failing with "missing or insufficient permissions" the whole time, silently, since the client already handles vote failures by just not updating optimistically. Fixed by adding a `votes` sibling rule (identical shape to `likes`) under `daily_gallery`; the stale `likes` rule was left in place rather than removed (harmless unused config, not worth touching beyond what's needed). **Action item: confirm voting actually works in the Voting Booth after publishing the updated rules** — this may not have been verified end-to-end before now.
  - `toggleVote(_:)` — guards against voting outside the current window first (`entry.date == currentVotableDate`, else no-op + `false`), then does optimistic vote/unvote against `yesterdayEntries` / `myEntryToday` (whichever matches the id). `@discardableResult` so the existing fire-and-forget call site still compiles; returns `Bool` so the UI can show "voting closed" feedback (`DailyEntryDetailSheet.canVote` uses this). Votes subcollection at `daily_gallery/{docId}/votes/{uid}`. Fully separate from World Gallery likes — the same image posted to both galleries accumulates two independent counts, in separate Firestore fields/subcollections. **Confirmed: voting is unlimited, not one-per-day.** Each entry's vote doc is independent (`daily_gallery/{docId}/votes/{uid}`), so a user can vote for as many different entries in a single day's contest as they want — functionally closer to World Gallery's likes than a single-pick election vote. Considered adding a one-vote-per-day cap (more like American Idol/The Voice) but decided against it for now; revisit if it matters later. The vote itself still writes/toggles instantly and is reflected privately in the voting booth (your own vote confirms immediately, like getting an "I Voted" sticker) — it's only the aggregate count/leader that's hidden from everyone, not the act of voting.
- **User-facing wording: "Prompt" → "Subject".** "TODAY'S PROMPT" → "TODAY'S SUBJECT" (`TodayTab.promptCard`), and the withdraw-confirmation message now reads "today's subject" instead of "today's prompt". `DrawScreen`'s canvas `.navigationTitle` also shows the actual subject (`DailyPrompt.today`) instead of the generic "New Doodle" whenever the session was opened via TodayTab's "Open Canvas" (`dailySubmitIntent == true`) — i.e. before you've even submitted, the canvas itself is titled with what you're drawing for. Deliberately word-only: the underlying `DailyPrompt` struct/type name, `promptCard` property name, and `DailyPrompt.today` accessor were left as-is — renaming internal identifiers throughout the codebase wasn't part of the ask and would be a much larger, purely-cosmetic-to-users refactor for no user-visible benefit.
- **`TodayTab.swift`** —
  - `promptCard` — shows `DailyPrompt.today`. If not signed in: sign-in prompt. If signed in and no entry yet: "Open Canvas" (posts `.todaySwitchToNew` notification, which `ContentView` observes to flip to the New tab) + "Post" (opens `DailyPostPickerSheet` to pick from your private gallery). If already posted: shows your entry with a "✓ Posted" badge, "Replace My Entry", and a destructive "Withdraw" button (confirmation dialog → `DailyManager.withdrawToday`). **Fixed: posted-entry thumbnail was a "sliver" on iPad** — the image previously had only `.frame(height: 200)`, so width stretched to the card's full (much wider, on iPad) width. Now a fixed `220x220` square, which also just centers itself via the parent `VStack`'s default center alignment on both iPhone and iPad.
  - **Fixed: no direct path to submit a brand-new doodle to today's challenge, then redesigned as toggles.** "Open Canvas" only ever switched to the New tab — after drawing and tapping Done, the result card offered just "Post to Community" / "Keep Private," so entering today's contest with a fresh drawing meant saving it privately first, then going back through `DailyPostPickerSheet` to pick it from the gallery. First fix added a third mutually-exclusive result-card button ("Submit to Today's Challenge"), but that couldn't express "post publicly AND submit to today's challenge" at the same time — superseded by the current design: the result card (`DrawScreen.swift`) always saves to the private gallery unconditionally (a static "Always saved to your gallery" line, not a toggle — the private gallery is framed as a history you can always come back to and re-edit, like browser history, not an opt-in), plus two independent, freely-combinable `Toggle`s — "Post to Community" (`$wantsPublicPost`, always defaults off) and "Submit to Today's Challenge" (`$wantsDailySubmit`, shown only when signed in and `DailyManager.shared.myEntryToday == nil`, defaults on only when the session was opened via TodayTab's "Open Canvas" — threaded in as `dailySubmitIntent`, a `@Binding` passed from `ContentView` through `DrawScreen`, set true only in the `.todaySwitchToNew` notification handler and reset to false on dismiss) — and a single "Save" button (`saveResult()`) that commits whichever combination is selected. `saveResult()` always writes the private copy; if either toggle is on, its corresponding network call (`WorldGalleryManager.shared.submit` / `daily.post`) runs inside a `DispatchGroup`, and the private save happens in `group.notify` using the (possibly-mutated-by-World-Gallery) `entry` so `worldGalleryId` is captured correctly even when both toggles are on. First error from either call is surfaced via `.alert("Something Went Wrong", ...)`; the doodle is never lost even on a partial failure, since the private save always completes as long as the guard clauses pass. Where the sheet lands afterward: Daily takes priority (tab 0) if `wantsDailySubmit`, else Gallery (tab 1) — same tab-index fix as below, now folded into `saveResult()`. `DrawScreen` gained `@ObservedObject private var daily = DailyManager.shared` for this (previously had no reference to the Daily system at all).
  - **Fixed (found while adding the above): the old `saveEntry(post:)`'s post-save tab index was stale.** Both branches ended with `selectedTab = 0` to land back on the gallery — correct back when Gallery was tab 0, but Today was inserted as the new tab 0 during this build and nothing here was updated, so "Post to Community" / "Keep Private" were silently landing on the Today tab instead of the gallery ever since. Fixed to `selectedTab = 1` (Gallery's actual index — see `ContentView.swift`'s `TabView` tags), now expressed as `selectedTab = wantsDailySubmit ? 0 : 1` inside `saveResult()`. `DrawScreen.swift` hadn't been touched at all during the Daily Doodle work until this fix, per "never touch working code outside stated scope" — this one was directly adjacent to the change above, not a separate detour.
  - `yesterdaySection` — "YESTERDAY'S CONTEST" header with entry count, then (blind-reveal redesign) a single large "VOTE!" button — no spotlight, no grid, no counts, since any of those would leak ranking before the reveal. Tapping it presents `DailyVotingBoothView` full-screen. Empty state unchanged: "No doodles were submitted yesterday."
  - `DailyVotingBoothView` — the actual blind-reveal voting experience: a `TabView(.page)` swiping one-at-a-time through `yesterdayEntries` (already arrived in timestamp order from `fetchYesterday()`), each page full-size image + tappable avatar + a vote button using `checkmark.seal`/`checkmark.seal.fill` (not a heart — kept distinct from World Gallery's like icon and from the archive's revealed vote button) with **no per-entry count displayed anywhere**. Voting toggles instantly and the seal fills in as private confirmation; nothing about per-entry results is shown. Reads the live entry from `daily.yesterdayEntries` on every page (via id lookup) so a vote is reflected immediately without leaving the view. Vote button disabled on your own entry and when signed out. Button label reads "Vote for This" (was ambiguous plain "Vote") since it wasn't clear a vote was necessarily *for* the entry on screen — **still an open question, revisit wording again if a better option comes up.** Subject shown once as a header capsule — reads `daily.yesterdaySubject` (see below), **not** any entry's own `caption` field. Originally read `entries.first?.caption` (reasoning: caption is always forced to the subject at post time) but this broke for hand-seeded/legacy test data whose caption was never forced to anything (a real AI-generated caption showed instead of the subject) — fragile by construction, since it silently trusted whatever every test doc happened to contain. Prev/Next chevron buttons overlaid directly on the image itself (moved here from a screen-level overlay that used `.frame(maxHeight: .infinity, alignment: .center)` — that positioned them relative to the *whole screen* height, which could land below the image entirely depending on device height, making them easy to miss or look randomly placed) — `goTo(_:)` clamps to valid range, disabled/dimmed at both ends. Vote button's bottom padding increased (50pt → 64pt) — was getting clipped by the home indicator on some devices.
  - `DailyManager.yesterdaySubject` / `fetchYesterdaySubject()` — yesterday's real subject, resolved the same Firestore-first/local-fallback way as `todaySubject` (see `fetchSubject(for:)`, the shared helper both now call, generalized to take any `Date` instead of hardcoding "today"). `DailyPrompt.subject(for:)` similarly generalizes the old `today` mod-cycle formula to an arbitrary date, so the *fallback* for a non-today date reflects that date's own day-of-year rather than today's. This is what the Voting Booth header actually reads now — deliberately independent of any entry's `caption` field (see above).
  - **Voting Booth turnout stats only refreshed on tab appear/refresh, not while the booth itself is open.** Casting a vote inside the booth didn't move the numbers on the Today tab until the next pull-to-refresh. Fixed: `TodayTab`'s `.fullScreenCover(isPresented: $showVotingBooth, onDismiss:)` now calls `daily.fetchYesterday()` + `daily.fetchTotalUserCount()` when the booth closes, so the counts are current the moment you're back.
  - **Redesigned: forced Yes/No per doodle instead of one opt-in "Vote for This" button.** Every entry now shows two buttons; whichever you tap, `advanceAfterVote()` auto-swipes to the next page (`goTo(currentIndex + 1)`, valid range extended to `0...entries.count` to include the new completion page below). "No" is never written anywhere — it's exactly equivalent to not voting at all, so this is a pure UI change with no new data concept. `setVote(_:voted:)` sets state absolutely rather than toggling (`if entry.isVotedByMe != voted { daily.toggleVote(entry) }`), since auto-advance means you won't naturally re-tap the same page to undo a mis-tap the way the old toggle button assumed — swiping back to an already-answered doodle correctly shows which side you picked (whichever button matches `isVotedByMe` renders filled/selected) rather than looking blank. Button wording itself ("Yes"/"No") is still a placeholder — deliberately plain text, no thumbs-up/down icon, to stay distinct from World Gallery's heart-based likes; revisit the exact words later.
  - **New: a completion page after the last doodle**, reached by auto-advance or by manually swiping/tapping Next past the last entry (`.tag(entries.count)` in the `TabView`, alongside a `completionPage` view). Explains the day-boundary/reveal mechanic in plain language ("every doodle is submitted blind during its own day, the next day it's revealed here for voting, results stay hidden until that day closes too"), reminds you that swiping back lets you change any answer, and has its own "Done" button to dismiss — a deliberate stop rather than just dumping you back on the Today tab the moment you finish. The top counter ("N of M") and subject capsule are hidden while on this page (`currentIndex < entries.count` guards both), since neither applies here.
  - `pastWinnersSection` — **inlined directly into the main scroll, not a separate screen.** Originally a `pastWinnersLink` row pushing `PastWinnersView` as its own pushed screen; changed since the whole point of this tab is that submit/vote/browse-winners all live on one continuously-scrolling screen, per the original design brief. Now renders the "PAST WINNERS" header + `PastWinnerRow` list directly below `yesterdaySection`, fetched via `daily.fetchPastWinners()` alongside the other two fetches in `TodayTab`'s own `.onAppear`/`.refreshable`. Tapping a row still pushes `DailyContestDayView` via `.navigationDestination(item:)` on `TodayTab`'s own `NavigationStack` — drilling into one specific day's full results is still a legitimate secondary screen, same as the voting booth is; it's the summary list itself that shouldn't require an extra tap. `PastWinnersView` (the old standalone screen) is left in place unused rather than deleted, same as `CalendarTab.swift`'s precedent.
  - `DailyEntryDetailSheet` — full-size image, avatar/caption, vote button labeled "Vote"/"Voted" **with a visible vote count**. This is intentionally still used by the archive (`DailyContestDayView`/`PastWinnersView` drill-in) only — those days are fully revealed/finalized, so showing counts there is correct; it's no longer used by the live "yesterday" flow (that's `DailyVotingBoothView` now, which never shows a count). `canVote` computed property gates the button on both "not your own entry" and "entry is from the currently votable day" — in practice this is now always false for anything reachable through this sheet, since "yesterday" no longer routes here, but the guard stays as a safety net.
  - `DailyPostPickerSheet` — grid picker over `SnoodleStore.entries` (your private gallery) to choose what to submit.
  - `PastWinnersView` / `PastWinnerRow` — scrollable list of `DailyWinnerSummary` (from `fetchPastWinners`), most recent first. Each row is **four independent sibling tap targets** (thumbnail, date, avatar, votes/count) rather than one row wrapped in a single tappable control — keeps "tap avatar → artist profile" fully separate from "tap row → open that day" without nested-button or hit-testing workarounds. Tapping the row (not the avatar) pushes `DailyContestDayView` via `.navigationDestination(item:)`. Requires `IdentifiableString` (`GalleryTab.swift`) to conform to `Hashable` in addition to `Identifiable` — `.navigationDestination(item:)` requires both; added since `IdentifiableString` previously only conformed to `Identifiable` (fine everywhere else it's used, since `.sheet(item:)` only needs `Identifiable`).
  - `DailyContestDayView` — full detail for one specific concluded (fully revealed) date: winner spotlight + grid, own local `@State` (not `daily.yesterdayEntries`, which is specifically "yesterday" and no longer sorted/displayed by votes — see blind-reveal note above). Fetches via `DailyManager.fetchEntries(for:)`. This is the one place left that still shows a winner-card-plus-grid layout, since archive days are fully revealed and showing rank there is correct and intentional.
  - **Artist profile tap-through** — every avatar/username in the Daily flows (voting booth pages, past-winners rows, archive detail, detail sheets) is independently tappable via an `onAuthorTap: (String) -> Void` closure threaded down from `TodayTab.showAuthorProfile`, which presents `PublicProfileView(userId:isOwnProfile: false)` as a sheet — matches World Gallery's existing `onAuthorTap`/`authorProfileUserId` pattern (`GalleryTab.swift`) exactly, including reusing the same `IdentifiableString` wrapper type. Implemented as separate sibling Buttons rather than nesting a button inside another button's label, per `WorldSnoodleTile`'s established convention.
  - **Fixed: Past Winners showed every date one day early.** `PastWinnerRow`/`DailyContestDayView` each parse the `date` string with a `parseFormatter` correctly pinned to `DailyEntry.contestTimeZone`, but their paired `displayFormatter` had no time zone set, defaulting to the device's local time zone. Formatting a contest-day Date with a different time zone than it was parsed with can roll it onto the adjacent calendar day — every date displayed one day earlier than the underlying `date` string. Fixed by pinning both formatters to the same `DailyEntry.contestTimeZone`. General rule going forward: any formatter that touches a `daily_gallery` `date` string, for parsing or display, must use `DailyEntry.contestTimeZone` — never the device default.

### Explicitly deferred (do this after functionality is solid)
- ~~Visual "skin" / flashy redesign of the whole Today tab~~ — **Started.** See "Today tab redesign: winner-first layout" below. Past Winners list and the day-detail archive view are still plain/functional for now.
- Winner celebration moment (confetti/modal/animation when you open Today and you won) — not built yet.
- Push notification when you win — not built yet.
- Firestore security rules to actually enforce "no reading other users' today-entries server-side" and "no voting outside the allowed window server-side" (client currently just doesn't ask/doesn't allow it, which isn't the same as the server refusing).
- Auto-refresh on day rollover while the Today tab is left open — currently only refreshes on `.onAppear` / pull-to-refresh; a stale in-memory view of an expired day is possible but low priority (add a "contest ended, refresh" message if it turns out to actually bother anyone).
- Pagination for Past Winners beyond the fixed `lookbackDays` window (default 60 days) — not built yet; revisit if anyone's actually browsing back that far.

### Today tab redesign: winner-first layout

**Rationale (design discussion before building):** the whole point of Daily Doodle is naming a #1 winner each day — submit and vote are just the two steps that get you there, not the main event. The old layout put the submit card front-and-center with vote and winners buried below; this flips it so the most recently *decided* winner is the very first thing you see, with Submit and Vote as two equal CTAs underneath.

**Timing model reconsidered, then kept as-is.** Before building, we revisited whether the 2-day submit→vote→winner cycle could be compressed (e.g. 12-hour submit + 12-hour vote, same-day resolution) now that Eddie wanted the winner to feel like the main event. Conclusion: keep the current 24h submission + 24h voting model. A same-day model would cut both the submission and voting windows in half, which (a) roughly halves the reach of each window since it's anchored to a fixed America/New_York clock rather than each user's own day, excluding whoever's asleep during whichever half gets assigned, and (b) roughly halves how many votes an entry can accumulate before the window closes. Both effects compound against the fact that this feature needs a real crowd (Eddie's own estimate: 100+ users) before a "#1 winner" is a meaningful signal rather than noise from 2-3 votes. Real-time/no-blind-period was also considered and rejected outright — it reintroduces the exact bandwagon/spoiler problem the blind-reveal design was already built to avoid. This is a revisit-later knob once the active user base is large enough that a shorter window is still statistically fine, not a permanent decision.

**Most recent decided winner ≠ "yesterday."** `daily.pastWinners` is already sorted most-recent-first (see `fetchPastWinners`'s doc comment above), so `.first` is exactly the most recent day whose *voting* has closed — always 2 days back from today, never "yesterday" (still an open, blind-reveal vote in progress) and never "today" (still blind submission). The hero card is deliberately labeled with the actual date (`heroDisplayDate`, `"MMM d"` in `DailyEntry.contestTimeZone`), not a relative word like "yesterday," since that would be factually wrong.

- **`heroWinnerSection` / `heroWinnerCard(_:)`** (`TodayTab.swift`) — new hero at the very top of the Today scroll. Loading state (first fetch in flight), populated state (image with yellow border + vote-count badge, "DOODLE OF THE DAY · <date>" label, avatar, caption — image+badge and avatar are separate sibling tap targets, same non-nested-button convention as `PastWinnerRow`), and an empty state ("The first Doodle of the Day winner will appear here once a day's voting closes") for when the feature is brand new and no day has finished voting yet. Tapping the image opens the same `DailyContestDayView` that tapping a Past Winners row opens (via the existing `selectedPastDate` / `navigationDestination(item:)`).
- **`subjectStrip`** — today's subject, demoted from a 36pt hero card to a slim context strip between the winner and the CTAs. Still there (you need to know what you're drawing), just no longer the star.
- **`ctaSection` / `ctaButton(...)`** — SUBMIT! and VOTE! as two equal, always-visible CTAs. Submit reads "SUBMITTED ✓" (green) once you've posted today instead of hiding/replacing the button; Vote is grayed out and disabled (not hidden) when yesterday has no entries, for visual symmetry between the two rather than one button disappearing. Turnout stats (unique voters, % of total users) still shown beneath, unchanged from before.
- **`DailySubmitScreen`** (new top-level struct, mirrors `DailyVotingBoothView`'s existing full-screen pattern) — everything that used to live inline in the old subject card (subject + count, Open Canvas / Post if not yet entered, Replace / Withdraw if already posted) now lives in its own full-screen cover, opened by the SUBMIT! CTA. `showingPostPicker` and `showWithdrawConfirm` stay owned by `TodayTab` and are passed down as `@Binding`s, since their `.sheet`/`.confirmationDialog` are declared on `TodayTab`'s own `NavigationStack` — presenting from there on top of the `DailySubmitScreen` full-screen cover works the same way sheet-on-sheet presentation already does elsewhere in the app. "Open Canvas" now calls `dismiss()` on the Submit screen before posting `.todaySwitchToNew` (0.35s delay, same pattern as other sheet-transition spots in this codebase) — otherwise the New tab's own full-screen `DrawScreen` cover would stack on top of the still-open Submit screen instead of replacing it.
- **`pastWinnersSection`** now shows `remainingPastWinners` (`daily.pastWinners.dropFirst()`) instead of the full list, since the hero above already covers the most recent entry — avoids showing the same winner twice on one screen. Empty-state copy changed from "No past winners yet" to "No more past winners yet" to match (the hero may already be showing the only winner so far).
- **Old `promptCard` and `yesterdaySection` removed** — fully superseded by the above. All underlying data/fetch logic (`myEntryToday`, `yesterdayEntries`, `todaySubject`, counts, turnout) is unchanged; this was presentation-only.
- **Still plain/unstyled, deliberately out of scope for this pass:** Past Winners list rows and `DailyContestDayView`'s own winner-card-plus-grid layout. Winner celebration moment and push-on-win are still separate, not-yet-built items (see above).
- **`RibbonBadge` / `RibbonTail`** (`TodayTab.swift`, top-level structs) — the blue prize ribbon overlapping the top-left corner of the hero winner's image. Built entirely from SwiftUI shapes (`Circle` petal ring + a custom `RibbonTail: Shape` with a V-notch cut into the bottom edge), no image asset. Chosen after mocking up three treatments together: a plain circle-and-rectangle badge read as a lollipop rather than a ribbon once actually rendered; a flat single-tone version felt too quiet; this pleated two-tone version (alternating petal shades + a darker medallion) was the one that actually looked like a ribbon. Label reads "BEST", not "1st" — there's no 2nd/3rd place in this design, just one decided winner per day. Deliberately overlaps the image corner rather than framing/tilting the whole canvas — the winning artist's linework stays perfectly flat and undistorted; only the ribbon breaks the grid. The old plain yellow border around the hero image was removed in favor of this.
- **Heart icon → `checkmark.seal` for votes, everywhere in Daily Doodle.** The heart-means-likes vs. votes ambiguity flagged as a known deferred item (see "Terminology: votes, not likes" above) is now fixed: every vote display in Daily Doodle (hero winner badge, `PastWinnerRow`, `DailyContestDayView`'s winner card, `DailyEntryDetailSheet`'s vote button and read-only vote count) uses `checkmark.seal`/`checkmark.seal.fill` (green when voted/counted) instead of `heart`/`heart.fill` (pink). Matches the icon the Voting Booth already used for casting a vote, so the whole vote visual language is now consistent and visually distinct from World Gallery's heart-based likes. World Gallery itself is untouched — hearts still mean likes there.
- **`RibbonBadge` still hand-rolled SwiftUI shapes, not a real image asset.** Eddie shared a reference "1st Place" ribbon photo (real pleated fabric, gradient shading) and asked whether that was being used — it isn't; there's no tool in this environment to save a chat-pasted image to disk or generate new art, and that reference photo looks like stock art we wouldn't have the right to ship anyway. **Decided (for now): keep iterating on the vector shape** rather than source a licensed image asset — revisit if a real asset becomes available (Eddie would need to add a properly-licensed file to the project; wiring it into Assets.xcassets is straightforward whenever that happens).
- **Confirmed: single winner only, no top-3 podium.** Discussed adding 2nd/3rd place to the hero (technically cheap — `fetchEntries(for:)` already returns each day sorted by votes descending, so a podium needs no new backend work) but decided against it, keeping the original single-winner framing. Ribbon wording stays "BEST", not "1st" — reopen this if the podium idea comes back.
- **Confirmed: hero image keeps cropping to fill (`.fill`/"cover"), not letterboxed.** Doodle canvases aren't guaranteed square — `canvasSize` in `DrawScreen.swift` is set from the actual on-screen drawing area's `GeometryReader` size at draw time, which varies by device, so a non-square doodle gets center-cropped into the hero's forced 1:1 square today. Raised as a possible conflict with the "don't distort the artist's work" principle from the ribbon discussion, but Eddie chose to keep the current crop-to-fill behavior rather than switch to letterboxing.
- **Fixed: hero image was full iPad-card-width, making the square tall enough to require scrolling to see the whole thing.** `.frame(maxWidth: .infinity)` on the 1:1-aspect image meant its width (and therefore height, since it's forced square) equaled the entire hero card's width — comfortable on iPhone, but on a wide iPad screen this produced a square tall enough that it didn't fit on screen together with the tab bar and header above it. Fixed by capping at `.frame(maxWidth: 380)` before the existing `.frame(maxWidth: .infinity)` (the fixed-width child is centered within the flexible parent) — same fix shape as the earlier "posted-entry thumbnail was a sliver on iPad" bug.
- **`RibbonBadge`/`RibbonTail` fixed through three rounds of screenshot-driven feedback:** (1) tails originally angled in from the sides instead of fanning out from one shared point — root cause was each tail sitting in an `HStack` and rotating around its own default `.center` anchor independently; fixed by moving both tails into a `ZStack(alignment: .top)` and using `.rotationEffect(_:anchor: .top)` on each so they share one attachment point and fan outward from it (angles widened to −16°/+16°, frames enlarged). (2) tails were rendering on top of the "BEST" medallion instead of behind it, and the whole badge was getting clipped against the hero card's edge — fixed by restructuring `RibbonBadge.body` into one outer `ZStack` with the tails-group declared first (paints behind) and the rosette-group declared second (paints on top), and by shrinking `heroWinnerCard`'s badge offset from `(-14,-14)` to `(-2,-6)` so it stays inside the card's 16pt padding before the card's own corner-radius clip. (3) tails were barely "peeking out" below the medallion instead of hanging down visibly — root cause was the outer `ZStack`'s default `.center` alignment centering each child's full height (including the tail-group's own vertical midpoint) before any offset was applied, so most of the offset budget was spent just clearing the tail-group's own half-height; fixed by switching the outer `ZStack` to `alignment: .top` (giving both children one shared top reference line so offsets behave as literally specified) and increasing `.offset(y: 12)` → `.offset(y: 26)` plus taller tail frames (54/58pt → 64/68pt height, 24pt → 26pt width).
- **In progress, not yet built: a decorative braid frame around the hero winner image, in addition to (not replacing) the ribbon.** Eddie wants something inspired by googling "elaborate but thin picture frames" — specifically a thin frame with a pattern in it, and specifically the app's own actual "Braid" dual-tone pen style (two sinusoidal weaving strands, *not* a diagonal barber-pole stripe — an early mockup got this wrong and was called out). Confirmed requirements: (a) must reuse the real `.braid` weave math from `DrawingEngine.swift` (arc-length-driven sinusoidal offsets, half-period alternating draw order for the over/under illusion — see the "Braid" pen bullet under v2.2's Dual Tone pen styles, ~line 303), ported from a stroke to a closed rounded-rectangle perimeter; (b) frame does NOT replace the ribbon — both appear together, with the ribbon rendering on top wherever they overlap; (c) colors should be gold plus one other color — first tried white/cream, Eddie moved away from that and asked to try different second colors; (d) thickness — first prototype (amplitude 7.0, strand width 9.0) was "way too thick," second pass roughly halved both (amplitude 4.2, strand width 4.2) and hasn't been confirmed yet. Prototyping has been happening entirely in standalone Python-generated SVG (`/tmp/braid2.py`, output copied to the outputs folder as `braid_compare.svg`/`braid_compare2.svg`), porting the exact perimeter-point math (241 points around a 150×150 rounded rect, seam hidden at the top-left corner arc midpoint where the ribbon sits) before touching any Swift — deliberately, since "going back and forth with graphics with AI can be painful" (Eddie's words) and this app's established pattern is to nail the visual in a throwaway mockup first. **Last thing shown to Eddie:** a three-way side-by-side comparison (gold+navy `#1E3A6E`, gold+burgundy `#7A1F2B`, gold+forest-green `#2F5D3A`) at the thinner amplitude/width, rendered via the visualize widget tool — Eddie has not yet responded with a pick. **Next steps once resumed:** get Eddie's color choice (and confirm the thinner weight actually reads right, or needs further adjustment), then port the validated geometry into a real reusable SwiftUI shape/view in `TodayTab.swift` that wraps around `heroWinnerCard`'s image at its actual rendered size (not the mockup's fixed 150×150), composited so the `RibbonBadge` still paints on top wherever it overlaps the frame.

---

## v2.4 b7 (submitted June 30, 2026)

### Fixes — v2.4 b7
- **Eraser wrong color when canvas color has opacity < 100%** — `DrawingCanvas` in DrawScreen received `canvasColor` as its `.background()`, creating a double-layer: the `canvasColor` fill at the top of the ZStack body (line 3173) PLUS `DrawingCanvas.background(canvasColor)` on top of it. Two semi-transparent layers stacked to a more-saturated composite; the eraser only accounted for one layer and painted a lighter color. Fix: `DrawingCanvas` in DrawScreen now receives `canvasColor: .clear` — its background is invisible; the ZStack-level `canvasColor` fill is the sole canvas background. Added `opaqueCanvasColor` computed property to DrawScreen (canvas color pre-composited over white, same formula as video export) and used it in `drawingLayerView` so eraser paints the visually-correct fully-opaque composited color. (`DrawScreen.swift`)
- **Eraser wrong color when background image has opacity < 100% AND canvas color has opacity < 100%** — `processedBackgroundForEraser` passed `UIColor(canvasColor)` (possibly semi-transparent) as the base fill to `_BgEffectsImageCache.get`. The UIKit bitmap context composites a semi-transparent fill slightly differently than SwiftUI (color-space / P3 vs sRGB path), producing a "darker shade" mismatch. Fix: `processedBackgroundForEraser` now pre-composites canvas color over white in sRGB (same formula as `opaqueCanvasColor`) before passing to the cache, guaranteeing a fully opaque base and eliminating the UIKit/SwiftUI discrepancy. Also added `UIColor.white` pre-fill in `_BgEffectsImageCache.get` (opaque context initializes to black, not white). (`DrawingEngine.swift`)
- **Timelapse video shows black/wrong background with semi-transparent canvas color** — `runningComposite` and `belowComp` renders in `DoodleVideoExport` used `canvasUIColor` directly. If canvas color had alpha < 1, `imgFormat.opaque = true` composited over black. Fix: added `opaqueCanvasColor` pre-composite (same formula) in the video export; all render calls use the opaque version. (`DoodleVideoExport.swift`)
- **Timelapse video colors lighter than live canvas** — H.264 encoder was blindly converting RGB → YCbCr without color space tagging, causing iOS to apply incorrect transfer curves. Fix: added `AVVideoColorProperties` (ITU-R BT.709 primaries, transfer function, and YCbCr matrix) to both the `AVAssetWriterInput` video settings and the `CVPixelBuffer` attributes. (`DoodleVideoExport.swift`)
- **No share button in video player** — `AVPlayerViewController.customOverlayViewController` is tvOS-only. Fix: wrapped `AVPlayerViewController` in a `VideoPlayerContainerVC` (UIViewController child), which adds a share button (↑ icon) as a sibling view on top of the player. Tapping opens `UIActivityViewController` for AirDrop, save, messages, etc. (`DoodleVideoExport.swift`)
- **AI processing slow (waiting for Gemini)** — Two-phase AI: Apple Vision (`VNClassifyImageRequest`) runs on-device instantly (~50ms), shows caption and tags immediately, then Gemini runs concurrently and silently upgrades the result when it finishes. No spinner shown to user; the result card appears immediately with Vision results. Added `VisionProvider` class implementing `AIProvider` protocol; `handleDone` runs both phases in a single `Task`. (`DrawingEngine.swift`, `DrawScreen.swift`)

## v2.4 b4 (submitted June 30, 2026)

### Fixes — v2.4 b4
- **Color picker `+` button stuck after cancelled swipe + X tap** — `presentationControllerWillDismiss` sets `interactiveDismiss = true` when a swipe starts. If the user cancelled the swipe (no delegate callback exists for swipe-cancel) and then tapped X, `colorPickerViewControllerDidFinish` early-returned on `!interactiveDismiss`, leaving `picker` non-nil and `isPresented` stuck true. Next `+` tap was a no-op (no state change). Fix: (1) reset `interactiveDismiss = false` in `colorPickerViewControllerDidSelectColor` so any color interaction after a cancelled swipe clears the flag; (2) added stale-picker check at top of `presentIfNeeded` — if `picker.presentingViewController == nil`, clear all stuck state before attempting re-presentation; (3) `+` button action now forces `showPenColorPicker = false` then `async true` to guarantee `updateUIView` fires even if state was stuck. (`StampTools.swift`, `DrawScreen.swift`)
- **"Resume Last Doodle?" alert appearing on re-edit** — On first launch after restart, `entryToEdit` was a `let` property frozen at DrawScreen's creation time. SwiftUI sometimes creates the sheet content before the `entryToEdit = entry` render cycle fully commits, so DrawScreen was created with `entryToEdit = nil`. `.onAppear` then hit the `else` branch and showed the resume alert (since `current.skadoodle` existed from the last session). Fix: changed `let entryToEdit: SnoodleEntry?` to `@Binding var entryToEdit: SnoodleEntry?` so `.onAppear` reads the live value from ContentView's state rather than the snapshot at creation time. ContentView now passes `$entryToEdit`. (`DrawScreen.swift`, `ContentView.swift`)
- **Processing time logging added** — `handleDone` and `saveEntry` print timing for `renderCanvasWithStamps` and `callSnoodleAI`. Confirmed: render is ~0.05s; slowness is entirely Gemini API retries on 503 (server load), not a code issue. Logs are intentionally left in for ongoing diagnostics. (`DrawScreen.swift`)

## v2.4 b3 (submitted June 29, 2026)

### Fixes — v2.4 b3
- **Stamp drag blocked when another stamp was selected** — `gestureRecognizerShouldBegin` and `handleLongPress.began` were blocking ALL stamp drags when `selectedStampId != nil`. Narrowed the guard: only blocks instant-pan and LP on the stamp that currently has the magic menu open (by checking `hit?.id == selectedStampId`). Other stamps can still be dragged freely while one is selected. (`DrawScreen.swift`)
- **LP/pan race causing snug rect flash during instant drag** — `UILongPressGestureRecognizer` (0.05s in stamp mode) could fire before the pan recognized movement, briefly setting `isLongPressing = true` and flashing the snug rect. Fix: raised LP minimum press duration in stamp mode from 0.05s to 0.3s, giving the pan time to own the touch first. Also: in `handleStampPan.began`, if LP already fired and set `selectedStampId` on the panned stamp, call `onCanvasTap()` to deselect immediately. (`DrawScreen.swift`)
- **Canvas defaults to pen mode** — `isStampMode` initial value changed from `false` to `true`. Stamp mode is the primary interaction mode; drawing still works in stamp mode on empty areas. (`DrawScreen.swift`)
- **Pen studio second color not showing as selected in recent list** — `dualToneColorB` was initialized from a legacy palette-index key and never persisted as RGBA, so custom colors were lost on relaunch and the swatch selection highlight failed. Fix: load/save `dualToneColorB` using `"dualToneColorB_rgba"` key (RGBA `[Double]` array). On sheet open, ensure `colorB` is in `recentColors` so the correct swatch is highlighted. (`DrawScreen.swift`)

## v2.4 b2 (submitted June 29, 2026)

### Fixes — v2.4 b2
- **Magic palette drag triggering stamp LP when finger over stamp** — `UILongPressGestureRecognizer` (0.05s stamp-mode LP) could fire while the user dragged the palette with a finger over a selected stamp, causing the stamp to highlight (`isLongPressing = true`) and `showStampMagicMenu = false` (palette disappears). Fix: added `guard parent.selectedStampId == nil else { return }` to `handleLongPress.began` — LP drag is fully blocked while any stamp has the magic menu open. (`DrawScreen.swift`)

---

## v2.4 b1 (submitted June 29, 2026)

### Fixes — v2.4 b1
- **Timelapse needsFull path now O(all_layers) + O(current_layer × chunks)** — Previously, strokes on non-topmost layers called `rebuildComposite(overrideLines:)` per chunk: O(all_layers × chunks), ~130ms/chunk. Now pre-renders `belowComp` (opaque: canvas + bg + everything below the layer) and `aboveComp` (transparent: everything above the layer) once per stroke, then per chunk renders only the current layer in isolation with `canvasColor=.clear, backgroundImage=nil` and composites `belowComp → currentLayer → aboveComp`. Eraser with `.clear` canvas color punches transparent holes → `belowComp` shows through correctly. `aboveComp` always stays on top. (`DoodleVideoExport.swift`)
- **Background picker long-press: Use as Stamp + Extract Objects** — Long-pressing a background thumbnail now shows three options: "Use as Stamp" (places full image as inline stamp, centered, magic menu opens), "Extract Objects" (runs Vision segmentation, same as before), "Remove". Previously only "Remove" was available. (`DrawScreen.swift`)
- **Precision tweak panel dismissing on button tap (main canvas)** — `TweakRepeatButton` uses `DragGesture`, not a UIKit Button, so `shouldReceive`'s class-name check didn't block it. The window-level tap recognizer fired, found no stamp hit, and called `onCanvasTap()` → deselect. Fix: added `blockCanvasTap: Bool` to `WindowPinchView`; set to `showMenuTweak` in DrawScreen. `handleWindowTap` skips `onCanvasTap()` when `blockCanvasTap` is true. Pinch/rotation unaffected. (`DrawScreen.swift`)
- **Black canvas on gallery re-edit** — SwiftUI split `entryToEdit = entry` and `showingDraw = true` across render cycles, presenting the sheet before the entry was committed. Fix: `DispatchQueue.main.async` between the two assignments guarantees one run-loop separation. (`ContentView.swift`)
- **`restoreSkadoodleData` deleting valid entry files** — empty-doc guard was also firing for gallery re-edits (which legitimately restore from the entry's `.skadoodle`). Fix: guard only deletes `current.skadoodle` when `entryToEdit == nil`. (`DrawScreen.swift`)
- **Use as Stamp (background picker) not registering in tray / not placing on canvas** — `onUseAsStamp` handler now calls `CustomStampManager.shared.addStamp` to register the image in the photo tray, sets `stamp.customImageId`, calls `appendStampToLayer`, opens magic menu, and schedules snug scan. (`DrawScreen.swift`)
- **Stamp picker: selected stamp not moving to most-recent position** — `autoPlaceStamp()` now calls `CustomStampManager.shared.moveToTop(id:)` before placing. `moveToTop` added to `CustomStampManager`. (`DrawScreen.swift`, `CustomStampManager.swift`)
- **Background extract placing 7 duplicate stamps** — `ObjectSegmentationSheet`'s `.task` was firing once per ForEach history item as the sheet dismissed, auto-confirming single-object segmentations 7 times. Fix: added `bypassSingle: Bool` param (default `true`); background-extract path passes `false`. Added `didAutoSelect` guard to prevent multiple fires. (`CustomStampViews.swift`, `DrawScreen.swift`)
- **Snug rect smaller than "Use as Stamp" stamp** — `inlineImage` was rendered with `.scaledToFill().clipped()` while `customImageId` path used `.scaledToFit()`. Snug scan measured the fit area but the stamp displayed fill, causing mismatch. Fixed both render paths to `.scaledToFit()`. (`StampCanvas.swift`, `StampTools.swift`)
- **Stamp mode: only pen button switches to pen mode** — Removed `isStampMode = false` from `onStampModeDragOnEmpty`. Drawing on empty canvas in stamp mode now draws without switching mode. The pen button is the only way to exit stamp mode. (`DrawScreen.swift`)
- **Stamp palette drifting off-screen** — `@AppStorage("stampPanelOffsetX_v3")` / `stampPanelOffsetY_v3` could accumulate to an off-screen value across sessions. Fix: `clampedMenuOffset` computed var in DrawScreen clamps saved offset to keep panel on-canvas. Live drag in `StampMagicMenu` also clamped in `.onChanged` so the panel can't be dragged off during a gesture. (`DrawScreen.swift`, `StampTools.swift`)
- **Stamp palette: drag-and-release firing button action** — `StampMagicMenu` drag gesture sets `isDragging = true` on first movement; all `sideButton` and `sideButtonLP` / `_SideLPButton` actions guard against `isDragging`. Dragging and releasing over flip/rotate/trash/dismiss no longer triggers the action. (`StampTools.swift`)
- **Stamp palette default position too close to canvas edge** — base position moved from 6pt to 16pt right margin. (`DrawScreen.swift`)
- **Instant stamp drag (colorforms feel)** — Added `UIPanGestureRecognizer` (`stampPanRecognizer`) to `WindowPinchView`. `gestureRecognizerShouldBegin` returns false unless in stamp mode and touching a stamp — empty-canvas touches fall through to drawing normally. Dragging a stamp is now instant (zero delay, no snug rect, no selection). `handleStampPan.began` clears any LP state that fired before movement was detected; `handleLongPress.began` skips if stamp pan already owns the touch. Long-press (0.05s) still selects stamps and opens the magic menu. `WindowPinchView` call extracted to `var windowPinchView: some View` to avoid Swift type-check timeout. (`DrawScreen.swift`)

---

## In Progress — v2.3 b7

### Fixes — v2.3 b7
- **Text stamp composer colors/shadow not persisting** — `selectedTextColor`, `selectedTextBgColor`, `shadowEnabled`, `shadowColor`, `shadowBlur`, `shadowOffsetX/Y` were all `@State` in `TextComposerSheet`, resetting to defaults on every open. Fix: added `_tcLoadColor`/`_tcSaveColor` private helpers (RGBA stored as `[Double]` in UserDefaults). State vars now load from UserDefaults at init. Values are written back to UserDefaults in the `onPlace` closure. Edit-stamp path (`onAppear` overrides) unchanged. (`StampTools.swift`)
- **Eraser opacity ignored on live canvas** — When a background image was set at opacity < 1, the eraser painted a semi-transparent version of the image onto the drawing layer, which then double-composited with the background image layer below in the ZStack, making erased areas appear more opaque than undrawn regions. Fix: `_BgEffectsImageCache` now produces a **fully opaque** pre-composited image (image at bgOpacity over the base canvas color) instead of a semi-transparent one. `DrawingLayerCanvas` gains a `baseCanvasColor` param (the actual selected canvas color, not `.clear`); `renderLine` and `drawEraserLine` gain the same param and forward it to the cache. (`DrawingEngine.swift`, `DrawScreen.swift`)
- **Video shows black in erased areas** — In the export/video path, `renderLine` was called with `canvasColor = canvasSwiftUI` (solid, e.g., black). `drawEraserLine`'s condition checked `canvasColor != .clear` first, so it painted the solid canvas color instead of the background image. Fix: `drawEraserLine` now checks for `backgroundImage` first (before `canvasColor`), so the image path is always used when a background image is present regardless of `canvasColor`. `renderCanvasWithStamps` computes `eraserBgImage` — a fully opaque pre-composited image — and passes it as `backgroundImage` to `renderLine` for drawing layers, fixing the double-opacity issue in the export path too. (`DrawingEngine.swift`, `StampTools.swift`)

## In Progress — v2.3 b5 (submitted)

### Fixes — v2.3 b5
- **Canvas gestures bleed through text composer and color pickers** — `WindowPinchView.shouldReceive` now checks `blockGestures` flag (passed from DrawScreen); true whenever any sheet/picker is open over the canvas. (`DrawScreen.swift`)
- **Layer up/down buttons dim on press + selection haptic** — `sideButtonLP` extracted to private `_SideLPButton` struct with `@State isPressed` + `DragGesture(minimumDistance:0)` for press state; `UISelectionFeedbackGenerator` fires on each tap. (`StampTools.swift`)
- **extractAllLayersAsStamps firing accidentally on rapid layer-button taps** — disconnected `onBackgroundDoubleTap` from `extractAllLayersAsStamps`; now accessible only via BG chip `···` menu in layers panel. (`DrawScreen.swift`)
- **Timelapse plays in creation order, not z-order** — `createdAt: Date` added to `DrawingLayer` and `PlacedStamp`; encoded as `timeIntervalSince1970` with `decodeIfPresent` fallback to epoch for old files (stable sort preserves z-order for them). `DoodleVideoExport` sorts `layerOrder` by `createdAt` before building state list. (`DrawingEngine.swift`, `StampTools.swift`, `DoodleFormat.swift`, `DoodleVideoExport.swift`)

### Notes — v2.3 b5
- Timelapse creation-order playback requires strategic layer creation to work well — especially around erasing. Acceptable as a power-user quirk for now; video feature is additive, not core. Will revisit.

## In Progress — v2.3 b4 (submitted)

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

### Fixes — v2.3 b4
- **Two-finger gestures no longer target stamp outside its content** — removed selected-stamp priority from `handlePinch` and `handleRotation`; all stamps now use pure alpha-aware `topmostStampHit`. (`DrawScreen.swift`)
- **Eraser on image background paints image pixels** — `drawEraserLine` uses `GraphicsContext.Shading.tiledImage` with cover-fit math matching the SwiftUI background layer exactly. (`DrawingEngine.swift`)
- **Auto-switch to draw mode when dragging on empty canvas in stamp mode** — `onStampModeDragOnEmpty` callback on `DrawingCanvas` returns `Bool`; first stroke draws immediately without waiting for SwiftUI re-render, via `DrawGestureState` reference-type class. (`DrawingEngine.swift`, `DrawScreen.swift`)
- **Auto-switch to stamp mode when placing from tray** — `autoPlaceStamp()`, `placeFullPhotoStamps()`, `placeMultipleEmojis()` set `isStampMode = true`. (`DrawScreen.swift`)
- **`needsNewLayer` no longer creates a new layer on every stroke** — `onBeforeDraw` sets `explicitLayerSelection = true` after auto-creating a layer. (`DrawScreen.swift`)
- **iPad stamp-mode auto-switch** — `PencilInputView` overlay always shown on iPad (was `isIPad && drawingEnabled`); `drawingEnabled` guards inside callbacks handle pen-vs-stamp routing. (`DrawingEngine.swift`)
- **Long press drag in draw mode shows snug rect** — `snugRectOverlay` condition simplified from `isLongPressing && showSnugDuringDrag` to `isLongPressing`. (`DrawScreen.swift`)
- **After long press drag in draw mode, single-finger touch no longer drags stamp** — `onStampDragEnd` clears `selectedStampId` when `showSnugDuringDrag` is false, preventing `StampContainerView.hitTest` from handing the stamp to its `UIPanGestureRecognizer` on the next touch. (`DrawScreen.swift`)
- **`consolidateDrawingLayers()` confirmed not called in any delete path** — dead code; comment documents it as available for a future "Merge Layers" feature. No code change needed.

### Pending
- **Website Firebase deploy** — Skadoodle website (skadoodle.nyc, Firebase Hosting) was updated with v2.2 marketing content and committed to GitHub (username: `eddienorton`, repo: `skadoodle-website`). Firebase deploy must be run from Eddie's terminal (`npx firebase deploy --only hosting` from `/Users/edwardbrayman/Development/Website/skadoodle`).
- ~~**Timelapse eraser optimization**~~ — **Done (v2.3 b8).** Eraser strokes now use incremental delta rendering: `bgBaseImage` (canvas + processed background, captured before the event loop) is painted into a transparent delta image clipped to each new stroke segment, then composited onto `runningComposite` with source-over. O(1) per chunk. `makeFullRender` removed.

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

## In Progress — Profile Doodle Action Tray fixes (found during Daily Doodle test-data setup)

While bulk-creating test doodles/users to exercise Daily Doodle voting paths, two bugs surfaced in `ProfileView.swift`'s `DoodleActionSheet` (the tray that opens when tapping a doodle in your own profile's community grid — thumbnail + Make Banner / Remove from Community / Delete from My Doodles / Cancel):

- **"Make Banner" appeared to be missing entirely** — root cause: `autoAssignBannerIfNeeded()` (called once per profile load, from `loadData()`'s `checkDone()`) silently assigns a user's very first community post as their profile banner the moment they have any doodles and no banner set yet — with no toast, badge, or other feedback anywhere. So the first doodle a (new, test) user ever posts publicly is already the banner by the time they look; `isCurrentBanner` correctly evaluates true for it, and the sheet used to just omit the "Make Banner" row entirely in that case, making it look like the option never existed rather than "already applied." **Fixed:** when `isCurrentBanner` is true, the sheet now shows a disabled "Current Banner" row (checkmark icon, secondary text) in the same slot instead of hiding the option outright. Any other (non-banner) doodle still shows a live "Make Banner" row as before.
- **"Delete from My Doodles" was also hiding the tile from the Community grid** — `onDeleteLocally`'s closure called `doodles.removeAll { $0.id == doodle.id }` in addition to deleting the local `SnoodleEntry`, even though deleting your private copy has zero effect on the world post — it's still live in Firestore/the world gallery. This made a purely-local delete look like it had also un-posted the doodle from the community (until the next profile refresh silently brought it back, since `fetchPublicDoodles` would still return it). It also meant doing *both* "Remove from Community" and "Delete from My Doodles" for the same doodle only worked if done in a specific order, since either action closed the tray and made the tile disappear from the grid, leaving no way back to the tray for the second action. **Fixed:** removed `doodles.removeAll` from `onDeleteLocally` — only `onRemoveFromCommunity` (the action that actually changes world-gallery state) removes the tile from `doodles` now. `onDeleteLocally` deleting an already-deleted (or never-existed) local entry is a harmless no-op via its `first(where:)` guard, so re-tapping "Delete from My Doodles" after a community removal is always safe.
- **Superseded by a full redesign: both delete actions removed from this tray entirely.** Rather than keep patching the two-delete-options confusion above, the tray itself was rethought — it now presents just **"Open" / "Make Banner"** via a plain `.confirmationDialog(presenting:)` (`actionDoodle` + `actionDoodleIndex` state, paired so "Open" knows which grid index to jump to), with no thumbnail/likes/caption preview, matching "minimal" per the redesign request. **Neither delete action was actually lost** — both were already properly available elsewhere and are now reached only from there, un-duplicated: "Remove from Community" lives in `WorldSnoodleDetailView`'s own action bar (`GalleryTab.swift`, the same trash icon every user's own post has there — and its version is strictly better than the old tray's, since it also unlinks the local copy's `isSubmitted`/`worldGalleryId`, which the old ProfileView tray's `onRemoveFromCommunity` never did); "Delete from My Doodles" lives in the private Gallery tab's own doodle detail view (`SnoodleDetailView` in `GalleryTab.swift`, unconditional trash icon — deletes the local `SnoodleEntry` regardless of world-post status). "Open" routes to the exact same `WorldSnoodleDetailView(initialEntries: displayableDoodles, startIndex:, lockToInitial: true)` `fullScreenCover` already used for tapping straight through on someone else's profile, so browsing your own community doodles now feels identical to browsing anyone else's, as requested. `DoodleActionSheet` (the old tray struct) is left in the file unused rather than deleted, matching this file's existing precedent for orphaned code (`CalendarTab.swift`, `PastWinnersView`).
- **iPad: menu appeared centered at the top of the screen instead of near the tapped doodle.** Root cause: `.confirmationDialog` is a bottom sheet on iPhone regardless of where it's attached, but on iPad it presents as a **popover** anchored to whatever view the modifier is attached to. It had been attached to the screen's root `Group`/`VStack` (spanning the whole profile screen), so iPad had nothing better to anchor to than that view's top-center. Fixed by moving the modifier off the root view and onto the individual grid cell inside `doodlesSection`'s `ForEach`, gated per-cell (`actionDoodle?.id == doodle.id`) instead of a single shared "is any doodle selected" binding — iPad's popover now anchors to the actual cell that was tapped. iPhone behavior is unchanged (still a bottom sheet either way).

---

## Dev Convenience — DEBUG-only Settings auto-scroll

`SettingsTab.swift`'s `List` is wrapped in a `ScrollViewReader`; on `.onAppear`, wrapped in `#if DEBUG`, it scrolls to the bottom (`debugBottomAnchorID`, tagged via `.id()` on the last section, "👻 Phantom Accounts") after a 0.3s delay to let the List finish laying out its rows first. Lands directly on Phantom Accounts on every Settings visit in dev builds — used constantly while bulk-creating test users/doodles for Daily Doodle testing. Release builds are unaffected: the `ScrollViewReader` wrapper itself is unconditional (harmless, no visible effect if `scrollTo` is never called), but the anchor id and the scroll-to call are both `#if DEBUG`-gated.

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
0. Today (TodayTab) — Daily Doodle challenge: today's prompt, post/replace your entry, browse yesterday's concluded contest
1. Gallery (GalleryTab) — community + private gallery
2. New (DrawScreen) — drawing canvas
3. Settings (SettingsTab)
4. Profile (ProfileTab → PublicProfileView)

**Note:** the Calendar tab is gone as of the Daily Doodle work below. `CalendarTab.swift` still exists on disk but is no longer referenced anywhere (dead code — see Outstanding Items).

### Key Files
| File | Lines | Notes |
|------|-------|-------|
| `TodayTab.swift` | ~950 | Daily Doodle: TodayTab, DailyVotingBoothView, DailyEntryTile, DailyAvatarRow, DailyEntryDetailSheet, DailyPostPickerSheet, PastWinnersView (unused, kept), PastWinnerRow, DailyContestDayView |
| `GalleryTab.swift` | ~1779 | Main gallery UI, WorldSnoodleDetailView, comment sheets |
| `SnoodleFirebase.swift` | ~1819 | All Firebase logic, WorldGalleryManager, auth, managers, `DailyManager` |
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

## `RetryAsyncImage` cold-launch stuck-loading fix (`GalleryTab.swift`)

**Bug reported:** Today tab's "already posted" card could show as if nothing had been submitted on a fresh app launch (after already having posted today), and switching to another tab and back made the real posted entry (with image) appear correctly.

**First attempt (incomplete — did not fix it):** Assumed the Firestore fetch was succeeding but the *image* load was the part getting stuck, so `RetryAsyncImage` was hardened with an `isResolved` flag + a `scheduleStuckWatchdog()` that forces a fresh attempt if `AsyncImage`'s phase never resolves to `.success`/`.failure` within 6 seconds of entering the loading state (previously only the `.failure` phase triggered a retry — a genuine bug in its own right, left in place). This didn't fix the reported symptom because it was solving the wrong layer: if `myEntryToday` is nil, the whole posted-entry branch — `RetryAsyncImage` included — never even gets instantiated in the first place.

**Actual root cause:** `TodayTab.onAppear` calls `daily.fetchMyEntryToday()`, which reads `SnoodleAuthManager.shared.userId` synchronously at that instant. Firebase Auth restores the signed-in session **asynchronously** after cold launch (via `Auth.auth().addStateDidChangeListener`, which updates `@Published var userId` some time after process start) — so on a fresh launch, `.onAppear` can fire before that listener has resolved. `fetchMyEntryToday()`'s guard then sees `userId == nil`, sets `myEntryToday = nil`, and returns — with nothing watching for `userId` to become non-nil afterward to retry. The view looked like "no submission today" until switching tabs re-fired `.onAppear` by coincidence, at which point auth had caught up and the fetch succeeded.

**Fix:** Added `.onChange(of: auth.userId) { _, newValue in if newValue != nil { daily.fetchMyEntryToday() } }` to `TodayTab`. Whenever Firebase Auth actually resolves to a signed-in uid (cold launch or otherwise), today's entry is re-fetched regardless of whether the initial `.onAppear` attempt already ran and failed. (`TodayTab.swift`)

---

## Outstanding Items

### Next Up — Today tab visual "skin"
- **Functionality is now considered done** (submit, blind reveal, forced Yes/No voting, turnout stats, Past Winners archive, per-day drill-in) — this is now the biggest remaining piece of the Daily Doodle feature. Everything under "Explicitly deferred" in the Daily Doodle section above (visual skin/flashy redesign of the whole Today tab including Past Winners and the day-detail archive, winner celebration moment, push notification when you win) was intentionally left for after functionality was solid — that point has been reached.

### To Do — iPad/iPhone device pass
- **Go screen by screen on both iPad and iPhone and special-case UI where needed.** Not a specific bug — a planned review pass. Known symptom driving this: some text renders way too small on iPad (layouts built/tuned on iPhone don't always scale up sensibly). Needs a deliberate per-screen check across the whole app (Today, Gallery, Draw, Settings, Profile, and all their sub-sheets/detail views) rather than fixing spots as they're stumbled into.

### Carry-forward bugs
- **Empty layers** — mechanism not yet confirmed. Suspected paths: eraser removing all lines from a layer (layer stays), or `onBeforeDraw` creating a layer that gets cancelled before any point lands. Needs repro to confirm.

### Deferred (deliberate — discussed, not a gap that was missed)
- **Multi-user-per-device private gallery separation.** `SnoodleEntry` has no `userId` field; `SnoodleStore` is one flat array shared by anyone using the device, signed in or not (e.g. three people signing into one shared iPad with three different Apple IDs currently all see one merged private gallery). Agreed fix, not yet built: add `userId: String?` to `SnoodleEntry` (nil-tolerant so old doodles decode fine), have `SnoodleStore.save(_:)` stamp the currently-signed-in user (or nil if signed out), and filter the actual gallery grid/search (`GalleryTab.swift`) and the Daily Doodle picker (`TodayTab.swift`'s `DailyPostPickerSheet`) to `userId == nil || userId == currentUserId` — leaving `SettingsTab.swift`'s storage/count stats and a couple of world-gallery-doodle-to-local-copy lookups (`ProfileView.swift`, `GalleryTab.swift`) reading the full unfiltered list, since those are either genuinely device-wide facts or already-scoped lookups. Deliberately additive, not a replacement: a `nil` userId doodle stays visible to everyone, so households who share one account (or never sign in — common for young kids, who often don't have their own Apple ID at all) keep exactly the pooled experience they have today; separation only starts for whoever individually signs in with their own account. No forced sign-in requirement, no migration needed. Explicitly deprioritized for now — there's a lot to finish on Daily Doodle first; revisit once that's in a good place.

### Low priority / style
- `ProfileView.swift:409-410` — `.presentationDetents` / `.presentationDragIndicator` after `.fullScreenCover` are dead code.
- `fetchPublicDoodles` does redundant client-side sort after ordered Firebase query.
- APNs watchdog timer in `snoodleApp.swift` captures `self` without `[weak self]` (benign since AppDelegate has app lifetime).
- **`CalendarTab.swift`** — orphaned. No longer referenced by `ContentView` (replaced by `TodayTab` in the tab bar). Still present on disk and still in the Xcode target. Safe to delete once we're sure nothing else needs it, but leaving in place for now per "never touch working code outside scope."
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
