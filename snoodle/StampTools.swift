//
//  StampTools.swift
//  snoodle
//

import SwiftUI
import PhotosUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine

// Wraps images for .sheet(item:) so presentation and data arrive atomically
struct SegmentationItem: Identifiable {
    let id = UUID()
    let images: [UIImage]
}


struct SubmitButton: View {
    let entry: SnoodleEntry
    @EnvironmentObject var store: SnoodleStore
    @StateObject private var auth = SnoodleAuthManager.shared
    @State private var showSignIn = false
    @State private var isSubmitting = false
    @State private var showError = false
    @State private var submitErrorMessage = ""

    var isSubmitted: Bool { entry.isSubmitted }

    var body: some View {
        Button(action: handleSubmit) {
            if isSubmitting {
                ProgressView().tint(.white)
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: isSubmitted ? "checkmark.circle.fill" : "globe")
                    .font(.system(size: 22))
                    .foregroundColor(isSubmitted ? .green : .white.opacity(0.6))
            }
        }
        .disabled(isSubmitting || isSubmitted)
        .sheet(isPresented: $showSignIn) {
            SignInView(onComplete: { handleSubmit() }, showCancel: true)
        }
        .alert("Submission Failed", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(submitErrorMessage.isEmpty
                 ? "Could not submit to the community. Please try again."
                 : submitErrorMessage)
        }
    }

    func handleSubmit() {
        guard auth.isSignedIn else {
            showSignIn = true
            return
        }
        isSubmitting = true
        WorldGalleryManager.shared.submit(entry: entry) { docId, error in
            DispatchQueue.main.async {
                self.isSubmitting = false
                if let error = error {
                    print("🔴 Submit error: \(error)")
                    self.submitErrorMessage = error.localizedDescription
                    self.showError = true
                } else {
                    var updated = entry
                    updated.isSubmitted = true
                    updated.worldGalleryId = docId
                    store.save(updated)
                }
            }
        }
    }
}

// MARK: - Helper: Identifiable Int for fullScreenCover

struct IdentifiableInt: Identifiable, Equatable {
    var id: Int { value }
    let value: Int
}

// MARK: - Stamp Tool

struct PlacedStamp: Identifiable {
    let id = UUID()
    var emoji: String
    var position: CGPoint
    var size: CGFloat
    var rotation: Double = 0
    var opacity: Double = 1.0
    var flipX: Bool = false
    var flipY: Bool = false
    var flipStep: Int = 0
    var customImageId: UUID? = nil  // if set, render from CustomStampManager instead of emoji
    var stampText: String? = nil    // if set, render as text stamp
    var fontName: String? = nil     // font for text stamp
    var textColor: Color = .black   // color for text stamp
    var textBgColor: Color = .clear // background color for text stamp

    var isTextStamp: Bool { stampText != nil }

    // For text stamps: natural content dimensions (honors line breaks, content-sized).
    // Zero means square (stamp.size x stamp.size) — used by all non-text stamps.
    var stampWidth: CGFloat = 0
    var stampHeight: CGFloat = 0

    // Effective display dimensions
    var displayWidth: CGFloat { stampWidth > 0 ? stampWidth : size }
    var displayHeight: CGFloat { stampHeight > 0 ? stampHeight : size }

    mutating func cycleFlip() {
        flipStep = (flipStep + 1) % 4
        rotation = Double(flipStep) * 90.0
    }
}

// Available fonts for text stamps
struct TextStampFont: Identifiable {
    let id: String  // font name or descriptor
    let label: String
    let font: UIFont

    static let all: [TextStampFont] = [
        TextStampFont(id: "system",     label: "Default",    font: .systemFont(ofSize: 48, weight: .regular)),
        TextStampFont(id: "bold",       label: "Bold",       font: .systemFont(ofSize: 48, weight: .bold)),
        TextStampFont(id: "rounded",    label: "Rounded",    font: {
            let desc = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
                .withDesign(.rounded)!
            return UIFont(descriptor: desc, size: 48)
        }()),
        TextStampFont(id: "serif",      label: "Serif",      font: .init(name: "Georgia", size: 48) ?? .systemFont(ofSize: 48)),
        TextStampFont(id: "mono",       label: "Mono",       font: .monospacedSystemFont(ofSize: 48, weight: .regular)),
        TextStampFont(id: "handwriting",label: "Script",     font: .init(name: "SnellRoundhand", size: 48) ?? .systemFont(ofSize: 48)),
    ]

