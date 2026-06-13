//
//  GalleryTab.swift
//  snoodle
//

import SwiftUI
import AVFoundation

struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
    init(_ value: String) { self.value = value }
}
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine

/// Decodes image data on a background thread to avoid main-thread stalls
struct AsyncImageFromData: View {
    let data: Data
    @State private var image: UIImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: data) {
            let decoded = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
            await MainActor.run { image = decoded }
        }
    }
}

struct SnoodleDetailView: View {
    @EnvironmentObject var store: SnoodleStore
    @Environment(\.dismiss) var dismiss

    let entries: [SnoodleEntry]   // the navigable list (all or day subset)
    let startIndex: Int

    @State private var currentIndex: Int = 0
    @State private var dragOffset: CGFloat = 0
    @State private var showDeleteConfirm: Bool = false

    private let dateFmt: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df
    }()

    // Current entry resolved from store so deletes reflect immediately
    var currentEntries: [SnoodleEntry] {
        entries.filter { e in store.entries.contains(where: { $0.id == e.id }) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(max(0.3, 1.0 - dragOffset / 300))

            if currentEntries.isEmpty {
                Text("No more doodles")
                    .foregroundColor(.white.opacity(0.5))
                    .onAppear { dismiss() }
            } else {
                TabView(selection: $currentIndex) {
                    ForEach(currentEntries.indices, id: \.self) { i in
                        card(for: currentEntries[i]).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            // Top bar — sits above everything
            VStack(spacing: 8) {
                HStack {
                    Button(action: { dismiss() }) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.65))
                                .frame(width: 44, height: 44)
                                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.leading, 32)
                    Spacer()
                    if currentEntries.count > 1 {
                        Text("\(currentIndex + 1) / \(currentEntries.count)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(14)
                            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                            .padding(.trailing, 32)
                    }
                }
                .padding(.top, 38)
                Spacer()
            }
            .zIndex(10)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 80, coordinateSpace: .global)
                .onChanged { value in
                    let h = value.translation.height
                    let w = value.translation.width
                    if abs(h) > abs(w) * 2 {
                        dragOffset = h
                    }
                }
                .onEnded { value in
                    let h = value.translation.height
                    let w = value.translation.width
                    if abs(h) > 100 && abs(h) > abs(w) * 2 {
                        dismiss()
                    } else {
                        withAnimation(.spring()) { dragOffset = 0 }
                    }
                }
        )
        .offset(y: dragOffset)
        .animation(.interactiveSpring(), value: dragOffset)
        .onAppear {
            currentIndex = min(startIndex, max(0, currentEntries.count - 1))
        }
    }

    func card(for entry: SnoodleEntry) -> some View {
        VStack(spacing: 20) {
            Spacer()

            AsyncImageFromData(data: entry.imageData)
                .cornerRadius(16)
                .padding(.horizontal, 24)
                .shadow(color: .white.opacity(0.06), radius: 20)

            VStack(spacing: 6) {
                if !entry.caption.isEmpty {
                    Text(entry.caption)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Text(dateFmt.string(from: entry.timestamp))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()

            // Action buttons
            HStack(spacing: 36) {
                Button(action: {
                    if let card = generateSnoodleCard(for: entry) {
                        presentShareSheet(with: card)
                    }
                }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                }

                // Submit to world gallery
                SubmitButton(entry: entry)

                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.35))
                }
                .confirmationDialog("Delete this doodle?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        let wasLast = currentIndex >= currentEntries.count - 1
                        store.delete(entry)
                        if currentEntries.isEmpty { dismiss() }
                        else if wasLast { currentIndex = max(0, currentIndex - 1) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding(.bottom, 44)
        }
    }
}

// MARK: - Tile

/// A reusable async thumbnail loader used by the calendar, search, and any other
/// inline image sites that don't use SnoodleTile directly.
struct AsyncThumbnailImage: View {
    let entry: SnoodleEntry
    @State private var thumb: UIImage? = nil

    var body: some View {
        ZStack {
            Color(UIColor.systemGray5)
            if let img = thumb {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ProgressView().scaleEffect(0.6)
            }
        }
        .task(id: entry.imageFilename) {
            let loaded = await entry.loadThumbnailAsync()
            await MainActor.run { thumb = loaded }
        }
    }
}

struct SnoodleTile: View {
    let entry: SnoodleEntry
    let dateFmt: DateFormatter
    @State private var thumb: UIImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack {
                    Color(UIColor.systemGray5)
                    if let img = thumb {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.width * 4/3)
                            .clipped()
                            .overlay(alignment: .topTrailing) {
                                if entry.isSubmitted {
                                    Image(systemName: "globe")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(4)
                                        .background(Color.green.opacity(0.85))
                                        .clipShape(Circle())
                                        .padding(4)
                                }
                            }
                    } else {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.width * 4/3)
            }
            .aspectRatio(3/4, contentMode: .fit)
            .cornerRadius(8)
            Text(entry.caption.isEmpty ? "Untitled" : entry.caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(entry.caption.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(height: 30, alignment: .topLeading)
                .padding(.horizontal, 2)
            Text(dateFmt.string(from: entry.timestamp))
                .font(.system(size: 10)).foregroundColor(.secondary).padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .clipped()
        .task(id: entry.imageFilename) {
            let loaded = await entry.loadThumbnailAsync()
            await MainActor.run { thumb = loaded }
        }
    }
}

// MARK: - Gallery Tab

enum WorldFeedMode { case everyone, following }

struct GalleryTab: View {
    @EnvironmentObject var store: SnoodleStore
    @ObservedObject private var worldManager = WorldGalleryManager.shared
    @ObservedObject private var followManager = FollowManager.shared
    @State private var selectedIndex: Int? = nil
    @State private var selectedWorldIndex: Int? = nil
    @State private var detailEntries: [WorldSnoodle] = []

    struct DetailSelection: Identifiable {
        let id = UUID()
        let entries: [WorldSnoodle]
        let startIndex: Int
    }
    @State private var detailSelection: DetailSelection? = nil
    @State private var query: String = ""
    @State private var showingWorld: Bool = true
    @State private var feedMode: WorldFeedMode = .everyone
    @State private var authorProfileUserId: IdentifiableString? = nil
    @State private var privateGalleryRefreshID: Int = 0
    @State private var selectedArtistId: String? = nil

    func applyWorldQuery() {
        if let artistId = selectedArtistId {
            worldManager.setQuery(.artist(artistId))
        } else if feedMode == .following {
            let followingIds = Array(FollowManager.shared.followingIds)
            worldManager.setQuery(.following(followingIds))
        } else {
            worldManager.setQuery(.everyone)
        }
    }
    @State private var worldSearchPeople: [UserProfile] = []
    @State private var isSearchingPeople: Bool = false
    @State private var peopleSearchTask: Task<Void, Never>? = nil

    let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let dateFmt: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "MMM d"; return df
    }()

    func searchWorldPeople(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else {
            worldSearchPeople = []
            return
        }
        peopleSearchTask?.cancel()
        peopleSearchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let db = Firestore.firestore()
            let endStr = trimmed + "\u{f8ff}"
            if let snapshot = try? await db.collection("users")
                .whereField("username", isGreaterThanOrEqualTo: trimmed)
                .whereField("username", isLessThan: endStr)
                .limit(to: 5)
                .getDocuments() {
                guard !Task.isCancelled else { return }
                let mgr = await MainActor.run { UserProfileManager.shared }
                let profiles = snapshot.documents.compactMap {
                    mgr.parseProfilePublic(userId: $0.documentID, data: $0.data())
                }
                await MainActor.run { self.worldSearchPeople = profiles }
            }
        }
    }

    var filteredEntries: [SnoodleEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.entries }
        let terms = q.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return store.entries.filter { entry in
            terms.allSatisfy { term in
                entry.caption.lowercased().contains(term) ||
                entry.keywords.contains { $0.lowercased().contains(term) }
            }
        }
    }

    var displayedWorldEntries: [WorldSnoodle] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return worldManager.sortedEntries }
        return worldManager.sortedEntries.filter {
            $0.caption.lowercased().contains(q) ||
            $0.keywords.contains { $0.lowercased().contains(q) }
        }
    }

    var isWorldSearchActive: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if showingWorld {
                    let loading = worldManager.isLoading
                    let isEmpty = worldManager.entries.isEmpty
                    if loading && isEmpty {
                        VStack { Spacer(); ProgressView(); Spacer() }
                    } else if !loading && isEmpty {
                        VStack(spacing: 20) {
                            if feedMode == .following {
                                Text("🎨").font(.system(size: 80))
                                Text("No doodles yet").font(.system(size: 22, weight: .semibold))
                                Text("Follow some artists to see their work here")
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 40)
                            } else {
                                Text("🌍").font(.system(size: 80))
                                Text("Community Doodles").font(.system(size: 22, weight: .semibold))
                                Text("No submissions yet — be the first!")
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else if isWorldSearchActive && worldSearchPeople.isEmpty && displayedWorldEntries.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 44)).foregroundColor(.secondary.opacity(0.3))
                            Text("No results for \(query.trimmingCharacters(in: .whitespaces))")
                                .font(.system(size: 17, weight: .semibold))
                            Spacer()
                        }
                    } else {
                        ScrollView {
                            Color.clear.frame(height: 0)
                            // People results — shown when searching
                            if isWorldSearchActive && !worldSearchPeople.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("People")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 16)
                                        .padding(.top, 12)
                                        .padding(.bottom, 4)
                                    ForEach(worldSearchPeople, id: \.userId) { profile in
                                        FollowListRow(profile: profile)
                                            .padding(.horizontal, 12)
                                            .onTapGesture {
                                                authorProfileUserId = IdentifiableString(profile.userId)
                                            }
                                        Divider().padding(.leading, 68)
                                    }
                                }
                            }
                            // Doodles section header when searching
                            if isWorldSearchActive && !displayedWorldEntries.isEmpty {
                                Text("Doodles")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)
                            }
                            // Top Artists strip
                            if !isWorldSearchActive && feedMode == .everyone {
                                TopArtistsStripView(
                                    entries: worldManager.topArtistEntries.isEmpty ? worldManager.sortedEntries : worldManager.topArtistEntries,
                                    selectedArtistId: $selectedArtistId,
                                    onShowProfile: { userId in
                                        authorProfileUserId = IdentifiableString(userId)
                                    },
                                    onArtistSelected: { _ in
                                        applyWorldQuery()
                                    }
                                )
                                .padding(.bottom, 4)
                            }
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(Array(displayedWorldEntries.enumerated()), id: \.element.id) { i, entry in
                                    WorldSnoodleTile(initialEntry: entry, dateFmt: dateFmt, onAuthorTap: { userId in
                                        authorProfileUserId = IdentifiableString(userId)
                                    }, onImageTap: {
                                        detailSelection = DetailSelection(entries: displayedWorldEntries, startIndex: i)
                                    })
                                    .onAppear {
                                        if !isWorldSearchActive && i == displayedWorldEntries.count - 1 {
                                            worldManager.fetchNextPage()
                                        }
                                    }

                                }
                            }
                            .padding(12)
                            if worldManager.isLoading && !worldManager.entries.isEmpty {
                                ProgressView()
                                    .padding(.vertical, 16)
                            }
                        }
                        .id("\(worldManager.scrollToTopTrigger)-\(feedMode == .everyone ? 0 : 1)")

                        .refreshable {
                            await worldManager.refresh()
                        }
                    }
                } else if store.entries.isEmpty {
                    VStack(spacing: 20) {
                        Image("SnoodleIcon")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 90, height: 90)
                            .cornerRadius(20)
                            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
                        Text("Your doodles live here").font(.system(size: 22, weight: .semibold))
                        Text(UIDevice.current.userInterfaceIdiom == .pad ? "Tap New to draw your first one" : "Tap + to draw your first one")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else if !query.isEmpty && filteredEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("No doodles found")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Try different words")
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(filteredEntries.indices, id: \.self) { i in
                                    SnoodleTile(entry: filteredEntries[i], dateFmt: dateFmt)
                                        .onTapGesture { selectedIndex = i }
                                }
                            }
                            .padding(12)
                        }
                    }
                    .id(privateGalleryRefreshID)
                }
            }
            .navigationTitle(showingWorld ? "Community Doodles" : "Private Doodles")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: showingWorld ? "Search people and doodles..." : "Search your doodles...")
            .scrollDismissesKeyboard(.immediately)
            .onAppear {
                if worldManager.pendingShowWorld {
                    showingWorld = true
                    worldManager.pendingShowWorld = false
                    // Don't fetch here — the submit callback will fetch once the doc is written
                } else if worldManager.pendingShowPrivate {
                    showingWorld = false
                    worldManager.pendingShowPrivate = false
                }
            }
            // onChange catches the case where GalleryTab was already the active
            // tab (so onAppear won't re-fire) when the user posts to world gallery.
            .onChange(of: worldManager.pendingShowWorld) { _, isPending in
                if isPending {
                    showingWorld = true
                    worldManager.pendingShowWorld = false
                    // Don't fetch here — the submit callback will fetch once the doc is written
                }
            }
            .onChange(of: worldManager.scrollToTopTrigger) { _, _ in
                privateGalleryRefreshID += 1
            }
            .onChange(of: showingWorld) { _, showing in
                if !showing {
                    worldSearchPeople = []
                    peopleSearchTask?.cancel()
                }
            }
            .onChange(of: worldManager.accountSwitchTrigger) { _, _ in
                // Account switched — reset to private so public gallery remounts fresh
                showingWorld = false
                feedMode = .everyone
                selectedArtistId = nil
                worldManager.setQuery(.everyone)
            }
            .onChange(of: selectedArtistId) { _, _ in
                applyWorldQuery()
            }
            .onChange(of: query) { _, q in
                if showingWorld { searchWorldPeople(q) }
            }
            .onChange(of: showingWorld) { _, showing in
                if showing { applyWorldQuery() }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if showingWorld {
                        HStack(spacing: 8) {
                            Picker("Feed", selection: $feedMode) {
                                Text("Everyone").tag(WorldFeedMode.everyone)
                                Text("Following").tag(WorldFeedMode.following)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 170)
                            .onChange(of: feedMode) { _, mode in
                                selectedArtistId = nil
                                applyWorldQuery()
                            }
                            Picker("Sort", selection: $worldManager.sortOrder) {
                                Text("Recent").tag(WorldSortOrder.recent)
                                Text("Trending").tag(WorldSortOrder.trending)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 120)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showingWorld.toggle()
                        if showingWorld {
                            feedMode = .everyone
                            selectedArtistId = nil
                            applyWorldQuery()
                        } else {
                            worldManager.stopListening()
                        }
                    }) {
                        Image(systemName: showingWorld ? "person.crop.circle" : "globe")
                            .font(.system(size: 20))
                            .foregroundColor(showingWorld ? .purple : .primary)
                    }
                }
            }
            .fullScreenCover(item: Binding(
                get: { selectedIndex.map { IdentifiableInt(value: $0) } },
                set: { selectedIndex = $0?.value }
            )) { idx in
                SnoodleDetailView(entries: store.entries, startIndex: idx.value)
                    .environmentObject(store)
            }
            .fullScreenCover(item: $detailSelection) { selection in
                WorldSnoodleDetailView(
                    initialEntries: selection.entries,
                    startIndex: selection.startIndex,
                    onShowAuthor: { userId in
                        authorProfileUserId = IdentifiableString(userId)
                    },
                    textFilter: query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : query)
                .environmentObject(store)
            }
            .sheet(item: $authorProfileUserId) { item in
                PublicProfileView(userId: item.value, isOwnProfile: false)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

// MARK: - World Snoodle Tile

// Retries image load up to 3 times with delay — handles CDN propagation lag on fresh uploads
// MARK: - Zoomable Image View

struct ZoomableImageView: UIViewRepresentable {
    let url: URL?
    @Binding var isZoomed: Bool

    class ZoomScrollView: UIScrollView {
        weak var coordinator: Coordinator?
        override func layoutSubviews() {
            super.layoutSubviews()
            // Don't reset frame while zooming
            guard zoomScale == minimumZoomScale else { return }
            coordinator?.updateImageFrame()
        }
    }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.tag = 100
        scrollView.addSubview(imageView)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(tap)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        scrollView.coordinator = context.coordinator

        if let url = url {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, let img = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    imageView.image = img
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        context.coordinator.updateImageFrame()
                    }
                }
            }.resume()
        }

        return scrollView
    }

    func updateUIView(_ scrollView: ZoomScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var isZoomed: Binding<Bool>
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        init(isZoomed: Binding<Bool>) {
            self.isZoomed = isZoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            isZoomed.wrappedValue = scrollView.zoomScale > 1.01
            centerImageView()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            if scale <= 1.0 {
                isZoomed.wrappedValue = false
            }
        }

        func centerImageView() {
            guard let scrollView = scrollView, let imageView = imageView else { return }
            let offsetX = max((scrollView.bounds.width - imageView.frame.width) / 2, 0)
            let offsetY = max((scrollView.bounds.height - imageView.frame.height) / 2, 0)
            imageView.frame.origin = CGPoint(x: offsetX, y: offsetY)
        }

        func updateImageFrame() {
            guard let scrollView = scrollView, let imageView = imageView, let image = imageView.image else { return }
            let size = scrollView.bounds.size
            let aspectFit = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: size))
            imageView.frame = aspectFit
            scrollView.contentSize = aspectFit.size
            centerImageView()
        }

        @objc func handleDoubleTap(_ tap: UITapGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            if scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let point = tap.location(in: imageView)
                let rect = CGRect(x: point.x - 50, y: point.y - 50, width: 100, height: 100)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

struct RetryAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var retryCount = 0
    @State private var urlVersion = UUID()

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeIn)) { phase in
            switch phase {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                ZStack {
                    Color.gray.opacity(0.15)
                    Image(systemName: "photo")
                        .foregroundColor(.gray.opacity(0.3))
                        .font(.system(size: 24))
                }
                .onAppear {
                    if retryCount < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryCount + 1) * 1.5) {
                            retryCount += 1
                            urlVersion = UUID()
                        }
                    }
                }
            default:
                ZStack {
                    Color.gray.opacity(0.12)
                    ProgressView().scaleEffect(0.7)
                }
            }
        }
        .id(urlVersion)
    }
}

