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
            avatar: (data["photoURL"] as? String) != nil ? "photo" : (data["avatar"] as? String ?? ""),
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
                                // Guard: only write if we're still signed in as this user
                                guard Auth.auth().currentUser?.uid == userId else { return }
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
                                    // Guard: only write if we're still signed in as this user
                                    guard Auth.auth().currentUser?.uid == userId else { return }
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

// MARK: - Daily Challenge

/// One entry in the daily_gallery collection.
struct DailyEntry: Identifiable {
    let id: String          // "{contestDate}_{userId}"
    let userId: String
    let date: String        // "YYYY-MM-DD" in DailyEntry.contestTimeZone (America/New_York)
    let imageURL: String
    let caption: String
    let timestamp: Date
    var votes: Int

    // Resolved live via UserProfileManager, never stored on the daily_gallery
    // doc itself — mirrors WorldSnoodle.applyProfile. A user's username/avatar
    // can change after they've posted; freezing it at submission time would mean
    // old entries keep showing stale info forever, which is exactly the bug this
    // avoids. See DailyManager.resolveProfiles(for:).
    var username: String = "Anonymous"
    var avatar: String = "🎨"
    var photoURL: String? = nil

    var isVotedByMe: Bool = false

    mutating func applyProfile(_ profile: UserProfile?) {
        guard let profile else { return }
        username = profile.username
        avatar = profile.avatar
        photoURL = profile.photoURL
    }

    // The single global instant every Daily Doodle day boundary is anchored to.
    // Chosen over UTC deliberately (skadoodle.nyc, and most current users are
    // US-based) — a global synchronized cutoff is still required for the blind
    // submission / timed reveal / voting-window mechanic to work at all (unlike,
    // say, Wordle, which has no such requirement and rolls over at each player's
    // own local midnight instead). TimeZone handles the EST/EDT shift automatically.
    static let contestTimeZone = TimeZone(identifier: "America/New_York")!

    static func contestDateString(for date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = contestTimeZone
        return fmt.string(from: date)
    }

    static func docId(date: String, userId: String) -> String {
        "\(date)_\(userId)"
    }
}

/// One past (already-concluded) day's winner, for the Past Winners archive list.
struct DailyWinnerSummary: Identifiable {
    let date: String
    let winner: DailyEntry
    let entryCount: Int
    var id: String { date }
}

/// Rotating daily prompts — picked by day-of-year (in DailyEntry.contestTimeZone) so everyone sees the same prompt.
struct DailyPrompt {
    static let prompts: [String] = [
        "Superhero", "Robot", "Dragon", "Treehouse", "Submarine",
        "Wizard", "Pizza", "Astronaut", "Mermaid", "Monster Truck",
        "Ghost Town", "Jungle", "Time Machine", "Sandwich", "Volcano",
        "Dinosaur", "Snowman", "Pirate Ship", "Unicorn", "Haunted House",
        "Spaceship", "Ninja", "Hot Air Balloon", "Ferris Wheel", "Lighthouse",
        "Secret Door", "Rainbow", "Treasure Map", "Roller Coaster", "Igloo",
        "Candy Castle", "Deep Sea", "Storm", "Knight", "Magic Potion",
        "Giant Robot", "Tiny World", "Cloud City", "Caveman", "Noodle Soup"
    ]

    /// Same mod-cycle formula as `today`, generalized to an arbitrary date —
    /// needed so the fallback for a non-today date (e.g. "yesterday" in the
    /// Voting Booth) reflects that date's own day-of-year, not today's.
    static func subject(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = DailyEntry.contestTimeZone
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        return prompts[(dayOfYear - 1) % prompts.count]
    }

    static var today: String { subject(for: Date()) }
}

class DailyManager: ObservableObject {
    static let shared = DailyManager()

    private let db = Firestore.firestore()
    private let storage = Storage.storage()
    private let collection = "daily_gallery"

    @Published var yesterdayEntries: [DailyEntry] = []
    @Published var myEntryToday: DailyEntry? = nil
    @Published var isLoadingYesterday: Bool = false
    @Published var isPosting: Bool = false
    @Published var isWithdrawing: Bool = false
    @Published var pastWinners: [DailyWinnerSummary] = []
    @Published var isLoadingPastWinners: Bool = false
    @Published var todaySubmissionCount: Int = 0