    static func font(forId id: String?) -> UIFont {
        all.first(where: { $0.id == id })?.font ?? all[0].font
    }
}

let stampEmojis: [String] = [
    // ⭐️ Magic & sparkle
    "⭐️","🌟","💫","✨","🔥","💥","🌠","🎇","🎆","🪄","☄️","🌀","🔆",
    // 😀 Faces & expressions
    "😀","😄","😂","🤣","😎","🤩","😍","🥳","😱","🤔","😏","🥹","😭",
    "🤯","😜","🤪","😇","🤠","🥺","😤","🤡","👻","💀","🎃","🤖","👾",
    "🫡","🙄","😅","😬","🤗","🫠","🥴","😒","😑","🤫","🫢","😶","🤥",
    "😌","😔","😪","😮","😯","😲","🥱","😴","🤤","😋","😛","😝","😞",
    // 👁️ Body parts
    "👁️","👀","👂","👃","👄","🦷","🫀","🧠","🦴","🦶","🦵","🫁",
    // 👍 Hands & gestures
    "👍","👎","👏","🙌","✌️","🤞","🤙","👋","🫶","🫰","🤘","🖖","💪",
    // ❤️ Hearts & love
    "❤️","🧡","💛","💚","💙","💜","🖤","🤍","🩷","🩵","💝","💖","💗",
    "💓","💞","💕","💌","🥰","😘","🌹","💍","❤️‍🔥",
    // 🐶 Animals — land
    "🐑","🐏","🐐","🦙","🐄","🐎","🐖","🐓","🦃","🐇","🦔",
    "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯","🦁","🐮","🐷",
    "🐸","🐵","🦝","🦨","🦡","🦫","🦦","🦥","🦔","🐺","🦌","🦘","🐗",
    // 🐧 Animals — birds & sea
    "🐧","🦋","🦄","🐝","🦩","🦚","🦜","🦢","🦅","🦆","🦉","🦇","🐦",
    "🐙","🐬","🐳","🦭","🦈","🐡","🐠","🐟","🦐","🦞","🦀","🐊","🐢",
    // 🌈 Nature & weather
    "🌈","🌊","🌸","🌺","🌻","🌼","🌷","🍀","🌴","🌵","🍁","🍂","🍃",
    "⚡️","🌙","☀️","❄️","⛄️","🌤️","🌧️","🌨️","🌪️","🏔️","🌋","🏝️","🌅",
    // 🍕 Food & treats
    "🍕","🍔","🌮","🌯","🍜","🍣","🍩","🍦","🎂","🍰","🧁","🍭","🍬",
    "🍫","🍓","🍉","🍇","🍑","🥝","🍋","🍊","🍎","🥑","🧃","🍺","🧋",
    // 🎈 Celebration & fun
    "🎈","🎉","🎊","🎁","🏆","🥇","🎯","🎪","🎠","🎡","🎢","🃏","🎲",
    // 🚀 Travel & transport
    "🚀","🛸","✈️","🚂","🚗","🏎️","🚁","⛵️","🚢","🛵","🚲","🛹","🛼",
    // ⚽️ Sports & activities
    "⚽️","🏀","🏈","⚾️","🎾","🏐","🎱","🏓","⛷️","🏄","🧗","🤸","🎿",
    // 🎸 Music & art
    "🎸","🎵","🎶","🎨","🎭","🎬","🎤","🎧","🥁","🎹","🎺","🎻","🪗",
    // 👣 Feet & tracks
    "👣","🐾","👠","👡","👟","👞","🥾","🧦",
    // 🌿 Plants & nature
    "🌿","🍄","🌾","🌱","🌲","🌳","🪨","🪵","🍃","🪸","🌊","🪷","🫧",
    "🪺","🪹","🍂","🌬️","🌫️","🌦️","🌈","🌻","🌼","🌸","🏵️","💐",
    // 🏠 Places & buildings
    "🏠","🏡","🏰","🏯","🗼","🗽","⛩️","🕌","🕍","⛪️","🏟️","🏬","🏦",
    "🏨","🏩","🏪","🎠","🎡","🎢","💒","🏛️","🗺️","🧭","🏕️","🌃","🌆",
    // 🎩 Clothing & fashion
    "🎩","👒","🪖","⛑️","👑","💎","👗","👘","🥻","🩱","👙","🩲","🩳",
    "👔","👕","👖","🧣","🧤","🧢","👜","👛","💼","🎒","🧳","☂️","👓","🕶️",
    // 🔨 Tools & objects
    "🔨","⚒️","🪛","🔧","🪚","⚙️","🔩","🪤","🧲","💡","🔦","🕯️","🪔",
    "📱","💻","⌨️","🖥️","🖨️","📷","📸","📹","🎥","📡","🔭","🔬","🧪",
    "📚","📖","✏️","🖊️","📝","📌","📎","✂️","🗑️","🪣","🧹","🪠","🔑","🗝️",
    // 🐉 Fantasy & mythical
    "🐉","🐲","🦄","🧚","🧜","🧝","🧙","🧛","🧟","🧞","🧕","🪄","👹",
    "👺","👻","💀","☠️","👽","👾","🤖","🛸","🌌","⚗️","🔮","🪬","🧿",
    // ♈️ Zodiac & symbols
    "♈️","♉️","♊️","♋️","♌️","♍️","♎️","♏️","♐️","♑️","♒️","♓️",
    "☯️","☮️","✡️","☪️","✝️","🕉️","☸️","🔯","🪯","⚜️","🔱","♾️","⚛️",
    // 🕯️ Spooky & dark
    "🕯️","🪦","💀","☠️","🕸️","🕷️","🦇","🌑","🌒","🌓","🌔","🌕","🌖",
    "🌗","🌘","🔮","🪄","🧿","👁️","🗝️","⚰️","🪬","🌙","😱","👹","👺",
    // 🧁 More food & drink
    "🥐","🥖","🥨","🧀","🥚","🍳","🥞","🧇","🥓","🌭","🥪","🥙","🧆",
    "🍱","🍛","🍲","🥘","🫕","🍝","🥗","🫙","🧂","🫖","☕️","🍵","🧉",
    "🥂","🍾","🍷","🍸","🍹","🍻","🥃","🧊","🫗",
    // 👶 People & ages
    "👶","🧒","👦","👧","🧑","👱","👨","👩","🧓","👴","👵","🧔","👼",
    "🙇","💁","🙅","🙆","🤷","🤦","💆","💇","🚶","🧍","🧎","🏃","💃","🕺",
    // 🏳️ Flags
    "🏳️","🏴","🚩","🏁","🏳️‍🌈","🏳️‍⚧️","🇺🇸","🇬🇧","🇫🇷","🇩🇪","🇯🇵","🇧🇷",
    "🇮🇳","🇨🇳","🇰🇷","🇮🇹","🇪🇸","🇦🇺","🇨🇦","🇲🇽","🇷🇺","🇦🇷","🇿🇦","🇳🇬",
    // 💎 Objects & misc
    "💎","💰","🔮","🗝️","🧲","🪬","🧿","📸","🔭","🧬","🪐","🌍","🗺️"
]