struct WorldSnoodleTile: View {
    let initialEntry: WorldSnoodle
    let dateFmt: DateFormatter
    var onAuthorTap: ((String) -> Void)? = nil
    var onImageTap: (() -> Void)? = nil
    @State private var showLikesList = false
    @ObservedObject private var worldManager = WorldGalleryManager.shared

    var entry: WorldSnoodle {
        worldManager.entries.first(where: { $0.id == initialEntry.id }) ?? initialEntry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                RetryAsyncImage(url: entry.imageStorageURL, contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.width * 4/3)
                    .clipped()
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                    .onTapGesture { onImageTap?() }
            }
            .aspectRatio(3/4, contentMode: .fit)
            Text(entry.caption.isEmpty ? "Untitled" : entry.caption)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .frame(height: 30, alignment: .topLeading)
                .padding(.horizontal, 2)
            HStack(spacing: 4) {
                Button(action: { onAuthorTap?(entry.userId) }) {
                    HStack(spacing: 3) {
                        if let url = entry.authorPhotoURL {
                            AsyncImage(url: url) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 14, height: 14).clipShape(Circle())
                                } else {
                                    Circle().fill(Color.gray.opacity(0.3)).frame(width: 14, height: 14)
                                }
                            }
                        } else if let img = entry.authorImage {
                            Image(uiImage: img)
                                .resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 14, height: 14).clipShape(Circle())
                        } else {
                            Text(entry.avatar == "photo" || entry.avatar == "silhouette" || entry.avatar.isEmpty ? "👤" : entry.avatar)
                                .font(.system(size: 10))
                        }
                        Text(entry.username.lowercased().contains("silhouette") || entry.username.isEmpty ? "👤" : entry.username)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if entry.commentCount > 0 {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.purple.opacity(0.6))
                    Text("\(entry.commentCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                if entry.likes > 0 {
                    if entry.commentCount > 0 {
                        Spacer().frame(width: 6)
                    }
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.pink)
                    Button(action: { showLikesList = true }) {
                        Text("\(entry.likes)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                onAuthorTap?(entry.userId)
            }
            .sheet(isPresented: $showLikesList) {
                LikesListView(doodleId: entry.id)
                    .presentationDetents([.medium, .large])
            }
        }
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Like Button
// Isolated view so liking doesn't cause WorldSnoodleDetailView to re-render
struct LikeButton: View {
    let snoodleId: String
    @ObservedObject private var worldManager = WorldGalleryManager.shared
    @StateObject private var auth = SnoodleAuthManager.shared
    @State private var showSignIn = false
    @State private var showLikesList = false

