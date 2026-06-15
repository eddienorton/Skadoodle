//
//  ProfileView.swift
//  snoodle
//

import SwiftUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine

// MARK: - Doodle Action Sheet

struct DoodleActionSheet: View {
    let doodle: WorldSnoodle
    let isCurrentBanner: Bool
    let onMakeBanner: () -> Void
    let onRemoveFromCommunity: () -> Void
    let onDeleteLocally: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var showDeleteConfirm = false
    @State private var showRemoveConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(UIColor.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 16)

            HStack(spacing: 14) {
                // Thumbnail
                AsyncImage(url: doodle.imageStorageURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(3/4, contentMode: .fill)
                            .frame(width: 72, height: 96)
                            .clipped()
                            .cornerRadius(10)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(UIColor.secondarySystemBackground))
                            .frame(width: 72, height: 96)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if !doodle.caption.isEmpty {
                        Text(doodle.caption)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                    }
                    HStack(spacing: 16) {
                        Label("\(doodle.likes)", systemImage: "heart.fill")
                            .foregroundColor(.pink)
                            .font(.system(size: 13))
                        Label("\(doodle.commentCount)", systemImage: "bubble.left.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 13))
                    }
                    if doodle.isLikedByMe {
                        Text("You liked this")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Text(doodle.timestamp, style: .date)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            Divider()

            // Actions
            VStack(spacing: 0) {
                if !isCurrentBanner {
                    actionRow(icon: "photo.on.rectangle", label: "Make Banner", color: .purple) {
                        onMakeBanner()
                    }
                    Divider().padding(.leading, 52)
                }

                if doodle.userId == SnoodleAuthManager.shared.userId {
                    actionRow(icon: "globe.slash", label: "Remove from Community", color: .orange) {
                        showRemoveConfirm = true
                    }
                    Divider().padding(.leading, 52)
                }

                actionRow(icon: "trash", label: "Delete from My Doodles", color: .red) {
                    showDeleteConfirm = true
                }

                Divider().padding(.leading, 52)

                actionRow(icon: "xmark", label: "Cancel", color: .secondary) {
                    dismiss()
                }
            }
        }
        .confirmationDialog("Remove from Community?", isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) { onRemoveFromCommunity() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This doodle will be removed from the world gallery. You keep it locally.")
        }
        .confirmationDialog("Delete Doodle?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { onDeleteLocally() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the doodle from your device. It cannot be undone.")
        }
    }

    func actionRow(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(color)
                    .frame(width: 28)
                    .padding(.leading, 20)
                Text(label)
                    .font(.system(size: 16))
                    .foregroundColor(color == .secondary ? .secondary : .primary)
                Spacer()
            }
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

struct AvatarPickerSheet: View {
    let onCamera: () -> Void
    let onLibrary: () -> Void
    let onGeneric: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.gray.opacity(0.3)).frame(width: 36, height: 4).padding(.top, 12).padding(.bottom, 20)
            Text("Profile Photo").font(.system(size: 17, weight: .semibold)).padding(.bottom, 24)

            VStack(spacing: 12) {
                photoOption(icon: "camera.fill", label: "Take Photo", action: { onCamera(); dismiss() })
                photoOption(icon: "photo.on.rectangle", label: "Choose from Library", action: { onLibrary(); dismiss() })
                Divider().padding(.horizontal, 20)
                Button(action: { onGeneric(); dismiss() }) {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle").font(.system(size: 24)).foregroundColor(.secondary)
                            .frame(width: 36)
                        Text("Use Generic").font(.system(size: 16))
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.vertical, 14)
                }
                .buttonStyle(.plain).foregroundColor(.primary)
            }
            .padding(.bottom, 32)
        }
        .presentationDetents([.fraction(UIDevice.current.userInterfaceIdiom == .pad ? 0.205 : 0.320)])
    }

    func photoOption(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 22)).foregroundColor(.purple).frame(width: 36)
                Text(label).font(.system(size: 16))
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .buttonStyle(.plain).foregroundColor(.primary)
    }
}

