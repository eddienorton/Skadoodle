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
                VStack(spacing: 0) {
                    heroWinnerSection
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    subjectStrip
                        .padding(.top, 24)

                    ctaSection
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                    pastWinnersSection
                        .padding(.top, 28)
                        .padding(.bottom, 32)
                }
            }
            .navigationTitle("Today")
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
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.timeZone = DailyEntry.contestTimeZone; return f
    }()
    private func heroDisplayDate(_ dateStr: String) -> String {
        guard let d = TodayTab.heroParseFormatter.date(from: dateStr) else { return dateStr }
        return TodayTab.heroDisplayFormatter.string(from: d)
    }

    /// Image + vote count are their own tap target (opens the full day detail),
    /// avatar is a separate sibling tap target (opens the artist's profile) —
    /// same non-nested-button convention used by PastWinnerRow.
    func heroWinnerCard(_ summary: DailyWinnerSummary) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill").foregroundColor(.yellow)
                Text("DOODLE OF THE DAY")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.5)
                Text("· \(heroDisplayDate(summary.date))")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.secondary)

            Button {
                selectedPastDate = IdentifiableString(summary.date)
            } label: {
                ZStack(alignment: .topLeading) {
                    // Capped at a fixed max width (not maxWidth: .infinity) and
                    // centered — on iPad the hero card spans nearly the full
                    // screen width, so a square that stretched edge-to-edge
                    // became tall enough to need scrolling just to see the
                    // whole thing under the tab bar/header. Same fix pattern
                    // as the old prompt-card thumbnail's iPad sliver bug.
                    RetryAsyncImage(url: URL(string: summary.winner.imageURL))
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 380)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 20))

                    // Overlaps the corner rather than framing the whole image —
                    // keeps the doodle itself perfectly flat/undistorted (an
                    // artist's linework shouldn't get tilted or bordered away),
                    // while still making it unmistakable at a glance that this
                    // is the winner. Chosen over a plain colored border after
                    // reviewing mockups together.
                    // Pulled in from the raw corner (not -14,-14) — the card
                    // only has 16pt of padding before its own rounded-rect
                    // clip, and the badge is wide enough that a bigger
                    // negative offset pushed part of it past that edge and
                    // got clipped off.
                    RibbonBadge()
                        .offset(x: -2, y: -6)
                }
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

            HStack {
                Button {
                    showAuthorProfile(summary.winner.userId)
                } label: {
                    DailyAvatarRow(entry: summary.winner)
                }
                .buttonStyle(.plain)

                Spacer()

                if !summary.winner.caption.isEmpty {
                    Text(summary.winner.caption)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color.yellow.opacity(0.15), Color.purple.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    // MARK: - Subject strip

    /// Just context now, not the star — the subject used to headline a 36pt
    /// card at the very top; now it's a slim strip between the winner hero and
    /// the Submit/Vote CTAs, big enough to read at a glance while scrolling by.
    var subjectStrip: some View {
        VStack(spacing: 4) {
            Text("TODAY'S SUBJECT")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(1.5)
            Text(daily.todaySubject)
                .font(.system(size: 24, weight: .black))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
        }
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
        return "\(daily.yesterdayEntries.count) \(daily.yesterdayEntries.count == 1 ? "entry" : "entries") · \(daily.yesterdayTotalVotes) vote\(daily.yesterdayTotalVotes == 1 ? "" : "s")"
    }

    var ctaSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ctaButton(
                    title: hasPostedToday ? "SUBMITTED ✓" : "SUBMIT!",
                    subtitle: submitSubtitle,
                    color: hasPostedToday ? Color.green : Color.purple,
                    systemImage: hasPostedToday ? "checkmark.seal.fill" : "pencil.tip"
                ) {
                    showSubmitScreen = true
                }

                ctaButton(
                    title: "VOTE!",
                    subtitle: voteSubtitle,
                    color: canVoteToday ? Color.purple : Color.gray.opacity(0.5),
                    systemImage: "hand.thumbsup.fill"
                ) {
                    showVotingBooth = true
                }
                .disabled(!canVoteToday)
            }

            // Turnout stats are safe to show during active voting — see
            // toggleVote/blind-reveal comments elsewhere in this file — a
            // combined number can't leak who's leading, unlike a per-entry tally.
            if !daily.yesterdayEntries.isEmpty && daily.totalUserCount > 0 {
                Text("\(daily.yesterdayUniqueVoterCount) of \(daily.totalUserCount) users voted (\(daily.yesterdayVoterTurnoutPercent)%)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    func ctaButton(title: String, subtitle: String, color: Color, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
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
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 6) {
                Image(systemName: "trophy.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 11))
                Text("PAST WINNERS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(1.5)
            }
            .padding(.horizontal, 16)

            if daily.isLoadingPastWinners && daily.pastWinners.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            } else if remainingPastWinners.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "trophy")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No more past winners yet.")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(remainingPastWinners) { summary in
                        PastWinnerRow(summary: summary, onAuthorTap: showAuthorProfile) {
                            selectedPastDate = IdentifiableString(summary.date)
                        }
                        .padding(.horizontal, 16)
                        if summary.id != remainingPastWinners.last?.id {
                            Divider().padding(.leading, 84)
                        }
                    }
                }
            }
        }
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
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 2)
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

    @ViewBuilder
    private func boothPage(for entry: DailyEntry) -> some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 64)

            ZStack {
                RetryAsyncImage(url: URL(string: entry.imageURL))
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

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
            Button {
                setVote(entry, voted: false)
                advanceAfterVote()
            } label: {
                Text("No")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(entry.isVotedByMe ? Color.gray.opacity(0.4) : Color.gray)
                    .clipShape(Capsule())
            }

            Button {
                setVote(entry, voted: true)
                advanceAfterVote()
            } label: {
                Text("Yes")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(entry.isVotedByMe ? Color.green : Color.purple)
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

            Text("You've gone through every doodle from yesterday's contest.")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Text("HOW THIS WORKS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(1.5)
                Text("Every doodle is submitted blind during its own day. The next day, it's revealed here for voting — and results stay hidden until that day closes too, so nothing's spoiled early. Check the Today tab tomorrow to see who won.")
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
                                    RetryAsyncImage(url: URL(string: mine.imageURL))
                                        .frame(width: 220, height: 220)
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
                .foregroundColor(compact ? .white : .primary)
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
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onRowTap) {
                RetryAsyncImage(url: URL(string: summary.winner.imageURL))
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Color.yellow)
                            .clipShape(Circle())
                            .offset(x: -3, y: -3)
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Button(action: onRowTap) {
                    Text(displayDate)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
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
                    }
                    Text("\(summary.entryCount) entr\(summary.entryCount == 1 ? "y" : "ies")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Contest Day Detail (Past Winners drill-in)

/// Full view of one specific already-concluded (fully revealed) day — winner
/// spotlight + grid, sorted by votes. Unlike the live "yesterday" flow (which
/// hides counts/ranking until reveal — see DailyVotingBoothView), archive days
/// are finalized, so showing the real ranking here is correct. Reached by
/// tapping into PastWinnersView.
struct DailyContestDayView: View {
    let date: String
    var onAuthorTap: (String) -> Void

    @State private var entries: [DailyEntry] = []
    @State private var isLoading = true
    @State private var showWinnerDetail = false

    private var winner: DailyEntry? {
        guard let top = entries.first, top.votes > 0 else { return nil }
        return top
    }

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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    if let winner {
                        winnerCard(winner)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                    }

                    let gridEntries = winner != nil ? Array(entries.dropFirst()) : entries
                    if !gridEntries.isEmpty {
                        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
                        let colCount = isIPad ? 4 : 3
                        let cellSize = (UIScreen.main.bounds.width - 16 - CGFloat(colCount - 1) * 2) / CGFloat(colCount)
                        let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: 2), count: colCount)
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(gridEntries) { entry in
                                DailyEntryTile(entry: entry, onAuthorTap: onAuthorTap)
                                    .frame(width: cellSize, height: cellSize)
                                    .clipped()
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 16)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .navigationTitle(displayDate)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            DailyManager.shared.fetchEntries(for: date) { fetched in
                entries = fetched
                isLoading = false
            }
        }
        .sheet(isPresented: $showWinnerDetail) {
            if let winner {
                DailyEntryDetailSheet(entry: winner, onAuthorTap: onAuthorTap)
            }
        }
    }

    func winnerCard(_ winner: DailyEntry) -> some View {
        HStack(spacing: 14) {
            Button {
                showWinnerDetail = true
            } label: {
                ZStack(alignment: .topLeading) {
                    RetryAsyncImage(url: URL(string: winner.imageURL))
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Image(systemName: "trophy.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.yellow)
                        .clipShape(Circle())
                        .padding(6)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    onAuthorTap(winner.userId)
                } label: {
                    DailyAvatarRow(entry: winner)
                }
                .buttonStyle(.plain)

                Button {
                    showWinnerDetail = true
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !winner.caption.isEmpty {
                            Text(winner.caption)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 13))
                            Text("\(winner.votes) vote\(winner.votes == 1 ? "" : "s")")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let todaySwitchToNew = Notification.Name("todaySwitchToNew")
}