    var entry: WorldSnoodle? {
        worldManager.entries.first(where: { $0.id == snoodleId })
    }

    var body: some View {
        let liked = entry?.isLikedByMe ?? false
        let count = entry?.likes ?? 0
        HStack(spacing: 6) {
            Button(action: handleLike) {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 22))
                    .foregroundColor(liked ? .pink : .white.opacity(0.6))
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: liked)
            }
            if count > 0 {
                Button(action: { showLikesList = true }) {
                    Text("\(count)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(liked ? .pink : .white.opacity(0.6))
                }
            }
        }
        .sheet(isPresented: $showSignIn) {
            SignInView(onComplete: { performLike() }, showCancel: true)
        }
        .sheet(isPresented: $showLikesList) {
            LikesListView(doodleId: snoodleId)
                .presentationDetents([.medium, .large])
        }
    }

    func handleLike() {
        guard auth.isSignedIn else {
            showSignIn = true
            return
        }
        performLike()
    }

    func performLike() {
        if let e = entry { worldManager.toggleLike(for: e) }
    }
}

// MARK: - World Snoodle Detail View

extension SwiftUI.Image {
    /// Renders the SwiftUI Image to a UIImage for use in share cards and renderers.
    func asUIImage() -> UIImage? {
        let controller = UIHostingController(rootView: self.resizable().scaledToFit())
        controller.view.bounds = CGRect(origin: .zero, size: CGSize(width: 1024, height: 1024))
        controller.view.backgroundColor = .clear
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        return renderer.image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
    }
}

