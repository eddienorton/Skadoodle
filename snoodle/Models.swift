//
//  Models.swift
//  snoodle
//

import SwiftUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine

//
//  ContentView.swift
//  snoodle
//

import SwiftUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine

// MARK: - Color Hex Extension

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8) & 0xFF) / 255
        let b = Double(val & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
    }
}

// MARK: - Data Model

// Cache of decoded, downscaled doodle thumbnails (keyed by image filename) so grids
// and lists don't re-read and re-decode full-resolution PNGs from disk on every render.
@MainActor
private let snoodleThumbnailCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 300
    return cache
}()

struct SnoodleEntry: Identifiable, Codable {
    let id: UUID
    var caption: String
    var keywords: [String]
    var timestamp: Date
    var imageFilename: String
    var isSubmitted: Bool = false
    var worldGalleryId: String? = nil

    // Only metadata is encoded/persisted. Image bytes live on disk as files,
    // so UserDefaults stays tiny and launches don't load every image into memory.
    enum CodingKeys: String, CodingKey {
        case id, caption, keywords, timestamp, imageFilename, isSubmitted, worldGalleryId
    }

    // Directory holding doodle image files (Documents/Doodles), created on demand.
    static var imagesDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doodles", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    var imageURL: URL { SnoodleEntry.imagesDirectory.appendingPathComponent(imageFilename) }

    // Backwards-compatible accessor: existing call sites using `entry.imageData`
    // keep working unchanged. The bytes are read from / written to disk, not UserDefaults.
    var imageData: Data {
        get { (try? Data(contentsOf: imageURL)) ?? Data() }
        set { try? newValue.write(to: imageURL, options: .atomic) }
    }

    /// Returns cached thumbnail synchronously if already loaded, nil otherwise.
    /// Use loadThumbnailAsync() in views so disk I/O stays off the main thread.
    @MainActor
    var cachedThumbnail: UIImage? {
        snoodleThumbnailCache.object(forKey: imageFilename as NSString)
    }

    /// Loads, downscales, and caches the thumbnail on a background thread, then
    /// delivers it on the main thread. Safe to call from a Task in a SwiftUI view.
    @MainActor
    func loadThumbnailAsync() async -> UIImage? {
        if let cached = snoodleThumbnailCache.object(forKey: imageFilename as NSString) {
            return cached
        }
        let path = imageURL.path
        let key = imageFilename as NSString
        let thumb = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let full = UIImage(contentsOfFile: path) else { return nil }
            let maxDim: CGFloat = 400
            let longest = max(full.size.width, full.size.height)
            if longest > maxDim {
                let scale = maxDim / longest
                let newSize = CGSize(width: full.size.width * scale, height: full.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                return renderer.image { _ in full.draw(in: CGRect(origin: .zero, size: newSize)) }
            }
            return full
        }.value
        if let thumb { snoodleThumbnailCache.setObject(thumb, forKey: key) }
        return thumb
    }

    // Reconstruct from stored metadata (used by Codable decode and internal copies).
    init(id: UUID = UUID(), caption: String = "", keywords: [String] = [], timestamp: Date = Date(), imageFilename: String, isSubmitted: Bool = false, worldGalleryId: String? = nil) {
        self.id = id
        self.caption = caption
        self.keywords = keywords
        self.timestamp = timestamp
        self.imageFilename = imageFilename
        self.isSubmitted = isSubmitted
        self.worldGalleryId = worldGalleryId
    }

    // Create from raw image bytes — writes them to a file and keeps only the filename.
    init(id: UUID = UUID(), caption: String = "", keywords: [String] = [], timestamp: Date = Date(), imageData: Data, isSubmitted: Bool = false, worldGalleryId: String? = nil) {
        self.id = id
        self.caption = caption
        self.keywords = keywords
        self.timestamp = timestamp
        self.imageFilename = "\(id.uuidString).png"
        self.isSubmitted = isSubmitted
        self.worldGalleryId = worldGalleryId
        try? imageData.write(to: SnoodleEntry.imagesDirectory.appendingPathComponent(imageFilename), options: .atomic)
    }
}

// MARK: - Persistence

class SnoodleStore: ObservableObject {
    static let shared = SnoodleStore()
    @Published var entries: [SnoodleEntry] = []
    private let saveKey = "snoodle_entries"

    init() { load() }

    func save(_ entry: SnoodleEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        persist()
    }

