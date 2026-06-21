//
//  SnoodleFirebase.swift
//  snoodle
//

import Foundation
import Combine
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import FirebaseMessaging
import AuthenticationServices
import CryptoKit
import UIKit
import SwiftUI

// MARK: - User Profile

struct ProfileLink: Codable, Equatable {
    var platform: String  // "instagram", "tiktok", "youtube", "x", "facebook", "website"
    var url: String

    var icon: String {
        switch platform {
        case "instagram":  return "camera"
        case "tiktok":     return "music.note"
        case "youtube":    return "play.rectangle"
        case "x":          return "at"
        case "facebook":   return "person.2"
        default:           return "globe"
        }
    }

    var displayName: String {
        switch platform {
        case "instagram":  return "Instagram"
        case "tiktok":     return "TikTok"
        case "youtube":    return "YouTube"
        case "x":          return "X"
        case "facebook":   return "Facebook"
        default:           return "Website"
        }
    }
}

enum ProfileBackgroundStyle: String {
    case color    = "color"
    case doodle   = "doodle"
    case gradient = "gradient"
}

enum ProfileLayoutStyle: String {
    case grid      = "grid"
    case scattered = "scattered"
    case chaos     = "chaos"
}

struct UserProfile {
    let userId: String
    var username: String
    var avatar: String
    var photoURL: String?
    var photoBase64: String?    // legacy — read-only fallback

    // Identity
    var tagline: String = ""
    var bio: String = ""
    var location: String = ""
    var links: [ProfileLink] = []

    // Visual customization
    var accentColor: String = "#A855F7"          // purple default
    var backgroundStyle: ProfileBackgroundStyle = .color
    var backgroundValue: String = "#FFFFFF"      // hex, doodle id, or gradient name
    var headerDoodleId: String = ""              // pinned featured doodle
    var pinnedDoodleIds: [String] = []
    var layoutStyle: ProfileLayoutStyle = .grid
    var gridSize: Int = 1                       // 0=small(4col) 1=medium(3col) 2=large(2col)
    var bannerHeight: CGFloat = 0               // 0 = use default; stored as Double in Firestore

    // Stats
    var followerCount: Int = 0
    var followingCount: Int = 0
    var joinedAt: Date = Date()
    var isPublic: Bool = true

    var avatarImage: UIImage? {
        if avatar == "photo",
           let data = UserDefaults.standard.data(forKey: "snoodleProfilePhoto") {
            return UIImage(data: data)
        }
        if let b64 = photoBase64, let data = Data(base64Encoded: b64) {
            return UIImage(data: data)
        }
        return nil
    }

    var accentSwiftUIColor: Color {
        Color(hex: accentColor) ?? .purple
    }
}

// MARK: - User Profile Manager

class UserProfileManager: ObservableObject {
    static let shared = UserProfileManager()

    private let db = Firestore.firestore()
    private let collection = "users"

    // In-memory cache: userId -> UserProfile
    @Published private var cache: [String: UserProfile] = [:]

    func saveProfile(userId: String, username: String, avatar: String, photoURL: String?, extended: UserProfile? = nil) {
        let resolvedAvatar = photoURL != nil ? "photo" : avatar
        UserDefaults.standard.set(username, forKey: "snoodleUsername")
        UserDefaults.standard.set(resolvedAvatar, forKey: "snoodleAvatar")

        var data: [String: Any] = [
            "username": username,
            "avatar": resolvedAvatar,
            "updatedAt": Timestamp(date: Date())
        ]
        if let url = photoURL {
            data["photoURL"] = url
        } else {
            data["photoURL"] = FieldValue.delete()
        }
        data["photoBase64"] = FieldValue.delete()

        // Extended profile fields
        if let p = extended {
            data["tagline"]          = p.tagline
            data["bio"]              = p.bio
            data["location"]         = p.location
            data["accentColor"]      = p.accentColor
            data["backgroundStyle"]  = p.backgroundStyle.rawValue
            data["backgroundValue"]  = p.backgroundValue
            data["headerDoodleId"]   = p.headerDoodleId
            data["pinnedDoodleIds"]  = p.pinnedDoodleIds
            data["layoutStyle"]      = p.layoutStyle.rawValue
            data["gridSize"]         = p.gridSize
            data["bannerHeight"]     = Double(p.bannerHeight)
            data["isPublic"]         = p.isPublic
            // Encode links as array of dicts
            data["links"] = p.links.map { ["platform": $0.platform, "url": $0.url] }
        }

        db.collection(collection).document(userId).setData(data, merge: true) { error in
            if let error = error {
                print("❌ saveProfile error: \(error)")
            } else {
                print("✅ saveProfile success for \(userId)")
            }
        }

        var updated = extended ?? UserProfile(userId: userId, username: username, avatar: avatar, photoURL: photoURL)
        updated = UserProfile(userId: userId, username: username, avatar: avatar, photoURL: photoURL,
                              tagline: extended?.tagline ?? "",
                              bio: extended?.bio ?? "",
                              location: extended?.location ?? "",
                              links: extended?.links ?? [],
                              accentColor: extended?.accentColor ?? "#A855F7",
                              backgroundStyle: extended?.backgroundStyle ?? .color,
                              backgroundValue: extended?.backgroundValue ?? "#FFFFFF",
                              headerDoodleId: extended?.headerDoodleId ?? "",
                              pinnedDoodleIds: extended?.pinnedDoodleIds ?? [],
                              layoutStyle: extended?.layoutStyle ?? .grid,
                              gridSize: extended?.gridSize ?? 1,
                              bannerHeight: extended?.bannerHeight ?? 0,
                              followerCount: extended?.followerCount ?? 0,
                              followingCount: extended?.followingCount ?? 0,
                              isPublic: extended?.isPublic ?? true)
        cache[userId] = updated
    }

    // Parse a full UserProfile from a Firestore document dictionary
    func parseProfilePublic(userId: String, data: [String: Any]) -> UserProfile? {
        return parseProfile(userId: userId, data: data)
    }

    private func parseProfile(userId: String, data: [String: Any]) -> UserProfile {
        let links = (data["links"] as? [[String: String]] ?? []).compactMap { d -> ProfileLink? in
            guard let platform = d["platform"], let url = d["url"] else { return nil }
            return ProfileLink(platform: platform, url: url)
        }
        let joinedAt = (data["joinedAt"] as? Timestamp)?.dateValue() ?? Date()
        return UserProfile(
            userId: userId,
            username: data["username"] as? String ?? "Anonymous",
            avatar: (data["photoURL"] as? String) != nil && (data["avatar"] as? String ?? "").isEmpty ? "photo" : (data["avatar"] as? String ?? ""),
            photoURL: data["photoURL"] as? String,
            photoBase64: data["photoBase64"] as? String,
            tagline: data["tagline"] as? String ?? "",
            bio: data["bio"] as? String ?? "",
            location: data["location"] as? String ?? "",
            links: links,
            accentColor: data["accentColor"] as? String ?? "#A855F7",
            backgroundStyle: ProfileBackgroundStyle(rawValue: data["backgroundStyle"] as? String ?? "") ?? .color,
            backgroundValue: data["backgroundValue"] as? String ?? "#FFFFFF",
            headerDoodleId: data["headerDoodleId"] as? String ?? "",
            pinnedDoodleIds: data["pinnedDoodleIds"] as? [String] ?? [],
            layoutStyle: ProfileLayoutStyle(rawValue: data["layoutStyle"] as? String ?? "") ?? .grid,
            gridSize: data["gridSize"] as? Int ?? 1,
            bannerHeight: CGFloat(data["bannerHeight"] as? Double ?? 0),
            followerCount: data["followerCount"] as? Int ?? 0,
            followingCount: data["followingCount"] as? Int ?? 0,
            joinedAt: joinedAt,
            isPublic: data["isPublic"] as? Bool ?? true
        )
    }