struct WorldSnoodleDetailView: View {
    @StateObject private var auth = SnoodleAuthManager.shared
    @EnvironmentObject var store: SnoodleStore
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var worldManager = WorldGalleryManager.shared
    let initialEntries: [WorldSnoodle]
    let startIndex: Int
    var onShowAuthor: ((String) -> Void)? = nil
    /// Active text search query from the gallery. When set, the detail view filters
    /// its entries to only show matching doodles instead of the full unfiltered feed.
    var textFilter: String? = nil
    @State private var currentIndex: Int = 0
    @State private var showDeleteConfirm = false
    @State private var showReportConfirm = false
    @State private var reportSubmitted = false
    @State private var reportedIds: Set<String> = []
    @State private var dragOffset: CGFloat = 0
    @State private var loadedWorldImage: UIImage? = nil
    @State private var isZoomed = false
    enum ActiveSheet: Identifiable {
        case comments(String)
        case authorProfile(String)
        var id: String {
            switch self {
            case .comments(let id): return "comments_\(id)"
            case .authorProfile(let id): return "profile_\(id)"
            }
        }
    }
    @State private var activeSheet: ActiveSheet? = nil
    @State private var showingComments = false
    @State private var showingProfile = false
    @State private var commentDoodleId: String = ""
    @State private var profileUserId: String = ""