// MARK: - Info Editor Sheet

struct InfoEditorSheet: View {
    @Binding var username: String
    @Binding var tagline: String
    @Binding var bio: String
    @Binding var location: String
    @Binding var isPublic: Bool
    @Binding var links: [ProfileLink]
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var showLinkEditor = false
    @State private var editingLink: ProfileLink? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("About You")) {
                    TextField("Username", text: $username)
                    TextField("Tagline — your artist motto", text: $tagline)
                    TextField("Bio", text: $bio, axis: .vertical).lineLimit(3...5)
                    TextField("Location", text: $location)
                    Toggle("Public profile", isOn: $isPublic)
                }
                Section(header: Text("Links")) {
                    ForEach(links, id: \.url) { link in
                        HStack {
                            Image(systemName: link.icon).foregroundColor(.purple)
                            Text(link.displayName)
                            Spacer()
                            Text(link.url).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    .onDelete { links.remove(atOffsets: $0) }
                    Button(action: { editingLink = ProfileLink(platform: "website", url: ""); showLinkEditor = true }) {
                        Label("Add link", systemImage: "plus.circle").foregroundColor(.purple)
                    }
                }
            }
            .navigationTitle("Edit Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { onSave(); dismiss() }
                        .fontWeight(.semibold)
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showLinkEditor) {
                LinkEditorSheet(link: $editingLink) { link in
                    links.removeAll { $0.platform == link.platform }
                    links.append(link)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Public Profile View

struct PublicProfileView: View {
    let userId: String
    var isOwnProfile: Bool = false
    var refreshTrigger: Int = 0

    @ObservedObject private var followManager = FollowManager.shared
    @ObservedObject private var auth = SnoodleAuthManager.shared

    @State private var profile: UserProfile? = nil
    @State private var doodles: [WorldSnoodle] = []
    @State private var isLoading = true
    @State private var selectedDoodleIndex: Int? = nil
    @State private var actionDoodle: WorldSnoodle? = nil  // drives doodle action tray
    @State private var localFollowerCount: Int = 0
    @State private var hasInitializedCount = false
    @State private var showFollowersList = false
    @State private var showFollowingList = false

    // Edit sheets
    @State private var showAvatarPicker = false
    @State private var showInfoEditor = false
    @State private var showCamera = false
    @State private var showLibrary = false

    // Editable local state (only used when isOwnProfile)
    @State private var editUsername = ""
    @State private var editTagline = ""
    @State private var editBio = ""
    @State private var editLocation = ""
    @State private var editIsPublic = true
    @State private var editLinks: [ProfileLink] = []
    @State private var editHeaderDoodleId = ""
    @State private var bannerHeight: CGFloat = 0   // 0 = use default
    @State private var dragBannerHeight: CGFloat = 0  // live drag offset
    @State private var editPhoto: UIImage? = nil
    @State private var isSavingPhoto = false

    var body: some View {
        Group {
            if isLoading && profile == nil {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading profile...")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isOwnProfile {
                VStack(spacing: 0) {
                    bannerZone
                        .overlay(alignment: .bottomTrailing) {
                            if isOwnProfile {
                        Image(systemName: "arrow.up.arrow.down.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.purple)
                            .background(Circle().fill(Color(UIColor.systemBackground)).frame(width: 24, height: 24))
                            .offset(y: 14)
                            .padding(.trailing, 16)
                            .allowsHitTesting(false)
                            }
                        }
                    avatarZone
                        .padding(.horizontal, 20)
                    infoZone
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    Divider().padding(.vertical, 16)
                    ScrollView {
                        doodlesSection.padding(.horizontal, 12)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        bannerZone
                        avatarZone
                            .padding(.horizontal, 20)
                        infoZone
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                        Divider().padding(.vertical, 16)
                        doodlesSection.padding(.horizontal, 12)
                    }
                }
            }
        }
        .onAppear { loadData() }
        .onChange(of: refreshTrigger) { _, _ in
            UserProfileManager.shared.clearCache(for: userId)
            loadData()
        }
        // Banner picker

        // Avatar picker
        .sheet(isPresented: $showAvatarPicker) {
            AvatarPickerSheet(
                onCamera: { showCamera = true },
                onLibrary: { showLibrary = true },
                onGeneric: { saveGenericAvatar() }
            )
        }
        .sheet(isPresented: $showCamera) {
            ImagePickerView(image: $editPhoto, sourceType: .camera)
                .onDisappear { if let img = editPhoto { savePhoto(img) } }
        }
        .sheet(isPresented: $showLibrary) {
            ImagePickerView(image: $editPhoto, sourceType: .photoLibrary)
                .onDisappear { if let img = editPhoto { savePhoto(img) } }
        }
        // Info editor
        .sheet(isPresented: $showInfoEditor) {
            InfoEditorSheet(
                username: $editUsername, tagline: $editTagline,
                bio: $editBio, location: $editLocation,
                isPublic: $editIsPublic, links: $editLinks,
                onSave: saveInfo
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // Followers list
        .sheet(isPresented: $showFollowersList) {
            FollowListSheet(userId: userId, mode: .followers)
                .presentationSizing(.page)
        }
        // Following list
        .sheet(isPresented: $showFollowingList) {
            FollowListSheet(userId: userId, mode: .following)
                .presentationSizing(.page)
        }
        .sheet(item: $actionDoodle) { doodle in
            DoodleActionSheet(
                doodle: doodle,
                isCurrentBanner: editHeaderDoodleId == doodle.id,
                onMakeBanner: {
                    editHeaderDoodleId = doodle.id
                    saveBanner(doodle.id)
                    actionDoodle = nil
                },
                onRemoveFromCommunity: {
                    WorldGalleryManager.shared.delete(worldSnoodle: doodle) { _ in }
                    doodles.removeAll { $0.id == doodle.id }
                    actionDoodle = nil
                },
                onDeleteLocally: {
                    if let entry = SnoodleStore.shared.entries.first(where: { $0.worldGalleryId == doodle.id || $0.id.uuidString == doodle.id }) {
                        SnoodleStore.shared.delete(entry)
                    }
                    doodles.removeAll { $0.id == doodle.id }
                    actionDoodle = nil
                }
            )
            .presentationDetents([.height(380)])
            .presentationDragIndicator(.visible)
        }
        // View a doodle — pass full array so left/right swipe works
        .fullScreenCover(item: Binding(
            get: { selectedDoodleIndex.map { IdentifiableInt(value: $0) } },
            set: { selectedDoodleIndex = $0?.value }
        )) { idx in
            WorldSnoodleDetailView(initialEntries: doodles, startIndex: idx.value)
        }
    }

    // MARK: - Banner Zone

    var bannerZone: some View {
        let hasBanner = !editHeaderDoodleId.isEmpty ||
            (profile?.headerDoodleId.isEmpty == false)
        return ZStack {
            // Banner image
            Group {
                if !editHeaderDoodleId.isEmpty,
                   let d = doodles.first(where: { $0.id == editHeaderDoodleId }),
                   let url = d.imageStorageURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else { defaultBannerGradient }
                    }
                } else if let p = profile, !p.headerDoodleId.isEmpty,
                          let d = doodles.first(where: { $0.id == p.headerDoodleId }),
                          let url = d.imageStorageURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else { defaultBannerGradient }
                    }
                } else {
                    defaultBannerGradient
                }
            }
            .clipped()

            // Hint when no banner set
            if isOwnProfile && !hasBanner {
                Text("Tap a doodle below to set your banner")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.4), radius: 4)
            }
        }
        .frame(height: effectiveBannerHeight)
        .clipped()
        .gesture(isOwnProfile ?
            DragGesture()
                .onChanged { val in dragBannerHeight = val.translation.height }
                .onEnded { val in
                    let newHeight = (bannerHeight == 0 ? defaultBannerHeight : bannerHeight) + val.translation.height
                    bannerHeight = min(max(newHeight, minBannerHeight), maxBannerHeight)
                    dragBannerHeight = 0
                    saveBannerHeight()
                }
            : nil
        )
    }

    // Banner height constants
    var defaultBannerHeight: CGFloat { UIDevice.current.userInterfaceIdiom == .pad ? 280 : UIScreen.main.bounds.width * 0.26 }
    let minBannerHeight: CGFloat = 120
    let maxBannerHeight: CGFloat = 360
    var effectiveBannerHeight: CGFloat {
        let base = bannerHeight == 0 ? defaultBannerHeight : bannerHeight
        return min(max(base + dragBannerHeight, minBannerHeight), maxBannerHeight)
    }

    var defaultBannerGradient: some View {
        LinearGradient(colors: [Color(white: 0.82), Color(white: 0.92)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Avatar Zone

    var avatarZone: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                // Avatar
                ZStack {
                    Circle().fill(Color(UIColor.systemBackground)).frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.15), radius: 6)
                    if let img = editPhoto {
                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 90, height: 90).clipShape(Circle())
                    } else if let urlStr = profile?.photoURL, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 90, height: 90).clipShape(Circle())
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 72)).foregroundColor(.purple)
                            }
                        }
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 72)).foregroundColor(.purple)
                    }
                }

                // Edit badge
                if isOwnProfile {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.purple)
                        .background(Circle().fill(Color(UIColor.systemBackground)).frame(width: 24, height: 24))
                }
            }
            .frame(maxWidth: .infinity)
            .onTapGesture { if isOwnProfile { showAvatarPicker = true } }

            HStack(spacing: 32) {
                statPill("\(doodles.count)", "doodles")
                Button(action: { showFollowersList = true }) {
                    statPill("\(localFollowerCount)", "followers")
                }
                .buttonStyle(.plain)
                Button(action: { showFollowingList = true }) {
                    statPill("\(profile?.followingCount ?? 0)", "following")
                }
                .buttonStyle(.plain)
            }
            .onChange(of: profile?.followerCount) { _, count in
                if let count, !hasInitializedCount {
                    localFollowerCount = count
                    hasInitializedCount = true
                }
            }

            if auth.userId != userId && auth.isSignedIn {
                let isFollowing = followManager.isFollowing(userId)
                Button(action: {
                    if isFollowing {
                        followManager.unfollow(targetUserId: userId)
                        localFollowerCount = max(0, localFollowerCount - 1)
                    } else {
                        followManager.follow(targetUserId: userId)
                        localFollowerCount += 1
                    }
                }) {
                    Text(isFollowing ? "Following" : "Follow")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isFollowing ? .primary : .white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 8)
                        .background(isFollowing ? Color(UIColor.systemGray5) : Color.purple)
                        .cornerRadius(20)
                }
                .padding(.top, 4)
            }
        }
        .padding(.top, -48)
    }

    func statPill(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold))
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    // MARK: - Info Zone

    var infoZone: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .center, spacing: 6) {
                let name = isOwnProfile && !editUsername.isEmpty ? editUsername : (profile?.username ?? "")
                let tagline = isOwnProfile ? editTagline : (profile?.tagline ?? "")
                let bio = isOwnProfile ? editBio : (profile?.bio ?? "")
                let location = isOwnProfile ? editLocation : (profile?.location ?? "")
                let links = isOwnProfile ? editLinks : (profile?.links ?? [])

                Text(name).font(.system(size: 22, weight: .bold))
                if !tagline.isEmpty {
                    Text(tagline).font(.system(size: 15, weight: .medium)).foregroundColor(.purple)
                }
                if !bio.isEmpty {
                    Text(bio).font(.system(size: 14)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                }
                if !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
                if !links.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(links, id: \.url) { link in
                            if let url = URL(string: link.url) {
                                Link(destination: url) {
                                    HStack(spacing: 4) {
                                        Image(systemName: link.icon)
                                        Text(link.displayName)
                                    }
                                    .font(.system(size: 13, weight: .medium)).foregroundColor(.purple)
                                }
                            }
                        }
                    }
                }
                if isOwnProfile && name.isEmpty && tagline.isEmpty {
                    Text("Tap to add your info").font(.system(size: 14)).foregroundColor(.secondary.opacity(0.6))
                }
                if isOwnProfile {
                    HStack {
                        Spacer()
                        Button {
                            SnoodleAuthManager.shared.signOut()
                        } label: {
                            Text("Sign Out")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, isOwnProfile ? 28 : 0)

            if isOwnProfile {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 22)).foregroundColor(.purple).opacity(0.7)
            }
        }
        .onTapGesture { if isOwnProfile { showInfoEditor = true } }
    }

    // MARK: - Doodles Grid

    var doodlesSection: some View {
        Group {
            if isLoading {
                ProgressView().padding(40)
            } else if doodles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "scribble").font(.system(size: 44)).foregroundColor(.secondary.opacity(0.3))
                    Text("No community doodles yet").foregroundColor(.secondary)
                }.padding(40)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 3) {
                    ForEach(Array(doodles.enumerated()), id: \.element.id) { index, doodle in
                        if doodle.imageStorageURL != nil {
                            RetryAsyncImage(url: doodle.imageStorageURL, contentMode: .fill)
                                .aspectRatio(3/4, contentMode: .fill)
                                .clipped()
                                .onTapGesture {
                                    if isOwnProfile {
                                        actionDoodle = doodle
                                    } else {
                                        selectedDoodleIndex = index
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Load

    func autoAssignBannerIfNeeded() {
        guard isOwnProfile,
              editHeaderDoodleId.isEmpty,
              profile != nil,
              let first = doodles.first else { return }
        editHeaderDoodleId = first.id
        saveBanner(first.id)
    }

    func loadData() {
        isLoading = true
        hasInitializedCount = false
        var profileDone = false
        var doodlesDone = false
        func checkDone() {
            if profileDone && doodlesDone {
                self.isLoading = false
                self.autoAssignBannerIfNeeded()
            }
        }
        UserProfileManager.shared.fetchProfile(userId: userId) { p in
            self.profile = p
            self.localFollowerCount = p?.followerCount ?? 0
            self.hasInitializedCount = true
            if let p = p, isOwnProfile {
                editUsername = p.username
                editTagline = p.tagline
                editBio = p.bio
                editLocation = p.location
                editIsPublic = p.isPublic
                editLinks = p.links
                editHeaderDoodleId = p.headerDoodleId
                bannerHeight = p.bannerHeight
            } else if let p = p {
                // Also load for viewing others' profiles
                bannerHeight = p.bannerHeight
            }
            profileDone = true
            checkDone()
        }
        fetchPublicDoodles(for: userId) { fetched in
            self.doodles = fetched
            doodlesDone = true
            checkDone()
        }
    }

    // MARK: - Save Actions

    func saveBanner(_ doodleId: String) {
        guard let uid = profile?.userId ?? (isOwnProfile ? SnoodleAuthManager.shared.userId : nil),
              let p = profile else { return }
        var updated = p
        updated.headerDoodleId = doodleId
        updated.backgroundStyle = doodleId.isEmpty ? .color : .doodle
        UserProfileManager.shared.saveProfile(userId: uid, username: p.username,
                                              avatar: p.avatar, photoURL: p.photoURL, extended: updated)
        UserProfileManager.shared.clearCache(for: uid)
        profile = updated
    }

    func saveBannerHeight() {
        guard let uid = profile?.userId ?? (isOwnProfile ? SnoodleAuthManager.shared.userId : nil),
              let p = profile else { return }
        var updated = p
        updated.bannerHeight = bannerHeight
        UserProfileManager.shared.saveProfile(userId: uid, username: p.username,
                                              avatar: p.avatar, photoURL: p.photoURL, extended: updated)
        UserProfileManager.shared.clearCache(for: uid)
        profile = updated
    }

    func saveInfo() {
        guard let uid = profile?.userId ?? (isOwnProfile ? SnoodleAuthManager.shared.userId : nil),
              let p = profile else { return }
        var updated = p
        updated.username = editUsername; updated.tagline = editTagline
        updated.bio = editBio; updated.location = editLocation
        updated.isPublic = editIsPublic; updated.links = editLinks
        UserProfileManager.shared.saveProfile(userId: uid, username: editUsername,
                                              avatar: p.avatar, photoURL: p.photoURL, extended: updated)
        UserProfileManager.shared.clearCache(for: uid)
        profile = updated
        UserDefaults.standard.set(editUsername, forKey: "snoodleUsername")
        SnoodleAuthManager.shared.needsProfileSetup = false
    }

    func savePhoto(_ photo: UIImage) {
        guard let uid = profile?.userId ?? (isOwnProfile ? SnoodleAuthManager.shared.userId : nil),
              let p = profile else { return }
        let thumbSize = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: thumbSize)
        let thumb = renderer.image { _ in photo.draw(in: CGRect(origin: .zero, size: thumbSize)) }
        guard let jpegData = thumb.jpegData(compressionQuality: 0.7) else { return }
        UserDefaults.standard.set(jpegData, forKey: "snoodleProfilePhoto")
        isSavingPhoto = true
        let storageRef = Storage.storage().reference().child("profile_photos/\(uid).jpg")
        let meta = StorageMetadata(); meta.contentType = "image/jpeg"
        storageRef.putData(jpegData, metadata: meta) { _, error in
            guard error == nil else { DispatchQueue.main.async { self.isSavingPhoto = false }; return }
            storageRef.downloadURL { url, _ in
                guard let downloadURL = url else { DispatchQueue.main.async { self.isSavingPhoto = false }; return }
                var updated = p; updated.photoURL = downloadURL.absoluteString
                UserProfileManager.shared.saveProfile(userId: uid, username: p.username,
                                                      avatar: "photo", photoURL: downloadURL.absoluteString,
                                                      extended: updated)
                UserProfileManager.shared.clearCache(for: uid)
                DispatchQueue.main.async { self.profile = updated; self.isSavingPhoto = false }
            }
        }
    }

    func saveGenericAvatar() {
        guard let uid = profile?.userId ?? (isOwnProfile ? SnoodleAuthManager.shared.userId : nil),
              let p = profile else { return }
        editPhoto = nil
        UserDefaults.standard.removeObject(forKey: "snoodleProfilePhoto")
        var updated = p; updated.photoURL = nil; updated.avatar = "silhouette"
        UserProfileManager.shared.saveProfile(userId: uid, username: p.username,
                                              avatar: "silhouette", photoURL: nil, extended: updated)
        UserProfileManager.shared.clearCache(for: uid)
        profile = updated
    }
}

// MARK: - Follow List Sheet

enum FollowListMode { case followers, following }

struct FollowListSheet: View {
    let userId: String
    let mode: FollowListMode
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var followManager = FollowManager.shared
    @State private var userIds: [String] = []
    @State private var profiles: [String: UserProfile] = [:]
    @State private var isLoading = true

    var title: String { mode == .followers ? "Followers" : "Following" }

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    VStack { Spacer(); ProgressView(); Spacer() }
                } else if userIds.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: mode == .followers ? "person.2" : "person.badge.plus")
                            .font(.system(size: 44)).foregroundColor(.secondary.opacity(0.3))
                        Text(mode == .followers ? "No followers yet" : "Not following anyone yet")
                            .foregroundColor(.secondary)
                    }
                } else {
                    List(userIds, id: \.self) { uid in
                        if let profile = profiles[uid] {
                            FollowListRow(profile: profile)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { loadList() }
        }
    }

    func loadList() {
        isLoading = true
        if mode == .followers {
            FollowManager.shared.fetchFollowers(userId: userId) { ids in
                self.userIds = ids
                loadProfiles(ids)
            }
        } else {
            FollowManager.shared.fetchFollowing(userId: userId) { ids in
                self.userIds = ids
                loadProfiles(ids)
            }
        }
    }

    func loadProfiles(_ ids: [String]) {
        guard !ids.isEmpty else { isLoading = false; return }
        UserProfileManager.shared.fetchProfiles(userIds: Set(ids)) { result in
            self.profiles = result
            self.isLoading = false
        }
    }
}

