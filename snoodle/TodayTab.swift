//
//  TodayTab.swift
//  snoodle
//

import SwiftUI
import FirebaseStorage

// MARK: - Today Tab

struct TodayTab: View {
    @ObservedObject private var auth = SnoodleAuthManager.shared
    @ObservedObject private var daily = DailyManager.shared
    @EnvironmentObject private var store: SnoodleStore
    @State private var showingPostPicker = false
    @State private var actionErrorMessage: String? = nil
    @State private var showActionError = false
    @State private var showVotingBooth = false
    @State private var showWithdrawConfirm = false
    @State private var showSubmitScreen = false
    @State private var authorProfileUserId: IdentifiableString? = nil
    @State private var selectedPastDate: IdentifiableString? = nil

    // MARK: - Redesign: winner-first layout
    //
    // The whole point of Daily Doodle is naming a #1 winner each day — submit
    // and vote are just the two steps that get you there, not the main event.
    // Previous layout put the submit card front and center with vote and
    // winners buried below; this flips it so the most recently decided winner
    // is the very first thing you see, with Submit/Vote as two equal CTAs
    // underneath (mirroring how Vote already opens its own full-screen booth,
    // Submit now opens its own full-screen DailySubmitScreen instead of living
    // inline). Functionality (fetches, blind-reveal rules, forced Yes/No
    // voting, turnout stats) is unchanged — this is presentation only.