    func loadProfile(userId: String, completion: (() -> Void)? = nil) {
        db.collection(collection).document(userId).getDocument { [weak self] snapshot, _ in
            guard let self = self, let data = snapshot?.data() else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let profile = self.parseProfile(userId: userId, data: data)
            DispatchQueue.main.async {
                if !profile.username.isEmpty {
                    UserDefaults.standard.set(profile.username, forKey: "snoodleUsername")
                }
                UserDefaults.standard.set(profile.avatar, forKey: "snoodleAvatar")
                if profile.photoURL == nil, let b64 = profile.photoBase64,
                   let imgData = Data(base64Encoded: b64) {
                    UserDefaults.standard.set(imgData, forKey: "snoodleProfilePhoto")
                }
                // Restore photo from Storage URL if local cache is missing
                if profile.avatar == "photo",
                   UserDefaults.standard.data(forKey: "snoodleProfilePhoto") == nil,
                   let urlStr = profile.photoURL,
                   let url = URL(string: urlStr) {
                    URLSession.shared.dataTask(with: url) { data, _, _ in
                        if let data = data {
                            DispatchQueue.main.async {
                                UserDefaults.standard.set(data, forKey: "snoodleProfilePhoto")
                                NotificationCenter.default.post(name: .snoodleProfilePhotoRestored, object: nil)
                            }
                        }
                    }.resume()
                }
                self.cache[userId] = profile
                completion?()
            }
        }
    }

    // Fetch multiple user profiles by userId, using cache where possible
    func fetchProfiles(userIds: Set<String>, completion: @escaping ([String: UserProfile]) -> Void) {
        let uncached = userIds.filter { cache[$0] == nil }

        if uncached.isEmpty {
            let result = Dictionary(uniqueKeysWithValues: userIds.compactMap { id -> (String, UserProfile)? in
                guard let p = cache[id] else { return nil }
                return (id, p)
            })
            completion(result)
            return
        }

        print("👤 fetchProfiles: looking up \(uncached.count) uncached userIds: \(uncached)")
        let batches = Array(uncached).chunked(into: 30)
        var fetched: [String: UserProfile] = [:]
        let group = DispatchGroup()

        for batch in batches {
            group.enter()
            db.collection(collection)
                .whereField(FieldPath.documentID(), in: batch)
                .getDocuments { [weak self] snapshot, error in
                    defer { group.leave() }
                    guard let self = self else { return }
                    if let error = error {
                        print("👤 fetchProfiles: ERROR \(error.localizedDescription)")
                    }
                    let docs = snapshot?.documents ?? []
                    print("👤 fetchProfiles: got \(docs.count) profile docs for batch \(batch)")
                    docs.forEach { doc in
                        let profile = self.parseProfile(userId: doc.documentID, data: doc.data())
                        print("👤 fetchProfiles: resolved \(doc.documentID) → '\(profile.username)'")
                        fetched[doc.documentID] = profile
                        self.cache[doc.documentID] = profile
                    }
                    let foundIds = Set(docs.map { $0.documentID })
                    for id in batch where !foundIds.contains(id) {
                        print("👤 fetchProfiles: ⚠️ NO profile doc for userId=\(id)")
                    }
                }
        }

        group.notify(queue: .main) {
            var result: [String: UserProfile] = [:]
            for id in userIds {
                if let p = fetched[id] ?? self.cache[id] {
                    result[id] = p
                }
            }
            completion(result)
        }
    }

    func getCached(_ userId: String) -> UserProfile? {
        return cache[userId]
    }

    func clearCache(for userId: String) {
        cache.removeValue(forKey: userId)
    }

    /// Fetch any user's full profile by userId — used for public profile pages
    func fetchProfile(userId: String, completion: @escaping (UserProfile?) -> Void) {
        // Always fetch fresh from Firestore for full profile data
        db.collection(collection).document(userId).getDocument { [weak self] snapshot, _ in
            guard let self = self, let data = snapshot?.data() else {
                // Fall back to cache if network fails
                DispatchQueue.main.async { completion(self?.cache[userId]) }
                return
            }
            let profile = self.parseProfile(userId: userId, data: data)
            DispatchQueue.main.async {
                self.cache[userId] = profile
                completion(profile)
            }
        }
    }

    /// Loads profile from Firestore; if no document exists yet, creates one
    /// from whatever username/avatar is stored in UserDefaults.
    func loadOrCreateProfile(userId: String) {
        db.collection(collection).document(userId).getDocument { [weak self] snapshot, _ in
            guard let self = self else { return }
            if let data = snapshot?.data(), !data.isEmpty {
                let profile = self.parseProfile(userId: userId, data: data)
                DispatchQueue.main.async {
                    if !profile.username.isEmpty {
                        UserDefaults.standard.set(profile.username, forKey: "snoodleUsername")
                    }
                    UserDefaults.standard.set(profile.avatar, forKey: "snoodleAvatar")
                    if profile.photoURL == nil, let b64 = profile.photoBase64,
                       let imgData = Data(base64Encoded: b64) {
                        UserDefaults.standard.set(imgData, forKey: "snoodleProfilePhoto")
                        self.migratePhotoToStorage(userId: userId, imageData: imgData,
                                                   username: profile.username, avatar: profile.avatar)
                    }
                    // Restore photo from Storage URL if local cache is missing
                    if profile.avatar == "photo",
                       UserDefaults.standard.data(forKey: "snoodleProfilePhoto") == nil,
                       let urlStr = profile.photoURL,
                       let url = URL(string: urlStr) {
                        URLSession.shared.dataTask(with: url) { data, _, _ in
                            if let data = data {
                                DispatchQueue.main.async {
                                    UserDefaults.standard.set(data, forKey: "snoodleProfilePhoto")
                                    NotificationCenter.default.post(name: .snoodleProfilePhotoRestored, object: nil)
                                }
                            }
                        }.resume()
                    }
                    self.cache[userId] = profile
                    // Always re-inject the tab icon after profile loads
                    NotificationCenter.default.post(name: .snoodleProfilePhotoRestored, object: nil)
                }
            } else {
                // No doc exists — new user. Create a default profile document immediately.
                let defaultUsername = "doodler\(Int.random(in: 1000...9999))"
                let defaultData: [String: Any] = [
                    "username": defaultUsername,
                    "avatar": "🎨",
                    "bio": "",
                    "tagline": "",
                    "location": "",
                    "accentColor": "#A855F7",
                    "backgroundStyle": "color",
                    "backgroundValue": "#FFFFFF",
                    "headerDoodleId": "",
                    "pinnedDoodleIds": [],
                    "layoutStyle": "grid",
                    "isPublic": true,
                    "links": [],
                    "updatedAt": Timestamp(date: Date())
                ]
                Firestore.firestore().collection("users").document(userId).setData(defaultData) { _ in
                    DispatchQueue.main.async {
                        SnoodleAuthManager.shared.needsProfileSetup = true
                    }
                }
            }
        }
    }

    /// Uploads a legacy base64 photo to Storage and updates the Firestore doc.
    private func migratePhotoToStorage(userId: String, imageData: Data, username: String, avatar: String) {
        let storageRef = Storage.storage().reference().child("profile_photos/\(userId).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        print("🔄 Uploading \(imageData.count) bytes to Storage path: profile_photos/\(userId).jpg")
        storageRef.putData(imageData, metadata: metadata) { [weak self] _, error in
            if let error = error {
                print("❌ Migration upload failed: \(error.localizedDescription)")
                return
            }
            guard let self = self else { return }
            print("🔄 Upload succeeded — fetching download URL")
            storageRef.downloadURL { [weak self] url, error in
                if let error = error {
                    print("❌ Migration downloadURL failed: \(error.localizedDescription)")
                    return
                }
                guard let self = self, let downloadURL = url else {
                    print("❌ Migration downloadURL was nil")
                    return
                }
                print("✅ Migration complete — photoURL: \(downloadURL.absoluteString)")
                self.saveProfile(userId: userId, username: username, avatar: avatar,
                                 photoURL: downloadURL.absoluteString)
            }
        }
    }

    /// Saves just the layout/gridSize preferences — used when artist changes their profile display.
    func saveLayoutPreferences(userId: String, layout: ProfileLayoutStyle, gridSize: Int) {
        db.collection(collection).document(userId).updateData([
            "layoutStyle": layout.rawValue,
            "gridSize": gridSize
        ])
        if var cached = cache[userId] {
            cached.layoutStyle = layout
            cached.gridSize = gridSize
            cache[userId] = cached
        }
    }

    /// Creates a Firestore user document only if one doesn't already exist.
    func createIfMissing(userId: String, username: String, avatar: String) {
        db.collection(collection).document(userId).getDocument { [weak self] snapshot, _ in
            guard let self = self else { return }
            if snapshot?.data() == nil || snapshot?.data()?.isEmpty == true {
                self.saveProfile(userId: userId, username: username, avatar: avatar, photoURL: nil)
            }
        }
    }
}

// Array chunking helper
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - World Snoodle

struct WorldSnoodle: Identifiable {
    let id: String
    let caption: String
    let keywords: [String]
    let timestamp: Date
    let userId: String
    let imageURL: String        // Firebase Storage CDN download URL
    var likes: Int
    var commentCount: Int = 0
    var isLikedByMe: Bool = false