struct FollowListRow: View {
    let profile: UserProfile
    @ObservedObject private var followManager = FollowManager.shared
    @ObservedObject private var auth = SnoodleAuthManager.shared
    @State private var showProfile = false

    var isMe: Bool { auth.userId == profile.userId }
    var isFollowing: Bool { followManager.isFollowing(profile.userId) }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle().fill(Color(UIColor.systemGray5)).frame(width: 44, height: 44)
                if let urlStr = profile.photoURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44).clipShape(Circle())
                        } else {
                            Text(profile.avatar == "photo" || profile.avatar == "silhouette" || profile.avatar.isEmpty ? "👤" : profile.avatar)
                                .font(.system(size: 30))
                        }
                    }
                } else {
                    Text(profile.avatar == "photo" || profile.avatar == "silhouette" || profile.avatar.isEmpty ? "👤" : profile.avatar)
                        .font(.system(size: 30))
                }
            }

            // Name + tagline
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.username).font(.system(size: 15, weight: .semibold))
                if !profile.tagline.isEmpty {
                    Text(profile.tagline).font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            Spacer()

            // Follow button — only for other users
            if !isMe && auth.isSignedIn {
                Button(action: {
                    if isFollowing {
                        followManager.unfollow(targetUserId: profile.userId)
                    } else {
                        followManager.follow(targetUserId: profile.userId)
                    }
                }) {
                    Text(isFollowing ? "Following" : "Follow")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isFollowing ? .primary : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(isFollowing ? Color(UIColor.systemGray5) : Color.purple)
                        .cornerRadius(16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { showProfile = true }
        .sheet(isPresented: $showProfile) {
            PublicProfileView(userId: profile.userId, isOwnProfile: isMe)
                .presentationSizing(.page)
        }
    }
}

// MARK: - Link Editor Sheet

struct LinkEditorSheet: View {
    @Binding var link: ProfileLink?
    let onSave: (ProfileLink) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var platform: String = "website"
    @State private var url: String = ""
    let platforms = ["instagram", "tiktok", "youtube", "x", "facebook", "website"]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Platform")) {
                    Picker("Platform", selection: $platform) {
                        ForEach(platforms, id: \.self) { p in
                            let pl = ProfileLink(platform: p, url: "")
                            Label(pl.displayName, systemImage: pl.icon).tag(p)
                        }
                    }.pickerStyle(.wheel)
                }
                Section(header: Text("URL")) {
                    TextField("https://", text: $url)
                        .keyboardType(.URL).autocapitalization(.none)
                }
            }
            .navigationTitle("Add Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") { onSave(ProfileLink(platform: platform, url: url)); dismiss() }
                        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty).fontWeight(.semibold)
                }
            }
            .onAppear { platform = link?.platform ?? "website"; url = link?.url ?? "" }
        }
    }
}

// MARK: - Profile Editor

// MARK: - Profile Tab

struct ProfileTab: View {
    @StateObject private var auth = SnoodleAuthManager.shared

    var body: some View {
        if auth.isSignedIn {
            NavigationStack {
                if let uid = auth.userId {
                    PublicProfileView(userId: uid, isOwnProfile: true)
                }
            }
        } else {
            NavigationStack {
                SignInView()
            }
        }
    }
}

// MARK: - Profile Tab Icon


// MARK: - Submit Button