// Returns first emoji for a given category marker by scanning stampEmojis array
// Since we cant inspect comments at runtime, we map category markers to their first known emoji
let categoryFirstEmoji: [String: String] = [
    "// ⭐️ Magic":     "⭐️",
    "// 😀 Faces":     "😀",
    "// 👁️ Body":      "👁️",
    "// 👍 Hands":     "👍",
    "// ❤️ Hearts":    "❤️",
    "// 🐶 Animals":   "🐑",
    "// 🐧 Animals":   "🐧",
    "// 🌈 Nature":    "🌈",
    "// 🍕 Food":      "🍕",
    "// 🎈 Celebration": "🎈",
    "// 🚀 Travel":    "🚀",
    "// ⚽️ Sports":   "⚽️",
    "// 🎸 Music":     "🎸",
    "// 👣 Feet":      "👣",
    "// 🌿 Plants":    "🌿",
    "// 🏠 Places":    "🏠",
    "// 🎩 Clothing":  "🎩",
    "// 🔨 Tools":     "🔨",
    "// 🐉 Fantasy":   "🐉",
    "// ♈️ Zodiac":   "♈️",
    "// 🕯️ Spooky":  "🕯️",
    "// 🧁 More food": "🥐",
    "// 👶 People":    "👶",
    "// 🏳️ Flags":   "🏳️",
    "// 💎 Objects":   "💎",
]

func emojisForCategory(_ marker: String) -> [String] {
    guard let first = categoryFirstEmoji[marker] else { return [] }
    return [first]
}