    // Stored so SwiftUI detects change when profiles resolve
    var username: String = "Anonymous"
    var avatar: String = ""
    var authorPhotoURL: URL? = nil
    var authorImage: UIImage? = nil

    var imageStorageURL: URL? { URL(string: imageURL) }

    // Stamp in resolved profile data so the struct actually changes value
    mutating func applyProfile(_ profile: UserProfile?) {
        guard let profile = profile else { return }
        username = profile.username
        avatar = profile.avatar
        if let urlString = profile.photoURL {
            authorPhotoURL = URL(string: urlString)
        }
        authorImage = profile.avatarImage
    }
}

// MARK: - Auth Manager

@MainActor
class SnoodleAuthManager: NSObject, ObservableObject {
    static let shared = SnoodleAuthManager()

    @Published var isSignedIn: Bool = false
    @Published var userId: String? = nil
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    @Published var needsProfileSetup: Bool = false
    private var authStateListener: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?

    override init() {
        super.init()
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.isSignedIn = user != nil
                self?.userId = user?.uid
                if let uid = user?.uid {
                    // Load follow graph whenever a user signs in
                    FollowManager.shared.loadFollowing(for: uid)
                    // Load profile and create Firestore record if missing
                    UserProfileManager.shared.loadOrCreateProfile(userId: uid)
                    // Save FCM token now that we have a userId
                    // flushPendingFCMToken handles token-before-auth race condition
                    NotificationManager.shared.flushPendingFCMToken()
                    if let token = Messaging.messaging().fcmToken {
                        NotificationManager.shared.saveFCMToken(token)
                    }
                } else {
                    // Signed out — clear follow state
                    FollowManager.shared.clear()
                }
            }
        }
    }

    var username: String {
        UserDefaults.standard.string(forKey: "snoodleUsername") ?? "Anonymous"
    }

    var avatar: String {
        UserDefaults.standard.string(forKey: "snoodleAvatar") ?? ""
    }

    func handleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
        isLoading = true
        errorMessage = nil
    }

    func handleSignInCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            handleAuthorization(auth)
        case .failure(let error):
            isLoading = false
            let nsError = error as NSError
            if !(nsError.domain == "com.apple.AuthenticationServices.AuthorizationError" && nsError.code == 1001) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleAuthorization(_ authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let nonce = currentNonce,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            isLoading = false
            return
        }
        let firebaseCred = OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: credential.fullName)
        Task {
            do {
                _ = try await Auth.auth().signIn(with: firebaseCred)
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
        UserDefaults.standard.removeObject(forKey: "snoodleUsername")
        UserDefaults.standard.removeObject(forKey: "snoodleAvatar")
        UserDefaults.standard.removeObject(forKey: "snoodleProfilePhoto")
    }

    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

extension SnoodleAuthManager: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return MainActor.assumeIsolated {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else {
                return UIWindow()
            }
            return window
        }
    }
}

// MARK: - World Gallery Manager

/// Fetches all public doodles for a specific user — used on public profile pages
func fetchPublicDoodles(for userId: String, completion: @escaping ([WorldSnoodle]) -> Void) {
    let db = Firestore.firestore()
    db.collection("world_gallery")
        .whereField("userId", isEqualTo: userId)
        .order(by: "timestamp", descending: true)
        .limit(to: 200)
        .getDocuments { snapshot, _ in
            guard let docs = snapshot?.documents else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let snoodles = docs.compactMap { doc -> WorldSnoodle? in
                let d = doc.data()
                guard let imageURL = d["imageURL"] as? String,
                      let ts = d["timestamp"] as? Timestamp else { return nil }
                return WorldSnoodle(
                    id: doc.documentID,
                    caption: d["caption"] as? String ?? "",
                    keywords: d["keywords"] as? [String] ?? [],
                    timestamp: ts.dateValue(),
                    userId: d["userId"] as? String ?? "",
                    imageURL: imageURL,
                    likes: d["likes"] as? Int ?? 0,
                    commentCount: d["commentCount"] as? Int ?? 0
                )
            }
            DispatchQueue.main.async {
                // Apply cached profile so username/avatar are populated immediately.
                // If not cached yet, fetch it and patch the snoodles on return.
                let mgr = UserProfileManager.shared
                if mgr.getCached(userId) != nil {
                    let patched = snoodles.map { s -> WorldSnoodle in
                        var e = s; e.applyProfile(mgr.getCached(e.userId)); return e
                    }
                    completion(patched)
                } else {
                    mgr.fetchProfiles(userIds: Set([userId])) { _ in
                        let patched = snoodles.map { s -> WorldSnoodle in
                            var e = s; e.applyProfile(mgr.getCached(e.userId)); return e
                        }
                        completion(patched)
                    }
                }
            }
        }
}

enum WorldSortOrder { case recent, trending }

class WorldGalleryManager: ObservableObject {
    static let shared = WorldGalleryManager()

    @Published var entries: [WorldSnoodle] = []
    @Published var totalCount: Int = 0
    @Published var topArtistEntries: [WorldSnoodle] = []  // always from .everyone query, drives artist strip
    @Published var isLoading: Bool = false
    @Published var sortOrder: WorldSortOrder = .recent

    enum FeedQuery: Equatable {
        case everyone
        case artist(String)
        case following([String])
        case search(String)
    }
    private(set) var currentQuery: FeedQuery = .everyone

    // Hacker News-style heat score: (likes + comments*2) / (hours_old + 2)^1.5
    func trendingScore(_ entry: WorldSnoodle) -> Double {
        let hoursOld = max(0, -entry.timestamp.timeIntervalSinceNow / 3600)
        let votes = Double(entry.likes + entry.commentCount * 2)
        return votes / pow(hoursOld + 2, 1.5)
    }
    @Published var pendingShowWorld: Bool = false
    @Published var pendingShowPrivate: Bool = false
    @Published var scrollToTopTrigger: Int = 0
    @Published var accountSwitchTrigger: Int = 0

    private let db = Firestore.firestore()
    private let storage = Storage.storage()
    private let collection = "world_gallery"


    private var lastFetch: Date?
    private var lastDocumentSnapshot: QueryDocumentSnapshot? = nil
    private var listenerRegistration: ListenerRegistration? = nil
    private let pageSize = 20

    var isFetchStale: Bool {
        guard let lastFetch else { return true }
        return Date().timeIntervalSince(lastFetch) > 30
    }

    var sortedEntries: [WorldSnoodle] {
        switch sortOrder {
        case .recent: return entries
        case .trending: return entries.sorted { trendingScore($0) > trendingScore($1) }
        }
    }

    /// Start a real-time listener for the first page. New documents appear
    /// automatically without polling — no more "3-4 tries to see your post".
    func startListening() {
        // Disabled — use simpleFetch() instead
        simpleFetch()
    }

    /// Simple one-shot fetch.
    func setQuery(_ query: FeedQuery) {
        guard query != currentQuery || entries.isEmpty else { return }
        currentQuery = query
        entries = []
        lastDocumentSnapshot = nil
        switch query {
        case .everyone:
            simpleFetch()
        case .artist(let userId):
            fetchArtist(userId: userId)
        case .following(let userIds):
            fetchFollowing(userIds: userIds)
        case .search(let term):
            fetchSearch(term)
        }
    }

    func refresh() async {
        await withCheckedContinuation { continuation in
            stopListening()
            isLoading = false  // reset in case stuck
            db.collection(collection)
                .order(by: "timestamp", descending: true)
                .limit(to: pageSize)
                .getDocuments { [weak self] snapshot, _ in
                    guard let self = self else { continuation.resume(); return }
                    DispatchQueue.main.async {
                        self.isLoading = false
                        guard let docs = snapshot?.documents else { continuation.resume(); return }
                        self.lastDocumentSnapshot = docs.last
                        self.currentQuery = .everyone
                        let snoodles = self.parseDocuments(docs)
                        self.entries = snoodles
                        self.lastFetch = Date()
                        self.applyProfilesAndLikes(to: snoodles)
                        self.fetchTopArtistEntries()
                        continuation.resume()
                    }
                }
        }
    }