    // The most recently *decided* winner is always from 2 days ago, never
    // "yesterday" — yesterday's contest is still an open vote (blind-reveal:
    // no counts/leader shown anywhere until the day itself closes), it only
    // becomes a locked-in winner once its own voting day closes.
    // daily.pastWinners is already sorted most-recent-first (see
    // fetchPastWinners), so its first element IS that most recent decided
    // winner — no separate fetch needed.
    var hasPostedToday: Bool { daily.myEntryToday != nil }
    var canVoteToday: Bool { !daily.yesterdayEntries.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                // Three visually distinct cards (hero, submit/vote, past
                // winners), each with its own contrasting tint — per
                // feedback that the screen should read as three clearly
                // separated zones at a glance, not one undifferentiated
                // scroll. Consistent 20pt gap between the three; each
                // card handles its own internal padding/background.
                VStack(spacing: 20) {
                    heroWinnerSection
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    submitVoteCard
                        .padding(.horizontal, 16)

                    pastWinnersCard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                }
            }
            // "Today" → "Daily Doodle" — matches the feature's actual name
            // used throughout (see CLAUDE.md), and frees up "Doodle of the
            // Day" so the hero card below can show the actual subject
            // instead of restating that same generic phrase.
            .navigationTitle("Daily Doodle")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                daily.fetchTodaySubject()
                daily.fetchYesterdaySubject()
                daily.fetchMyEntryToday()
                daily.fetchYesterday()
                daily.fetchPastWinners()
                daily.fetchTodaySubmissionCount()
                daily.fetchTotalUserCount()
            }
            .onAppear {
                daily.fetchTodaySubject()
                daily.fetchYesterdaySubject()
                daily.fetchMyEntryToday()
                daily.fetchYesterday()
                if daily.pastWinners.isEmpty { daily.fetchPastWinners() }
                daily.fetchTodaySubmissionCount()
                daily.fetchTotalUserCount()
            }
            // Cold-launch race: Firebase Auth restores the signed-in session
            // asynchronously, so .onAppear above can fire before auth.userId is
            // populated — fetchMyEntryToday() then sees a nil uid and just sets
            // myEntryToday = nil, with nothing to retry it once auth catches up
            // a moment later. Looked like "my post disappeared" until switching
            // tabs re-fired onAppear by coincidence. Re-fetch whenever userId
            // actually resolves to a real value.
            .onChange(of: auth.userId) { _, newValue in
                if newValue != nil { daily.fetchMyEntryToday() }
            }
            .sheet(isPresented: $showingPostPicker) {
                DailyPostPickerSheet(store: store) { entry in
                    postEntry(entry)
                }
            }
            .alert("Something Went Wrong", isPresented: $showActionError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionErrorMessage ?? "Unknown error")
            }
            .fullScreenCover(isPresented: $showVotingBooth, onDismiss: {
                // Turnout stats (vote counts, unique voters) are only fetched on
                // tab appear/refresh, not live while the booth is open — refresh
                // them here so a vote cast just now shows up immediately instead
                // of only after the next pull-to-refresh.
                daily.fetchYesterday()
                daily.fetchTotalUserCount()
            }) {
                DailyVotingBoothView(entries: daily.yesterdayEntries, onAuthorTap: showAuthorProfile)
            }
            .fullScreenCover(isPresented: $showSubmitScreen) {
                DailySubmitScreen(showingPostPicker: $showingPostPicker, showWithdrawConfirm: $showWithdrawConfirm)
            }
            .confirmationDialog("Withdraw today's entry?", isPresented: $showWithdrawConfirm, titleVisibility: .visible) {
                Button("Withdraw Entry", role: .destructive) {
                    withdrawEntry()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your doodle for today's subject will be removed. You can submit again before today's contest closes.")
            }
            .sheet(item: $authorProfileUserId) { item in
                PublicProfileView(userId: item.value, isOwnProfile: false)
                    .presentationDetents([.large])
            }
            .navigationDestination(item: $selectedPastDate) { item in
                DailyContestDayView(date: item.value, onAuthorTap: showAuthorProfile)
            }
        }
    }

    /// Shared by every avatar/username tap in the Daily flows (voting booth, winner
    /// spotlight, past-winners list) — matches World Gallery's existing
    /// author-tap → PublicProfileView sheet pattern exactly.
    func showAuthorProfile(_ userId: String) {
        authorProfileUserId = IdentifiableString(userId)
    }

    // MARK: - Hero: most recently decided winner

    /// The star of the screen. `daily.pastWinners` is already sorted
    /// most-recent-first (see fetchPastWinners's doc comment), so `.first` is
    /// exactly "the most recent day whose voting has closed" — never
    /// "yesterday" (still an open vote) or "today" (still blind submission).
    @ViewBuilder
    var heroWinnerSection: some View {
        if daily.isLoadingPastWinners && daily.pastWinners.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading today's champion…")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 50)
        } else if let latest = daily.pastWinners.first {
            heroWinnerCard(latest)
        } else {
            // Feature is brand new / no day has finished voting yet — a
            // friendly placeholder, not an error state.
            VStack(spacing: 10) {
                Image(systemName: "trophy")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundColor(.secondary.opacity(0.4))
                Text("The first Doodle of the Day winner will appear here once a day's voting closes.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }

    private static let heroParseFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = DailyEntry.contestTimeZone; return f
    }()
    private static let heroDisplayFormatter: DateFormatter = {
        // Same time-zone-safety rule as PastWinnerRow/DailyContestDayView — must
        // match heroParseFormatter's zone or the date rolls onto the wrong day.
        // "Sat, Jul 3, 2026" — day of week and year added per feedback.
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d, yyyy"; f.timeZone = DailyEntry.contestTimeZone; return f
    }()
    private func heroDisplayDate(_ dateStr: String) -> String {
        guard let d = TodayTab.heroParseFormatter.date(from: dateStr) else { return dateStr }
        return TodayTab.heroDisplayFormatter.string(from: d)
    }

    /// Image + vote count are their own tap target (opens the full day detail),
    /// avatar is a separate sibling tap target (opens the artist's profile) —
    /// same non-nested-button convention used by PastWinnerRow.
    func heroWinnerCard(_ summary: DailyWinnerSummary) -> some View {
        VStack(spacing: 10) {
            // Banner-shaped label instead of plain text — part of the
            // "every label gets its own shaped chrome" pass (see
            // "Game-Chrome Components" above). Date sits underneath as its
            // own small pill rather than crammed into the same line, closer
            // to the two-tier header/date look from the reference mockups.
            BannerLabel(text: "Doodle of the Day", color: Color(red: 0.55, green: 0.20, blue: 0.65))
            // Explicit cream pill + dark ink instead of the dynamic system
            // background/.secondary — those assumed a light-ish card, but
            // this card's fill is now a fixed dark plum regardless of system
            // appearance (see background comment below), so a dynamic gray
            // pill would wash out or clash. Cream/dark-ink pairing echoes
            // SubjectPlacard's parchment tone for a consistent "frame label"
            // family across the two.
            Text(heroDisplayDate(summary.date))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(red: 0.32, green: 0.20, blue: 0.09))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(red: 0.94, green: 0.87, blue: 0.68))
                .clipShape(Capsule())

            Button {
                selectedPastDate = IdentifiableString(summary.date)
            } label: {
                ZStack(alignment: .topTrailing) {
                    // Capped at a fixed max width (not maxWidth: .infinity) —
                    // on iPad the hero card spans nearly the full screen
                    // width, so a square that stretched edge-to-edge became
                    // tall enough to need scrolling just to see the whole
                    // thing under the tab bar/header. Same fix pattern as
                    // the old prompt-card thumbnail's iPad sliver bug.
                    // contentMode: .fit (not RetryAsyncImage's own .fill
                    // default) — doodle canvases aren't guaranteed square
                    // (canvasSize varies by device's on-screen drawing area
                    // at draw time), so .fill was center-cropping the sides
                    // off every non-square doodle to force it into a 1:1 box.
                    // FIXED (round two): the earlier fix kept a forced
                    // `.aspectRatio(1, contentMode: .fit)` on the *container*,
                    // which still boxed every doodle into a square and just
                    // letterboxed uncropped pixels inside it — reported back
                    // as "the frame is wider than the canvas... a black strip
                    // on either side." Removed that forced square entirely:
                    // with only `.frame(maxWidth: 380)` constraining width,
                    // `img.resizable().aspectRatio(contentMode: .fit)` (inside
                    // RetryAsyncImage) now sizes the view to the *doodle's own
                    // real aspect ratio* within that width — so the frame
                    // built on `geo.size` below hugs the actual doodle
                    // rectangle exactly, no matte, no letterbox bars, for any
                    // doodle shape. The `.background` fill only matters now
                    // for RetryAsyncImage's brief loading/failure placeholder
                    // (which still defaults to a plain square — see its own
                    // `.aspectRatio(1, contentMode: .fit)` added alongside
                    // this fix) before the real image — and its real aspect
                    // ratio — has loaded in.
                    RetryAsyncImage(url: URL(string: summary.winner.imageURL), contentMode: .fit)
                        .background(Color(red: 0.06, green: 0.03, blue: 0.08))
                        .frame(maxWidth: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        // Thin dark-to-light bevel ring, sized to the image's
                        // actual rendered geometry via GeometryReader.
                        // Declared before RibbonBadge below so the ribbon
                        // still paints on top wherever the two overlap.
                        .overlay(
                            GeometryReader { geo in
                                // OrnateGoldFrame (not the plain GradientFrame) —
                                // per direct request to make this specific frame
                                // more elaborate. Keeps the same innerEdgeColor
                                // fix underneath (this frame sits directly
                                // against the doodle photo, a light interior, so
                                // without it the lightColor end would fade into
                                // the photo instead of reading as a bevel edge —
                                // see GradientFrame's doc comment), with a
                                // scalloped Bezier-curve gold ring layered on top
                                // as ornamental trim.
                                OrnateGoldFrame(cornerRadius: 20, innerEdgeColor: Color(red: 0.20, green: 0.12, blue: 0.05))
                                    .frame(width: geo.size.width, height: geo.size.height)
                            }
                        )
                        // Museum-placard-style subject tag straddling the
                        // bottom edge, like a nameplate on a picture frame.
                        // Reads daily.heroWinnerSubject — see the crown row's
                        // doc comment above for why this deliberately does
                        // NOT read summary.winner.caption directly.
                        .overlay(alignment: .bottom) {
                            if !daily.heroWinnerSubject.isEmpty {
                                SubjectPlacard(text: daily.heroWinnerSubject)
                                    .offset(y: -18)
                            }
                        }

                    // Moved from overlapping the top-left corner to sitting
                    // fully on the canvas at the top-right, inside the
                    // frame — offset clears the frame's own 10pt thickness
                    // plus a bit of breathing room, so the ribbon reads as
                    // resting on the artwork itself with a gap between it
                    // and the frame, not touching/overlapping the frame ring.
                    RibbonBadge()
                        .offset(x: -22, y: 22)
                }
                // Centers the whole ZStack (image + frame + ribbon) as one
                // unit within the available card width — not just the image
                // alone. That distinction matters: putting .frame(maxWidth:
                // .infinity) on the image only (inside the ZStack, as a
                // sibling to RibbonBadge) made the ZStack's own bounding box
                // expand to that full width, so .topTrailing aligned the
                // ribbon against the *expanded* box instead of the true
                // 380pt image — the ribbon ended up pinned to the edge of
                // the card, not the edge of the doodle, on anything wider
                // than exactly 380pt. Moving the infinity frame out here, to
                // wrap image+ribbon together, fixes that: the ZStack's own
                // size is now the true ~380×380 image, and this frame just
                // centers that whole correctly-proportioned unit.
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    // checkmark.seal, not a heart — matches the Voting Booth's
                    // existing vote icon. Votes and World Gallery's likes are
                    // deliberately separate systems (see CLAUDE.md); using a
                    // heart here would blur that distinction right on the
                    // screen most likely to be seen every day.
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 12))
                        Text("\(summary.winner.votes)")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .padding(10)
                }
            }
            .buttonStyle(.plain)

            // Caption/subject no longer duplicated here now that
            // SubjectPlacard shows it prominently on the frame itself —
            // this row is just the artist now.
            Button {
                showAuthorProfile(summary.winner.userId)
            } label: {
                // Explicit white text — see the card background's doc
                // comment just below. `DailyAvatarRow`'s default (non-compact)
                // text color is `.primary`, which is near-black in light mode
                // and would be unreadable on this card's now-dark fill.
                DailyAvatarRow(entry: summary.winner, textColor: .white)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            // Deliberately dark, not just "darker" — a light pastel wash (the
            // previous yellow/purple tint) sits at roughly the same
            // brightness as a typical doodle photo, so the card and the
            // framed image blended together instead of reading as separate
            // objects. A doodle's own hue varies wildly (that's the whole
            // point of the app), so hue-matching the card to "whatever's
            // popular" isn't reliable — but going genuinely dark is: nearly
            // any bright/colorful doodle will contrast against a near-black
            // card the way art contrasts against a gallery wall.
            //
            // Switched from a diagonal plum-to-near-black gradient to a
            // plain vertical black-to-gray one, per direct request — "black
            // to a gray at bottom, as if light is being shined on the pic."
            // A neutral top-to-bottom gradient reads more like directional
            // stage lighting than the plum diagonal did, and there's no
            // longer a hue to worry about clashing with any doodle's own
            // colors. Bumped from an initial `white: 0.22` bottom stop
            // (reported as not visibly reading as a gradient at all — likely
            // too close to black, especially once the framed doodle fills
            // most of the card's height and leaves little bare background
            // exposed to show it) up to `white: 0.4`, a clearly lighter gray
            // that should be unambiguous evidence of the gradient even
            // against a mostly-covered card.
            // Switched from black/gray to a dark-to-medium blue pair, per
            // direct request, paired with `submitVoteCard` below using the
            // SAME two colors but reversed top/bottom — the idea being a
            // single light source that reads as brightest right at the
            // seam between the two cards (this card's bottom, the next
            // card's top) and fades to dark at both outer edges, like it's
            // "overflowing" from card #1 down into card #2.
            LinearGradient(colors: [Color(red: 0.03, green: 0.07, blue: 0.18), Color(red: 0.15, green: 0.35, blue: 0.62)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        // Real carved-bezel border instead of a flat stroke — reuses
        // GradientFrame's concentric-ring technique (already proven correct
        // around corners, unlike a plain RadialGradient) with a gold/bronze
        // pair matching this card's own warm identity color.
        .overlay(
            GeometryReader { geo in
                GradientFrame(
                    cornerRadius: 24,
                    thickness: 5,
                    darkColor: Color(red: 0.55, green: 0.40, blue: 0.06),
                    lightColor: Color(red: 1.0, green: 0.87, blue: 0.55)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        )
    }

    // MARK: - Subject strip

    /// Just context now, not the star — the subject used to headline a 36pt
    /// card at the very top; now it's a slim strip between the winner hero and
    /// the Submit/Vote CTAs, big enough to read at a glance while scrolling by.
    var subjectStrip: some View {
        VStack(spacing: 4) {
            Text("TODAY'S SUBJECT")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.65))
                .tracking(1.5)
            Text(daily.todaySubject)
                .font(.system(size: 24, weight: .black))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Countdown

    /// The submission window (today) and the voting window (yesterday) are
    /// two 24h windows permanently offset by exactly one day (see
    /// "Submission / voting window model" above) — which means they always
    /// close at the *exact same instant*, every day, by construction. Rather
    /// than show that identical number twice (once next to SUBMIT!, once
    /// next to VOTE!, which would just look like a duplicate-data bug), this
    /// shows it once, as a single shared clock governing both actions —
    /// no need to spell out which calendar date it's "for" on either side.
    /// `TimelineView` (not a manual Timer + @State) drives the per-second
    /// tick, which is the idiomatic SwiftUI way to get a live-updating clock.
    var countdownStrip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 4) {
                Text("TIME REMAINING")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.65))
                    .tracking(1.5)
                Text(countdownText(secondsUntilContestBoundary(from: context.date)))
                    // Monospaced digits so the ticking seconds don't jitter
                    // the layout width every time a digit changes.
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
    }

    /// Seconds remaining until the next contest-day boundary (midnight in
    /// `DailyEntry.contestTimeZone`) — the same instant `fetchYesterday()`'s
    /// window ages out and `fetchTodaySubject()`'s "today" rolls over.
    private func secondsUntilContestBoundary(from now: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = DailyEntry.contestTimeZone
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        return max(0, Int(startOfTomorrow.timeIntervalSince(now)))
    }

    private func countdownText(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // MARK: - Submit / Vote CTAs

    var submitSubtitle: String {
        if !auth.isSignedIn { return "Sign in to join" }
        if hasPostedToday { return "Tap to replace or withdraw" }
        if daily.todaySubmissionCount > 0 {
            return "\(daily.todaySubmissionCount) submitted so far"
        }
        return "Be the first today!"
    }

    var voteSubtitle: String {
        if daily.isLoadingYesterday { return "Loading…" }
        if daily.yesterdayEntries.isEmpty { return "No doodles yesterday" }
        // "Yes votes," not just "votes" — per direct feedback ("this yes no
        // thing is confusing"). Every vote counted here is a Yes tap (a "No"
        // tap writes nothing to Firestore, see DailyVotingBoothView's forced
        // Yes/No redesign elsewhere in this file), so labeling the raw count
        // plain "votes" invited the reader to assume it also included No's.
        return "\(daily.yesterdayEntries.count) \(daily.yesterdayEntries.count == 1 ? "entry" : "entries") · \(daily.yesterdayTotalVotes) yes vote\(daily.yesterdayTotalVotes == 1 ? "" : "s")"
    }

    var ctaSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Colors swapped per direct request — SUBMIT is now always
                // purple (previously flipped to green once posted; the
                // "SUBMITTED ✓" title + checkmark-seal icon already convey
                // the state change on their own), VOTE is now green.
                ctaButton(
                    title: hasPostedToday ? "SUBMITTED ✓" : "SUBMIT!",
                    subtitle: submitSubtitle,
                    color: Color.purple,
                    systemImage: hasPostedToday ? "checkmark.seal.fill" : "pencil.tip"
                ) {
                    showSubmitScreen = true
                }

                ctaButton(
                    title: "VOTE!",
                    subtitle: voteSubtitle,
                    color: canVoteToday ? Color.green : Color.gray.opacity(0.5),
                    systemImage: "hand.thumbsup.fill"
                ) {
                    showVotingBooth = true
                }
                .disabled(!canVoteToday)
            }

            // A raw count is safe to show during active voting — see
            // toggleVote/blind-reveal comments elsewhere in this file — a
            // combined number can't leak who's leading, unlike a per-entry
            // tally. Deliberately NOT "X of Y users voted (Z%)" anymore —
            // that framing implied a real turnout/participation rate, but a
            // "No" tap writes nothing to Firestore (see DailyVotingBoothView's
            // forced Yes/No redesign — "No" is explicitly equivalent to not
            // voting at all), so there's no tracked "didn't vote" population
            // to divide against. Just state the plain fact: how many votes
            // have been cast so far, no denominator, no percent, no implied
            // comparison to a "no" that isn't actually being counted.
            if !daily.yesterdayEntries.isEmpty {
                let voteCount = daily.yesterdayUniqueVoterCount
                Text("\(voteCount) vote\(voteCount == 1 ? "" : "s") \(voteCount == 1 ? "is" : "are") in")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.6))
            }
        }
    }

    /// "Chunky game button" treatment — a top-lit linear gradient (light face
    /// fading to the base color, same lit-from-above logic as the medal discs
    /// and the hero bezel, just linear instead of radial/concentric) plus a
    /// bright top highlight line and a darker bottom-edge shadow, so the
    /// button reads as a raised chip rather than a flat color swatch.
    @ViewBuilder
    func ctaButton(title: String, subtitle: String, color: Color, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                Text(title)
                    .font(.system(size: 17, weight: .heavy))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .opacity(0.85)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                LinearGradient(colors: [color.shaded(0.35), color, color.shaded(-0.25)],
                               startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                // Bright bevel highlight along the top edge only — a thin
                // rounded-rect stroke would ring the whole button evenly,
                // which reads as an outline, not a raised edge catching light.
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 2
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(color.shaded(-0.45), lineWidth: 1.5)
            )
            .shadow(color: color.shaded(-0.5).opacity(0.6), radius: 5, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submit/Vote Card

    /// "Gem panel" treatment — a deep indigo/violet gradient fill (a jewel
    /// tone, not a flat tint) plus a real gold bezel (reusing `GradientFrame`,
    /// same as the hero card's frame) instead of a flat stroke, and a
    /// BannerLabel header instead of plain section text — the same three
    /// game-chrome moves applied to the hero card, carried over here so the
    /// three Today-tab cards read as one consistent visual language rather
    /// than each having its own one-off treatment. `subjectStrip`,
    /// `countdownStrip`, and `ctaSection` had their internal text colors
    /// switched from `.secondary`/`.primary` to explicit white/opacity
    /// values as part of this change, since those dynamic colors don't have
    /// enough contrast against a dark jewel-tone background — safe since
    /// none of the three are reused anywhere outside this card.
    var submitVoteCard: some View {
        VStack(spacing: 0) {
            BannerLabel(text: "Today's Challenge", color: Color(red: 0.20, green: 0.45, blue: 0.55))
                .padding(.bottom, 14)
            subjectStrip
            countdownStrip
                .padding(.top, 10)
            ctaSection
                .padding(.top, 14)
        }
        .padding(16)
        // Switched from purple/violet to the SAME dark/medium blue pair as
        // the hero card above, but reversed (medium at top, darkest at
        // bottom) and using the same vertical `.top`→`.bottom` direction
        // (was a diagonal) so the two cards' gradients actually line up at
        // the seam between them — the hero card fades TO medium blue at
        // its bottom edge, this card starts FROM that same medium blue at
        // its top edge and fades further down to the darkest blue, like
        // one light source brightest at the seam, dimming outward in both
        // directions.
        .background(
            LinearGradient(colors: [Color(red: 0.15, green: 0.35, blue: 0.62), Color(red: 0.03, green: 0.07, blue: 0.18)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            GeometryReader { geo in
                GradientFrame(
                    cornerRadius: 24,
                    thickness: 5,
                    darkColor: Color(red: 0.45, green: 0.32, blue: 0.05),
                    lightColor: Color(red: 1.0, green: 0.87, blue: 0.55)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        )
    }

    // MARK: - Past Winners (inline — everything Daily Doodle lives on this one
    // scrolling screen; PastWinnersView still exists as a standalone view but is
    // no longer linked to from here, kept only in case it's useful again later)

    // The hero above already shows daily.pastWinners.first (the most recent
    // decided winner) front and center — this list is for browsing further
    // back, so it starts at the second entry to avoid showing that same day
    // twice on the same screen.
    var remainingPastWinners: [DailyWinnerSummary] {
        Array(daily.pastWinners.dropFirst())
    }

    var pastWinnersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Green banner, matching the reference mockups' habit of giving
            // every section its own shaped-chrome label instead of plain
            // tracked caps sitting on the tint. Frame centered since this
            // card reads top-down like a scroll/ledger, not left-anchored.
            BannerLabel(text: "Past Winners", color: Color(red: 0.15, green: 0.42, blue: 0.20))
                .frame(maxWidth: .infinity, alignment: .center)

            if daily.isLoadingPastWinners && daily.pastWinners.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else if remainingPastWinners.isEmpty {
                // Explicit brown tone rather than `.secondary` — `.secondary`
                // is a dynamic light/dark-mode color, but this card's
                // parchment background is a fixed light tint regardless of
                // system appearance (same reasoning as the hero/submit
                // cards), so a dynamic gray would lose contrast in dark mode.
                VStack(spacing: 10) {
                    Image(systemName: "trophy")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundColor(Color(red: 0.32, green: 0.20, blue: 0.09).opacity(0.35))
                    Text("No more past winners yet.")
                        .font(.system(size: 14))
                        .foregroundColor(Color(red: 0.32, green: 0.20, blue: 0.09).opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                VStack(spacing: 0) {
                    // Rank starts at 2 — the hero card above is always the
                    // actual #1 (most recent decided winner), so the very
                    // first row in this list is already the runner-up day.
                    ForEach(Array(remainingPastWinners.enumerated()), id: \.element.id) { index, summary in
                        PastWinnerRow(summary: summary, rank: index + 2, onAuthorTap: showAuthorProfile) {
                            selectedPastDate = IdentifiableString(summary.date)
                        }
                        if summary.id != remainingPastWinners.last?.id {
                            Divider().padding(.leading, 84)
                        }
                    }
                }
            }
        }
    }

    /// "Parchment archive" treatment — a warm tan/parchment gradient fill
    /// (reads as an old ledger/scroll, fitting for a historical record) plus
    /// a brown wood-tone `GradientFrame` bezel, replacing the flat amber
    /// tint + stroke. Same game-chrome moves as the other two cards: a real
    /// bezel instead of a flat stroke, a BannerLabel instead of plain
    /// tracked-caps text (see `pastWinnersSection`). `pastWinnersSection`
    /// itself is otherwise unchanged, just composed with this background.
    var pastWinnersCard: some View {
        pastWinnersSection
            .padding(16)
            .background(
                LinearGradient(colors: [Color(red: 0.93, green: 0.85, blue: 0.68), Color(red: 0.85, green: 0.74, blue: 0.53)],
                               startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                GeometryReader { geo in
                    GradientFrame(
                        cornerRadius: 24,
                        thickness: 5,
                        darkColor: Color(red: 0.32, green: 0.20, blue: 0.09),
                        lightColor: Color(red: 0.72, green: 0.55, blue: 0.32)
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            )
    }

    // MARK: - Post Action

    func postEntry(_ entry: SnoodleEntry) {
        let data = entry.imageData
        // Compress to JPEG for upload
        guard let img = UIImage(data: data),
              let jpeg = img.jpegData(compressionQuality: 0.85) else { return }
        // Always the day's theme, never the private gallery entry's own AI-generated
        // caption — Daily Doodle entries should be labeled by what they're answering
        // ("Ferris Wheel"), not by whatever Vision/Gemini captioned the source doodle.
        daily.post(imageData: jpeg, caption: daily.todaySubject) { error in
            if let error {
                actionErrorMessage = error.localizedDescription
                showActionError = true
            }
        }
    }

    // MARK: - Withdraw Action

    func withdrawEntry() {
        daily.withdrawToday { error in
            if let error {
                actionErrorMessage = error.localizedDescription
                showActionError = true
            }
        }
    }
}

// MARK: - Winner Ribbon Badge

/// Blue prize ribbon overlaid on the hero winner's corner — a pleated
/// rosette (two-tone petal ring + darker medallion) with notched fabric
/// tails, built entirely from SwiftUI shapes (no image asset, crisp at any
/// size). Chosen after comparing three treatments in a mockup: a plain
/// circle-and-rectangle badge read as a lollipop rather than a ribbon once
/// actually rendered, and a flat single-tone version felt too quiet; this
/// pleated two-tone version was the one that actually looked like a ribbon.
/// Label reads "BEST" rather than "1st" — there's no 2nd or 3rd place in this
/// design, just one decided winner per day.
struct RibbonBadge: View {
    var label: String = "BEST"

    // Same 10-point ring math used in the design mockup (radius 15, petal
    // radius 9) — hardcoded rather than computed with sin/cos at render time
    // since the ring never changes shape.
    private static let petalOffsets: [(CGFloat, CGFloat)] = [
        (0, -15), (8.8, -12.1), (14.3, -4.6), (14.3, 4.6), (8.8, 12.1),
        (0, 15), (-8.8, 12.1), (-14.3, 4.6), (-14.3, -4.6), (-8.8, -12.1)
    ]
    private let petalLight = Color(red: 0.30, green: 0.53, blue: 1.0)
    private let petalDark = Color(red: 0.14, green: 0.37, blue: 0.88)
    private let medallion = Color(red: 0.07, green: 0.23, blue: 0.60)

    var body: some View {
        // Single ZStack, not a VStack — painting order in a ZStack is simply
        // source order (earlier = further back), so the tails are declared
        // FIRST here to render behind the medallion. The previous VStack put
        // the tails after the rosette, and since the tails' offset pulled
        // them up into overlap with it, they painted on top of the "BEST"
        // circle instead of appearing to emerge from behind it.
        //
        // alignment: .top on the OUTER ZStack matters here — a default
        // (.center) ZStack centers each child as a whole *before* any
        // .offset is applied, so the tail group's own vertical midpoint (not
        // its top/attachment point) was landing at the rosette's center,
        // and the .offset budget was mostly spent just clearing the tail
        // group's own half-height rather than actually pushing it past the
        // rosette — that's why only a sliver was peeking out. Top-aligning
        // both children to a shared y=0 reference line makes the offset
        // values below behave exactly as they read.
        ZStack(alignment: .top) {
            // Both tails share one attachment point at the top and fan out
            // from there — top-aligned so their top-centers coincide, each
            // rotated with anchor: .top (pivoting around that shared point)
            // so they splay outward from one spot rather than angling in
            // from the sides.
            ZStack(alignment: .top) {
                RibbonTail()
                    .fill(petalDark)
                    .frame(width: 26, height: 64)
                    .rotationEffect(.degrees(-16), anchor: .top)
                RibbonTail()
                    .fill(petalLight)
                    .frame(width: 26, height: 68)
                    .rotationEffect(.degrees(16), anchor: .top)
            }
            .offset(y: 26)

            ZStack {
                ForEach(Array(RibbonBadge.petalOffsets.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(index.isMultiple(of: 2) ? petalLight : petalDark)
                        .frame(width: 18, height: 18)
                        .offset(x: point.0, y: point.1)
                }
                Circle()
                    .fill(medallion)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2.2))
                Text(label)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(.white)
            }
        }
        // Scaled up a bit per feedback — applied before the shadow (not
        // baked into every individual frame/offset/font number above) so
        // the shadow scales up proportionally along with the badge itself.
        .scaleEffect(1.2)
        // Deepened from the original tight (radius 2, offset 2) shadow —
        // a bigger blur radius and offset with a softer opacity reads as
        // the badge floating just above the image rather than being
        // printed flat onto it.
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 4)
        .fixedSize()
    }
}

/// Ribbon tail shape — a tapered strip with a V-notch cut into the bottom
/// edge, the detail that actually reads as "fabric ribbon" rather than
/// "rectangle."
struct RibbonTail: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.16, y: 0))
        p.addLine(to: CGPoint(x: w * 0.84, y: 0))
        p.addLine(to: CGPoint(x: w * 0.84, y: h))
        p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.78))
        p.addLine(to: CGPoint(x: w * 0.16, y: h))
        p.closeSubpath()
        return p
    }
}