// Category nav data
let stampCategories: [(icon: String, label: String, marker: String)] = [
    ("⭐️", "Magic",      "// ⭐️ Magic"),
    ("😀", "Faces",      "// 😀 Faces"),
    ("👁️", "Body",       "// 👁️ Body"),
    ("👍", "Hands",      "// 👍 Hands"),
    ("❤️", "Hearts",     "// ❤️ Hearts"),
    ("🐶", "Animals",    "// 🐶 Animals"),
    ("🐧", "Birds/Sea",  "// 🐧 Animals"),
    ("🌈", "Nature",     "// 🌈 Nature"),
    ("🍕", "Food",       "// 🍕 Food"),
    ("🎈", "Party",      "// 🎈 Celebration"),
    ("🚀", "Travel",     "// 🚀 Travel"),
    ("⚽️", "Sports",    "// ⚽️ Sports"),
    ("🎸", "Music",      "// 🎸 Music"),
    ("👣", "Feet",       "// 👣 Feet"),
    ("🌿", "Plants",     "// 🌿 Plants"),
    ("🏠", "Places",     "// 🏠 Places"),
    ("🎩", "Fashion",    "// 🎩 Clothing"),
    ("🔨", "Tools",      "// 🔨 Tools"),
    ("🐉", "Fantasy",    "// 🐉 Fantasy"),
    ("♈️", "Zodiac",    "// ♈️ Zodiac"),
    ("🕯️", "Spooky",   "// 🕯️ Spooky"),
    ("🧁", "More Food",  "// 🧁 More food"),
    ("👶", "People",     "// 👶 People"),
    ("🏳️", "Flags",    "// 🏳️ Flags"),
    ("💎", "Objects",    "// 💎 Objects"),
]

struct StampToolButton: View {
    @Binding var selectedStamp: String
    @Binding var placedStamps: [PlacedStamp]
    @Binding var stampUndoStack: [[PlacedStamp]]
    @Binding var selectedCustomStampId: String
    @Binding var isCustomStampMode: Bool
    let canvasSize: CGSize
    @State private var showPicker = false
    @State private var segmentationItem: SegmentationItem? = nil  // drives sheet(item:) atomically
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showSourcePicker = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var isLoadingPhotos = false
    @State private var pickerTab = 0  // 0 = emoji, 1 = photos, 2 = text
    @State private var catProxy: ScrollViewProxy? = nil

    @ObservedObject var customManager = CustomStampManager.shared

