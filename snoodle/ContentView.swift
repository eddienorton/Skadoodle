//
//  ContentView.swift
//  snoodle
//

import SwiftUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine

// MARK: - Onboarding

struct OnboardingView: View {
    let onComplete: () -> Void
    @State private var currentPage: Int = 0

    let pages: [(icon: String, isAsset: Bool, title: String, subtitle: String)] = [
        ("SnoodleIcon", true, "Welcome to Skadoodle", "Create beautiful doodles.\nKeep them in your diary, post to the Skadoodle gallery, or share anywhere."),
        ("pencil.and.outline", false, "AI captions and tags your doodles.", "Just draw. Skadoodle figures out what it is and makes it searchable."),
        ("globe", false, "Join the community.", "Browse the gallery, follow other artists, and share your doodles with the world.")
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.92, green: 0.88, blue: 0.98), Color(UIColor.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentPage) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(spacing: 32) {
                            Spacer()

                            // Icon
                            if pages[i].isAsset {
                                Image("SnoodleIcon")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 120, height: 120)
                                    .cornerRadius(26)
                                    .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                            } else {
                                Image(systemName: pages[i].icon)
                                    .font(.system(size: 72, weight: .thin))
                                    .foregroundColor(.purple)
                            }

                            // Text
                            VStack(spacing: 12) {
                                Text(pages[i].title)
                                    .font(.system(size: 28, weight: .bold))
                                    .multilineTextAlignment(.center)

                                Text(pages[i].subtitle)
                                    .font(.system(size: 17))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(4)
                            }
                            .padding(.horizontal, 40)

                            Spacer()
                            Spacer()
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Page dots
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle()
                            .fill(currentPage == i ? Color.purple : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.easeInOut, value: currentPage)
                    }
                }
                .padding(.bottom, 32)

                // Button
                Button(action: {
                    if currentPage < pages.count - 1 {
                        withAnimation { currentPage += 1 }
                    } else {
                        onComplete()
                    }
                }) {
                    Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.purple)
                        .cornerRadius(16)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
                .animation(.easeInOut, value: currentPage)
            }
        }
    }
}

// MARK: - Root with Tab Bar

struct ContentView: View {
    @ObservedObject private var store = SnoodleStore.shared
    @ObservedObject private var auth = SnoodleAuthManager.shared
    @State private var showingDraw = false
    @State private var firstDrawLaunch = true
    @State private var entryToEdit: SnoodleEntry? = nil
    // Set right before showingDraw when opened via TodayTab's "Open Canvas" —
    // lets DrawScreen default its "Submit to Today's Challenge" toggle to on
    // only in that context, off for the ordinary New-tab entry point.
    @State private var dailySubmitIntent: Bool = false
    // Default landing tab is Gallery (1), not Today (0) — Daily Doodle has no real audience
    // yet, so opening straight into an empty/near-empty daily contest isn't a good first
    // impression. Today tab itself is untouched, still fully reachable via the tab bar; this
    // is purely about where the app lands on open. Revisit once Daily Doodle has real users.
    @State private var selectedTab: Int = 1
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @State private var showingOnboarding: Bool = false
    @State private var showUpdateAlert = false
    @State private var appStoreVersion = ""
    @AppStorage("dismissedUpdateVersion") private var dismissedUpdateVersion = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayTab()
                .environmentObject(store)
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(0)

            GalleryTab()
                .environmentObject(store)
                .tabItem { Label("Gallery", systemImage: "photo.on.rectangle.angled") }
                .tag(1)

            Color.clear
                .tabItem { Label("New", systemImage: "plus.circle.fill") }
                .onAppear {
                    if firstDrawLaunch {
                        firstDrawLaunch = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showingDraw = true
                        }
                    } else {
                        showingDraw = true
                    }
                }
                .tag(2)

            SettingsTab()
                .environmentObject(store)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)

            ProfileTab()
                .tabItem {
                    // SwiftUI tabItem only renders SF Symbols; photo injection is done
                    // via UIKit in the background modifier below.
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(4)
        }
        .accentColor(.purple)
        .background(ProfileTabIconInjector(auth: auth, selectedTab: selectedTab))
        .alert("Update Available", isPresented: $showUpdateAlert) {
            Button("Go to App Store") {
                if let url = URL(string: "https://apps.apple.com/app/id\(AppInfo.appStoreId)") {
                    UIApplication.shared.open(url)
                }
            }
            Button("Continue", role: .cancel) {
                dismissedUpdateVersion = "\(AppInfo.currentVersion)->\(appStoreVersion)"
            }
        } message: {
            Text("Version \(appStoreVersion) is available. You're on \(AppInfo.currentVersion).")
        } 
        .onAppear {
            WorldGalleryManager.shared.fetchRecent()
            if !hasSeenOnboarding {
                showingOnboarding = true
            }
            checkForUpdate()
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingView {
                hasSeenOnboarding = true
                showingOnboarding = false
            }
        }
        .modifier(DrawScreenPresenter(
            isPresented: $showingDraw,
            onDismiss: {
                if selectedTab == 2 { selectedTab = 1 }   // fall back to Gallery, matching the new default landing tab
                entryToEdit = nil
                dailySubmitIntent = false
                NotificationCenter.default.post(name: .snoodleProfilePhotoRestored, object: nil)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .snoodleProfilePhotoRestored, object: nil)
                }
            },
            content: { DrawScreen(isPresented: $showingDraw, selectedTab: $selectedTab, entryToEdit: $entryToEdit, dailySubmitIntent: $dailySubmitIntent).environmentObject(store) }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .todaySwitchToNew)) { _ in
            dailySubmitIntent = true
            showingDraw = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .snoodleReEditEntry)) { note in
            // Set entryToEdit first, then open the sheet one run-loop later so the
            // content closure is guaranteed to capture the non-nil entry.
            // Without the async separation, SwiftUI can split the two assignments across
            // render cycles, presenting the sheet with entryToEdit = nil → black canvas.
            entryToEdit = note.object as? SnoodleEntry
            DispatchQueue.main.async {
                showingDraw = true
            }
        }
        // Profile setup handled naturally via Profile tab
    }
}