    // Use live worldManager entries so pagination loads show up automatically.
    // When textFilter is active, apply it so the detail view only shows matching doodles.
    var entries: [WorldSnoodle] {
        let live = worldManager.sortedEntries
        let base = live.isEmpty ? initialEntries : live
        guard let filter = textFilter, !filter.trimmingCharacters(in: .whitespaces).isEmpty else {
            return base
        }
        let terms = filter.lowercased().trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return base.filter { snoodle in
            terms.allSatisfy { term in
                snoodle.caption.lowercased().contains(term) ||
                snoodle.keywords.contains { $0.lowercased().contains(term) }
            }
        }
    }

    private let dateFmt: DateFormatter = {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none; return df
    }()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentIndex) {
                ForEach(entries.indices, id: \.self) { i in
                    worldCard(entry: entries[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .scrollDisabled(isZoomed)

            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.65))
                                .frame(width: 54, height: 54)
                                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.leading, 20)
                    Spacer()
                    if entries.count > 1 {
                        let isFiltered = !(textFilter?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                        let total = isFiltered ? entries.count : (worldManager.totalCount > 0 ? worldManager.totalCount : entries.count)
                        Text("\(currentIndex + 1) / \(total)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(14)
                            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                            .padding(.trailing, 20)
                    }
                }
                .padding(.top, 12)
                Spacer()
            }
            .zIndex(10)
        }
        // drag-to-dismiss removed — use X button or swipe down on sheet
        .onAppear {
            currentIndex = min(startIndex, max(0, entries.count - 1))
            let ids = entries.map { $0.id }
            WorldGalleryManager.shared.fetchReportedIds(doodleIds: ids) { reported in
                DispatchQueue.main.async {
                    reportedIds = reported
                    reportSubmitted = reported.contains(entries[currentIndex].id)
                }
            }
        }
        .onChange(of: currentIndex) { _, newIndex in
            reportSubmitted = reportedIds.contains(entries[newIndex].id)
            // Trigger next page when within 5 of the end
            if newIndex >= entries.count - 5 {
                worldManager.fetchNextPage()
            }
        }
        // 💡 Sheet at root level — completely outside TabView to avoid UIPageViewController collision
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .comments(let doodleId):
                CommentSheetView(doodleId: doodleId, doodleCaption: "")
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .authorProfile(let uid):
                PublicProfileView(userId: uid, isOwnProfile: false)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    func worldCard(entry: WorldSnoodle) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ZoomableImageView(url: entry.imageStorageURL, isZoomed: $isZoomed)
            VStack(spacing: 6) {
                if !entry.caption.isEmpty {
                    Text(entry.caption)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                // Author row — date left, artist pill right
                HStack {
                    Text(dateFmt.string(from: entry.timestamp))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                    Button(action: {
                        if let callback = onShowAuthor {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                callback(entry.userId)
                            }
                        } else {
                            activeSheet = .authorProfile(entry.userId)
                        }
                    }) {
                        HStack(spacing: 6) {
                            if let url = entry.authorPhotoURL {
                                AsyncImage(url: url) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                            .frame(width: 24, height: 24).clipShape(Circle())
                                    } else {
                                        Circle().fill(Color.white.opacity(0.2)).frame(width: 24, height: 24)
                                    }
                                }
                            } else if let img = entry.authorImage {
                                Image(uiImage: img)
                                    .resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 24, height: 24).clipShape(Circle())
                            } else if entry.avatar != "photo" && entry.avatar != "silhouette" && !entry.avatar.isEmpty {
                                Text(entry.avatar).font(.system(size: 18))
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Text(entry.username)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(20)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 32)
                .padding(.top, 4)
            }
            Spacer()
            HStack(spacing: 48) {
                Button(action: {
                    // Load image lazily only when sharing — avoids the flash from asUIImage()
                    if let cached = loadedWorldImage {
                        if let card = generateWorldShareCard(for: entry, doodle: cached) {
                            presentShareSheet(with: card)
                        }
                    } else if let url = entry.imageStorageURL {
                        URLSession.shared.dataTask(with: url) { data, _, _ in
                            guard let data = data, let img = UIImage(data: data) else { return }
                            DispatchQueue.main.async {
                                loadedWorldImage = img
                                if let card = generateWorldShareCard(for: entry, doodle: img) {
                                    presentShareSheet(with: card)
                                }
                            }
                        }.resume()
                    }
                }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 22)).foregroundColor(.white.opacity(0.6))
                }

                LikeButton(snoodleId: entry.id)

                // Comment button — read count live from worldManager so it updates immediately
                let liveCommentCount = worldManager.entries.first(where: { $0.id == entry.id })?.commentCount ?? entry.commentCount
                Button(action: {
                    CommentManager.shared.fetchComments(for: entry.id) {
                        activeSheet = .comments(entry.id)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 22)).foregroundColor(.white.opacity(0.6))
                        if liveCommentCount > 0 {
                            Text("\(liveCommentCount)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }

                if auth.userId == entry.userId {
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 22)).foregroundColor(.white.opacity(0.35))
                    }
                    .confirmationDialog("Remove from Community?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button("Remove", role: .destructive) {
                            WorldGalleryManager.shared.delete(worldSnoodle: entry) { _ in }
                            // Match by worldGalleryId first, fall back to timestamp proximity
                            let local = store.entries.first(where: { $0.worldGalleryId == entry.id })
                                ?? store.entries.first(where: { abs($0.timestamp.timeIntervalSince(entry.timestamp)) < 60 })
                            if let local = local {
                                var updated = local
                                updated.isSubmitted = false
                                updated.worldGalleryId = nil
                                store.save(updated)
                            }
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                } else {
                    // Report button — only shown for other people's snoodles
                    Button(action: { showReportConfirm = true }) {
                        Image(systemName: reportSubmitted ? "flag.fill" : "flag")
                            .font(.system(size: 20))
                            .foregroundColor(reportSubmitted ? .orange : .white.opacity(0.3))
                    }
                    .disabled(reportSubmitted)
                    .confirmationDialog("Report this doodle?", isPresented: $showReportConfirm, titleVisibility: .visible) {
                        Button("Report", role: .destructive) {
                            WorldGalleryManager.shared.report(snoodleId: entry.id)
                            reportedIds.insert(entry.id)
                            reportSubmitted = true
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("We'll review this doodle and take action if it violates our guidelines.")
                    }
                }
            }
            .padding(.bottom, 44)
        }
    }  // end worldCard

    func generateWorldShareCard(for entry: WorldSnoodle, doodle: UIImage) -> UIImage? {
        let doodle = doodle
        let cardSize = CGSize(width: 1080, height: 1350)
        let renderer = UIGraphicsImageRenderer(size: cardSize)
        return renderer.image { ctx in
            let c = ctx.cgContext
            let colors = [UIColor(red: 0.97, green: 0.97, blue: 1.0, alpha: 1).cgColor,
                          UIColor(red: 0.88, green: 0.90, blue: 1.0, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0,1])!
            c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: cardSize.height), options: [])
            let padding: CGFloat = 80
            let doodleRect = CGRect(x: padding, y: padding, width: cardSize.width - padding*2, height: cardSize.height - padding*2 - 120)
            doodle.draw(in: doodleRect)
            let brandStr = "skadoodle community · \(entry.username)"
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 32, weight: .medium), .foregroundColor: UIColor(white: 0.5, alpha: 1)]
            let sz = (brandStr as NSString).size(withAttributes: attrs)
            (brandStr as NSString).draw(at: CGPoint(x: (cardSize.width - sz.width)/2, y: cardSize.height - 60), withAttributes: attrs)
        }
    }
}