    var body: some View {
        Button {
            showPicker = true
        } label: {
            ZStack {
                Circle()
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(width: 38, height: 38)
                    .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                if isCustomStampMode, let customId = UUID(uuidString: selectedCustomStampId),
                   let stamp = customManager.stamps.first(where: { $0.id == customId }),
                   let img = stamp.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text(selectedStamp)
                        .font(.system(size: 18))
                        .minimumScaleFactor(0.5)
                        .frame(width: 30, height: 30)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color(UIColor.systemGray4))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Toggle
                Picker("", selection: $pickerTab) {
                    Text("😊 Emoji").tag(0)
                    Text("📷 Photos").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

                Divider()

                Group {
                if pickerTab == 0 {
                    // Emoji picker
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(stampCategories, id: \.label) { cat in
                                Button {
                                    let catEmojis = emojisForCategory(cat.marker)
                                    if let first = catEmojis.first {
                                        withAnimation { catProxy?.scrollTo(first, anchor: .top) }
                                    }
                                } label: {
                                    VStack(spacing: 2) {
                                        Text(cat.icon).font(.system(size: 24))
                                        Text(cat.label)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(width: 58, height: 52)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(8)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .padding(.leading, UIDevice.current.userInterfaceIdiom == .pad ? 14 : 6)
                    }
                    Divider().padding(.bottom, 8)
                    ScrollViewReader { proxy in
                        ScrollView {
                            let isIPad = UIDevice.current.userInterfaceIdiom == .pad
                            let stampCols = isIPad ? 10 : 6
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: stampCols), spacing: 6) {
                                ForEach(stampEmojis, id: \.self) { emoji in
                                    Button {
                                        selectedStamp = emoji
                                        isCustomStampMode = false
                                        selectedCustomStampId = ""
                                        showPicker = false
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 28))
                                            .frame(width: 44, height: 44)
                                            .background(!isCustomStampMode && selectedStamp == emoji ? Color.purple.opacity(0.15) : Color.gray.opacity(0.08))
                                            .cornerRadius(8)
                                            .overlay(RoundedRectangle(cornerRadius: 8)
                                                .stroke(!isCustomStampMode && selectedStamp == emoji ? Color.purple : Color.clear, lineWidth: 2.5))
                                    }
                                    .id(emoji)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .onAppear { catProxy = proxy }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                proxy.scrollTo(selectedStamp, anchor: .center)
                            }
                        }
                    }
                } else if pickerTab == 1 {
                    // Photo stamps
                    VStack(spacing: 0) {
                        if customManager.stamps.isEmpty {
                            Spacer()
                            VStack(spacing: 12) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 36))
                                    .foregroundColor(.secondary)
                                Text("No photo stamps yet")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("Grab objects from your photos")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                addPhotoButton
                            }
                            Spacer()
                        } else {
                            ScrollView {
                                let cols = [GridItem(.adaptive(minimum: 70), spacing: 10)]
                                LazyVGrid(columns: cols, spacing: 10) {
                                    // Add button
                                    Button { showSourcePicker = true } label: {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.purple.opacity(0.08))
                                                .frame(width: 70, height: 70)
                                                .overlay(RoundedRectangle(cornerRadius: 10)
                                                    .stroke(Color.purple.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4])))
                                            Image(systemName: "plus")
                                                .font(.system(size: 20))
                                                .foregroundColor(.purple)
                                        }
                                    }
                                    ForEach(customManager.stamps) { stamp in
                                        if let img = stamp.image {
                                            Button {
                                                selectedCustomStampId = stamp.id.uuidString
                                                isCustomStampMode = true
                                                showPicker = false
                                            } label: {
                                                Image(uiImage: img)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 70, height: 70)
                                                    .background(Color.gray.opacity(0.05))
                                                    .cornerRadius(10)
                                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                                        .stroke(isCustomStampMode && selectedCustomStampId == stamp.id.uuidString ? Color.purple : Color.gray.opacity(0.2),
                                                                lineWidth: isCustomStampMode && selectedCustomStampId == stamp.id.uuidString ? 2.5 : 1))
                                            }
                                            .contextMenu {
                                                Button(role: .destructive) {
                                                    customManager.delete(stamp)
                                                    if selectedCustomStampId == stamp.id.uuidString {
                                                        selectedCustomStampId = ""
                                                        isCustomStampMode = false
                                                    }
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(12)
                            }
                            addPhotoButton.padding(.bottom, 8)
                        }
                    }
                }
                } // end Group
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden) // we draw our own above
            // confirmationDialog inside sheet so it appears centered
            .confirmationDialog("Add Photo Stamp", isPresented: $showSourcePicker) {
                Button("Take Photo") {
                    showPicker = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showCamera = true
                    }
                }
                Button("Choose from Library") {
                    showPicker = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showPhotoPicker = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            // Loading overlay inside sheet so it fills the sheet, not the tiny button
            .overlay {
                if isLoadingPhotos {
                    ZStack {
                        Color.black.opacity(0.5)
                        VStack(spacing: 14) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                            Text("Loading photos…")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                        }
                        .padding(28)
                        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image in
                print("📷 StampTools: onCapture fired — image=\(image != nil ? "YES" : "NIL")")
                showCamera = false
                if let img = image {
                    // Use sheet(item:) — data and presentation trigger arrive atomically,
                    // no race between segmentationImages state and showPhotoSegmentation bool.
                    // Small delay lets the fullScreenCover binding fully unwind first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        print("📷 StampTools: setting segmentationItem to trigger sheet")
                        segmentationItem = SegmentationItem(images: [img])
                    }
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await MainActor.run { isLoadingPhotos = true }
                var loaded: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        loaded.append(img)
                    }
                }
                await MainActor.run {
                    isLoadingPhotos = false
                    if !loaded.isEmpty {
                        segmentationItem = SegmentationItem(images: loaded)
                    }
                    selectedPhotoItems = []
                }
            }
        }
        .sheet(item: $segmentationItem) { item in
            ObjectSegmentationSheet(images: item.images) { cutouts in
                segmentationItem = nil
                var lastStamp: CustomStamp? = nil
                for cutout in cutouts {
                    if let stamp = customManager.addStamp(image: cutout) {
                        lastStamp = stamp
                    }
                }
                if let stamp = lastStamp {
                    selectedCustomStampId = stamp.id.uuidString
                    isCustomStampMode = true
                    showPicker = false
                }
            }
        }
    }

    var addPhotoButton: some View {
        Button { showSourcePicker = true } label: {
            HStack {
                Image(systemName: "plus.circle.fill")
                Text("Add from Photo Library")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.purple)
            .cornerRadius(10)
        }
    }
}