// MARK: - Subject Placard (nameplate on the hero winner frame)

/// A small museum-nameplate-style tag showing the day's subject, straddling
/// the bottom edge of the hero winner's frame — like the little brass plaque
/// on a picture frame that names the piece. Cream/ivory fill with a bold
/// black border and serif type reads as "plaque," not "app label," which is
/// the point.
struct SubjectPlacard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .heavy, design: .serif))
            .foregroundColor(.black)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color(red: 0.96, green: 0.94, blue: 0.86))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                // Thinned slightly per direct request ("a wee bit thinner").
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.black, lineWidth: 1.75)
            )
            .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
            .fixedSize()
    }
}

// MARK: - Gradient Frame (thin dark-to-light border around the hero winner image)

/// Replaces an earlier woven-braid frame attempt — that read as taking over
/// the doodle itself ("if they want a border like that they'd draw it in the
/// doodle"). This is deliberately much quieter: a thin ring around the image
/// that shades from dark at the outer edge to light at the inner edge (right
/// where it meets the photo), like a beveled metal/gold picture-frame edge —
/// no woven pattern, nothing that competes with the artist's own linework.
///
/// **First version used a single `RadialGradient` centered on the square and
/// got the "outside" and "inside" wrong everywhere except the exact midpoint
/// of each flat edge.** A `RadialGradient` shades by straight-line distance
/// from one center point — on a rounded *rectangle* (not a circle), that
/// distance only equals "how far into the ring" at the four points directly
/// above/below/left/right of center. Anywhere else along an edge, straight-
/// line distance from center is *larger* than the ring's true local depth
/// (Pythagoras — moving along the edge adds a sideways component the radial
/// math has no way to discount), so the gradient's inner/outer stops crept
/// past their intended radii well before reaching the corners. The visible
/// result was a band partway down each side where the ring had already
/// (incorrectly) blended partway from dark toward light — reading as the
/// brown drifting toward yellow — while the corners themselves, being
/// farthest from center of all, clamped to flat dark with no gradient at all.
///
/// **Fix: concentric offset rings, not a radial field.** `body` layers
/// several thin `RoundedRectangle` strokes, each padded inward a bit more
/// than the last with its corner radius shrunk to match (a true parallel
/// offset of the original rounded rect, the same shape a picture-frame
/// bevel or a pen's `.padding` naturally produces) and colored by
/// interpolating darkColor → lightColor across the steps. Because each ring
/// is a genuine inward offset of the *actual* shape — corners included —
/// "how far into the frame" is correct at every point on the perimeter, not
/// just the four edge midpoints.
struct GradientFrame: View {
    var cornerRadius: CGFloat = 20
    var thickness: CGFloat = 10
    var darkColor: Color = Color(red: 0.42, green: 0.27, blue: 0.15)   // dark bronze/brown, outer edge
    var lightColor: Color = Color(red: 0.94, green: 0.83, blue: 0.53)  // light gold, inner edge (against photo)