// MARK: - Top Artists Strip

struct ArtistStat {
    let userId: String
    let score: Double
}

struct TopArtistsStripView: View {
    let entries: [WorldSnoodle]
    @Binding var selectedArtistId: String?
    var onShowProfile: ((String) -> Void)? = nil
    var onArtistSelected: ((String?) -> Void)? = nil
    @ObservedObject private var profileManager = UserProfileManager.shared

    // Compute top artists by heat score
    var topArtists: [ArtistStat] {
        var scores: [String: Double] = [:]
        for entry in entries {
            let hoursOld = max(0, -entry.timestamp.timeIntervalSinceNow / 3600)
            let heat = Double(entry.likes + entry.commentCount * 2) / pow(hoursOld + 2, 1.5)
            scores[entry.userId, default: 0] += heat
        }
        return scores.map { ArtistStat(userId: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score }
            .prefix(10)
            .map { $0 }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // ALL button
                ArtistChipView(
                    label: "ALL",
                    avatar: nil,
                    photoURL: nil,
                    isSelected: selectedArtistId == nil
                ) {
                    selectedArtistId = nil
                    onArtistSelected?(nil)
                }

                ForEach(topArtists, id: \.userId) { stat in
                    let profile = profileManager.getCached(stat.userId)
                    ArtistChipView(
                        label: profile?.username ?? "...",
                        avatar: profile?.avatar,
                        photoURL: profile?.photoURL,
                        isSelected: selectedArtistId == stat.userId,
                        action: {
                            let tappedId = stat.userId
                            if selectedArtistId == tappedId {
                                selectedArtistId = nil
                                onArtistSelected?(nil)
                            } else {
                                selectedArtistId = tappedId
                                onArtistSelected?(tappedId)
                            }
                        },
                        onLongPress: {
                            onShowProfile?(stat.userId)
                        }
                    )
                    .onAppear {
                        if profile == nil {
                            UserProfileManager.shared.fetchProfiles(userIds: [stat.userId]) { _ in }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

struct ArtistChipView: View {
    let label: String
    let avatar: String?
    let photoURL: String?
    let isSelected: Bool
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Avatar
                if let urlStr = photoURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 28, height: 28).clipShape(Circle())
                        } else {
                            Circle().fill(Color.gray.opacity(0.3)).frame(width: 28, height: 28)
                        }
                    }
                } else if let av = avatar, av != "photo" && av != "silhouette" && !av.isEmpty {
                    Text(av).font(.system(size: 18)).frame(width: 28, height: 28)
                } else if label == "ALL" {
                    Text("🌍").font(.system(size: 18)).frame(width: 28, height: 28)
                } else {
                    Text("👤").font(.system(size: 18)).frame(width: 28, height: 28)
                }

                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.purple : Color(UIColor.secondarySystemBackground))
            .foregroundColor(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isSelected ? Color.purple : Color.clear, lineWidth: 1.5))
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                onLongPress?()
            }
        )
    }
}