    /// The subject everyone's drawing to today. Always has a safe, synchronous
    /// value from the moment DailyManager exists (falls back to the legacy
    /// local 40-item mod-cycle in `DailyPrompt.today`), then silently upgrades
    /// once fetchTodaySubject() resolves the real server-assigned value — same
    /// "instant safe default, upgrades when the network catches up" pattern as
    /// the two-phase Vision/Gemini caption flow. See fetchTodaySubject() below
    /// for the server-side plan (`daily_prompts` collection, one doc per
    /// calendar date — not yet backed by an admin tool, so most dates will
    /// still fall back to the local list until that's built).
    @Published var todaySubject: String = DailyPrompt.today

    /// Total votes cast across all of yesterday's entries. A single aggregate
    /// number like this doesn't violate blind-reveal — it can't be used to infer
    /// which entry is leading (unlike a per-entry tally or vote-sorted list
    /// order), the same way an election turnout counter doesn't leak who's
    /// ahead. Derived from `yesterdayEntries`, which is already fully fetched
    /// (see fetchYesterday()) — no extra query needed.
    var yesterdayTotalVotes: Int {
        yesterdayEntries.reduce(0) { $0 + $1.votes }
    }

    /// Distinct people who voted yesterday — NOT the same as yesterdayTotalVotes,
    /// since voting is unlimited (one person can vote for several entries). Set by
    /// fetchYesterday() once entries arrive. Still just an aggregate count, same
    /// blind-reveal exception as yesterdayTotalVotes above — it says nothing about
    /// which entry anyone voted for.
    @Published var yesterdayUniqueVoterCount: Int = 0

    /// Total registered accounts — a soft denominator for the turnout percentage
    /// below. Grows as people sign up and includes inactive/test accounts, so it's
    /// shown alongside the raw voter count rather than replacing it.
    @Published var totalUserCount: Int = 0

    var yesterdayVoterTurnoutPercent: Int {
        guard totalUserCount > 0 else { return 0 }
        return Int((Double(yesterdayUniqueVoterCount) / Double(totalUserCount) * 100).rounded())
    }

    // MARK: - Fetch

    /// Fetches only the current user's own entry for today, by known docId.
    /// Deliberately does NOT query the whole day's collection — today's contest
    /// is blind until it concludes, so the client should never receive other
    /// users' entries while the day is still in progress.
    func fetchMyEntryToday() {
        guard let uid = SnoodleAuthManager.shared.userId else {
            DispatchQueue.main.async { self.myEntryToday = nil }
            return
        }
        let dateStr = DailyEntry.contestDateString()
        let docId = DailyEntry.docId(date: dateStr, userId: uid)
        db.collection(collection).document(docId).getDocument { [weak self] snap, error in
            guard let self else { return }
            if let error { print("❌ DailyManager fetchMyEntryToday: \(error.localizedDescription)") }
            guard let entry = snap.flatMap({ self.parse(id: $0.documentID, data: $0.data() ?? [:]) }) else {
                DispatchQueue.main.async { self.myEntryToday = nil }
                return
            }
            self.resolveProfiles(for: [entry]) { resolved in
                DispatchQueue.main.async { self.myEntryToday = resolved.first }
            }
        }
    }