    /// Optional thin dark stroke drawn exactly at the frame's innermost
    /// edge, where it meets whatever sits inside it. Why this is needed at
    /// all: the bevel reads correctly on its own when the interior is dark
    /// (a card's gem-panel fill, say) because `lightColor` — pale gold —
    /// already contrasts sharply against that dark interior, so the ring's
    /// own inner edge *is* a visible value break. But against a light
    /// interior (a photo, a parchment card), `lightColor` is close in value
    /// to the interior itself, so the ring just fades out instead of
    /// stopping — no seam, no "frame," just a soft gradient trailing off.
    /// Setting `innerEdgeColor` manufactures that missing value-break
    /// artificially: a solid line right where the ring's light end would
    /// otherwise blend away. `nil` (default) leaves every existing call
    /// site's look untouched.
    var innerEdgeColor: Color? = nil
    var innerEdgeWidth: CGFloat = 1.5

    // Enough concentric steps that the color change reads as a smooth
    // gradient rather than visible banding, without the cost of a
    // per-pixel Canvas render for something this small on screen.
    private let steps = 16

    var body: some View {
        ZStack {
            ForEach(0..<steps, id: \.self) { i in
                let t = CGFloat(i) / CGFloat(steps - 1)     // 0 = outer (dark), 1 = inner (light)
                let inset = t * thickness
                // Slight overlap between adjacent rings (rather than exact
                // edge-to-edge tiling) so there's no hairline gap from
                // sub-pixel rounding between one ring and the next.
                let ringWidth = thickness / CGFloat(steps) + 1
                RoundedRectangle(cornerRadius: max(0, cornerRadius - inset))
                    .strokeBorder(lerp(darkColor, lightColor, t), lineWidth: ringWidth)
                    .padding(inset)
            }
            if let innerEdgeColor {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - thickness))
                    .stroke(innerEdgeColor, lineWidth: innerEdgeWidth)
                    .padding(thickness)
            }
        }
        .allowsHitTesting(false)
    }

    /// Plain linear RGBA interpolation — `Color` itself doesn't expose its
    /// components, so this bridges through `UIColor` to read them out.
    private func lerp(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(red: Double(ar + (br - ar) * t),
                     green: Double(ag + (bg - ag) * t),
                     blue: Double(ab + (bb - ab) * t),
                     opacity: Double(aa + (ba - aa) * t))
    }
}

// MARK: - Ornate Scalloped Frame (elaborated version, hero image only)

/// A fancier alternative to the plain `GradientFrame` bevel, requested
/// specifically for card #1's canvas frame (the border around the doodle
/// photo itself, not any card-level bezel) — "could we do some kind of
/// bezier curve with the gold gradient." `GradientFrame`'s concentric rings
/// are flat-sided by construction (straight rounded-rect offsets); this
/// instead traces a ring that ripples in and out around the same rounded
/// rect perimeter, the peaks/troughs joined by real cubic Bezier curves —
/// reads like a fluted or twisted-rope gold molding instead of a plain band.
/// Layered on top of a normal `GradientFrame` (kept underneath, still with
/// `innerEdgeColor`) rather than replacing it, so the geometrically-correct
/// bevel shading is preserved and the scallop reads as ornamental trim on
/// top of it, not instead of it.
struct OrnateGoldFrame: View {
    var cornerRadius: CGFloat = 20
    var thickness: CGFloat = 10
    var darkColor: Color = Color(red: 0.42, green: 0.27, blue: 0.15)
    var lightColor: Color = Color(red: 1.0, green: 0.90, blue: 0.55)
    var innerEdgeColor: Color? = nil

    /// **Shimmer animation removed entirely, per direct request** ("lets
    /// kill this animation... somebody's trying to tell me something").
    /// After many rounds — AngularGradient dot, LinearGradient-point
    /// rotation, `.rotationEffect`+`.mask`, `.offset`-swept rectangle,
    /// `.trim()`-based single glint, then two counter-traveling glints with
    /// progressively narrowed color ranges — none of them landed. The frame
    /// is back to a plain static scalloped gold ribbon, no `TimelineView`,
    /// no animation dependency at all. The animation idea moved to a new
    /// "light fireworks" effect behind the hero photo instead — see
    /// `FireworksBackground`, used in `heroWinnerCard`'s background.
    private var ribbonShape: ScallopRingShape {
        ScallopRingShape(cornerRadius: cornerRadius, thickness: thickness * 0.85,
                         amplitude: thickness * 0.22, wavelength: 15)
    }