func renderFontFor(stamp: PlacedStamp) -> Font {
    let s = stamp.size
    switch stamp.fontName ?? "system" {
    case "bold":         return .system(size: s, weight: .bold)
    case "rounded":      return .system(size: s, weight: .regular, design: .rounded)
    case "serif":        return .custom("Georgia", size: s)
    case "mono":         return .system(size: s, design: .monospaced)
    case "handwriting":  return .custom("SnellRoundhand", size: s)
    default:             return .system(size: s)
    }
}

func renderCanvasWithStamps(lines: [DrawingLine], stamps: [PlacedStamp], size: CGSize, canvasColor: UIColor = .white, backgroundImage: UIImage? = nil, backgroundOffset: CGSize = .zero) -> UIImage {
    let canvasSwiftUI = Color(canvasColor)
    let view = ZStack {
        Canvas { context, canvasSize in
            // Draw background photo — cover fit with offset
            if let bgImg = backgroundImage {
                let imgW = bgImg.size.width, imgH = bgImg.size.height
                guard imgW > 0, imgH > 0 else { return }
                let scale = max(canvasSize.width / imgW, canvasSize.height / imgH)
                let drawW = imgW * scale, drawH = imgH * scale
                let x = (canvasSize.width - drawW) / 2 + backgroundOffset.width
                let y = (canvasSize.height - drawH) / 2 + backgroundOffset.height
                let uiImg = Image(uiImage: bgImg)
                context.draw(uiImg, in: CGRect(x: x, y: y, width: drawW, height: drawH))
            }
            for line in lines {
                renderLine(line, in: &context, canvasColor: canvasSwiftUI)
            }
        }
        ForEach(stamps) { stamp in
            Group {
                if let customId = stamp.customImageId,
                   let customStamp = CustomStampManager.shared.stamps.first(where: { $0.id == customId }),
                   let img = customStamp.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: stamp.displayWidth, height: stamp.displayHeight)
                } else if let text = stamp.stampText {
                    Text(text)
                        .font(renderFontFor(stamp: stamp))
                        .foregroundColor(stamp.textColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(24)
                        .frame(minWidth: stamp.displayWidth, minHeight: stamp.displayHeight)
                        .background(stamp.textBgColor == .clear ? Color.clear : stamp.textBgColor)
                        .cornerRadius(stamp.textBgColor == .clear ? 0 : 8)
                } else {
                    Text(stamp.emoji)
                        .font(.system(size: stamp.size))
                }
            }
            .scaleEffect(x: stamp.flipX ? -1 : 1, y: stamp.flipY ? -1 : 1)
            .rotationEffect(.degrees(stamp.rotation))
            .opacity(stamp.opacity)
            .position(stamp.position)
        }
    }
    .frame(width: size.width, height: size.height)
    .background(canvasSwiftUI)

    let renderer = ImageRenderer(content: view)
    renderer.scale = UITraitCollection.current.displayScale
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    if let uiImage = renderer.uiImage { return uiImage }
    return renderCanvas(lines: lines, size: size, canvasColor: canvasColor)
}

// MARK: - Thickness Picker

// ThicknessPanel — rendered as an overlay in DrawScreen, no popover
struct ThicknessPanel: View {
    @Binding var lineWidth: CGFloat
    var onSelect: () -> Void