// MARK: - UIKit Tab Bar Photo Injector
// SwiftUI tabItem silently ignores UIImage/custom views. This UIViewRepresentable
// finds the UITabBar after layout and replaces the profile tab icon with the
// user's actual photo (circular crop) or their emoji rendered as an image.

struct ProfileTabIconInjector: UIViewRepresentable {
    @ObservedObject var auth: SnoodleAuthManager
    var selectedTab: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let auth = SnoodleAuthManager.shared
        injectProfileIcon(auth: auth)
        DispatchQueue.main.async { injectProfileIcon(auth: auth) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { injectProfileIcon(auth: auth) }
    }

    class Coordinator {
        var observer: NSObjectProtocol?

        init() {
            observer = NotificationCenter.default.addObserver(
                forName: .snoodleProfilePhotoRestored,
                object: nil,
                queue: .main
            ) { _ in
                injectProfileIcon(auth: SnoodleAuthManager.shared)
                DispatchQueue.main.async {
                    injectProfileIcon(auth: SnoodleAuthManager.shared)
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

private func injectProfileIcon(auth: SnoodleAuthManager) {
    // iPad uses top tab bar (no UITabBar) — skip injection silently
    guard UIDevice.current.userInterfaceIdiom != .pad else { return }
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.windows.first,
          let tabBar = findTabBar(in: window) else { return }

    let profileTabIndex = 4
    guard let items = tabBar.items, items.count > profileTabIndex else { print("🔴 injectProfileIcon: not enough tab items \(tabBar.items?.count ?? 0)"); return }
    let item = items[profileTabIndex]

    let size = CGSize(width: 28, height: 28)

    if auth.isSignedIn {
        if auth.avatar == "photo",
           let data = UserDefaults.standard.data(forKey: "snoodleProfilePhoto"),
           let photo = UIImage(data: data) {

            let cropped = circularTabImage(from: photo, size: size)
            item.image = cropped.withRenderingMode(.alwaysOriginal)
            item.selectedImage = cropped.withRenderingMode(.alwaysOriginal)
        } else if !auth.avatar.isEmpty && auth.avatar != "photo" && auth.avatar != "🎨" {
            let emojiImage = emojiTabImage(auth.avatar, size: size)
            item.image = emojiImage.withRenderingMode(.alwaysOriginal)
            item.selectedImage = emojiImage.withRenderingMode(.alwaysOriginal)
        } else {
            // Signed in but no avatar set yet — use SF Symbol silhouette
            let icon = UIImage(systemName: "person.crop.circle")?.withRenderingMode(.alwaysTemplate)
            item.image = icon
            item.selectedImage = UIImage(systemName: "person.crop.circle.fill")?.withRenderingMode(.alwaysTemplate)
        }
    } else {
        // Not signed in — reset to SF Symbol silhouette
        let icon = UIImage(systemName: "person.crop.circle")?.withRenderingMode(.alwaysTemplate)
        item.image = icon
        item.selectedImage = UIImage(systemName: "person.crop.circle.fill")?.withRenderingMode(.alwaysTemplate)
    }
}

private func findTabBar(in view: UIView) -> UITabBar? {
    if let tabBar = view as? UITabBar { return tabBar }
    for sub in view.subviews {
        if let found = findTabBar(in: sub) { return found }
    }
    return nil
}

private func circularTabImage(from image: UIImage, size: CGSize) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
        let rect = CGRect(origin: .zero, size: size)
        UIBezierPath(ovalIn: rect).addClip()
        let imgSize = image.size
        let scale = max(size.width / imgSize.width, size.height / imgSize.height)
        let drawSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let drawOrigin = CGPoint(x: (size.width - drawSize.width) / 2,
                                 y: (size.height - drawSize.height) / 2)
        image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
    }
}

private func emojiTabImage(_ emoji: String, size: CGSize) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
        let fontSize = size.width * 0.85
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize)]
        let str = emoji as NSString
        let strSize = str.size(withAttributes: attrs)
        let origin = CGPoint(x: (size.width - strSize.width) / 2,
                             y: (size.height - strSize.height) / 2)
        str.draw(at: origin, withAttributes: attrs)
    }
}

#Preview {
    ContentView()
}

// MARK: - DrawScreenPresenter
// On iPad, present the drawing screen as fullScreenCover so the canvas fills the display.
// On iPhone, keep the existing sheet behaviour.
private struct DrawScreenPresenter<C: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: () -> Void
    let content: () -> C

    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    func body(content body: Content) -> some View {
        if isIPad {
            body.fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss, content: content)
        } else {
            body.sheet(isPresented: $isPresented, onDismiss: onDismiss, content: content)
                .interactiveDismissDisabled(true)
        }
    }
}

// MARK: - Version Check

enum AppInfo {
    static let appStoreId = "6771497563"
    static let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }()
}

extension ContentView {
    func checkForUpdate() {
        guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=maxsdad.skadoodle") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let storeVersion = first["version"] as? String else { return }
            DispatchQueue.main.async {
                let current = AppInfo.currentVersion
                // Only show if store version is newer and user hasn't dismissed this specific upgrade
                if storeVersion != current && dismissedUpdateVersion != "\(current)->\(storeVersion)" {
                    appStoreVersion = storeVersion
                    showUpdateAlert = true
                }
            }
        }.resume()
    }
}