    private var ribbonStrokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: thickness * 0.6, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack {
            GradientFrame(cornerRadius: cornerRadius, thickness: thickness,
                          darkColor: darkColor, lightColor: lightColor,
                          innerEdgeColor: innerEdgeColor)

            // Static gold ribbon.
            // BUG FIXED (earlier round): this used to be `.fill(...)` on
            // `ScallopRingShape` directly, which paints the entire area
            // enclosed by the ring's path — since the shape is a single
            // closed wavy contour (not an outer+inner annulus with a
            // hole cut out), that painted almost the *entire* photo area
            // solid, hiding the doodle underneath ("nailed the gold
            // zigzag edge... where's the doodle?"). `.stroke(...)` paints
            // only a fixed-width ribbon following the path instead.
            ribbonShape
                .stroke(
                    LinearGradient(colors: [lightColor, darkColor, lightColor, darkColor, lightColor],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: ribbonStrokeStyle
                )
                .overlay(
                    // Thin dark seam down the center of the gold ribbon
                    // — reads like the twist-line of a rope rather than
                    // an outline, since it follows the same centerline
                    // path.
                    ribbonShape
                        .stroke(darkColor.shaded(-0.35), style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round))
                )
                .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// A closed ring shape that rides the same rounded-rect perimeter
/// `GradientFrame` uses, but bulges in and out sinusoidally (alternating
/// peak/trough anchor points every half-`wavelength`) with the anchors
/// joined by cubic Bezier curves rather than straight lines — a rope-twist/
/// fluted molding profile instead of a flat band. Built from first
/// principles (arc length + outward normal at each point on a rounded rect,
/// walked segment by segment: top edge, corner arc, right edge, corner arc,
/// ...) since SwiftUI has no built-in "wavy rounded rect" primitive.
struct ScallopRingShape: Shape {
    var cornerRadius: CGFloat
    var thickness: CGFloat
    var amplitude: CGFloat
    var wavelength: CGFloat

    /// Point and outward-unit-normal at arc length `s` around the rounded
    /// rect centered in `rect`, with corner radius `r`. Walks the 8-segment
    /// loop clockwise starting at the top-left corner's end (top edge start):
    /// top edge → top-right corner → right edge → bottom-right corner →
    /// bottom edge → bottom-left corner → left edge → top-left corner.
    private func pointAndNormal(_ s: CGFloat, rect: CGRect, r: CGFloat,
                                 topLen: CGFloat, sideLen: CGFloat, cornerLen: CGFloat,
                                 perimeter: CGFloat) -> (CGPoint, CGPoint) {
        var t = s.truncatingRemainder(dividingBy: perimeter)
        if t < 0 { t += perimeter }

        if t <= topLen {
            return (CGPoint(x: rect.minX + r + t, y: rect.minY), CGPoint(x: 0, y: -1))
        }
        t -= topLen
        if t <= cornerLen {
            let theta = -CGFloat.pi / 2 + (t / cornerLen) * (CGFloat.pi / 2)
            let c = CGPoint(x: rect.maxX - r, y: rect.minY + r)
            return (CGPoint(x: c.x + r * cos(theta), y: c.y + r * sin(theta)), CGPoint(x: cos(theta), y: sin(theta)))
        }
        t -= cornerLen
        if t <= sideLen {
            return (CGPoint(x: rect.maxX, y: rect.minY + r + t), CGPoint(x: 1, y: 0))
        }
        t -= sideLen
        if t <= cornerLen {
            let theta = (t / cornerLen) * (CGFloat.pi / 2)
            let c = CGPoint(x: rect.maxX - r, y: rect.maxY - r)
            return (CGPoint(x: c.x + r * cos(theta), y: c.y + r * sin(theta)), CGPoint(x: cos(theta), y: sin(theta)))
        }
        t -= cornerLen
        if t <= topLen {
            return (CGPoint(x: rect.maxX - r - t, y: rect.maxY), CGPoint(x: 0, y: 1))
        }
        t -= topLen
        if t <= cornerLen {
            let theta = CGFloat.pi / 2 + (t / cornerLen) * (CGFloat.pi / 2)
            let c = CGPoint(x: rect.minX + r, y: rect.maxY - r)
            return (CGPoint(x: c.x + r * cos(theta), y: c.y + r * sin(theta)), CGPoint(x: cos(theta), y: sin(theta)))
        }
        t -= cornerLen
        if t <= sideLen {
            return (CGPoint(x: rect.minX, y: rect.maxY - r - t), CGPoint(x: -1, y: 0))
        }
        t -= sideLen
        let theta = CGFloat.pi + (t / max(cornerLen, 0.0001)) * (CGFloat.pi / 2)
        let c = CGPoint(x: rect.minX + r, y: rect.minY + r)
        return (CGPoint(x: c.x + r * cos(theta), y: c.y + r * sin(theta)), CGPoint(x: cos(theta), y: sin(theta)))
    }

    func path(in rect: CGRect) -> Path {
        // Ride the centerline of the given thickness band so the ripple has
        // room to bulge both outward and inward without poking past either
        // edge of the frame it's decorating.
        let insetRect = rect.insetBy(dx: thickness / 2, dy: thickness / 2)
        let r = max(1, cornerRadius - thickness / 2)
        let topLen = max(0, insetRect.width - 2 * r)
        let sideLen = max(0, insetRect.height - 2 * r)
        let cornerLen = (CGFloat.pi / 2) * r
        let perimeter = 2 * topLen + 2 * sideLen + 4 * cornerLen
        guard perimeter > 0 else { return Path() }

        let halfWave = max(4, wavelength / 2)
        let count = max(12, Int((perimeter / halfWave).rounded()))

        var anchors: [(point: CGPoint, tangent: CGPoint)] = []
        anchors.reserveCapacity(count)
        for i in 0..<count {
            let s = perimeter * CGFloat(i) / CGFloat(count)
            let (p, n) = pointAndNormal(s, rect: insetRect, r: r, topLen: topLen, sideLen: sideLen,
                                         cornerLen: cornerLen, perimeter: perimeter)
            let sign: CGFloat = (i % 2 == 0) ? 1 : -1
            let offsetPoint = CGPoint(x: p.x + n.x * amplitude * sign, y: p.y + n.y * amplitude * sign)
            // Tangent = normal rotated 90° CCW — matches this loop's clockwise
            // travel direction at every segment (verified against each
            // straight edge's known direction of travel).
            let tangent = CGPoint(x: -n.y, y: n.x)
            anchors.append((offsetPoint, tangent))
        }

        var path = Path()
        guard let first = anchors.first else { return path }
        path.move(to: first.point)
        let segLen = perimeter / CGFloat(count)
        let controlDist = segLen * 0.55
        for i in 0..<count {
            let a = anchors[i]
            let b = anchors[(i + 1) % count]
            let c1 = CGPoint(x: a.point.x + a.tangent.x * controlDist, y: a.point.y + a.tangent.y * controlDist)
            let c2 = CGPoint(x: b.point.x - b.tangent.x * controlDist, y: b.point.y - b.tangent.y * controlDist)
            path.addCurve(to: b.point, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Game-Chrome Components (Today tab visual pass)

/// Reference mockups (AI-generated concept art, not something this
/// environment can produce) showed a much more game-like "carved wood and
/// gold" skin — banner-shaped labels, beveled stone/gold panels, medal
/// icons for rank — instead of flat tinted rounded rects. The actual
/// painted textures (wood grain, stone, parchment, the illustrated
/// background) aren't reproducible as SwiftUI shapes/gradients, but the
/// *structural* ideas are: every text label gets its own shaped chrome
/// instead of sitting on a plain tint, panels get a genuine beveled border
/// (reusing `GradientFrame`'s concentric-ring technique, not a flat
/// stroke), and rank gets a medal icon instead of a plain number/trophy.
/// These three components carry that across the three Today-tab cards.

/// A ribbon-banner/pennant shape — a rectangle with a small triangular
/// notch cut into each end, like a hanging nameplate. Used for section
/// header labels so they read as a distinct object, not text-on-a-tint.
struct BannerShape: Shape {
    var notchDepth: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w - notchDepth, y: h / 2))
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: notchDepth, y: h / 2))
        p.closeSubpath()
        return p
    }
}

struct BannerLabel: View {
    let text: String
    var color: Color
    var textColor: Color = .white
    var fontSize: CGFloat = 13

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .heavy))
            .foregroundColor(textColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(
                BannerShape()
                    .fill(color)
                    .overlay(BannerShape().stroke(Color.black.opacity(0.15), lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
    }
}

/// Small numbered medal for Past Winners rank — a gold/silver/bronze
/// gradient disc with a short ribbon tail beneath (reusing the existing
/// `RibbonTail` shape), replacing the plain trophy-badge-on-thumbnail-corner
/// that was here before. Only ranks 2+ ever reach this — the actual #1
/// winner is already spotlighted separately in the hero card above.
struct RankMedal: View {
    let rank: Int

    private var discColors: (light: Color, dark: Color) {
        switch rank {
        case 2: return (Color(red: 0.90, green: 0.90, blue: 0.94), Color(red: 0.58, green: 0.58, blue: 0.64)) // silver
        case 3: return (Color(red: 0.88, green: 0.62, blue: 0.42), Color(red: 0.55, green: 0.35, blue: 0.18)) // bronze
        default: return (Color(red: 1.0, green: 0.87, blue: 0.45), Color(red: 0.75, green: 0.55, blue: 0.06)) // gold (rank 4+ reuses gold rather than inventing a 4th tier)
        }
    }
    private var tailColor: Color {
        switch rank {
        case 2: return Color.blue
        case 3: return Color.red
        default: return Color.purple
        }
    }

    var body: some View {
        VStack(spacing: -3) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(colors: [discColors.light, discColors.dark],
                                       center: .topLeading, startRadius: 1, endRadius: 22)
                    )
                Circle()
                    .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                Text("\(rank)")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.white)
            }
            .frame(width: 22, height: 22)

            RibbonTail()
                .fill(tailColor)
                .frame(width: 9, height: 9)
        }
        .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
    }
}