// MARK: - Likes List Sheet

struct LikesListView: View {
    let doodleId: String
    @State private var userIds: [String] = []
    @State private var isLoading = true
    @ObservedObject private var profileManager = UserProfileManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if userIds.isEmpty {
                    Text("No likes yet")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(userIds, id: \.self) { userId in
                        let profile = profileManager.getCached(userId)
                        HStack(spacing: 12) {
                            if let urlStr = profile?.photoURL, let url = URL(string: urlStr) {
                                AsyncImage(url: url) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                            .frame(width: 36, height: 36).clipShape(Circle())
                                    } else {
                                        Circle().fill(Color.gray.opacity(0.3)).frame(width: 36, height: 36)
                                    }
                                }
                            } else {
                                Text(profile?.avatar ?? "👤")
                                    .font(.system(size: 22))
                                    .frame(width: 36, height: 36)
                            }
                            Text(profile?.username ?? "...")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .onAppear {
                            if profile == nil {
                                UserProfileManager.shared.fetchProfiles(userIds: Set([userId])) { _ in }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Liked by")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            WorldGalleryManager.shared.fetchLikers(doodleId: doodleId) { ids in
                DispatchQueue.main.async {
                    userIds = ids
                    isLoading = false
                    UserProfileManager.shared.fetchProfiles(userIds: Set(ids)) { _ in }
                }
            }
        }
    }
}

// MARK: - Comment Sheet

struct CommentSheetView: View {
    let doodleId: String
    let doodleCaption: String
    @ObservedObject private var manager = CommentManager.shared
    @StateObject private var auth = SnoodleAuthManager.shared
    @State private var commentText: String = ""
    @State private var replyingTo: SnoodleComment? = nil
    @State private var showSignIn = false
    @State private var isSending = false
    @FocusState private var inputFocused: Bool
    @Environment(\.dismiss) var dismiss

