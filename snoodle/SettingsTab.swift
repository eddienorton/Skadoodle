//
//  SettingsTab.swift
//  snoodle
//

import SwiftUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine
import StoreKit
import UserNotifications

struct SettingsTab: View {
    @ObservedObject private var notifManager = NotificationManager.shared
    @EnvironmentObject var store: SnoodleStore
    @ObservedObject private var worldManager = WorldGalleryManager.shared
    @State private var showingClearConfirm = false
    @State private var showingOnboarding = false
    @State private var showingDeleteConfirm = false
    @State private var isDeletingAccount = false
    @State private var showDeletedMessage = false
    @State private var isDownloadingDoodles = false
    @State private var downloadStatus: String = ""
    @State private var communityCount: Int = 0
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @AppStorage("shareCardStretch") private var shareCardStretch: Bool = true
    #if DEBUG
    @State private var seedCount: Int = 20
    @State private var seedToWorld: Bool = false
    @State private var isSeeding: Bool = false
    @State private var seedStatus: String = ""
    @State private var showNukeConfirm: Bool = false
    @State private var nukeStatus: String = ""
    @State private var isBackfilling: Bool = false
    @State private var backfillStatus: String = ""
    @StateObject private var phantomSession = PhantomSessionManager.shared
    #endif

    var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

    var totalSize: String {
        // Sum on-disk file sizes via attributes — avoids loading every image into memory.
        let bytes = store.entries.reduce(0) { total, entry in
            let attrs = try? FileManager.default.attributesOfItem(atPath: entry.imageURL.path)
            return total + ((attrs?[.size] as? Int) ?? 0)
        }
        let mb = Double(bytes) / 1_000_000
        if mb < 1 { return "\(Int(mb * 1000)) KB" }
        return String(format: "%.1f MB", mb)
    }

