# Skadoodle Pre-Submission Test Plan

Run through this before every archive. Target: ~20 minutes.
Mark each item ✅ pass or ❌ fail (note the issue).

---

## 1. Launch & Auth

- [ ] Cold launch — app opens to Gallery tab without crash
- [ ] Signed out: gallery shows Sign In prompt in Settings
- [ ] Sign In with Apple works end-to-end
- [ ] After sign-in, profile tab shows correct username/avatar
- [ ] Sign out → sign back in → state is clean (no stale data)

---

## 2. World Gallery — Everyone

- [ ] Gallery loads first 20 doodles
- [ ] Scroll to bottom → next page loads (pagination)
- [ ] Scroll to bottom of page 2 → page 3 loads
- [ ] Pull-to-refresh works
- [ ] Top Artists strip appears and scrolls horizontally
- [ ] Tap an artist in the strip → gallery filters to their doodles
- [ ] Clear artist filter → returns to Everyone
- [ ] Trending sort shows different order than Recent

---

## 3. World Gallery — Following

- [ ] Switch to Following tab
- [ ] If following nobody: empty state message appears (not a crash)
- [ ] If following someone: their doodles appear
- [ ] Scroll to bottom → pagination loads more
- [ ] Tap author name on a tile → profile sheet opens

---

## 4. Search

- [ ] Type a single word (e.g. "dog") → Firebase results appear (not just 20)
- [ ] Results count is stable — does not change while swiping in detail
- [ ] Type two words (e.g. "big dog") → results are filtered correctly
- [ ] Clear search → returns to previous feed mode (Everyone or Following)
- [ ] Search with no results → empty state message appears

---

## 5. Detail View (World)

- [ ] Tap a doodle → detail opens at correct index
- [ ] Swipe through all results — count stays stable (e.g. 1/8 stays 8)
- [ ] Double-tap to like works
- [ ] Like count updates
- [ ] Tap author name → profile sheet opens
- [ ] Comments sheet opens
- [ ] Add a comment → appears immediately
- [ ] Close detail → returns to gallery at correct position

---

## 6. Artist Profile

- [ ] Profile sheet shows correct avatar, username, bio
- [ ] Follow / Unfollow button works
- [ ] Follower count updates after follow/unfollow
- [ ] Tap a doodle in their grid → detail opens
- [ ] Profile links (Instagram etc.) open correctly if set

---

## 7. Drawing — Canvas

- [ ] New doodle opens blank canvas
- [ ] Each pen style draws correctly: pencil, ink, brush, marker, chalk, neon, spray, watercolor, dotted, dualTone
- [ ] Color picker works
- [ ] Stroke width slider works
- [ ] Background color/pattern changes apply
- [ ] Undo removes last stroke
- [ ] Redo restores it
- [ ] Undo/redo multiple steps works without crash

---

## 8. Drawing — Stamps

- [ ] Emoji stamp picker opens
- [ ] Tap emoji → places on canvas
- [ ] Drag stamp to new position
- [ ] Undo after drag → stamp returns to original position (not removed)
- [ ] Resize stamp with pinch
- [ ] Delete stamp works
- [ ] Photo stamp: pick from library → appears on canvas
- [ ] Text stamp: enter text → appears on canvas

---

## 9. Drawing — Save & Submit

- [ ] Tap Done → AI caption generates (not blank, not "Add a caption")
- [ ] Caption and keywords appear within a few seconds
- [ ] Edit caption field works
- [ ] Save to private gallery → appears in Gallery and Calendar
- [ ] Post to World → appears in World gallery (may need pull-to-refresh)
- [ ] Posted doodle has correct caption, keywords, author

---

## 10. Private Gallery & Calendar

- [ ] Private doodles appear in gallery grid
- [ ] Tap a doodle → detail opens, swipe works
- [ ] Calendar shows doodles on correct dates
- [ ] Tap a date with doodles → they appear
- [ ] Delete a doodle → removed from gallery and calendar

---

## 11. Settings

- [ ] Stats show correct private doodle count and size
- [ ] Download My Doodles works (check Files app)
- [ ] Notifications toggle works
- [ ] Rate / Share links open correctly
- [ ] Version number matches build

---

## 12. Edge Cases

- [ ] Airplane mode: gallery shows cached content, no crash
- [ ] Airplane mode: posting a doodle fails gracefully (error shown, not silent)
- [ ] Poor wifi: caption generation times out gracefully
- [ ] First launch with zero doodles: empty state, no crash
- [ ] Very long caption text doesn't break layout

---

## Notes

_Write any failures here with build number and steps to reproduce._