extension Color {
    /// Brightness-adjusts a color by blending it toward white (positive
    /// `amount`) or black (negative), bridging through `UIColor` the same
    /// way `GradientFrame.lerp` does — `Color` doesn't expose its own RGBA
    /// components directly. Used to turn a single flat identity color (the
    /// CTA buttons' `color` param) into a lit-from-above bevel gradient
    /// without having to hand-pick a second literal color at every call site.
    func shaded(_ amount: CGFloat) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let mix: (CGFloat) -> CGFloat = { channel in
            if amount >= 0 {
                return channel + (1 - channel) * amount
            } else {
                return channel * (1 + amount)
            }
        }
        return Color(red: Double(mix(r)), green: Double(mix(g)), blue: Double(mix(b)), opacity: Double(a))
    }
}

// MARK: - Voting Booth (blind-reveal voting, one doodle at a time)

/// Full-screen, swipeable one-at-a-time viewer for yesterday's entries — the
/// entire "help decide, without knowing the outcome yet" experience lives here.
/// No vote counts, no leader, anywhere in this view — entries arrive already in
/// timestamp order from DailyManager.fetchYesterday(), which is deliberate (see
/// that function's doc comment). Reads the live entry from daily.yesterdayEntries
/// on every page so a vote you cast is reflected immediately without dismissing.
struct DailyVotingBoothView: View {
    let entries: [DailyEntry]
    var onAuthorTap: (String) -> Void
    @ObservedObject private var daily = DailyManager.shared
    @ObservedObject private var auth = SnoodleAuthManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0

    private func liveEntry(_ entry: DailyEntry) -> DailyEntry {
        daily.yesterdayEntries.first { $0.id == entry.id } ?? entry
    }

    // Valid range is 0...entries.count — the extra index past the last real
    // doodle is the completion page, not another entry.
    private func goTo(_ index: Int) {
        guard index >= 0 && index <= entries.count else { return }
        currentIndex = index
    }

    /// Yes/No are absolute, not a toggle — tapping Yes always ensures a vote
    /// exists, No always ensures it doesn't. Auto-advance means you won't
    /// naturally re-tap the same page to "undo" the way the old single vote
    /// button worked, so a plain toggle would risk flipping the wrong way if
    /// you swiped back to a page and tapped the same answer again.
    private func setVote(_ entry: DailyEntry, voted: Bool) {
        if entry.isVotedByMe != voted {
            daily.toggleVote(entry)
        }
    }