    var comments: [SnoodleComment] { manager.topLevel(for: doodleId) }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Comments")
                    .font(.system(size: 17, weight: .semibold))
                let total = manager.comments(for: doodleId).count
                if total > 0 {
                    Text("(\(total))")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            // Comment list
            if manager.loadingDoodleId == doodleId {
                Spacer()
                ProgressView()
                Spacer()
            } else if comments.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text("🎨")
                        .font(.system(size: 40))
                    Text("Be the first to comment")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(comments) { comment in
                                CommentRowView(
                                    comment: comment,
                                    doodleId: doodleId,
                                    replies: manager.replies(to: comment.id, in: doodleId),
                                    onReply: {
                                        replyingTo = comment
                                        inputFocused = true
                                    }
                                )
                                .id(comment.id)
                                Divider().padding(.leading, 52)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .onAppear {
                        if let last = comments.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Reply indicator
            if let replying = replyingTo {
                HStack {
                    Text("Replying to \(replying.username)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { replyingTo = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(UIColor.secondarySystemBackground))
            }

            // Input bar
            HStack(spacing: 10) {
                ZStack {
                    TextField(replyingTo != nil ? "Add a reply…" : "Add a comment…", text: $commentText, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(20)
                        .focused($inputFocused)
                        .disabled(!auth.isSignedIn)
                    // Overlay tap target for sign-in when not authenticated
                    if !auth.isSignedIn {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { showSignIn = true }
                    }
                }

                Button(action: sendComment) {
                    if isSending {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .purple)
                    }
                }
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(UIColor.systemBackground))
        }
        .sheet(isPresented: $showSignIn) {
            SignInView(onComplete: { inputFocused = true }, showCancel: true)
        }
        .onAppear {
            // No auto-focus — user taps text field when ready to type
        }
    }

    func sendComment() {
        guard auth.isSignedIn else { showSignIn = true; return }
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSending = true
        CommentManager.shared.postComment(
            doodleId: doodleId,
            parentId: replyingTo?.id,
            text: text
        ) { success in
            isSending = false
            if success {
                commentText = ""
                replyingTo = nil
            }
        }
    }
}

struct CommentRowView: View {
    let comment: SnoodleComment
    let doodleId: String
    let replies: [SnoodleComment]
    var onReply: () -> Void
    @StateObject private var auth = SnoodleAuthManager.shared
    @State private var showDeleteConfirm = false
    @State private var showReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main comment
            HStack(alignment: .top, spacing: 10) {
                // Avatar
                Group {
                    if let url = comment.authorPhotoURL {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 34, height: 34).clipShape(Circle())
                            } else {
                                Circle().fill(Color.gray.opacity(0.3)).frame(width: 34, height: 34)
                            }
                        }
                    } else {
                        Text(comment.avatar == "photo" || comment.avatar == "silhouette" || comment.avatar.isEmpty ? "👤" : comment.avatar)
                            .font(.system(size: 22))
                            .frame(width: 34, height: 34)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(comment.username)
                            .font(.system(size: 13, weight: .semibold))
                        Text(relativeTime(comment.timestamp))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        if auth.userId == comment.userId {
                            Button(action: { showDeleteConfirm = true }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                        }
                    }
                    Text(comment.text)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)

                    // Reply button
                    Button(action: onReply) {
                        Text("Reply")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.purple)
                    }
                    .padding(.top, 2)

                    // Show/hide replies
                    if !replies.isEmpty {
                        Button(action: { showReplies.toggle() }) {
                            HStack(spacing: 4) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.4))
                                    .frame(width: 24, height: 1)
                                Text(showReplies ? "Hide replies" : "\(replies.count) \(replies.count == 1 ? "reply" : "replies")")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .confirmationDialog("Delete comment?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    CommentManager.shared.deleteComment(doodleId: doodleId, commentId: comment.id) { _ in }
                }
                Button("Cancel", role: .cancel) {}
            }

            // Replies (indented)
            if showReplies {
                ForEach(replies) { reply in
                    ReplyRowView(reply: reply, doodleId: doodleId)
                        .padding(.leading, 52)
                    Divider().padding(.leading, 52 + 44)
                }
            }
        }
    }

    func relativeTime(_ date: Date) -> String {
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(diff/60)m" }
        if diff < 86400 { return "\(diff/3600)h" }
        return "\(diff/86400)d"
    }
}

struct ReplyRowView: View {
    let reply: SnoodleComment
    let doodleId: String
    @StateObject private var auth = SnoodleAuthManager.shared
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let url = reply.authorPhotoURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 26, height: 26).clipShape(Circle())
                        } else {
                            Circle().fill(Color.gray.opacity(0.3)).frame(width: 26, height: 26)
                        }
                    }
                } else {
                    Text(reply.avatar == "photo" || reply.avatar == "silhouette" || reply.avatar.isEmpty ? "👤" : reply.avatar)
                        .font(.system(size: 16))
                        .frame(width: 26, height: 26)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(reply.username)
                        .font(.system(size: 12, weight: .semibold))
                    Text(relativeTime(reply.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    if auth.userId == reply.userId {
                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
                Text(reply.text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .confirmationDialog("Delete reply?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                CommentManager.shared.deleteComment(doodleId: doodleId, commentId: reply.id) { _ in }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    func relativeTime(_ date: Date) -> String {
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(diff/60)m" }
        if diff < 86400 { return "\(diff/3600)h" }
        return "\(diff/86400)d"
    }
}

// MARK: - Calendar Tab