    var sizes: [CGFloat] {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return [1, 2, 4, 8, 14, 22, 36, 60, 90, 130]
        } else {
            return [1, 2, 4, 8, 14, 22, 36, 60, 90]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sizes, id: \.self) { size in
                Button {
                    lineWidth = size
                    UserDefaults.standard.set(Double(size), forKey: "lastLineWidth")
                    onSelect()
                } label: {
                    HStack(spacing: 16) {
                        Canvas { ctx, canvasSize in
                            let y = canvasSize.height / 2
                            var path = Path()
                            path.move(to: CGPoint(x: 8, y: y))
                            path.addLine(to: CGPoint(x: canvasSize.width - 8, y: y))
                            ctx.stroke(path, with: .color(.primary),
                                       style: StrokeStyle(lineWidth: size, lineCap: .round))
                        }
                        .frame(width: 100, height: max(min(size, 100) + 8, 28))
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.purple)
                            .opacity(lineWidth == size ? 1 : 0)
                            .frame(width: 24)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(lineWidth == size ? Color.purple.opacity(0.1) : Color.clear)
                }
                .buttonStyle(.plain)
                if size != sizes.last { Divider().padding(.leading, 14) }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}


// MARK: - Stamp Magic Menu

enum StampTransform {
    case flipH, flipV, rotate90
}

struct StampMagicMenu: View {
    let stamp: PlacedStamp
    let canvasSize: CGSize
    let onDismiss: () -> Void
    let onTransform: (StampTransform) -> Void
    var onDelete: (() -> Void)? = nil
    var onDupe: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Handle / title
            HStack {
                Spacer()
                if stamp.isTextStamp {
                    Text("✏️ Text")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                } else {
                    Text(stamp.emoji)
                        .font(.system(size: 20))
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            let columns = stamp.isTextStamp
                ? Array(repeating: GridItem(.flexible()), count: 6)
                : Array(repeating: GridItem(.flexible()), count: 5)
            LazyVGrid(columns: columns, spacing: 0) {
                magicButton("↔️", "Flip H",   "↔️ swipe")  { onTransform(.flipH) }
                magicButton("↕️", "Flip V",   "↕️ swipe")  { onTransform(.flipV) }
                magicButton("🔄", "Rotate",   "↻ pinch")  { onTransform(.rotate90) }
                magicButton("📋", "Dupe",     "copy")      { onDupe?() }
                if stamp.isTextStamp {
                    magicButton("✏️", "Edit",  "")          { onEdit?() }
                }
                magicButton("🗑️", "Delete",   "tap tap")  { onDelete?() }
            }
            .padding(.bottom, 6)
        }
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 4)
        .frame(width: 300)
    }

    @ViewBuilder
    func magicButton(_ icon: String, _ label: String, _ hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(icon).font(.system(size: 22))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

}

// MARK: - Text Stamp Composer

struct TextStampComposer: View {
    @Binding var textInput: String
    @Binding var selectedFontId: String
    @Binding var selectedTextColorIndex: Int
    @Binding var selectedTextBgColorIndex: Int   // -1 = clear
    var onPlace: (String, String, Color, Color) -> Void

    @FocusState private var isFocused: Bool

    var selectedTextColor: Color {
        selectedTextColorIndex < paletteColors.count ? paletteColors[selectedTextColorIndex] : .black
    }
    var selectedBgColor: Color {
        selectedTextBgColorIndex < 0 ? .clear :
            (selectedTextBgColorIndex < paletteColors.count ? paletteColors[selectedTextBgColorIndex] : .clear)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // Preview
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(selectedBgColor == .clear
                              ? Color(UIColor.secondarySystemBackground)
                              : selectedBgColor)
                        .frame(height: 110)
                        // checkerboard hint when transparent
                        .overlay(
                            Group {
                                if selectedBgColor == .clear {
                                    Text(textInput.isEmpty ? "Your text" : textInput)
                                        .font(swiftUIFont(forId: selectedFontId, size: 28))
                                        .foregroundColor(textInput.isEmpty ? .secondary : selectedTextColor)
                                        .multilineTextAlignment(.center)
                                        .minimumScaleFactor(0.2)
                                        .lineLimit(nil)
                                        .padding(.horizontal, 12)
                                } else {
                                    Text(textInput.isEmpty ? "Your text" : textInput)
                                        .font(swiftUIFont(forId: selectedFontId, size: 28))
                                        .foregroundColor(textInput.isEmpty ? .secondary : selectedTextColor)
                                        .multilineTextAlignment(.center)
                                        .minimumScaleFactor(0.2)
                                        .lineLimit(nil)
                                        .padding(.horizontal, 12)
                                }
                            }
                        )
                }
                .cornerRadius(12)
                .padding(.horizontal, 16)