    private func advanceAfterVote() {
        goTo(currentIndex + 1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(UIColor.systemBackground).ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    boothPage(for: liveEntry(entry))
                        .tag(index)
                }
                completionPage
                    .tag(entries.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 8) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    Spacer()

                    if !entries.isEmpty && currentIndex < entries.count {
                        Text("\(currentIndex + 1) of \(entries.count)")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                }

                if currentIndex < entries.count && !daily.yesterdaySubject.isEmpty {
                    Text(daily.yesterdaySubject.uppercased())
                        .font(.system(size: 13, weight: .bold))
                        .tracking(1)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func navArrow(systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
    }

    // Fixed-rect doodle box, cover-cropped — same concept as the private/public
    // gallery detail screens (SnoodleDetailView/WorldSnoodleDetailView), per
    // direct feedback: "i dont want any vertical scrolling on the voting
    // screens... there is a fixed rect that every doodle must fit into. if the
    // natural aspect ratio doesnt match, the cover-type-styling is used."
    // First pass used a literal fixed height (300pt) — safe on the smallest
    // iPhone, but on an iPad (much taller usable screen) it left a big dead
    // gap above and below, since the box didn't know to grow with the
    // available room ("a very wide narrow strip and not filling the entire
    // area with the style thats like the cover css"). Fixed: `.frame(maxHeight:
    // .infinity)` instead of a literal number — this is what makes it behave
    // like CSS `object-fit: cover` on a `height: 100%` container rather than a
    // fixed-pixel box. The image still can't grow past whatever's left after
    // the avatar/question/buttons block claims its own (fixed) height, since
    // the whole page is itself bounded by the fullscreen ZStack behind it —
    // it just now fills *all* of that remaining room instead of a hardcoded
    // guess, so it scales correctly on any device.
    @ViewBuilder
    private func boothPage(for entry: DailyEntry) -> some View {
        VStack(spacing: 14) {
            // GeometryReader is the actual fix here — `.frame(maxWidth:
            // .infinity, maxHeight: .infinity)` alone does NOT give this box a
            // size independent of its own content: with no GeometryReader
            // breaking the link, SwiftUI still lets RetryAsyncImage's aspect-
            // ratio-driven ideal size bubble up through the frame modifier
            // into this VStack's layout pass, so a tall/portrait doodle
            // inflates the whole page's required height and pushes the
            // avatar/question/vote-buttons block off the bottom of the
            // screen — exactly the reported bug ("doodle areas are diff
            // sizes... pushes buttons under the bottom of the screen").
            // GeometryReader has no ideal size that depends on its child, so
            // it reads as "just take whatever room is left" the same way a
            // Spacer does — the VStack now sizes the fixed elements below
            // first and this box gets the true remainder, guaranteed, no
            // matter how tall the source image is.
            GeometryReader { geo in
                ZStack {
                    RetryAsyncImage(url: URL(string: entry.imageURL), contentMode: .fill)
                        .frame(width: max(0, geo.size.width - 48), height: max(0, geo.size.height - 24))
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal, 24)
                        .padding(.top, 24)

                    // Prev/Next overlaid directly on the image itself — anywhere
                    // else on screen risked landing in an unrelated spot (avatar,
                    // vote button) depending on device height, easy to miss or feel
                    // out of place. Here they always flank the thing being browsed.
                    // Next is never disabled — there's always somewhere to go,
                    // either another doodle or the completion page.
                    HStack {
                        navArrow(systemName: "chevron.left", disabled: currentIndex == 0) {
                            goTo(currentIndex - 1)
                        }
                        Spacer()
                        navArrow(systemName: "chevron.right", disabled: false) {
                            goTo(currentIndex + 1)
                        }
                    }
                    .padding(.horizontal, 36)
                }
            }

            Button {
                onAuthorTap(entry.userId)
            } label: {
                DailyAvatarRow(entry: entry)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // Question + buttons grouped tightly together (own spacing, not the
            // outer VStack's) so adding the question line doesn't push the
            // buttons low enough to clip against the home indicator — only the
            // Spacer above absorbs slack, this block's own height is fixed.
            VStack(spacing: 10) {
                if !daily.yesterdaySubject.isEmpty {
                    Text("Is this \u{201c}\(daily.yesterdaySubject)\u{201d} doodle the doodle of the day?")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .fixedSize(horizontal: false, vertical: true)
                }

                voteButtons(for: entry)
            }
            .padding(.bottom, 40)
        }
    }

    /// Forced binary choice instead of a single opt-in vote button — whichever
    /// you tap, it auto-advances (see advanceAfterVote()). A "No" is never
    /// written anywhere; it's exactly equivalent to not voting at all, so
    /// there's no new data concept here, just a UI that asks for an answer on
    /// every doodle instead of only the ones you'd have bothered to tap
    /// "Vote" on. Whichever side matches the entry's current vote state reads
    /// as selected/filled — so swiping back to a doodle you already answered
    /// shows your answer rather than looking blank/undecided.
    @ViewBuilder
    private func voteButtons(for entry: DailyEntry) -> some View {
        let isMe = auth.userId == entry.userId
        HStack(spacing: 14) {
            // Selection indicator redesigned per direct feedback — opacity
            // dimming for the non-chosen answer ("both No and Yes look
            // disabled in their dimmed state") read as a disabled control,
            // not as "this is simply not your current pick." Both buttons
            // now stay at full, undimmed color always; a checkmark next to
            // the label is the ONLY thing that changes to show which side
            // you're currently on — unambiguous, and neither button ever
            // looks broken/inactive.
            Button {
                setVote(entry, voted: false)
                advanceAfterVote()
            } label: {
                HStack(spacing: 6) {
                    if !entry.isVotedByMe {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .bold))
                    }
                    Text("No")
                        .font(.system(size: 19, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color(red: 0.90, green: 0.35, blue: 0.35))
                .clipShape(Capsule())
            }

            Button {
                setVote(entry, voted: true)
                advanceAfterVote()
            } label: {
                HStack(spacing: 6) {
                    if entry.isVotedByMe {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .bold))
                    }
                    Text("Yes")
                        .font(.system(size: 19, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                // Same `Color.green` as the main Today tab's VOTE! button —
                // always full strength now, never dimmed (see selection
                // indicator note above).
                .background(Color.green)
                .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 40)
        .disabled(isMe || !auth.isSignedIn)
        .opacity((isMe || !auth.isSignedIn) ? 0.4 : 1)
    }

    /// Reached by auto-advance after answering the last doodle, or by
    /// swiping/tapping Next manually — a deliberate stop, not a dead end, so
    /// it explains what just happened and how to fix a mis-tap before you
    /// leave, instead of just dumping you back on the Today tab.
    private var completionPage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("You're All Caught Up!")
                .font(.system(size: 26, weight: .heavy))

            // Bumped from 15pt — "we have lots of room" on this page, per
            // direct feedback.
            Text("You've gone through every doodle from yesterday's contest.")
                .font(.system(size: 19, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Text("HOW THIS WORKS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(1.5)
                // Replaced per direct feedback ("replace the text... with
                // something much more clear") — the previous paragraph
                // ("Every doodle is submitted blind during its own day...")
                // packed the whole submit/reveal/vote/results-hidden
                // mechanic into one dense sentence. Broken into 3 short,
                // plain-language beats instead, one per step of the cycle.
                Text("Doodles stay hidden while people are still submitting them. The next day, they show up here for everyone to vote on. Once voting closes, the winner is revealed on the Today tab.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 4)

            Text("Swipe back anytime to change an answer.")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.purple)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 64)
        }
    }
}

// MARK: - Submit Screen

/// Full-screen destination for the "SUBMIT!" CTA — everything that used to
/// live inline in the old top-of-tab subject card (subject display, today's
/// submission count, Open Canvas / Post if you haven't entered yet, Replace /
/// Withdraw if you have) now lives here instead, mirroring how Vote already
/// opens its own full-screen DailyVotingBoothView. showingPostPicker and
/// showWithdrawConfirm stay owned by TodayTab (passed down as bindings) since
/// their sheet/dialog are declared on TodayTab's own NavigationStack — this
/// screen just flips those flags, same as the old inline card did.
struct DailySubmitScreen: View {
    @Binding var showingPostPicker: Bool
    @Binding var showWithdrawConfirm: Bool
    @ObservedObject private var daily = DailyManager.shared
    @ObservedObject private var auth = SnoodleAuthManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text("TODAY'S SUBJECT")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .tracking(1.5)

                        Text(daily.todaySubject)
                            .font(.system(size: 36, weight: .black))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)

                        // Just a count — doesn't reveal who's posted or what they
                        // drew, so it's safe during the still-blind submission window.
                        if daily.todaySubmissionCount > 0 {
                            Text("\(daily.todaySubmissionCount) doodle\(daily.todaySubmissionCount == 1 ? "" : "s") submitted so far today")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }

                    if auth.isSignedIn {
                        if let mine = daily.myEntryToday {
                            // Already posted today
                            VStack(spacing: 12) {
                                ZStack(alignment: .topTrailing) {
                                    // Was a fixed 220×220 square using
                                    // RetryAsyncImage's default `.fill`
                                    // contentMode — cropped every non-square
                                    // doodle AND left most of the screen's
                                    // height as bare white space on both
                                    // iPad (~60%) and iPhone (~50%), since
                                    // this screen has nothing else on it.
                                    // Fixed the same way as the hero card's
                                    // own crop/space fix: `contentMode: .fit`
                                    // (full doodle, no cropping) inside only
                                    // a `.frame(maxWidth:)` cap — no fixed
                                    // height — so the real aspect ratio sets
                                    // the height and the preview actually
                                    // uses the room available on this screen.
                                    RetryAsyncImage(url: URL(string: mine.imageURL), contentMode: .fit)
                                        .frame(maxWidth: 500)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))

                                    Text("✓ Posted")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.green.opacity(0.85))
                                        .clipShape(Capsule())
                                        .padding(10)
                                }

                                HStack(spacing: 20) {
                                    Button {
                                        showingPostPicker = true
                                    } label: {
                                        Label("Replace My Entry", systemImage: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.purple)
                                    }

                                    Button(role: .destructive) {
                                        showWithdrawConfirm = true
                                    } label: {
                                        Label("Withdraw", systemImage: "trash")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.red)
                                    }
                                }
                                .disabled(daily.isPosting || daily.isWithdrawing)

                                if daily.isWithdrawing {
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                        } else {
                            // Not posted yet
                            VStack(spacing: 10) {
                                HStack(spacing: 12) {
                                    Button {
                                        // Dismiss this full-screen cover before switching
                                        // to the New tab — otherwise the New tab's own
                                        // full-screen DrawScreen cover would be presented
                                        // on top of this one instead of replacing it.
                                        // Same 0.35s sheet-transition delay pattern used
                                        // elsewhere in the app (see CLAUDE.md).
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                            NotificationCenter.default.post(name: .todaySwitchToNew, object: nil)
                                        }
                                    } label: {
                                        Label("Open Canvas", systemImage: "pencil.tip")
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 14)
                                            .background(Color.purple)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                    }

                                    Button {
                                        showingPostPicker = true
                                    } label: {
                                        Label("Post", systemImage: "arrow.up.circle")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.purple)
                                            .padding(.vertical, 14)
                                            .padding(.horizontal, 16)
                                            .background(Color.purple.opacity(0.1))
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                }

                                Text("Draw something, save it, then tap Post to enter today's challenge.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    } else {
                        Text("Sign in to join today's challenge")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Submit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Daily Entry Tile

struct DailyEntryTile: View {
    let entry: DailyEntry
    var onAuthorTap: ((String) -> Void)? = nil
    @ObservedObject private var daily = DailyManager.shared
    @ObservedObject private var auth = SnoodleAuthManager.shared
    @State private var showDetail = false

    var isMe: Bool { auth.userId == entry.userId }

    var body: some View {
        // Image and avatar/username are separate, sibling tap targets (not
        // nested buttons) so tapping the name opens the artist's profile while
        // tapping anywhere else on the tile opens the doodle detail — mirrors
        // WorldSnoodleTile's onAuthorTap/onImageTap split in GalleryTab.swift.
        ZStack(alignment: .bottomLeading) {
            Button { showDetail = true } label: {
                ZStack(alignment: .bottomLeading) {
                    RetryAsyncImage(url: URL(string: entry.imageURL))
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()

                    // Bottom gradient
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .center, endPoint: .bottom)
                        .frame(height: 40)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .buttonStyle(.plain)

            Button {
                onAuthorTap?(entry.userId)
            } label: {
                DailyAvatarRow(entry: entry, compact: true)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
            .buttonStyle(.plain)
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .sheet(isPresented: $showDetail) {
            DailyEntryDetailSheet(entry: entry, onAuthorTap: onAuthorTap)
        }
    }
}

// MARK: - Avatar Row

struct DailyAvatarRow: View {
    let entry: DailyEntry
    var compact: Bool = false
    // Lets a call site pin an explicit text color regardless of `compact`'s
    // size/color coupling (compact controls both avatar/font size AND
    // defaults the text to white) — added for the hero card, which needs
    // full (non-compact) size but white text now that its background is a
    // fixed dark fill. `nil` (default) preserves every existing call site's
    // look exactly as before.
    var textColor: Color? = nil

    var avatarSize: CGFloat { compact ? 20 : 28 }
    var fontSize: CGFloat { compact ? 11 : 14 }

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            Group {
                if entry.avatar == "photo", let urlStr = entry.photoURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Circle().fill(Color.purple.opacity(0.2))
                        }
                    }
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                } else {
                    Text(entry.avatar)
                        .font(.system(size: avatarSize * 0.7))
                        .frame(width: avatarSize, height: avatarSize)
                }
            }

            Text(entry.username)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(textColor ?? (compact ? .white : .primary))
                .lineLimit(1)
        }
    }
}

// MARK: - Detail Sheet

struct DailyEntryDetailSheet: View {
    let entry: DailyEntry
    var onAuthorTap: ((String) -> Void)? = nil
    @ObservedObject private var daily = DailyManager.shared
    @ObservedObject private var auth = SnoodleAuthManager.shared
    @Environment(\.dismiss) private var dismiss

    // Only "yesterday" lives in daily.yesterdayEntries and updates in place after
    // a vote. Older archive days are effectively frozen displays anyway — voting
    // on them is already blocked by toggleVote's window guard (see canVote below)
    // — so falling back to the static `entry` for anything else is fine.
    var currentEntry: DailyEntry {
        daily.yesterdayEntries.first { $0.id == entry.id } ?? entry
    }

    // Voting is only ever allowed on the current votable day ("yesterday").
    // Entries from the Past Winners archive land here too (same sheet, reused),
    // so this keeps the vote button from doing anything on an entry that's
    // already outside its window — matches DailyManager.toggleVote's own guard.
    var canVote: Bool {
        auth.isSignedIn && auth.userId != currentEntry.userId && currentEntry.date == daily.currentVotableDate
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Handle
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)

                // Image
                RetryAsyncImage(url: URL(string: currentEntry.imageURL))
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: UIDevice.current.userInterfaceIdiom == .pad ? 420 : 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)

                // Artist
                Button {
                    onAuthorTap?(currentEntry.userId)
                } label: {
                    DailyAvatarRow(entry: currentEntry)
                }
                .buttonStyle(.plain)

                // Caption
                if !currentEntry.caption.isEmpty {
                    Text(currentEntry.caption)
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Vote button
                if canVote {
                    Button {
                        daily.toggleVote(currentEntry)
                    } label: {
                        HStack(spacing: 8) {
                            // checkmark.seal, not a heart — matches the Voting
                            // Booth's icon and keeps votes visually distinct
                            // from World Gallery's heart-based likes.
                            Image(systemName: currentEntry.isVotedByMe ? "checkmark.seal.fill" : "checkmark.seal")
                                .foregroundColor(currentEntry.isVotedByMe ? .green : .primary)
                            Text(currentEntry.isVotedByMe ? "Voted" : "Vote")
                                .fontWeight(.semibold)
                            Text("· \(currentEntry.votes)")
                                .foregroundColor(.secondary)
                        }
                        .font(.system(size: 17))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                            Text("\(currentEntry.votes) votes").foregroundColor(.secondary)
                        }
                        .font(.system(size: 17))

                        if auth.isSignedIn && auth.userId != currentEntry.userId {
                            Text("Voting has closed for this day")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer(minLength: 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - Post Picker Sheet

struct DailyPostPickerSheet: View {
    let store: SnoodleStore
    let onPost: (SnoodleEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var daily = DailyManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("No doodles in your gallery yet.\nDraw something first!")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let columns = [GridItem(.flexible(), spacing: 2),
                                   GridItem(.flexible(), spacing: 2),
                                   GridItem(.flexible(), spacing: 2)]
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(store.entries) { entry in
                                Button {
                                    onPost(entry)
                                    dismiss()
                                } label: {
                                    if let img = UIImage(data: entry.imageData) {
                                        Image(uiImage: img)
                                            .resizable()
                                            .aspectRatio(1, contentMode: .fill)
                                            .clipped()
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(0.2))
                                            .aspectRatio(1, contentMode: .fill)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("Pick a Doodle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Past Winners Archive

struct PastWinnersView: View {
    var onAuthorTap: (String) -> Void
    @ObservedObject private var daily = DailyManager.shared
    @State private var selectedDate: IdentifiableString? = nil

    var body: some View {
        Group {
            if daily.isLoadingPastWinners && daily.pastWinners.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if daily.pastWinners.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "trophy")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No past winners yet.")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(daily.pastWinners) { summary in
                            PastWinnerRow(summary: summary, onAuthorTap: onAuthorTap) {
                                selectedDate = IdentifiableString(summary.date)
                            }
                            Divider().padding(.leading, 84)
                        }
                    }
                }
            }
        }
        .navigationTitle("Past Winners")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if daily.pastWinners.isEmpty { daily.fetchPastWinners() }
        }
        .refreshable {
            daily.fetchPastWinners()
        }
        .navigationDestination(item: $selectedDate) { item in
            DailyContestDayView(date: item.value, onAuthorTap: onAuthorTap)
        }
    }
}

struct PastWinnerRow: View {
    let summary: DailyWinnerSummary
    // Defaults to 2 (not 1 — the hero card above is always the real #1) so
    // the old, no-longer-linked-to `PastWinnersView` standalone screen
    // (which calls this without a rank, showing every day including what
    // would elsewhere be "the" winner) still compiles unchanged, per this
    // codebase's convention of leaving orphaned call sites alone rather
    // than threading a rank through code paths nothing routes to anymore.
    var rank: Int = 2
    var onAuthorTap: (String) -> Void
    var onRowTap: () -> Void

    private var displayDate: String {
        guard let d = PastWinnerRow.parseFormatter.date(from: summary.date) else { return summary.date }
        return PastWinnerRow.displayFormatter.string(from: d)
    }
    private static let parseFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = DailyEntry.contestTimeZone; return f
    }()
    private static let displayFormatter: DateFormatter = {
        // Must match parseFormatter's time zone — the "date" string is a contest-day
        // identifier in DailyEntry.contestTimeZone, not whatever zone the device
        // happens to be in. A mismatch here rolls the date onto the wrong calendar
        // day when displayed (this was a real bug — see CLAUDE.md).
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; f.timeZone = DailyEntry.contestTimeZone; return f
    }()

    // Four independent, non-overlapping tap targets side by side (thumbnail,
    // date, avatar, votes) rather than one row wrapped in a single button —
    // keeps the avatar's tap-to-profile fully separate from tap-to-open-day
    // without needing any nested-button or hit-testing workarounds.
    // Fixed brown tone (matches pastWinnersSection's empty-state fix) rather
    // than `.secondary` — this row now always sits on the parchment card's
    // fixed light background regardless of system light/dark mode, so a
    // dynamic gray would lose contrast in dark mode.
    private static let inkColor = Color(red: 0.32, green: 0.20, blue: 0.09)

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onRowTap) {
                RetryAsyncImage(url: URL(string: summary.winner.imageURL))
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        // RankMedal replaces the old plain trophy-badge
                        // corner icon — see "Game-Chrome Components" above.
                        RankMedal(rank: rank)
                            .scaleEffect(0.7)
                            .offset(x: -8, y: -8)
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Button(action: onRowTap) {
                    Text(displayDate)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(PastWinnerRow.inkColor.opacity(0.75))
                }
                .buttonStyle(.plain)

                Button {
                    onAuthorTap(summary.winner.userId)
                } label: {
                    DailyAvatarRow(entry: summary.winner)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button(action: onRowTap) {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                        Text("\(summary.winner.votes)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(PastWinnerRow.inkColor)
                    }
                    Text("\(summary.entryCount) entr\(summary.entryCount == 1 ? "y" : "ies")")
                        .font(.system(size: 11))
                        .foregroundColor(PastWinnerRow.inkColor.opacity(0.75))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Contest Day Detail (Past Winners drill-in)

/// Full swipeable browse of one specific already-concluded (fully revealed)
/// day, most-voted first — reached by tapping either the hero winner image
/// or a Past Winners row (both just set TodayTab's `selectedPastDate`, which
/// drives this same `.navigationDestination`, so both land here).
///
/// Replaces an earlier winner-spotlight-card + grid layout — that screen is
/// gone per direct feedback ("we don't want that... it should let the user
/// swipe thru the list of submissions in yes vote order"). This now mirrors
/// `DailyVotingBoothView`'s one-doodle-at-a-time swiping, just read-only (no
/// vote buttons — archive days are already closed, `toggleVote` would no-op
/// on them anyway) and with the real vote count shown per page, since these
/// days are fully revealed/finalized (unlike the live "yesterday" flow,
/// which hides counts until its own reveal).
///
/// `DailyEntryTile` and `DailyEntryDetailSheet` (the old grid-cell/sheet
/// pair this replaced) are left in the file unused rather than deleted —
/// same precedent as `PastWinnersView`/`CalendarTab.swift` elsewhere in this
/// codebase.
struct DailyContestDayView: View {
    let date: String
    var onAuthorTap: (String) -> Void

    @State private var entries: [DailyEntry] = []
    @State private var isLoading = true
    @State private var currentIndex: Int = 0

    private var displayDate: String {
        guard let d = DailyContestDayView.parseFormatter.date(from: date) else { return date }
        return DailyContestDayView.displayFormatter.string(from: d)
    }
    private static let parseFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = DailyEntry.contestTimeZone; return f
    }()
    private static let displayFormatter: DateFormatter = {
        // Must match parseFormatter's time zone — see PastWinnerRow's identical fix.
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"; f.timeZone = DailyEntry.contestTimeZone; return f
    }()

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "pencil.and.scribble")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No doodles were submitted this day.")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // entries already arrive sorted votes-descending, timestamp-
                // ascending (see DailyManager.fetchEntries's doc comment) —
                // index 0 is always the winner, no separate sort needed here.
                ZStack(alignment: .top) {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            dayPage(for: entry, rank: index)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    Text("\(currentIndex + 1) of \(entries.count)")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.top, 8)
                }
            }
        }
        .navigationTitle(displayDate)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            DailyManager.shared.fetchEntries(for: date) { fetched in
                entries = fetched
                isLoading = false
            }
        }
    }