    var totalLikes: Int {
        guard let userId = SnoodleAuthManager.shared.userId else { return 0 }
        return worldManager.entries
            .filter { $0.userId == userId }
            .reduce(0) { $0 + $1.likes }
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: Stats
                Section("Your Doodles") {
                    HStack {
                        Label("Private doodles", systemImage: "scribble.variable")
                        Spacer()
                        Text("\(store.entries.count)").foregroundColor(.secondary)
                    }
                    HStack {
                        Label("Posted to community", systemImage: "globe")
                        Spacer()
                        Text("\(communityCount)").foregroundColor(.secondary)
                    }
                    HStack {
                        Label("Total likes", systemImage: "heart.fill")
                        Spacer()
                        Text("\(totalLikes)").foregroundColor(.secondary)
                    }
                    HStack {
                        Label("Storage used", systemImage: "internaldrive")
                        Spacer()
                        Text(totalSize).foregroundColor(.secondary)
                    }
                }

                // MARK: Sharing
                Section("Sharing") {
                    Toggle(isOn: $shareCardStretch) {
                        Label("Stretch to fill", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }

                // MARK: Data
                Section("Data") {
                    Button(action: { showingOnboarding = true }) {
                        Label("Show Intro", systemImage: "info.circle")
                    }
                    .foregroundColor(.primary)
                    if SnoodleAuthManager.shared.isSignedIn {
                        Button(action: downloadMyDoodles) {
                            if isDownloadingDoodles {
                                HStack(spacing: 10) {
                                    ProgressView().scaleEffect(0.8)
                                    Text(downloadStatus.isEmpty ? "Downloading…" : downloadStatus)
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 14))
                                }
                            } else {
                                Label("Download My Doodles", systemImage: "icloud.and.arrow.down")
                                    .foregroundColor(.primary)
                            }
                        }
                        .disabled(isDownloadingDoodles)
                        if !downloadStatus.isEmpty && !isDownloadingDoodles {
                            Text(downloadStatus)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        showingClearConfirm = true
                    } label: {
                        Label("Clear Local Doodles", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
                // MARK: Notifications
                if SnoodleAuthManager.shared.isSignedIn {
                    Section(header: Text("Notifications")) {
                        // iOS-level notification status
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Label("Push Notifications", systemImage: "bell.fill")
                                    .foregroundColor(.primary)
                                Spacer()
                                switch notifAuthStatus {
                                case .authorized:
                                    Text("On").foregroundColor(.secondary)
                                case .denied:
                                    Text("Off — tap to enable").foregroundColor(.orange)
                                default:
                                    Text("Not set").foregroundColor(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if notifAuthStatus == .authorized {
                            Toggle("Likes", isOn: $notifManager.likesEnabled)
                                .onChange(of: notifManager.likesEnabled) { _, _ in notifManager.savePreferences() }
                            Toggle("Comments on my doodles", isOn: $notifManager.commentsEnabled)
                                .onChange(of: notifManager.commentsEnabled) { _, _ in notifManager.savePreferences() }
                            Toggle("Replies to my comments", isOn: $notifManager.repliesEnabled)
                                .onChange(of: notifManager.repliesEnabled) { _, _ in notifManager.savePreferences() }
                            Toggle("New followers", isOn: $notifManager.followersEnabled)
                                .onChange(of: notifManager.followersEnabled) { _, _ in notifManager.savePreferences() }
                            Toggle("New posts from artists I follow", isOn: $notifManager.newPostsEnabled)
                                .onChange(of: notifManager.newPostsEnabled) { _, _ in notifManager.savePreferences() }
                        }
                    }
                }

                // MARK: Sign In prompt when not signed in
                if !SnoodleAuthManager.shared.isSignedIn {
                    Section {
                        NavigationLink {
                            SignInView(onComplete: {}, showCancel: false)
                        } label: {
                            Label("Sign In to join the community", systemImage: "person.crop.circle.badge.plus")
                                .foregroundColor(.purple)
                        }
                    }
                }

                // MARK: Account
                if SnoodleAuthManager.shared.isSignedIn {
                    Section("Account") {
                        if isDeletingAccount {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Deleting your account…").foregroundColor(.secondary)
                            }
                        } else {
                            Button(role: .destructive) {
                                showingDeleteConfirm = true
                            } label: {
                                Label("Delete Account", systemImage: "person.crop.circle.badge.minus")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }

                // MARK: App
                Section("Skadoodle") {
                    Button {
                        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                            SKStoreReviewController.requestReview(in: scene)
                        }
                    } label: {
                        Label("Rate Skadoodle ⭐️", systemImage: "star.fill")
                            .foregroundColor(.primary)
                    }

                    Button {
                        let url = URL(string: "https://apps.apple.com/us/app/skadoodle/id6771497563")!
                        let av = UIActivityViewController(activityItems: ["Check out Skadoodle — a fun doodling app!", url], applicationActivities: nil)
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let root = scene.windows.first?.rootViewController {
                            root.present(av, animated: true)
                        }
                    } label: {
                        Label("Share Skadoodle", systemImage: "square.and.arrow.up")
                            .foregroundColor(.primary)
                    }

                    Link(destination: URL(string: "https://skadoodle.nyc/skadoodle-privacy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised.fill")
                    }

                    Link(destination: URL(string: "https://skadoodle.nyc/skadoodle-support.html")!) {
                        Label("Support", systemImage: "questionmark.circle.fill")
                    }

                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text(appVersion).foregroundColor(.secondary)
                    }
                }

            #if DEBUG
                Section(header: Text("⚠️ Debug").foregroundColor(.orange)) {
                    Stepper("Seed \(seedCount) doodles", value: $seedCount, in: 1...200, step: 10)
                    Toggle("⚠️ Post to World (DANGER)", isOn: $seedToWorld).tint(.red)
                    if isSeeding {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(seedStatus).font(.system(size: 13)).foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: runSeeder) {
                            Label("Seed doodles now", systemImage: "wand.and.stars")
                                .foregroundColor(.orange)
                        }
                    }
                    if !seedStatus.isEmpty && !isSeeding {
                        Text(seedStatus)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Divider()
                    Button(role: .destructive, action: { showNukeConfirm = true }) {
                        Label("Nuke world_gallery + likes", systemImage: "flame.fill")
                            .foregroundColor(.red)
                    }
                    if !nukeStatus.isEmpty {
                        Text(nukeStatus).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Divider()
                    if isBackfilling {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Backfilling searchIndex…").font(.system(size: 13)).foregroundColor(.secondary)
                        }
                    } else {
                        Button {
                            isBackfilling = true
                            backfillStatus = ""
                            Task {
                                let result = await WorldGalleryManager.shared.backfillSearchIndex()
                                await MainActor.run {
                                    isBackfilling = false
                                    backfillStatus = result
                                }
                            }
                        } label: {
                            Label("Backfill searchIndex (run once)", systemImage: "magnifyingglass.circle")
                                .foregroundColor(.orange)
                        }
                    }
                    if !backfillStatus.isEmpty {
                        Text(backfillStatus).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }

                Section(header: Text("👻 Phantom Accounts").foregroundColor(.purple)) {
                    if let active = phantomSession.activePhantom {
                        HStack {
                            Text(active.avatar).font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Signed in as").font(.system(size: 11)).foregroundColor(.secondary)
                                Text(active.name).font(.system(size: 14, weight: .semibold))
                            }
                            Spacer()
                            Button("Sign Out") {
                                phantomSession.signOut()
                            }
                            .foregroundColor(.red)
                            .font(.system(size: 13, weight: .medium))
                        }
                    } else {
                        ForEach(PhantomAccounts.all, id: \.userId) { phantom in
                            Button(action: { phantomSession.signIn(as: phantom) }) {
                                HStack {
                                    Text(phantom.avatar).font(.system(size: 20))
                                    Text(phantom.name).foregroundColor(.primary)
                                    Spacer()
                                    if phantomSession.isSigningIn {
                                        ProgressView().scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "arrow.right.circle")
                                            .foregroundColor(.purple)
                                    }
                                }
                            }
                            .disabled(phantomSession.isSigningIn)
                        }
                        if let err = phantomSession.errorMessage {
                            Text(err).font(.system(size: 11)).foregroundColor(.red)
                        }
                    }
                }
            #endif
            }
            .navigationTitle("Settings")
            .onAppear {
                fetchCommunityCount()
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    DispatchQueue.main.async {
                        notifAuthStatus = settings.authorizationStatus
                    }
                }
            }
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView {
                    showingOnboarding = false
                }
            }
            .confirmationDialog("Clear local doodles?", isPresented: $showingClearConfirm, titleVisibility: .visible) {
                Button("Clear Local Doodles", role: .destructive) {
                    store.entries.removeAll()
                    store.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all \(store.entries.count) doodles from this device only. Your community posts are not affected.")
            }
            .confirmationDialog("Delete your account?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) {
                    deleteAccount()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your profile, all your community posts and their images, your likes, and your private gallery. This cannot be undone.")
            }
            .sheet(isPresented: $showDeletedMessage) {
                AccountDeletedView()
            }
            #if DEBUG
            .confirmationDialog("Nuke Firebase?", isPresented: $showNukeConfirm, titleVisibility: .visible) {
                Button("Delete world_gallery, likes + Storage", role: .destructive) {
                    nukeCollections()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes ALL documents in world_gallery and likes, and all images in Storage. Cannot be undone.")
            }
            #endif
        }
    }

    private func downloadMyDoodles() {
        guard let userId = SnoodleAuthManager.shared.userId else { return }
        isDownloadingDoodles = true
        downloadStatus = "Looking up your doodles…"

        // Collect worldGalleryIds already in local store so we can skip dupes
        let existingWorldIds = Set(store.entries.compactMap { $0.worldGalleryId })

        Firestore.firestore().collection("world_gallery")
            .whereField("userId", isEqualTo: userId)
            .order(by: "timestamp", descending: true)
            .getDocuments { [self] snapshot, error in
                guard let docs = snapshot?.documents, error == nil else {
                    DispatchQueue.main.async {
                        self.isDownloadingDoodles = false
                        self.downloadStatus = "Could not reach the server. Try again."
                    }
                    return
                }

                // Filter out docs already saved locally
                let toDownload = docs.filter { !existingWorldIds.contains($0.documentID) }

                guard !toDownload.isEmpty else {
                    DispatchQueue.main.async {
                        self.isDownloadingDoodles = false
                        self.downloadStatus = "Nothing new — you're all caught up."
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.downloadStatus = "Downloading 0 / \(toDownload.count)…"
                }

                let group = DispatchGroup()
                var downloadedEntries: [SnoodleEntry] = []
                var failed = 0
                let lock = NSLock()

                for doc in toDownload {
                    let data = doc.data()
                    guard let imageURL = data["imageURL"] as? String,
                          let url = URL(string: imageURL),
                          let ts = (data["timestamp"] as? Timestamp)?.dateValue() else {
                        failed += 1
                        continue
                    }
                    let caption = data["caption"] as? String ?? ""
                    let keywords = data["keywords"] as? [String] ?? []
                    let docId = doc.documentID

                    group.enter()
                    URLSession.shared.dataTask(with: url) { imgData, _, err in
                        defer { group.leave() }
                        guard let imgData = imgData, err == nil else {
                            lock.lock(); failed += 1; lock.unlock()
                            return
                        }
                        let entry = SnoodleEntry(
                            caption: caption,
                            keywords: keywords,
                            timestamp: ts,
                            imageData: imgData,
                            isSubmitted: true,
                            worldGalleryId: docId
                        )
                        lock.lock(); downloadedEntries.append(entry); lock.unlock()
                        DispatchQueue.main.async {
                            self.downloadStatus = "Downloading \(downloadedEntries.count) / \(toDownload.count)…"
                        }
                    }.resume()
                }

                group.notify(queue: .main) {
                    // Save all entries first, then sort the whole store newest-first
                    for entry in downloadedEntries {
                        self.store.save(entry)
                    }
                    self.store.entries.sort { $0.timestamp > $1.timestamp }
                    self.store.persistAll()
                    self.isDownloadingDoodles = false
                    let downloaded = downloadedEntries.count
                    if failed == 0 {
                        self.downloadStatus = "✓ Downloaded \(downloaded) doodle\(downloaded == 1 ? "" : "s")"
                    } else {
                        self.downloadStatus = "✓ Downloaded \(downloaded), \(failed) failed"
                    }
                }
            }
    }

    private func fetchCommunityCount() {
        guard let userId = SnoodleAuthManager.shared.userId else { return }
        Firestore.firestore().collection("world_gallery")
            .whereField("userId", isEqualTo: userId)
            .getDocuments { snapshot, _ in
                DispatchQueue.main.async {
                    communityCount = snapshot?.documents.count ?? 0
                }
            }
    }

    private func deleteAccount() {
        guard let userId = SnoodleAuthManager.shared.userId else { return }
        isDeletingAccount = true
        let db = Firestore.firestore()
        let storage = Storage.storage()
        let group = DispatchGroup()

        // Step 1: Delete user's world_gallery docs + their Storage images
        group.enter()
        db.collection("world_gallery")
            .whereField("userId", isEqualTo: userId)
            .getDocuments { snapshot, _ in
                let docs = snapshot?.documents ?? []
                let batch = db.batch()
                for doc in docs {
                    batch.deleteDocument(doc.reference)
                    // Delete Storage image
                    if let imageURL = doc.data()["imageURL"] as? String,
                       let path = Self.storagePathFromURL(imageURL) {
                        group.enter()
                        storage.reference().child(path).delete { _ in group.leave() }
                    }
                }
                batch.commit { _ in group.leave() }
            }

        // Step 2: Delete all likes by this user
        group.enter()
        db.collection("likes")
            .whereField("userId", isEqualTo: userId)
            .getDocuments { snapshot, _ in
                let batch = db.batch()
                snapshot?.documents.forEach { batch.deleteDocument($0.reference) }
                batch.commit { _ in group.leave() }
            }

        // Step 3: Delete following/followers subcollections
        group.enter()
        db.collection("users").document(userId).collection("following").getDocuments { snapshot, _ in
            let batch = db.batch()
            snapshot?.documents.forEach { batch.deleteDocument($0.reference) }
            batch.commit { _ in group.leave() }
        }
        group.enter()
        db.collection("users").document(userId).collection("followers").getDocuments { snapshot, _ in
            let batch = db.batch()
            snapshot?.documents.forEach { batch.deleteDocument($0.reference) }
            batch.commit { _ in group.leave() }
        }

        // Step 4: Delete profile photo from Storage if exists
        group.enter()
        storage.reference().child("profile_photos/\(userId).jpg").delete { _ in group.leave() }

        // Step 5: When all done, delete user doc then sign out
        group.notify(queue: .main) {
            db.collection("users").document(userId).delete { _ in
                // Clear local data
                store.clearAll()
                UserDefaults.standard.removeObject(forKey: "snoodleUsername")
                UserDefaults.standard.removeObject(forKey: "snoodleAvatar")
                UserDefaults.standard.removeObject(forKey: "snoodleProfilePhoto")
                WorldGalleryManager.shared.entries = []
                SnoodleAuthManager.shared.signOut()
                self.isDeletingAccount = false
                self.showDeletedMessage = true
            }
        }
    }

    private static func storagePathFromURL(_ urlString: String) -> String? {
        // Firebase Storage URLs encode the path after "/o/" and before "?"
        guard let url = URL(string: urlString),
              let pathEncoded = url.path.components(separatedBy: "/o/").last else { return nil }
        return pathEncoded.removingPercentEncoding
    }

    #if DEBUG
    private func runSeeder() {
        isSeeding = true
        seedStatus = "Generating..."
        let total = seedCount
        let postToWorld = seedToWorld
        let canvasSize = CGSize(width: 300, height: 300)

        let fakeCaptions = [
            "a wobbly fish", "something birdlike", "maybe a house?",
            "abstract feelings", "a confused cloud", "definitely not a cat",
            "wiggly landscape", "a person perhaps", "geometric vibes",
            "late night scribble", "an attempt at a tree", "mystery object",
            "the concept of Thursday", "a happy accident", "squiggle study #1"
        ]
        let fakeKeywords: [[String]] = [
            ["fish","ocean","wobbly"], ["bird","wings","sky"],
            ["house","home","building"], ["abstract","art","feelings"],
            ["cloud","sky","fluffy"], ["cat","animal","confused"],
            ["landscape","hills","nature"], ["person","figure","human"],
            ["geometric","shapes","lines"], ["night","dark","scribble"],
            ["tree","nature","green"], ["mystery","unknown","object"],
            ["concept","abstract","Thursday"], ["accident","art","happy"],
            ["squiggle","study","lines"]
        ]

        Task {
            var saved = 0
            for i in 0..<total {
                // Generate random lines
                let lines = makeStuckLines(in: canvasSize) + makeStuckLines(in: canvasSize)
                let rendered = renderCanvas(lines: lines, size: canvasSize)
                guard let data = rendered.jpegData(compressionQuality: 0.85) else { continue }

                let idx = i % fakeCaptions.count
                var entry = SnoodleEntry(
                    caption: fakeCaptions[idx] + " \(i+1)",
                    keywords: fakeKeywords[idx],
                    imageData: data
                )

                if postToWorld && SnoodleAuthManager.shared.isSignedIn {
                    await withCheckedContinuation { cont in
                        WorldGalleryManager.shared.submit(entry: entry) { docId, error in
                            if let docId = docId {
                                entry.isSubmitted = true
                                entry.worldGalleryId = docId
                            }
                            cont.resume()
                        }
                    }
                }

                SnoodleStore.shared.save(entry)
                saved += 1

                let s = saved
                await MainActor.run {
                    seedStatus = "\(s) / \(total)..."
                }
            }

            await MainActor.run {
                isSeeding = false
                seedStatus = "✓ Seeded \(saved) doodles"
                if postToWorld { WorldGalleryManager.shared.fetchRecent() }
            }
        }
    }

    private func nukeCollections() {
        nukeStatus = "Deleting..."
        let db = Firestore.firestore()
        let group = DispatchGroup()

        for collection in ["world_gallery", "likes"] {
            group.enter()
            db.collection(collection).getDocuments { snapshot, _ in
                let batch = db.batch()
                snapshot?.documents.forEach { batch.deleteDocument($0.reference) }
                batch.commit { _ in group.leave() }
            }
        }

        group.notify(queue: .main) {
            // Also clear Storage world_doodles folder
            let storage = Storage.storage().reference().child("world_doodles")
            storage.listAll { result, _ in
                result?.items.forEach { $0.delete { _ in } }
            }
            WorldGalleryManager.shared.entries = []
            nukeStatus = "✓ Nuked"
        }
    }
    #endif
}


// MARK: - Profile Setup Prompt

struct ProfileSetupPromptView: View {
    @ObservedObject private var auth = SnoodleAuthManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var username: String = ""
    @State private var tagline: String = ""
    @State private var bio: String = ""
    @State private var location: String = ""
    @State private var isPublic: Bool = true
    @State private var profilePhoto: UIImage? = nil
    @State private var showAvatarPicker: Bool = false
    @State private var showCamera: Bool = false
    @State private var showLibrary: Bool = false
    @State private var isSaving: Bool = false
    @FocusState private var usernameFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(spacing: 16) {
                        Text("Welcome to Skadoodle!")
                            .font(.system(size: 22, weight: .bold))
                        Text("Set up your profile so the community knows who you are.")
                            .font(.system(size: 14)).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        // Photo circle
                        ZStack(alignment: .bottomTrailing) {
                            if let photo = profilePhoto {
                                Image(uiImage: photo)
                                    .resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 90, height: 90).clipShape(Circle())
                            } else {
                                Circle().fill(Color.purple.opacity(0.12))
                                    .frame(width: 90, height: 90)
                                    .overlay(Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 54)).foregroundColor(.purple.opacity(0.4)))
                            }
                            Button(action: { showAvatarPicker = true }) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                                    .padding(7)
                                    .background(Color.purple)
                                    .clipShape(Circle())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                Section(header: Text("About You")) {
                    TextField("Username", text: $username)
                        .focused($usernameFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Tagline — your artist motto", text: $tagline)
                    TextField("Bio", text: $bio, axis: .vertical).lineLimit(2...4)
                    TextField("Location", text: $location)
                    Toggle("Public profile", isOn: $isPublic)
                }
            }
            .navigationTitle("Your Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Save") { saveAndDismiss() }
                            .fontWeight(.semibold)
                            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onAppear { usernameFocused = true }
            .sheet(isPresented: $showAvatarPicker) {
                AvatarPickerSheet(
                    onCamera: { showCamera = true },
                    onLibrary: { showLibrary = true },
                    onGeneric: { profilePhoto = nil }
                )
            }
            .sheet(isPresented: $showCamera) {
                ImagePickerView(image: $profilePhoto, sourceType: .camera)
            }
            .sheet(isPresented: $showLibrary) {
                ImagePickerView(image: $profilePhoto, sourceType: .photoLibrary)
            }
        }
        .interactiveDismissDisabled(true)
    }

    func saveAndDismiss() {
        guard let uid = auth.userId else { return }
        isSaving = true
        let avatarVal = profilePhoto != nil ? "photo" : "silhouette"
        let profile = UserProfile(userId: uid, username: username, avatar: avatarVal, photoURL: nil,
                                  tagline: tagline, bio: bio, location: location, links: [],
                                  accentColor: "#A855F7", backgroundStyle: .color,
                                  backgroundValue: "#FFFFFF", headerDoodleId: "",
                                  pinnedDoodleIds: [], layoutStyle: .grid, isPublic: isPublic)
        if let photo = profilePhoto {
            let thumbSize = CGSize(width: 120, height: 120)
            let renderer = UIGraphicsImageRenderer(size: thumbSize)
            let thumb = renderer.image { _ in photo.draw(in: CGRect(origin: .zero, size: thumbSize)) }
            guard let jpegData = thumb.jpegData(compressionQuality: 0.7) else { isSaving = false; return }
            UserDefaults.standard.set(jpegData, forKey: "snoodleProfilePhoto")
            let storageRef = Storage.storage().reference().child("profile_photos/\(uid).jpg")
            let meta = StorageMetadata(); meta.contentType = "image/jpeg"
            storageRef.putData(jpegData, metadata: meta) { _, error in
                guard error == nil else { DispatchQueue.main.async { self.isSaving = false }; return }
                storageRef.downloadURL { url, _ in
                    guard let downloadURL = url else { DispatchQueue.main.async { self.isSaving = false }; return }
                    var p = profile; p.photoURL = downloadURL.absoluteString
                    UserProfileManager.shared.saveProfile(userId: uid, username: self.username,
                                                          avatar: "photo", photoURL: downloadURL.absoluteString,
                                                          extended: p)
                    DispatchQueue.main.async {
                        self.isSaving = false
                        SnoodleAuthManager.shared.needsProfileSetup = false
                        self.dismiss()
                    }
                }
            }
        } else {
            UserProfileManager.shared.saveProfile(userId: uid, username: username,
                                                  avatar: "silhouette", photoURL: nil, extended: profile)
            isSaving = false
            auth.needsProfileSetup = false
            dismiss()
        }
    }
}

// MARK: - Account Deleted View

struct AccountDeletedView: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            VStack(spacing: 12) {
                Text("Account Deleted")
                    .font(.system(size: 28, weight: .bold))
                Text("Your account, community posts, likes, and profile photo have all been permanently removed. Your personal doodles on this device have also been cleared.")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Text("Thanks for doodling with us.")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            Spacer()
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(false)
    }
}

// MARK: - Avatar Picker Sheet