                // Multi-line text editor
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(UIColor.secondarySystemBackground))
                    if textInput.isEmpty {
                        Text("Type your text...")
                            .foregroundColor(.secondary)
                            .font(.system(size: 16))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                    TextEditor(text: $textInput)
                        .font(.system(size: 16))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 80, maxHeight: 120)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .padding(.trailing, 28)
                        .focused($isFocused)
                    // Clear button
                    if !textInput.isEmpty {
                        VStack {
                            HStack {
                                Spacer()
                                Button {
                                    textInput = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundColor(.secondary)
                                        .padding(8)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .frame(minHeight: 80, maxHeight: 120)
                .padding(.horizontal, 16)
                .onAppear { isFocused = true }

                // Place button — above keyboard
                Button {
                    onPlace(textInput, selectedFontId, selectedTextColor, selectedBgColor)
                } label: {
                    Text("Place Text Stamp")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.purple)
                        .cornerRadius(14)
                        .padding(.horizontal, 16)
                }
                .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                // Font picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Font")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(TextStampFont.all) { f in
                                Button {
                                    selectedFontId = f.id
                                } label: {
                                    Text(f.label)
                                        .font(swiftUIFont(forId: f.id, size: 15))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(selectedFontId == f.id ? Color.purple.opacity(0.15) : Color(UIColor.secondarySystemBackground))
                                        .foregroundColor(selectedFontId == f.id ? .purple : .primary)
                                        .cornerRadius(20)
                                        .overlay(RoundedRectangle(cornerRadius: 20)
                                            .stroke(selectedFontId == f.id ? Color.purple : Color.gray.opacity(0.2), lineWidth: 1.5))
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Text color picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Text Color")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(paletteColors.enumerated()), id: \.offset) { idx, color in
                                Button { selectedTextColorIndex = idx } label: {
                                    Circle()
                                        .fill(color)
                                        .frame(width: 32, height: 32)
                                        .overlay(Circle().stroke(Color.white, lineWidth: selectedTextColorIndex == idx ? 3 : 0))
                                        .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                        .shadow(color: .black.opacity(selectedTextColorIndex == idx ? 0.3 : 0), radius: 3)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                // Background color picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Background")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            // Transparent option first
                            Button { selectedTextBgColorIndex = -1 } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(UIColor.secondarySystemBackground))
                                        .frame(width: 32, height: 32)
                                    // diagonal slash = transparent
                                    Image(systemName: "circle.slash")
                                        .font(.system(size: 20))
                                        .foregroundColor(.secondary)
                                }
                                .overlay(Circle().stroke(Color.purple, lineWidth: selectedTextBgColorIndex == -1 ? 3 : 0))
                                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: selectedTextBgColorIndex == -1 ? 0 : 1))
                            }
                            ForEach(Array(paletteColors.enumerated()), id: \.offset) { idx, color in
                                Button { selectedTextBgColorIndex = idx } label: {
                                    Circle()
                                        .fill(color)
                                        .frame(width: 32, height: 32)
                                        .overlay(Circle().stroke(Color.white, lineWidth: selectedTextBgColorIndex == idx ? 3 : 0))
                                        .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                        .shadow(color: .black.opacity(selectedTextBgColorIndex == idx ? 0.3 : 0), radius: 3)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }


            }
            .padding(.vertical, 16)
        }
    }

    func swiftUIFont(forId id: String, size: CGFloat) -> Font {
        switch id {
        case "bold":        return .system(size: size, weight: .bold)
        case "rounded":     return .system(size: size, weight: .regular, design: .rounded)
        case "serif":       return .custom("Georgia", size: size)
        case "mono":        return .system(size: size, design: .monospaced)
        case "handwriting": return .custom("SnellRoundhand", size: size)
        default:            return .system(size: size)
        }
    }
}

// MARK: - Text Composer Sheet (standalone, accessed via T button)

struct TextComposerSheet: View {
    var initialText: String? = nil
    var onPlace: (String, String, Color, Color) -> Void

    @AppStorage("lastTextStampText") private var textInput: String = ""
    @AppStorage("lastTextStampFontId") private var selectedFontId: String = "system"
    @AppStorage("lastTextStampColorIndex") private var selectedTextColorIndex: Int = 0
    @AppStorage("lastTextStampBgColorIndex") private var selectedTextBgColorIndex: Int = -1
    @Environment(\.dismiss) private var dismiss

    var selectedTextColor: Color {
        selectedTextColorIndex < paletteColors.count ? paletteColors[selectedTextColorIndex] : .black
    }
    var selectedBgColor: Color {
        selectedTextBgColorIndex < 0 ? .clear :
            (selectedTextBgColorIndex < paletteColors.count ? paletteColors[selectedTextBgColorIndex] : .clear)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color(UIColor.systemGray4))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)

            TextStampComposer(
                textInput: $textInput,
                selectedFontId: $selectedFontId,
                selectedTextColorIndex: $selectedTextColorIndex,
                selectedTextBgColorIndex: $selectedTextBgColorIndex,
                onPlace: { text, fontId, color, bgColor in
                    onPlace(text, fontId, color, bgColor)
                }
            )
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            if let initial = initialText {
                textInput = initial
            }
        }
    }
}