    // Fixed-rect doodle box, cover-cropped — same concept as the private/public
    // gallery detail screens and the Voting Booth's boothPage(for:), per direct
    // feedback: no vertical scrolling on any of these doodle-browsing screens,
    // just a fixed image rect that crops (rather than scrolls or letterboxes)
    // whatever doesn't match its aspect ratio. Superseded the earlier
    // ScrollView-per-page fix. Caption capped to 2 lines for the same reason —
    // without a ScrollView, an unbounded caption could still push the vote
    // count off-screen the same way the image used to.
    //
    // Uses `.frame(maxHeight: .infinity)` rather than a literal pixel height —
    // same fix as boothPage(for:) — so the box fills whatever room is actually
    // available instead of a fixed guess that leaves dead space on a taller
    // screen (iPad) or risks clipping on a shorter one.
    @ViewBuilder
    private func dayPage(for entry: DailyEntry, rank: Int) -> some View {
        VStack(spacing: 14) {
            // Same GeometryReader fix as DailyVotingBoothView.boothPage(for:)
            // — `.frame(maxWidth: .infinity, maxHeight: .infinity)` alone
            // doesn't give this box a size independent of the image's own
            // aspect ratio; without GeometryReader, a tall doodle's ideal
            // size bubbles up into the VStack layout and can push the
            // caption/vote-count row off screen the same way it did in the
            // Voting Booth. GeometryReader reads as "take whatever's left"
            // (no ideal size tied to its child), so the fixed elements below
            // get sized first and this box gets the guaranteed remainder.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    RetryAsyncImage(url: URL(string: entry.imageURL), contentMode: .fill)
                        .frame(width: max(0, geo.size.width - 48), height: max(0, geo.size.height - 24))
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .padding(.horizontal, 24)
                        .padding(.top, 24)

                    // Only the top-voted entry (rank 0, since entries already
                    // arrive votes-descending) gets the trophy badge — same
                    // marker PastWinnerRow's own thumbnail uses.
                    if rank == 0 {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.yellow)
                            .clipShape(Circle())
                            .padding(.leading, 34)
                            .padding(.top, 10)
                    }

                    // Prev/Next overlaid directly on the image — same
                    // reasoning as DailyVotingBoothView: always flank the
                    // thing being browsed, regardless of device height.
                    // Unlike the Voting Booth (which always has a completion
                    // page to advance to), this is a finite, already-revealed
                    // list, so Next is disabled on the last entry rather than
                    // always enabled.
                    HStack {
                        navArrow(systemName: "chevron.left", disabled: currentIndex == 0) {
                            currentIndex = max(0, currentIndex - 1)
                        }
                        Spacer()
                        navArrow(systemName: "chevron.right", disabled: currentIndex == entries.count - 1) {
                            currentIndex = min(entries.count - 1, currentIndex + 1)
                        }
                    }
                    .padding(.horizontal, 36)
                }
            }

            Button {
                onAuthorTap(entry.userId)
            } label: {
                DailyAvatarRow(entry: entry)
            }
            .buttonStyle(.plain)

            if !entry.caption.isEmpty {
                Text(entry.caption)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .lineLimit(2)
            }

            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 15))
                Text("\(entry.votes) vote\(entry.votes == 1 ? "" : "s")")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 24)
        }
    }

    @ViewBuilder
    private func navArrow(systemName: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let todaySwitchToNew = Notification.Name("todaySwitchToNew")
}