    /// Fetches only the *count* of today's submissions via a Firestore count
    /// aggregation query — never the documents themselves. This preserves the
    /// same blind-submission privacy guarantee as fetchMyEntryToday(): a raw
    /// number reveals nothing about who's posted or what they drew, just how
    /// many people have entered so far today.
    func fetchTodaySubmissionCount() {
        let dateStr = DailyEntry.contestDateString()
        db.collection(collection)
            .whereField("date", isEqualTo: dateStr)
            .count
            .getAggregation(source: .server) { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("❌ DailyManager fetchTodaySubmissionCount: \(error.localizedDescription)")
                    return
                }
                let count = snapshot?.count.intValue ?? 0
                DispatchQueue.main.async { self.todaySubmissionCount = count }
            }
    }

    /// Resolves today's subject: checks a same-day UserDefaults cache first
    /// (the subject for a given date never changes once fetched, so there's no
    /// reason to re-hit Firestore every time this is called — TodayTab's
    /// onAppear/refreshable and DrawScreen's onAppear all call this
    /// defensively), then reads `daily_prompts/{date}` — one doc per calendar
    /// date, `subject: String` — falling back to the legacy local mod-cycle
    /// (`DailyPrompt.today`) if that date has no assignment yet. This is the
    /// first piece of moving subjects server-side; there's no admin tool to
    /// populate `daily_prompts` yet, so for now most dates will fall back to
    /// the local list until dates are seeded (by hand via Firebase Console, or
    /// later via the planned website admin panel).
    private var cachedSubjectDate: String {
        get { UserDefaults.standard.string(forKey: "cachedSubjectDate") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cachedSubjectDate") }
    }
    private var cachedSubjectText: String {
        get { UserDefaults.standard.string(forKey: "cachedSubjectText") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cachedSubjectText") }
    }

    /// Shared subject resolver for an arbitrary date — reads `daily_prompts/{date}`,
    /// falling back to the local mod-cycle formula (`DailyPrompt.subject(for:)`,
    /// evaluated for *that* date, not "today") if no assignment exists yet.
    /// `hasRealAssignment` tells the caller whether it's safe to cache the
    /// result permanently (only true for a real Firestore-sourced value — see
    /// fetchTodaySubject()'s caching note).
    private func fetchSubject(for date: Date, completion: @escaping (_ subject: String, _ hasRealAssignment: Bool) -> Void) {
        let dateStr = DailyEntry.contestDateString(for: date)
        db.collection("daily_prompts").document(dateStr).getDocument { snap, error in
            if let error {
                print("❌ DailyManager fetchSubject(\(dateStr)): \(error.localizedDescription)")
            }
            let raw = snap?.data()?["subject"] as? String
            let hasRealAssignment = raw?.isEmpty == false
            let subject = hasRealAssignment ? raw! : DailyPrompt.subject(for: date)
            completion(subject, hasRealAssignment)
        }
    }

    func fetchTodaySubject() {
        let dateStr = DailyEntry.contestDateString()
        if cachedSubjectDate == dateStr, !cachedSubjectText.isEmpty {
            todaySubject = cachedSubjectText
            return
        }
        fetchSubject(for: Date()) { [weak self] subject, hasRealAssignment in
            guard let self else { return }
            DispatchQueue.main.async {
                self.todaySubject = subject
                // Only persist the cache once there's a real, permanent Firestore
                // assignment for this date. If we cached the fallback too, seeding
                // daily_prompts/{date} by hand mid-day (the current workflow, with
                // no admin tool yet) would never show up on a device that already
                // fetched today once — it'd be stuck showing the fallback until the
                // date rolls over. Leaving the fallback un-cached costs one cheap
                // Firestore read per app open on unseeded days, which is fine.
                if hasRealAssignment {
                    self.cachedSubjectDate = dateStr
                    self.cachedSubjectText = subject
                }
            }
        }
    }

    /// Yesterday's real subject — used by the Voting Booth header. Deliberately
    /// NOT derived from any entry's `caption` field: that's fragile for any
    /// hand-seeded/legacy test data whose caption was never forced to the
    /// subject the way a real `post()` call always does, and would silently
    /// show whatever garbage caption a test doc happens to have. This always
    /// resolves the same way `today` does (Firestore-first, local-list
    /// fallback), just for yesterday's date instead.
    @Published var yesterdaySubject: String = ""

    func fetchYesterdaySubject() {
        let yesterday = Date().addingTimeInterval(-86400)
        fetchSubject(for: yesterday) { [weak self] subject, _ in
            DispatchQueue.main.async { self?.yesterdaySubject = subject }
        }
    }

    /// Subject for the hero card's date specifically — `pastWinners.first`,
    /// the most recently decided winner. Same reliability fix as
    /// `yesterdaySubject` above, for the exact same reason: the hero card
    /// briefly showed `winner.caption` directly, which is only guaranteed to
    /// equal the subject for entries posted through the real `post()` flow.
    /// A hand-seeded/legacy test doc can have an actual AI-style caption
    /// sitting in that field instead — that's a real bug that showed up here
    /// ("My poodle is feeling a little purple today" displayed as if it were
    /// the day's theme). This resolves the same Firestore-first/local-
    /// fallback way as today/yesterday's subject, just for whichever date
    /// fetchPastWinners() decided is the most recent winner. Triggered
    /// automatically at the end of fetchPastWinners() below — not something
    /// the view needs to remember to call separately.
    @Published var heroWinnerSubject: String = ""

    private static let dateOnlyFormatter: DateFormatter = {
        // Same time-zone-safety rule as every other formatter that touches a
        // daily_gallery `date` string — must be pinned to contestTimeZone or
        // parsing can roll the date onto the wrong calendar day.
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = DailyEntry.contestTimeZone; return f
    }()

    func fetchHeroWinnerSubject(for dateStr: String) {
        guard let date = DailyManager.dateOnlyFormatter.date(from: dateStr) else { return }
        fetchSubject(for: date) { [weak self] subject, _ in
            DispatchQueue.main.async { self?.heroWinnerSubject = subject }
        }
    }

    /// Fetches all entries from yesterday's now-concluded-submission-but-still-voting
    /// contest and publishes them to yesterdayEntries. Thin wrapper around the shared
    /// per-day fetch below — this is the only place that writes to that published
    /// property, since it's specifically "yesterday," not any arbitrary past day
    /// (the archive/past-winners views use fetchEntries(for:) directly and hold
    /// their own local state instead).
    ///
    /// Blind-reveal voting: no winner is computed or shown here at all, and the
    /// vote-sorted order the query returns is deliberately discarded in favor of
    /// timestamp order — showing entries in vote-count order would leak who's
    /// leading via list position alone, even without printing a number. The
    /// revealed/final version (sorted by votes, winner spotlighted) only exists
    /// once a day ages out of this window into the Past Winners archive.
    func fetchYesterday() {
        let yesterday = DailyEntry.contestDateString(for: Date().addingTimeInterval(-86400))
        isLoadingYesterday = true
        fetchEntries(for: yesterday) { [weak self] entries in
            let displayOrder = entries.sorted { $0.timestamp < $1.timestamp }
            DispatchQueue.main.async {
                self?.yesterdayEntries = displayOrder
                self?.isLoadingYesterday = false
            }
            self?.fetchUniqueVoterCount(for: entries) { count in
                DispatchQueue.main.async { self?.yesterdayUniqueVoterCount = count }
            }
        }
    }

    /// Counts distinct voters across a set of entries — reads each entry's full
    /// `votes` subcollection (not just an existence check for one uid, unlike
    /// fetchVotedIds below) and unions the doc IDs (each doc ID is a voter's
    /// uid). Bounded by entry count × votes-per-entry, which is fine at this
    /// app's current scale; would need a collectionGroup query instead if a
    /// single day ever had a very large number of entries/votes.
    private func fetchUniqueVoterCount(for entries: [DailyEntry], completion: @escaping (Int) -> Void) {
        guard !entries.isEmpty else { completion(0); return }
        let group = DispatchGroup()
        var voterIds = Set<String>()
        let lock = NSLock()
        for entry in entries {
            group.enter()
            db.collection(collection).document(entry.id).collection("votes").getDocuments { snap, error in
                defer { group.leave() }
                if let error {
                    print("❌ DailyManager fetchUniqueVoterCount(\(entry.id)): \(error.localizedDescription)")
                    return
                }
                let ids = (snap?.documents ?? []).map { $0.documentID }
                lock.lock()
                voterIds.formUnion(ids)
                lock.unlock()
            }
        }
        group.notify(queue: .main) { completion(voterIds.count) }
    }

    /// Total registered accounts, via a count aggregation query (never fetches
    /// the actual user docs). Denominator for the turnout percentage.
    func fetchTotalUserCount() {
        db.collection("users").count.getAggregation(source: .server) { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                print("❌ DailyManager fetchTotalUserCount: \(error.localizedDescription)")
                return
            }
            let count = snapshot?.count.intValue ?? 0
            DispatchQueue.main.async { self.totalUserCount = count }
        }
    }

    /// Fetches all entries for a specific date, sorted server-side by votes
    /// descending (earliest submission breaks ties), with each entry's
    /// isVotedByMe resolved against the current user's votes subcollection.
    ///
    /// Shared by fetchYesterday() and the past-winners archive (both "yesterday"
    /// and any older concluded day are the identical shape of query, just
    /// parameterized by which date string). Sorting/limiting happens in the query
    /// itself so this scales past whatever a single day's entry count grows to —
    /// requires a composite Firestore index on daily_gallery: date (==), votes
    /// (desc), timestamp (asc). See CLAUDE.md "Daily Doodle" section for the spec.
    func fetchEntries(for date: String, completion: @escaping ([DailyEntry]) -> Void) {
        db.collection(collection)
            .whereField("date", isEqualTo: date)
            .order(by: "votes", descending: true)
            .order(by: "timestamp", descending: false)
            .limit(to: 200)
            .getDocuments { [weak self] snap, error in
                guard let self else { completion([]); return }
                if let error { print("❌ DailyManager fetchEntries(\(date)): \(error.localizedDescription)") }
                let parsed = (snap?.documents ?? [])
                    .compactMap { self.parse(id: $0.documentID, data: $0.data()) }
                self.resolveProfiles(for: parsed) { withProfiles in
                    var entries = withProfiles
                    self.fetchVotedIds(for: entries) { votedIds in
                        for i in entries.indices {
                            entries[i].isVotedByMe = votedIds.contains(entries[i].id)
                        }
                        completion(entries)
                    }
                }
            }
    }

    /// Fetches winners for a window of already-concluded past days, most recent
    /// first — the "Past Winners" archive. Starts 2 days ago rather than
    /// yesterday, since yesterday already has its own dedicated section on the
    /// Today tab; goes back `lookbackDays` from there.
    ///
    /// This is ONE range query for the whole window, not one query per day: sorted
    /// by date ascending then votes descending, so the first entry encountered for
    /// each date is guaranteed to be that day's top-voted entry (everything sharing
    /// a date is grouped together by the primary sort, and within a date group the
    /// highest-voted entry sorts first). No separate summary/snapshot collection
    /// needed — same composite index as fetchEntries(for:), just a range instead
    /// of an equality filter on `date`. Fixed-size window for now rather than
    /// paginated; revisit if history ever outgrows `lookbackDays`.
    func fetchPastWinners(lookbackDays: Int = 60, completion: (() -> Void)? = nil) {
        isLoadingPastWinners = true
        let anchor = Date().addingTimeInterval(-86400 * 2)
        let earliest = anchor.addingTimeInterval(-86400 * Double(lookbackDays - 1))
        let anchorStr = DailyEntry.contestDateString(for: anchor)
        let earliestStr = DailyEntry.contestDateString(for: earliest)
        print("🔍 DailyManager fetchPastWinners: querying date range \(earliestStr)...\(anchorStr)")

        db.collection(collection)
            .whereField("date", isGreaterThanOrEqualTo: earliestStr)
            .whereField("date", isLessThanOrEqualTo: anchorStr)
            .order(by: "date", descending: false)
            .order(by: "votes", descending: true)
            .order(by: "timestamp", descending: false)
            .limit(to: 3000) // safety cap on raw docs across the whole window, not just winners
            .getDocuments { [weak self] snap, error in
                guard let self else { return }
                if let error {
                    // Most common cause of an empty archive: Firestore hasn't built the
                    // composite index yet (date ASC, votes DESC, timestamp ASC). When that's
                    // the case this error includes a direct "create index" console link.
                    print("❌ DailyManager fetchPastWinners: \(error.localizedDescription)")
                }
                let rawDocs = snap?.documents ?? []
                print("🔍 DailyManager fetchPastWinners: \(rawDocs.count) raw doc(s) returned from Firestore")
                let parsed = rawDocs.compactMap { self.parse(id: $0.documentID, data: $0.data()) }
                if parsed.count != rawDocs.count {
                    print("⚠️ DailyManager fetchPastWinners: \(rawDocs.count - parsed.count) doc(s) failed to parse (missing/malformed imageURL, userId, date, or timestamp field)")
                }

                self.resolveProfiles(for: parsed) { entries in
                    var winnerByDate: [String: DailyEntry] = [:]
                    var countByDate: [String: Int] = [:]
                    for entry in entries {
                        countByDate[entry.date, default: 0] += 1
                        // First entry seen per date wins — the sort order guarantees
                        // it's the highest-voted one in that date's group.
                        if winnerByDate[entry.date] == nil {
                            winnerByDate[entry.date] = entry
                        }
                    }
                    let summaries = winnerByDate.compactMap { date, winner -> DailyWinnerSummary? in
                        // Zero-engagement rule — don't list a day at all if nobody
                        // voted for anything that day.
                        guard winner.votes > 0 else { return nil }
                        return DailyWinnerSummary(date: date, winner: winner, entryCount: countByDate[date] ?? 1)
                    }.sorted { $0.date > $1.date }
                    print("🔍 DailyManager fetchPastWinners: \(countByDate.count) date(s) present in range, \(summaries.count) surfaced as summaries (dates with 0 votes are omitted) — dates seen: \(countByDate.keys.sorted())")

                    DispatchQueue.main.async {
                        self.pastWinners = summaries
                        self.isLoadingPastWinners = false
                        // Resolve the hero card's subject reliably (never
                        // from winner.caption — see heroWinnerSubject's doc
                        // comment) as soon as we know which date is most
                        // recent, so the view never has to remember to
                        // trigger this itself.
                        if let heroDate = summaries.first?.date {
                            self.fetchHeroWinnerSubject(for: heroDate)
                        }
                        completion?()
                    }
                }
            }
    }

    /// Checks which of the given daily entries the current user has voted for,
    /// via a batched existence check on each entry's votes subcollection.
    /// Mirrors WorldGalleryManager.fetchLikedIds — daily entries don't get this
    /// for free from parse() since "isVotedByMe" isn't a field on the doc itself.
    private func fetchVotedIds(for entries: [DailyEntry], completion: @escaping (Set<String>) -> Void) {
        guard let uid = SnoodleAuthManager.shared.userId, !entries.isEmpty else {
            completion([])
            return
        }
        let group = DispatchGroup()
        var votedIds = Set<String>()
        for entry in entries {
            group.enter()
            db.collection(collection).document(entry.id)
                .collection("votes").document(uid)
                .getDocument { snap, _ in
                    defer { group.leave() }
                    if snap?.exists == true { votedIds.insert(entry.id) }
                }
        }
        group.notify(queue: .main) { completion(votedIds) }
    }

    // MARK: - Post

    /// Upload imageData and post (or replace) this user's entry for today.
    func post(imageData: Data, caption: String, completion: @escaping (Error?) -> Void) {
        guard let uid = SnoodleAuthManager.shared.userId else {
            completion(NSError(domain: "DailyManager", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not signed in"]))
            return
        }
        let dateStr = DailyEntry.contestDateString()
        let docId = DailyEntry.docId(date: dateStr, userId: uid)
        let storageRef = storage.reference().child("daily_gallery/\(docId).jpg")
        isPosting = true

        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"
        storageRef.putData(imageData, metadata: meta) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async { self?.isPosting = false; completion(error) }
                return
            }
            storageRef.downloadURL { [weak self] url, error in
                guard let self, let downloadURL = url else {
                    DispatchQueue.main.async { self?.isPosting = false; completion(error) }
                    return
                }
                // Deliberately does NOT write username/avatar/photoURL — these can change
                // after posting, so they're resolved live via resolveProfiles(for:) on read
                // instead of frozen on the doc at submission time. See DailyEntry.applyProfile.
                let data: [String: Any] = [
                    "userId": uid,
                    "date": dateStr,
                    "imageURL": downloadURL.absoluteString,
                    "caption": caption,
                    "timestamp": Timestamp(date: Date()),
                    "votes": 0
                ]

                self.db.collection(self.collection).document(docId).setData(data) { [weak self] error in
                    DispatchQueue.main.async {
                        self?.isPosting = false
                        if error == nil {
                            // Only bump the count locally the first time — replacing an
                            // existing entry (same docId) is an overwrite, not a new
                            // submission, so re-posting shouldn't inflate the total.
                            if self?.myEntryToday == nil { self?.todaySubmissionCount += 1 }
                            self?.fetchMyEntryToday()
                        }
                        completion(error)
                    }
                }
            }
        }
    }

    // MARK: - Withdraw

    /// Deletes the signed-in user's own entry for today. Only ever touches today's
    /// doc (derived from the current uid + today's date, not whatever's in
    /// `myEntryToday`), so there's no way to withdraw anyone else's entry. Safe to
    /// do as a clean delete — today's entry is guaranteed still-blind/unvoted, so
    /// there's no votes subcollection to reconcile. Not available once an entry
    /// has been revealed (see CLAUDE.md — withdrawal is scoped to today only).
    func withdrawToday(completion: @escaping (Error?) -> Void) {
        guard let uid = SnoodleAuthManager.shared.userId else {
            completion(NSError(domain: "DailyManager", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not signed in"]))
            return
        }
        let dateStr = DailyEntry.contestDateString()
        let docId = DailyEntry.docId(date: dateStr, userId: uid)
        let storageRef = storage.reference().child("daily_gallery/\(docId).jpg")
        isWithdrawing = true

        db.collection(collection).document(docId).delete { [weak self] error in
            if let error {
                DispatchQueue.main.async { self?.isWithdrawing = false; completion(error) }
                return
            }
            // Best-effort image cleanup — the Firestore doc is the source of truth
            // for whether an entry exists, so don't block the UI on Storage.
            storageRef.delete { error in
                if let error { print("⚠️ DailyManager withdrawToday: storage cleanup failed: \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                self?.myEntryToday = nil
                self?.isWithdrawing = false
                if let count = self?.todaySubmissionCount, count > 0 { self?.todaySubmissionCount -= 1 }
                completion(nil)
            }
        }
    }

    // MARK: - Vote

    /// The one day currently open for voting — "yesterday" relative to now, i.e.
    /// the day that was just revealed and hasn't aged out of the lookback window yet.
    /// See CLAUDE.md's submission/voting window model.
    var currentVotableDate: String {
        DailyEntry.contestDateString(for: Date().addingTimeInterval(-86400))
    }

    /// Toggles a vote on `entry`. Returns `false` (no-op, nothing written) if the
    /// entry isn't from the currently-votable day. Today this is belt-and-suspenders —
    /// the UI only ever surfaces entries from `yesterdayEntries`, which is always
    /// exactly this window — but it's what will actually stop out-of-window voting
    /// once an archive/history view can reach older entries. Client-side only; a
    /// Firestore security rule doing the same check server-side is still deferred
    /// (see CLAUDE.md).
    @discardableResult
    func toggleVote(_ entry: DailyEntry) -> Bool {
        guard let uid = SnoodleAuthManager.shared.userId else { return false }
        guard entry.date == currentVotableDate else {
            print("⚠️ DailyManager toggleVote: blocked — entry.date (\(entry.date)) is outside the current voting window (\(currentVotableDate))")
            return false
        }
        let ref = db.collection(collection).document(entry.id)
        let voteRef = ref.collection("votes").document(uid)
        if entry.isVotedByMe {
            voteRef.delete { error in
                if let error { print("❌ DailyManager toggleVote (delete): \(error.localizedDescription)") }
            }
            ref.updateData(["votes": FieldValue.increment(Int64(-1))]) { error in
                if let error { print("❌ DailyManager toggleVote (decrement): \(error.localizedDescription)") }
            }
            updateLocal(entry.id, voted: false, delta: -1)
        } else {
            voteRef.setData(["userId": uid, "timestamp": Timestamp(date: Date())]) { error in
                if let error { print("❌ DailyManager toggleVote (setData): \(error.localizedDescription)") }
            }
            ref.updateData(["votes": FieldValue.increment(Int64(1))]) { error in
                if let error { print("❌ DailyManager toggleVote (increment): \(error.localizedDescription)") }
            }
            updateLocal(entry.id, voted: true, delta: 1)
        }
        return true
    }

    private func updateLocal(_ id: String, voted: Bool, delta: Int) {
        if let i = yesterdayEntries.firstIndex(where: { $0.id == id }) {
            yesterdayEntries[i].isVotedByMe = voted
            yesterdayEntries[i].votes += delta
        }
        if myEntryToday?.id == id {
            myEntryToday?.isVotedByMe = voted
            myEntryToday?.votes += delta
        }
    }

    // MARK: - Parse

    private func parse(id: String, data d: [String: Any]) -> DailyEntry? {
        guard let imageURL = d["imageURL"] as? String,
              let userId = d["userId"] as? String,
              let date = d["date"] as? String,
              let ts = d["timestamp"] as? Timestamp else { return nil }
        // Deliberately does NOT read username/avatar/photoURL from the doc —
        // those are resolved live via resolveProfiles(for:) after parsing.
        return DailyEntry(
            id: id,
            userId: userId,
            date: date,
            imageURL: imageURL,
            caption: d["caption"] as? String ?? "",
            timestamp: ts.dateValue(),
            votes: d["votes"] as? Int ?? 0
        )
    }

    /// Resolves username/avatar/photoURL for each entry via UserProfileManager
    /// (batched, cached) instead of trusting whatever was frozen on the doc at
    /// submission time. Mirrors WorldGalleryManager.applyProfilesAndLikes.
    private func resolveProfiles(for entries: [DailyEntry], completion: @escaping ([DailyEntry]) -> Void) {
        guard !entries.isEmpty else { completion([]); return }
        let userIds = Set(entries.map { $0.userId })
        UserProfileManager.shared.fetchProfiles(userIds: userIds) { _ in
            let resolved = entries.map { entry -> DailyEntry in
                var e = entry
                e.applyProfile(UserProfileManager.shared.getCached(e.userId))
                return e
            }
            completion(resolved)
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
        PhantomAccount(name: "Doodle Dan",    avatar: "👻", userId: "T8KZZCKad1cmWbffmdGNZ1wvoJt2", email: "phantom1@skadoodle.dev",  password: "Skadoodle#1"),
        PhantomAccount(name: "bart-art",      avatar: "🎨", userId: "Q8FTk1ew49fnulc9nSWoXXsLXuf2", email: "phantom2@skadoodle.dev",  password: "Skadoodle#2"),
        PhantomAccount(name: "Pete Kaso",     avatar: "🖊️", userId: "Oa1gXqUPgAOGrGzKYSmb87bJGo02", email: "phantom3@skadoodle.dev",  password: "Skadoodle#3"),
        PhantomAccount(name: "Big Franky",    avatar: "⚡", userId: "vTKqPAnP85QnzngpO8cOwIC3pIA3", email: "phantom4@skadoodle.dev",  password: "Skadoodle#4"),
        PhantomAccount(name: "doodlemaven",   avatar: "🌊", userId: "J3nHTel5XKgObx7hoc29vCYphDY2", email: "phantom5@skadoodle.dev",  password: "Skadoodle#5"),
        PhantomAccount(name: "doodle poodle", avatar: "🍦", userId: "37ZUwwxCmRRKVe3HPM5u6f84Zzy1", email: "phantom6@skadoodle.dev",  password: "Skadoodle#6"),
        PhantomAccount(name: "Cindys Pen",    avatar: "🌀", userId: "5KwWL0OJ5LhtnhzmTKFia1y1Rnd2", email: "phantom7@skadoodle.dev",  password: "Skadoodle#7"),
        PhantomAccount(name: "Dadoodle",      avatar: "👑", userId: "2t5KHcBWtdX112rAai8l25j2GqW2", email: "phantom8@skadoodle.dev",  password: "Skadoodle#8"),
        PhantomAccount(name: "Squiggle man",  avatar: "😬", userId: "TNSg8JoUhqQPIJhf1bAkL7ojDz62", email: "phantom9@skadoodle.dev",  password: "Skadoodle#9"),
        PhantomAccount(name: "i-cant-draw",   avatar: "🌙", userId: "bL2jgsyuC3O2fWmv2Eux5XEu7Zu2", email: "phantom10@skadoodle.dev", password: "Skadoodle#10"),
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
            // Write correct username + avatar to Firestore, then clear cache so
            // the profile view re-fetches fresh instead of showing a stale random username.
            // Only fix the username — don't touch avatar, which may be "photo" if the
            // phantom has uploaded a profile picture. Overwriting it here would clobber
            // the photo avatar back to the emoji on every sign-in.
            Firestore.firestore().collection("users").document(phantom.userId).setData(
                ["username": phantom.name, "isPublic": true],
                merge: true
            ) { _ in
                UserProfileManager.shared.clearCache(for: phantom.userId)
            }
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