    func delete(_ entry: SnoodleEntry) {
        try? FileManager.default.removeItem(at: entry.imageURL)
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clearAll() {
        entries = []
        UserDefaults.standard.removeObject(forKey: saveKey)
        // Remove all doodle image files from disk.
        let dir = SnoodleEntry.imagesDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    func persistAll() {
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let decoded = try? JSONDecoder().decode([SnoodleEntry].self, from: data) else {
            // No data, or data saved in the old image-in-UserDefaults format.
            // Start clean and reclaim the space the old image blob used.
            UserDefaults.standard.removeObject(forKey: saveKey)
            entries = []
            return
        }
        entries = decoded
    }

    func entries(for date: Date) -> [SnoodleEntry] {
        let cal = Calendar.current
        let target = cal.dateComponents([.year, .month, .day], from: date)
        return entries.filter {
            let c = cal.dateComponents([.year, .month, .day], from: $0.timestamp)
            return c.year == target.year && c.month == target.month && c.day == target.day
        }
    }
}

// MARK: - Share

func generateSnoodleCard(for entry: SnoodleEntry) -> UIImage? {
    guard let doodle = UIImage(data: entry.imageData) else { return nil }
    let cardSize = CGSize(width: 1080, height: 1350)
    let renderer = UIGraphicsImageRenderer(size: cardSize)
    let fmt = DateFormatter()
    fmt.dateStyle = .medium
    fmt.timeStyle = .none

    return renderer.image { ctx in
        let c = ctx.cgContext
        let colors = [UIColor(red: 0.97, green: 0.97, blue: 1.0, alpha: 1).cgColor,
                      UIColor(red: 0.88, green: 0.90, blue: 1.0, alpha: 1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
        c.drawLinearGradient(gradient, start: .zero,
                             end: CGPoint(x: 0, y: cardSize.height), options: [])
        let padding: CGFloat = 80
        let captionArea: CGFloat = entry.caption.isEmpty ? 80 : 140
        let doodleSize = cardSize.width - padding * 2
        let doodleHeight = cardSize.height - padding * 2 - captionArea
        let doodleRect = CGRect(x: padding, y: padding, width: doodleSize, height: doodleHeight)
        let cardRect = doodleRect.insetBy(dx: -16, dy: -16)
        let path = UIBezierPath(roundedRect: cardRect, cornerRadius: 24)
        c.setFillColor(UIColor.white.cgColor)
        c.setShadow(offset: CGSize(width: 0, height: 8), blur: 24,
                    color: UIColor.black.withAlphaComponent(0.12).cgColor)
        c.addPath(path.cgPath)
        c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        // Draw doodle — stretch or preserve aspect ratio based on user setting
        let stretch = UserDefaults.standard.object(forKey: "shareCardStretch") as? Bool ?? true
        let drawRect: CGRect
        if stretch {
            drawRect = doodleRect
        } else {
            let doodleAspect = doodle.size.width / doodle.size.height
            let rectAspect = doodleRect.width / doodleRect.height
            if doodleAspect > rectAspect {
                let h = doodleRect.width / doodleAspect
                drawRect = CGRect(x: doodleRect.minX, y: doodleRect.midY - h/2, width: doodleRect.width, height: h)
            } else {
                let w = doodleRect.height * doodleAspect
                drawRect = CGRect(x: doodleRect.midX - w/2, y: doodleRect.minY, width: w, height: doodleRect.height)
            }
        }
        doodle.draw(in: drawRect)
        if !entry.caption.isEmpty {
            let captionY = padding + doodleHeight + 24
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 48, weight: .semibold),
                .foregroundColor: UIColor(red: 0.2, green: 0.2, blue: 0.35, alpha: 1)
            ]
            let str = entry.caption as NSString
            let sz = str.size(withAttributes: attrs)
            str.draw(at: CGPoint(x: (cardSize.width - sz.width) / 2, y: captionY), withAttributes: attrs)
        }
        let brandStr = "skadoodle  •  \(fmt.string(from: entry.timestamp))"
        let brandAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 30, weight: .medium),
            .foregroundColor: UIColor(white: 0.5, alpha: 1)
        ]
        let brandSize = (brandStr as NSString).size(withAttributes: brandAttrs)
        (brandStr as NSString).draw(
            at: CGPoint(x: (cardSize.width - brandSize.width) / 2, y: cardSize.height - 60),
            withAttributes: brandAttrs)
    }
}

func presentShareSheet(with image: UIImage) {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let rootViewController = windowScene.windows.first?.rootViewController else { return }
    var topController = rootViewController
    while let presented = topController.presentedViewController {
        topController = presented
    }
    let activityVC = UIActivityViewController(activityItems: [image], applicationActivities: nil)
    if let popover = activityVC.popoverPresentationController {
        popover.sourceView = topController.view
        popover.sourceRect = CGRect(x: topController.view.bounds.midX,
                                   y: topController.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
    topController.present(activityVC, animated: true)
}


// MARK: - Drawing