    func simpleFetch() {
        guard !isLoading else { return }
        stopListening()
        isLoading = true
        db.collection(collection)
            .order(by: "timestamp", descending: true)
            .limit(to: pageSize)
            .getDocuments { [weak self] snapshot, error in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isLoading = false
                    if error != nil {
                        return
                    }
                    guard let docs = snapshot?.documents else { return }
                    self.lastDocumentSnapshot = docs.last
                    let snoodles = self.parseDocuments(docs)
                    self.entries = snoodles
                    self.lastFetch = Date()
                    self.syncLocalSubmittedFlags(worldIds: Set(self.entries.map { $0.id }))
                    self.applyProfilesAndLikes(to: snoodles)
                    self.fetchTopArtistEntries()
                    self.fetchTotalCount()
                }
            }
    }

    func stopListening() {
        listenerRegistration?.remove()
        listenerRegistration = nil
    }

    /// Fetch the true total count for the current query using Firestore aggregation.
    func fetchTotalCount() {
        switch currentQuery {
        case .everyone:
            db.collection(collection)
                .count.getAggregation(source: .server) { [weak self] snapshot, _ in
                    guard let self = self, let count = snapshot?.count else { return }
                    DispatchQueue.main.async { self.totalCount = count.intValue }
                }
        case .artist(let userId):
            db.collection(collection)
                .whereField("userId", isEqualTo: userId)
                .count.getAggregation(source: .server) { [weak self] snapshot, _ in
                    guard let self = self, let count = snapshot?.count else { return }
                    DispatchQueue.main.async { self.totalCount = count.intValue }
                }
        case .search(let term):
            let primaryTerm = term.lowercased().trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces).first(where: { !$0.isEmpty }) ?? term.lowercased()
            db.collection(collection)
                .whereField("searchIndex", arrayContains: primaryTerm)
                .count.getAggregation(source: .server) { [weak self] snapshot, _ in
                    guard let self = self, let count = snapshot?.count else { return }
                    DispatchQueue.main.async { self.totalCount = count.intValue }
                }
        case .following(let userIds):
            guard !userIds.isEmpty else { DispatchQueue.main.async { self.totalCount = 0 }; return }
            // Firestore count with `in` — split into batches of 30
            let batches = userIds.chunked(into: 30)
            var total = 0
            let group = DispatchGroup()
            for batch in batches {
                group.enter()
                db.collection(collection)
                    .whereField("userId", in: batch)
                    .count.getAggregation(source: .server) { [weak self] snapshot, _ in
                        defer { group.leave() }
                        if let count = snapshot?.count { total += count.intValue }
                    }
            }
            group.notify(queue: .main) { [weak self] in
                self?.totalCount = total
            }
        }
    }

    /// Fetches the top 100 most-liked doodles specifically to power the Top Artists strip.
    /// Called once on launch/refresh — independent of pagination.
    func fetchTopArtistEntries() {
        db.collection(collection)
            .order(by: "likes", descending: true)
            .limit(to: 100)
            .getDocuments { [weak self] snapshot, _ in
                guard let self = self,
                      let docs = snapshot?.documents,
                      !docs.isEmpty else { return }
                DispatchQueue.main.async {
                    let snoodles = self.parseDocuments(docs)
                    self.topArtistEntries = snoodles
                    let userIds = Set(snoodles.map { $0.userId })
                    UserProfileManager.shared.fetchProfiles(userIds: userIds) { _ in }
                }
            }
    }

    /// One-time admin backfill: writes searchIndex to any world_gallery doc that lacks it.
    /// Call once from SettingsTab Debug section, then remove the button.
    func backfillSearchIndex() async -> String {
        guard let snapshot = try? await db.collection(collection).getDocuments() else {
            return "Failed to fetch documents"
        }
        var updated = 0
        for doc in snapshot.documents {
            let data = doc.data()
            if data["searchIndex"] != nil { continue }  // already has it
            let caption = (data["caption"] as? String ?? "").lowercased()
            let keywords = data["keywords"] as? [String] ?? []
            let captionWords = caption
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
            let keywordsLower = keywords.map { $0.lowercased() }
            let searchIndex = Array(Set(captionWords + keywordsLower)).filter { !$0.isEmpty }
            try? await doc.reference.updateData(["searchIndex": searchIndex])
            updated += 1
        }
        return "Done: \(updated) of \(snapshot.documents.count) docs updated"
    }

    private func applyProfilesAndLikes(to snoodles: [WorldSnoodle]) {
        let userIds = Set(snoodles.map { $0.userId })
        UserProfileManager.shared.fetchProfiles(userIds: userIds) { _ in
            self.entries = self.entries.map { entry in
                var e = entry
                e.applyProfile(UserProfileManager.shared.getCached(e.userId))
                return e
            }
            self.fetchLikedIds(for: snoodles) { likedIds in
                self.entries = self.entries.map { entry in
                    var e = entry
                    if likedIds.contains(e.id) { e.isLikedByMe = true }
                    return e
                }
                NotificationCenter.default.post(name: .snoodleProfilePhotoRestored, object: nil)
            }
        }
    }

    private func fetchArtist(userId: String) {
        guard !isLoading else { return }
        isLoading = true
        db.collection(collection)
            .whereField("userId", isEqualTo: userId)
            .order(by: "timestamp", descending: true)
            .limit(to: pageSize)
            .getDocuments { [weak self] snapshot, _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isLoading = false
                    guard let docs = snapshot?.documents else { return }
                    self.lastDocumentSnapshot = docs.last
                    let snoodles = self.parseDocuments(docs)
                    self.entries = snoodles
                    self.applyProfilesAndLikes(to: snoodles)
                    self.fetchTotalCount()
                }
            }
    }

    private func fetchFollowing(userIds: [String]) {
        guard !isLoading, !userIds.isEmpty else {
            isLoading = false
            return
        }
        isLoading = true
        let batches = userIds.chunked(into: 30)
        var allSnoodles: [WorldSnoodle] = []
        let group = DispatchGroup()

        for batch in batches {
            group.enter()
            db.collection(collection)
                .whereField("userId", in: batch)
                .order(by: "timestamp", descending: true)
                .limit(to: pageSize)
                .getDocuments { [weak self] snapshot, _ in
                    defer { group.leave() }
                    guard let self = self else { return }
                    let snoodles = self.parseDocuments(snapshot?.documents ?? [])
                    allSnoodles.append(contentsOf: snoodles)
                }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.isLoading = false
            let sorted = allSnoodles.sorted { $0.timestamp > $1.timestamp }
            self.entries = sorted
            self.applyProfilesAndLikes(to: sorted)
            self.fetchTotalCount()
        }
    }

    private func fetchSearch(_ term: String) {
        guard !isLoading else { return }
        let termLower = term.lowercased().trimmingCharacters(in: .whitespaces)
        // Use the first word for array-contains; GalleryTab applies secondary filter for additional words
        let primaryTerm = termLower.components(separatedBy: .whitespaces).first(where: { !$0.isEmpty }) ?? termLower
        guard !primaryTerm.isEmpty else { return }
        isLoading = true
        db.collection(collection)
            .whereField("searchIndex", arrayContains: primaryTerm)
            .order(by: "timestamp", descending: true)
            .limit(to: pageSize)
            .getDocuments { [weak self] snapshot, _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.isLoading = false
                    guard let docs = snapshot?.documents else { return }
                    self.lastDocumentSnapshot = docs.last
                    let snoodles = self.parseDocuments(docs)
                    self.entries = snoodles
                    self.lastFetch = Date()
                    self.applyProfilesAndLikes(to: snoodles)
                    self.fetchTotalCount()
                }
            }
    }

    /// Fetch the next page and append to entries (called as user scrolls to bottom).
    /// Respects the active query so artist/following filters stay scoped on pagination.
    func fetchNextPage() {
        guard entries.count % pageSize == 0, entries.count > 0 else { return }
        guard !isLoading else { return }

        switch currentQuery {
        case .everyone:
            guard let lastDoc = lastDocumentSnapshot else { return }
            isLoading = true
            db.collection(collection)
                .order(by: "timestamp", descending: true)
                .limit(to: pageSize)
                .start(afterDocument: lastDoc)
                .getDocuments { [weak self] snapshot, _ in
                    self?.appendNextPage(snapshot?.documents)
                }

        case .artist(let userId):
            guard let lastDoc = lastDocumentSnapshot else { return }
            isLoading = true
            db.collection(collection)
                .whereField("userId", isEqualTo: userId)
                .order(by: "timestamp", descending: true)
                .limit(to: pageSize)
                .start(afterDocument: lastDoc)
                .getDocuments { [weak self] snapshot, _ in
                    self?.appendNextPage(snapshot?.documents)
                }

        case .search(let term):
            guard let lastDoc = lastDocumentSnapshot else { return }
            let primaryTerm = term.lowercased().trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces).first(where: { !$0.isEmpty }) ?? term.lowercased()
            isLoading = true
            db.collection(collection)
                .whereField("searchIndex", arrayContains: primaryTerm)
                .order(by: "timestamp", descending: true)
                .limit(to: pageSize)
                .start(afterDocument: lastDoc)
                .getDocuments { [weak self] snapshot, _ in
                    self?.appendNextPage(snapshot?.documents)
                }

        case .following(let userIds):
            // Following uses timestamp-based pagination (can't share a cursor across batched `in` queries)
            guard !userIds.isEmpty, let lastTimestamp = entries.last?.timestamp else { return }
            isLoading = true
            let batches = userIds.chunked(into: 30)
            var allNew: [WorldSnoodle] = []
            let group = DispatchGroup()
            for batch in batches {
                group.enter()
                db.collection(collection)
                    .whereField("userId", in: batch)
                    .whereField("timestamp", isLessThan: Timestamp(date: lastTimestamp))
                    .order(by: "timestamp", descending: true)
                    .limit(to: pageSize)
                    .getDocuments { [weak self] snapshot, _ in
                        defer { group.leave() }
                        guard let self = self else { return }
                        allNew.append(contentsOf: self.parseDocuments(snapshot?.documents ?? []))
                    }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                self.isLoading = false
                let page = Array(allNew.sorted { $0.timestamp > $1.timestamp }.prefix(self.pageSize))
                guard !page.isEmpty else { return }
                self.entries.append(contentsOf: page)
                self.lastFetch = Date()
                self.postPageProfilesAndLikes(page)
            }
        }
    }

    /// Shared handler for cursor-based next-page results (.everyone and .artist).
    private func appendNextPage(_ docs: [QueryDocumentSnapshot]?) {
        DispatchQueue.main.async {
            self.isLoading = false
            guard let docs = docs, !docs.isEmpty else { return }
            self.lastDocumentSnapshot = docs.last
            let newSnoodles = self.parseDocuments(docs)
            self.entries.append(contentsOf: newSnoodles)
            self.lastFetch = Date()
            self.postPageProfilesAndLikes(newSnoodles)
        }
    }

    /// Loads profiles and like state for a newly fetched page, then patches self.entries.
    private func postPageProfilesAndLikes(_ page: [WorldSnoodle]) {
        let userIds = Set(page.map { $0.userId })
        UserProfileManager.shared.fetchProfiles(userIds: userIds) { _ in
            self.entries = self.entries.map { entry in
                var e = entry
                if e.username == "Anonymous" {
                    e.applyProfile(UserProfileManager.shared.getCached(e.userId))
                }
                return e
            }
            self.fetchLikedIds(for: page) { likedIds in
                self.entries = self.entries.map { entry in
                    var e = entry
                    if likedIds.contains(e.id) { e.isLikedByMe = true }
                    return e
                }
            }
        }
    }

    /// Full refresh — clears entries and (re)starts the live listener.
    /// The snapshot listener fires immediately with current Firestore data,
    /// so a separate simpleFetch() pass is unnecessary and was causing a
    /// race where the deferred startListening() would set isLoading = true
    /// *after* the one-shot fetch had already cleared it.
    func fetchRecent(accountSwitch: Bool = false) {
        stopListening()
        entries = []
        isLoading = false   // must be false so simpleFetch() guard passes
        lastDocumentSnapshot = nil
        scrollToTopTrigger += 1
        if accountSwitch { accountSwitchTrigger += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.simpleFetch()
        }
    }

    private func parseDocuments(_ docs: [QueryDocumentSnapshot]) -> [WorldSnoodle] {
        docs.compactMap { doc -> WorldSnoodle? in
            let d = doc.data()
            guard let userId = d["userId"] as? String,
                  let imageURL = d["imageURL"] as? String,
                  let ts = d["timestamp"] as? Timestamp else { return nil }
            var snoodle = WorldSnoodle(
                id: doc.documentID,
                caption: d["caption"] as? String ?? "",
                keywords: d["keywords"] as? [String] ?? [],
                timestamp: ts.dateValue(),
                userId: userId,
                imageURL: imageURL,
                likes: d["likes"] as? Int ?? 0,
                commentCount: d["commentCount"] as? Int ?? 0
            )
            // Stamp in profile if already cached (warm cache — tab switch, pagination)
            snoodle.applyProfile(UserProfileManager.shared.getCached(userId))
            return snoodle
        }
    }

    /// Merge incoming snoodles into entries, preserving like state for existing ones.
    private func mergeEntries(_ incoming: [WorldSnoodle]) {
        var merged = incoming
        for i in merged.indices {
            if let existing = entries.first(where: { $0.id == merged[i].id }) {
                merged[i].isLikedByMe = existing.isLikedByMe
            }
        }
        // Keep any older pages that aren't in the first-page snapshot
        let incomingIds = Set(incoming.map { $0.id })
        let olderPages = entries.filter { !incomingIds.contains($0.id) }
        entries = merged + olderPages
    }

    private func fetchLikedIds(for snoodles: [WorldSnoodle], completion: @escaping (Set<String>) -> Void) {
        guard let userId = Auth.auth().currentUser?.uid else {
            print("❤️ fetchLikedIds: NO userId — returning empty (auth not ready?)")
            completion([])
            return
        }
        print("❤️ fetchLikedIds: checking subcollection for \(snoodles.count) doodles")
        let group = DispatchGroup()
        var likedIds = Set<String>()

        for snoodle in snoodles {
            group.enter()
            db.collection(collection).document(snoodle.id)
                .collection("likes").document(userId)
                .getDocument { snapshot, _ in
                    defer { group.leave() }
                    if snapshot?.exists == true { likedIds.insert(snoodle.id) }
                }
        }

        group.notify(queue: .main) {
            print("❤️ fetchLikedIds: found \(likedIds.count) liked doodles")
            completion(likedIds)
        }
    }

    func toggleLike(for snoodle: WorldSnoodle) {
        guard let userId = Auth.auth().currentUser?.uid else {
            print("❤️ toggleLike: no userId")
            return
        }
        let likeRef = db.collection(collection).document(snoodle.id)
            .collection("likes").document(userId)
        let snoodleRef = db.collection(collection).document(snoodle.id)

        guard let idx = entries.firstIndex(where: { $0.id == snoodle.id }) else {
            print("❤️ toggleLike: could not find \(snoodle.id) in entries (\(entries.count) entries)")
            return
        }
        let currentlyLiked = entries[idx].isLikedByMe
        print("❤️ toggleLike: doodleId=\(snoodle.id) currentlyLiked=\(currentlyLiked)")

        if currentlyLiked {
            entries[idx].isLikedByMe = false
            entries[idx].likes = max(0, entries[idx].likes - 1)
            likeRef.delete()
            snoodleRef.updateData(["likes": FieldValue.increment(Int64(-1))])
        } else {
            entries[idx].isLikedByMe = true
            entries[idx].likes += 1
            likeRef.setData(["userId": userId, "timestamp": Timestamp(date: Date())]) { error in
                if let error = error {
                    print("❤️ toggleLike: WRITE FAILED \(error)")
                } else {
                    print("❤️ toggleLike: write SUCCESS to \(self.collection)/\(snoodle.id)/likes/\(userId)")
                }
            }
            snoodleRef.updateData(["likes": FieldValue.increment(Int64(1))]) { error in
                if let error = error { print("❤️ toggleLike: counter update FAILED \(error)") }
            }
        }
    }

    /// Fetches ALL world_gallery docs for the current user, then does a full
    /// two-way reconciliation of isSubmitted flags.
    ///
    /// Matching strategy:
    ///   1. If local entry has worldGalleryId → match directly by doc ID
    ///   2. If worldGalleryId was cleared (by old pagination bug) → match by
    ///      imageURL containing the entry's UUID (Storage path uses entry.id)
    ///
    /// Result: restores wrongly-cleared globe markers, clears genuinely deleted ones,
    /// and writes back the worldGalleryId for any entry that was missing it.
    func syncLocalSubmittedFlags(worldIds: Set<String>) {
        let store = SnoodleStore.shared
        guard !store.entries.isEmpty else { return }
        guard let userId = Auth.auth().currentUser?.uid else { return }

        db.collection(collection)
            .whereField("userId", isEqualTo: userId)
            .getDocuments { snapshot, _ in
                guard let docs = snapshot?.documents else { return }

                // docId -> imageURL for all this user's Firestore posts
                var firestoreMap: [String: String] = [:]   // docId -> imageURL
                for doc in docs {
                    if let url = doc.data()["imageURL"] as? String {
                        firestoreMap[doc.documentID] = url
                    }
                }
                let myWorldIds = Set(firestoreMap.keys)

                DispatchQueue.main.async {
                    var changed = false
                    var updatedEntries = store.entries
                    for i in updatedEntries.indices {
                        let entry = updatedEntries[i]

                        if let wid = entry.worldGalleryId {
                            // Has a worldGalleryId — straightforward check
                            if myWorldIds.contains(wid) {
                                if !entry.isSubmitted {
                                    updatedEntries[i].isSubmitted = true
                                    changed = true
                                    print("✅ Restored globe for entry \(entry.id)")
                                }
                            } else {
                                // Doc deleted from Firestore — clear local flag
                                updatedEntries[i].isSubmitted = false
                                updatedEntries[i].worldGalleryId = nil
                                changed = true
                            }
                        } else {
                            // worldGalleryId was cleared by old bug — try matching by imageURL
                            let uuidStr = entry.id.uuidString
                            if let match = firestoreMap.first(where: { $0.value.contains(uuidStr) }) {
                                updatedEntries[i].isSubmitted = true
                                updatedEntries[i].worldGalleryId = match.key
                                changed = true
                            }
                        }
                    }
                    if changed {
                        store.entries = updatedEntries
                        store.persistAll()
                    }
                }
            }
    }

    /// Upload image to Firebase Storage, then write metadata + URL to Firestore.
    func submit(entry: SnoodleEntry, completion: @escaping (String?, Error?) -> Void) {
        guard let userId = Auth.auth().currentUser?.uid else {
            completion(nil, NSError(domain: "Skadoodle", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Not signed in"]))
            return
        }
        guard let image = UIImage(data: entry.imageData),
              let compressed = image.jpegData(compressionQuality: 0.85) else {
            completion(nil, NSError(domain: "Skadoodle", code: 400))
            return
        }

        // Step 1: upload JPEG to Storage under world_doodles/<uuid>.jpg
        let imageId = entry.id.uuidString
        let storageRef = storage.reference().child("world_doodles/\(imageId).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        storageRef.putData(compressed, metadata: metadata) { [weak self] _, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { completion(nil, error) }
                return
            }
            // Step 2: get permanent CDN download URL
            storageRef.downloadURL { url, error in
                if let error = error {
                    DispatchQueue.main.async { completion(nil, error) }
                    return
                }
                guard let downloadURL = url else {
                    DispatchQueue.main.async {
                        completion(nil, NSError(domain: "Skadoodle", code: 500))
                    }
                    return
                }
                // Step 3: write tiny Firestore document — just metadata + URL
                let auth = SnoodleAuthManager.shared
                // Build a search index: lowercase caption words + keywords.
                // Enables array-contains-any Firebase queries for scalable text search.
                let captionWords = entry.caption.lowercased()
                    .components(separatedBy: .whitespacesAndNewlines)
                    .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                    .filter { !$0.isEmpty }
                let searchIndex = Array(Set(entry.keywords.map { $0.lowercased() } + captionWords))
                let data: [String: Any] = [
                    "caption": entry.caption,
                    "keywords": entry.keywords,
                    "searchIndex": searchIndex,
                    "timestamp": Timestamp(date: Date()),
                    "userId": userId,
                    "username": auth.username,
                    "avatar": auth.avatar,
                    "imageURL": downloadURL.absoluteString,
                    "likes": 0
                ]
                var ref: DocumentReference?
                ref = self.db.collection(self.collection).addDocument(data: data) { error in
                    DispatchQueue.main.async { completion(ref?.documentID, error) }
                }
            }
        }
    }

    /// Insert a just-posted doodle at the top of the local feed immediately,
    /// using the Storage URL we already have from submit().
    func addPostedSnoodle(_ entry: SnoodleEntry, docId: String, imageURL: String) {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        let world = WorldSnoodle(
            id: docId,
            caption: entry.caption,
            keywords: entry.keywords,
            timestamp: entry.timestamp,
            userId: userId,
            imageURL: imageURL,
            likes: 0
        )
        DispatchQueue.main.async {
            if !self.entries.contains(where: { $0.id == docId }) {
                self.entries.insert(world, at: 0)
            }
        }
    }

    func report(snoodleId: String) {
        guard let userId = Auth.auth().currentUser?.uid else {
            print("🚨 report: no userId")
            return
        }
        print("🚨 report: writing doodleId=\(snoodleId) reportedBy=\(userId)")
        db.collection("reports").addDocument(data: [
            "doodleId": snoodleId,
            "reportedBy": userId,
            "timestamp": Timestamp(date: Date())
        ]) { error in
            if let error = error {
                print("🚨 report: FAILED \(error)")
            } else {
                print("🚨 report: SUCCESS")
            }
        }
    }

    func fetchLikers(doodleId: String, completion: @escaping ([String]) -> Void) {
        db.collection(collection).document(doodleId)
            .collection("likes")
            .getDocuments { snapshot, _ in
                let userIds = snapshot?.documents.map { $0.documentID } ?? []
                completion(userIds)
            }
    }

    func fetchReportedIds(doodleIds: [String], completion: @escaping (Set<String>) -> Void) {
        guard let userId = Auth.auth().currentUser?.uid else { completion([]); return }
        db.collection("reports")
            .whereField("reportedBy", isEqualTo: userId)
            .whereField("doodleId", in: doodleIds.isEmpty ? ["__none__"] : Array(doodleIds.prefix(30)))
            .getDocuments { snapshot, _ in
                let ids = Set(snapshot?.documents.compactMap { $0.data()["doodleId"] as? String } ?? [])
                completion(ids)
            }
    }

    /// Delete from Firestore and also remove the image from Storage.
    func delete(worldSnoodle: WorldSnoodle, completion: @escaping (Error?) -> Void) {
        db.collection(collection).document(worldSnoodle.id).delete { [weak self] error in
            if error == nil {
                DispatchQueue.main.async {
                    self?.entries.removeAll { $0.id == worldSnoodle.id }
                }
                // Best-effort Storage cleanup — extract the path from the URL
                if let url = URL(string: worldSnoodle.imageURL),
                   let pathComponent = url.pathComponents.last {
                    let storageRef = Storage.storage().reference()
                        .child("world_doodles/\(pathComponent)")
                    storageRef.delete { _ in }   // ignore error — orphan cleanup is fine
                }
            }
            completion(error)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let snoodleProfilePhotoRestored = Notification.Name("snoodleProfilePhotoRestored")
}

// MARK: - Follow Manager

class FollowManager: ObservableObject {
    static let shared = FollowManager()

    private let db = Firestore.firestore()

    /// Set of userIds the current user is following — loaded at sign-in,
    /// kept live so any Follow button in the app can read state synchronously.
    @Published var followingIds: Set<String> = []

    // MARK: - Load

    /// Call once at sign-in to populate followingIds.
    func loadFollowing(for userId: String) {
        db.collection("users").document(userId).collection("following")
            .getDocuments { [weak self] snapshot, _ in
                guard let self, let docs = snapshot?.documents else { return }
                let ids = Set(docs.map { $0.documentID })
                DispatchQueue.main.async { self.followingIds = ids }
            }
    }

    func clear() {
        followingIds = []
    }

    // MARK: - Follow / Unfollow

    func follow(targetUserId: String) {
        guard let myId = Auth.auth().currentUser?.uid,
              myId != targetUserId else { return }

        // Optimistic local update
        followingIds.insert(targetUserId)

        let batch = db.batch()

        // My following subcollection
        let myFollowingRef = db.collection("users").document(myId)
            .collection("following").document(targetUserId)
        batch.setData([
            "followedId": targetUserId,
            "createdAt": Timestamp(date: Date())
        ], forDocument: myFollowingRef)

        // Their followers subcollection
        let theirFollowersRef = db.collection("users").document(targetUserId)
            .collection("followers").document(myId)
        batch.setData([
            "followerId": myId,
            "createdAt": Timestamp(date: Date())
        ], forDocument: theirFollowersRef)

        // Increment counts
        let myRef = db.collection("users").document(myId)
        batch.updateData(["followingCount": FieldValue.increment(Int64(1))], forDocument: myRef)

        let theirRef = db.collection("users").document(targetUserId)
        batch.updateData(["followerCount": FieldValue.increment(Int64(1))], forDocument: theirRef)

        batch.commit { [weak self] error in
            if let error {
                print("❌ follow error: \(error)")
                // Roll back optimistic update
                DispatchQueue.main.async { self?.followingIds.remove(targetUserId) }
            }
        }
    }

    func unfollow(targetUserId: String) {
        guard let myId = Auth.auth().currentUser?.uid else { return }

        // Optimistic local update
        followingIds.remove(targetUserId)

        let batch = db.batch()

        let myFollowingRef = db.collection("users").document(myId)
            .collection("following").document(targetUserId)
        batch.deleteDocument(myFollowingRef)

        let theirFollowersRef = db.collection("users").document(targetUserId)
            .collection("followers").document(myId)
        batch.deleteDocument(theirFollowersRef)

        let myRef = db.collection("users").document(myId)
        batch.updateData(["followingCount": FieldValue.increment(Int64(-1))], forDocument: myRef)

        let theirRef = db.collection("users").document(targetUserId)
        batch.updateData(["followerCount": FieldValue.increment(Int64(-1))], forDocument: theirRef)

        batch.commit { [weak self] error in
            if let error {
                print("❌ unfollow error: \(error)")
                // Roll back optimistic update
                DispatchQueue.main.async { self?.followingIds.insert(targetUserId) }
            }
        }
    }

    func isFollowing(_ userId: String) -> Bool {
        followingIds.contains(userId)
    }

    // MARK: - Fetch Lists

    /// Fetch ordered list of userIds this user is following (most recent first).
    func fetchFollowing(userId: String, completion: @escaping ([String]) -> Void) {
        db.collection("users").document(userId).collection("following")
            .order(by: "createdAt", descending: true)
            .getDocuments { snapshot, _ in
                let ids = snapshot?.documents.map { $0.documentID } ?? []
                DispatchQueue.main.async { completion(ids) }
            }
    }

    /// Fetch ordered list of userIds following this user (most recent first).
    func fetchFollowers(userId: String, completion: @escaping ([String]) -> Void) {
        db.collection("users").document(userId).collection("followers")
            .order(by: "createdAt", descending: true)
            .getDocuments { snapshot, _ in
                let ids = snapshot?.documents.map { $0.documentID } ?? []
                DispatchQueue.main.async { completion(ids) }
            }
    }

    // MARK: - Following Feed

    /// Fetch world_gallery doodles from users the current user follows.
    /// Batches the followingIds in groups of 30 to stay within Firestore limits.
    func fetchFollowingFeed(completion: @escaping ([WorldSnoodle]) -> Void) {
        guard let myId = Auth.auth().currentUser?.uid else {
            print("❌ fetchFollowingFeed: not signed in")
            completion([])
            return
        }

        // First get the full following list
        fetchFollowing(userId: myId) { ids in
            guard !ids.isEmpty else {
                print("⚠️ fetchFollowingFeed: following list is empty")
                completion([])
                return
            }

            let batches = ids.chunked(into: 30)
            var allSnoodles: [WorldSnoodle] = []
            let group = DispatchGroup()
            let db = Firestore.firestore()

            for batch in batches {
                group.enter()
                db.collection("world_gallery")
                    .whereField("userId", in: batch)
                    .order(by: "timestamp", descending: true)
                    .limit(to: 50)
                    .getDocuments { snapshot, _ in
                        defer { group.leave() }
                        guard let docs = snapshot?.documents else { return }
                        let snoodles = docs.compactMap { doc -> WorldSnoodle? in
                            let d = doc.data()
                            guard let userId = d["userId"] as? String,
                                  let imageURL = d["imageURL"] as? String,
                                  let ts = d["timestamp"] as? Timestamp else { return nil }
                            return WorldSnoodle(
                                id: doc.documentID,
                                caption: d["caption"] as? String ?? "",
                                keywords: d["keywords"] as? [String] ?? [],
                                timestamp: ts.dateValue(),
                                userId: userId,
                                imageURL: imageURL,
                                likes: d["likes"] as? Int ?? 0,
                                commentCount: d["commentCount"] as? Int ?? 0
                            )
                        }
                        allSnoodles.append(contentsOf: snoodles)
                    }
            }

            group.notify(queue: .main) {
                let sorted = allSnoodles.sorted { $0.timestamp > $1.timestamp }
                completion(sorted)
            }
        }
    }
}

// MARK: - Phantom Accounts (DEBUG only)

#if DEBUG
struct PhantomAccount {
    let name: String
    let avatar: String
    let userId: String
    let email: String
    let password: String
}

struct PhantomAccounts {
    static let all: [PhantomAccount] = [
        PhantomAccount(
            name: "Phantom One",
            avatar: "👻",
            userId: "OuoU7FyilGRQgA0W3q3sxXw5z942",
            email: "phantom1@skadoodle.dev",
            password: "password"
        ),
        PhantomAccount(
            name: "Phantom Two",
            avatar: "🎨",
            userId: "tFlfWm4t5YahtGe8aYZnCfISk6d2",
            email: "phantom2@skadoodle.dev",
            password: "password"
        )
    ]
}

@MainActor
class PhantomSessionManager: ObservableObject {
    static let shared = PhantomSessionManager()

    @Published var activePhantom: PhantomAccount? = nil
    @Published var isSigningIn: Bool = false
    @Published var errorMessage: String? = nil

    init() {
        // Restore phantom session if app was relaunched while signed in as a phantom
        if let uid = Auth.auth().currentUser?.uid,
           let match = PhantomAccounts.all.first(where: { $0.userId == uid }) {
            activePhantom = match
        }
    }

    func signIn(as phantom: PhantomAccount) {
        isSigningIn = true
        errorMessage = nil
        Auth.auth().signIn(withEmail: phantom.email, password: phantom.password) { [weak self] result, error in
            guard let self else { return }
            self.isSigningIn = false
            if let error {
                self.errorMessage = error.localizedDescription
                return
            }
            self.activePhantom = phantom
            // Seed UserDefaults so the app shows the phantom's name/avatar
            UserDefaults.standard.set(phantom.name, forKey: "snoodleUsername")
            UserDefaults.standard.set(phantom.avatar, forKey: "snoodleAvatar")
            UserDefaults.standard.removeObject(forKey: "snoodleProfilePhoto")
            FollowManager.shared.loadFollowing(for: phantom.userId)
            // Refresh world gallery so like state reflects the phantom's account
            WorldGalleryManager.shared.fetchRecent(accountSwitch: true)
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
        activePhantom = nil
        UserDefaults.standard.removeObject(forKey: "snoodleUsername")
        UserDefaults.standard.removeObject(forKey: "snoodleAvatar")
        UserDefaults.standard.removeObject(forKey: "snoodleProfilePhoto")
        FollowManager.shared.clear()
        // Refresh world gallery so like state reflects the next signed-in account
        WorldGalleryManager.shared.fetchRecent(accountSwitch: true)
    }
}
#endif

// MARK: - Comment Model

struct SnoodleComment: Identifiable {
    let id: String
    let doodleId: String
    let parentId: String?       // nil = top level, commentId = reply to that comment
    let userId: String
    let username: String
    let avatar: String
    let photoURL: String?
    let text: String
    let timestamp: Date

    var isReply: Bool { parentId != nil }

    var avatarImage: UIImage? { UserProfileManager.shared.getCached(userId)?.avatarImage }
    var authorPhotoURL: URL? {
        guard let u = photoURL ?? UserProfileManager.shared.getCached(userId)?.photoURL else { return nil }
        return URL(string: u)
    }
}

// MARK: - Comment Manager

class CommentManager: ObservableObject {
    static let shared = CommentManager()
    private let db = Firestore.firestore()

    @Published var commentsByDoodle: [String: [SnoodleComment]] = [:]
    @Published var loadingDoodleId: String? = nil

    // Fetch all comments (top level + replies) for a doodle
    func fetchComments(for doodleId: String, completion: (() -> Void)? = nil) {
        loadingDoodleId = doodleId
        db.collection("world_gallery").document(doodleId)
            .collection("comments")
            .order(by: "timestamp", descending: false)
            .getDocuments { [weak self] snap, error in
                guard let self = self, let docs = snap?.documents else {
                    DispatchQueue.main.async { self?.loadingDoodleId = nil }
                    return
                }
                let comments: [SnoodleComment] = docs.compactMap { doc in
                    let d = doc.data()
                    guard let text = d["text"] as? String,
                          let userId = d["userId"] as? String,
                          let ts = d["timestamp"] as? Timestamp else { return nil }
                    return SnoodleComment(
                        id: doc.documentID,
                        doodleId: doodleId,
                        parentId: d["parentId"] as? String,
                        userId: userId,
                        username: d["username"] as? String ?? "Anonymous",
                        avatar: d["avatar"] as? String ?? "🎨",
                        photoURL: d["photoURL"] as? String,
                        text: text,
                        timestamp: ts.dateValue()
                    )
                }
                DispatchQueue.main.async {
                    self.commentsByDoodle[doodleId] = comments
                    self.loadingDoodleId = nil
                    completion?()
                }
            }
    }

    // Post a new comment or reply
    func postComment(doodleId: String, parentId: String? = nil, text: String, completion: @escaping (Bool) -> Void) {
        guard let userId = SnoodleAuthManager.shared.userId else {
            completion(false); return
        }
        // Use cached profile if available, otherwise fall back to UserDefaults
        let profile = UserProfileManager.shared.getCached(userId)
        let username = profile?.username ?? UserDefaults.standard.string(forKey: "snoodleUsername") ?? "doodler"
        let avatar = profile?.avatar ?? UserDefaults.standard.string(forKey: "snoodleAvatar") ?? "🎨"
        var data: [String: Any] = [
            "userId": userId,
            "username": username,
            "avatar": avatar,
            "text": text,
            "timestamp": Timestamp(date: Date())
        ]
        if let pid = parentId { data["parentId"] = pid }
        if let url = profile?.photoURL { data["photoURL"] = url }

        let ref = db.collection("world_gallery").document(doodleId).collection("comments")
        ref.addDocument(data: data) { [weak self] error in
            guard error == nil else { completion(false); return }
            // Increment commentCount on the doodle document
            self?.db.collection("world_gallery").document(doodleId)
                .updateData(["commentCount": FieldValue.increment(Int64(1))])
            // Update local in-memory entry so UI reflects new count immediately
            DispatchQueue.main.async {
                if let idx = WorldGalleryManager.shared.entries.firstIndex(where: { $0.id == doodleId }) {
                    WorldGalleryManager.shared.entries[idx].commentCount += 1
                }
                self?.fetchComments(for: doodleId)
                completion(true)
            }
        }
    }

    // Delete a comment (own comments only — enforced by Firestore rules)
    func deleteComment(doodleId: String, commentId: String, completion: @escaping (Bool) -> Void) {
        db.collection("world_gallery").document(doodleId)
            .collection("comments").document(commentId)
            .delete { [weak self] error in
                guard error == nil else { completion(false); return }
                self?.db.collection("world_gallery").document(doodleId)
                    .updateData(["commentCount": FieldValue.increment(Int64(-1))])
                DispatchQueue.main.async {
                    self?.commentsByDoodle[doodleId]?.removeAll { $0.id == commentId }
                    if let idx = WorldGalleryManager.shared.entries.firstIndex(where: { $0.id == doodleId }) {
                        WorldGalleryManager.shared.entries[idx].commentCount = max(0, WorldGalleryManager.shared.entries[idx].commentCount - 1)
                    }
                    completion(true)
                }
            }
    }

    func comments(for doodleId: String) -> [SnoodleComment] {
        commentsByDoodle[doodleId] ?? []
    }

    func topLevel(for doodleId: String) -> [SnoodleComment] {
        comments(for: doodleId).filter { $0.parentId == nil }
    }

    func replies(to commentId: String, in doodleId: String) -> [SnoodleComment] {
        comments(for: doodleId).filter { $0.parentId == commentId }
    }
}

// MARK: - Notification Manager

class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    private let db = Firestore.firestore()

    // Notification preference keys
    static let keyLikes      = "notif_likes"
    static let keyComments   = "notif_comments"
    static let keyReplies    = "notif_replies"
    static let keyFollowers  = "notif_followers"
    static let keyNewPosts   = "notif_new_posts"

    // Published so Settings UI can bind to them
    @Published var likesEnabled:     Bool = UserDefaults.standard.bool(forKey: keyLikes, default: true)
    @Published var commentsEnabled:  Bool = UserDefaults.standard.bool(forKey: keyComments, default: true)
    @Published var repliesEnabled:   Bool = UserDefaults.standard.bool(forKey: keyReplies, default: true)
    @Published var followersEnabled: Bool = UserDefaults.standard.bool(forKey: keyFollowers, default: true)
    @Published var newPostsEnabled:  Bool = UserDefaults.standard.bool(forKey: keyNewPosts, default: true)

    // Stash token here if auth isn't ready yet
    private var pendingFCMToken: String?

    // Save FCM token to current user's Firestore document
    // If auth isn't ready yet, stash it — call flushPendingFCMToken() once auth is confirmed
    func saveFCMToken(_ token: String) {
        guard let userId = SnoodleAuthManager.shared.userId else {
            print("📱 FCM token arrived before auth — stashing for later")
            pendingFCMToken = token
            return
        }
        writeToken(token, userId: userId)
    }

    // Call this from SnoodleAuthManager once userId is available
    func flushPendingFCMToken() {
        guard let token = pendingFCMToken,
              let userId = SnoodleAuthManager.shared.userId else { return }
        print("📱 Flushing pending FCM token for userId=\(userId)")
        pendingFCMToken = nil
        writeToken(token, userId: userId)
    }

    private func writeToken(_ token: String, userId: String) {
        db.collection("users").document(userId).updateData([
            "fcmToken": token,
            "fcmTokenUpdatedAt": Timestamp(date: Date())
        ]) { error in
            if error != nil {
                self.db.collection("users").document(userId).setData([
                    "fcmToken": token,
                    "fcmTokenUpdatedAt": Timestamp(date: Date())
                ], merge: true)
            }
        }
    }

    // Save notification preferences to Firestore so Cloud Functions can respect them
    func savePreferences() {
        guard let userId = SnoodleAuthManager.shared.userId else { return }
        let prefs: [String: Any] = [
            "notifLikes":     likesEnabled,
            "notifComments":  commentsEnabled,
            "notifReplies":   repliesEnabled,
            "notifFollowers": followersEnabled,
            "notifNewPosts":  newPostsEnabled
        ]
        db.collection("users").document(userId).setData(["notificationPrefs": prefs], merge: true)

        // Save locally too
        UserDefaults.standard.set(likesEnabled,     forKey: NotificationManager.keyLikes)
        UserDefaults.standard.set(commentsEnabled,  forKey: NotificationManager.keyComments)
        UserDefaults.standard.set(repliesEnabled,   forKey: NotificationManager.keyReplies)
        UserDefaults.standard.set(followersEnabled, forKey: NotificationManager.keyFollowers)
        UserDefaults.standard.set(newPostsEnabled,  forKey: NotificationManager.keyNewPosts)
    }

    // Handle notification tap — navigate to relevant content
    func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let type = userInfo["type"] as? String else { return }
        // Post a notification so ContentView can navigate
        NotificationCenter.default.post(
            name: .snoodleNotificationTapped,
            object: nil,
            userInfo: ["type": type, "doodleId": userInfo["doodleId"] as? String ?? ""]
        )
    }
}

extension Notification.Name {
    static let snoodleNotificationTapped = Notification.Name("snoodleNotificationTapped")
}

extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        if object(forKey: key) == nil { return defaultValue }
        return bool(forKey: key)
    }
}
