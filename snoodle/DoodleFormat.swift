// DoodleFormat.swift
// Codable conformances for the .skadoodle file format.
// Handles non-Codable types: Color (encoded as RGBA), CGPoint (as x/y doubles),
// UIImage (as PNG data), and PenType (custom enum with associated value).

import SwiftUI

// MARK: - CodableColor

/// Bridges SwiftUI Color ↔ JSON as four RGBA doubles.
struct CodableColor: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.r = Double(r); self.g = Double(g); self.b = Double(b); self.a = Double(a)
    }

    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }
}

// MARK: - DualToneStyle  (just needs Codable — handled in DrawingEngine.swift)

// MARK: - PenType Codable

extension PenType: Codable {
    private enum CodingKeys: String, CodingKey { case type, style }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pencil:      try c.encode("pencil",      forKey: .type)
        case .ink:         try c.encode("ink",         forKey: .type)
        case .brush:       try c.encode("brush",       forKey: .type)
        case .marker:      try c.encode("marker",      forKey: .type)
        case .chalk:       try c.encode("chalk",       forKey: .type)
        case .neon:        try c.encode("neon",        forKey: .type)
        case .spray:       try c.encode("spray",       forKey: .type)
        case .watercolor:  try c.encode("watercolor",  forKey: .type)
        case .dotted:      try c.encode("dotted",      forKey: .type)
        case .calligraphy: try c.encode("calligraphy", forKey: .type)
        case .confetti:    try c.encode("confetti",    forKey: .type)
        case .dualTone(let style):
            try c.encode("dualTone", forKey: .type)
            try c.encode(style.rawValue, forKey: .style)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ink":        self = .ink
        case "brush":      self = .brush
        case "marker":     self = .marker
        case "chalk":      self = .chalk
        case "neon":       self = .neon
        case "spray":      self = .spray
        case "watercolor": self = .watercolor
        case "dotted":     self = .dotted
        case "calligraphy": self = .calligraphy
        case "confetti":    self = .confetti
        case "dualTone":
            let raw = try c.decode(String.self, forKey: .style)
            self = .dualTone(DualToneStyle(rawValue: raw) ?? .gradient)
        default:           self = .pencil
        }
    }
}

// MARK: - DrawingLine Codable

extension DrawingLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case px, py, widths, color, colorB, lineWidth, isEraser, penType, timestamp
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Separate x/y arrays are more compact than point objects for large arrays.
        try c.encode(points.map { Double($0.x) }, forKey: .px)
        try c.encode(points.map { Double($0.y) }, forKey: .py)
        try c.encode(widths.map { Double($0) },   forKey: .widths)
        try c.encode(CodableColor(color),          forKey: .color)
        try c.encode(CodableColor(colorB),         forKey: .colorB)
        try c.encode(Double(lineWidth),            forKey: .lineWidth)
        try c.encode(isEraser,                     forKey: .isEraser)
        try c.encode(penType,                      forKey: .penType)
        try c.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let px = try c.decode([Double].self, forKey: .px)
        let py = try c.decode([Double].self, forKey: .py)
        points    = zip(px, py).map { CGPoint(x: $0, y: $1) }
        widths    = try c.decode([Double].self, forKey: .widths).map { CGFloat($0) }
        color     = try c.decode(CodableColor.self, forKey: .color).color
        colorB    = try c.decode(CodableColor.self, forKey: .colorB).color
        lineWidth = CGFloat(try c.decode(Double.self, forKey: .lineWidth))
        isEraser  = try c.decode(Bool.self, forKey: .isEraser)
        penType   = try c.decode(PenType.self, forKey: .penType)
        let ts    = try c.decodeIfPresent(Double.self, forKey: .timestamp)
        timestamp = ts.map { Date(timeIntervalSince1970: $0) } ?? Date(timeIntervalSince1970: 0)
    }
}

// MARK: - Notification Names

// MARK: - DrawingLayer Codable
// Custom (not synthesized) so createdAt can use decodeIfPresent for old files.
// Old files fall back to Date(timeIntervalSince1970: 0); stable sort preserves z-order for them.

extension DrawingLayer: Codable {
    private enum CodingKeys: String, CodingKey { case id, lines, opacity, createdAt }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,        forKey: .id)
        try c.encode(lines,     forKey: .lines)
        try c.encode(opacity,   forKey: .opacity)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
    }

    init(from decoder: Decoder) throws {
        let c   = try decoder.container(keyedBy: CodingKeys.self)
        id      = try c.decode(UUID.self,         forKey: .id)
        lines   = try c.decode([DrawingLine].self, forKey: .lines)
        opacity = (try? c.decode(Double.self,     forKey: .opacity)) ?? 1.0
        let ts  = try c.decodeIfPresent(Double.self, forKey: .createdAt)
        createdAt = ts.map { Date(timeIntervalSince1970: $0) } ?? Date(timeIntervalSince1970: 0)
    }
}

extension Notification.Name {
    static let snoodleReEditEntry = Notification.Name("snoodleReEditEntry")
}

// MARK: - File URL

extension FileManager {
    /// URL for the auto-saved "current session" doodle in the app's Documents folder.
    static var currentSkadoodleURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("current.skadoodle")
    }
}

// MARK: - ChapterBreak

/// A user-placed pause marker in the timelapse video timeline.
/// Holds on the current frame for `holdDuration` seconds at this point in playback.
struct ChapterBreak: Codable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date               // when the break was placed (for sorting into the event timeline)
    var holdDuration: Double = 3.0    // seconds to hold (rendered as frames in the timelapse)
}

// MARK: - LayerOrderChange

/// Records an explicit user-initiated layer reorder so the timelapse video can reproduce
/// the effect at the right moment in the timeline.
/// When encountered during playback, the composite is rebuilt in the new z-order —
/// e.g. if the user moved a draw layer below a text stamp and then drew behind it,
/// the video shows exactly that: stamp visible, drawing appearing underneath it.
struct LayerOrderChange: Codable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date           // when the reorder happened
    var layerOrder: [LayerEntry]  // complete new order after this change
}

// MARK: - SkadoodleDocument

/// Top-level serializable snapshot of a complete doodle — everything needed to
/// restore DrawScreen to exactly the state it was in when saved.
struct SkadoodleDocument: Codable {
    var version: Int = 1
    var drawingLayers: [DrawingLayer]
    var placedStamps: [PlacedStamp]
    var layerOrder: [LayerEntry]
    var hiddenLayerIds: [UUID]           // Set<UUID> isn't Codable; store as array
    var canvasColorIndex: Int = 0        // Legacy — kept for backward-compat decode only
    var canvasColorRGBA: CodableColor?   // v2.3+: full RGBA canvas color; preferred over index
    var backgroundImageData: Data?       // JPEG of the background photo, nil if none
    var backgroundOffsetX: Double
    var backgroundOffsetY: Double
    var bgOpacity: Double
    var bgBlur: Double
    var bgBrightness: Double
    var bgSaturation: Double
    var chapterBreaks: [ChapterBreak] = []          // user-placed pause markers for timelapse video
    var layerOrderChanges: [LayerOrderChange] = []  // user-initiated reorder events for timelapse video playback
}

// MARK: - LayerEntry Codable

extension LayerEntry: Codable {
    private enum CodingKeys: String, CodingKey { case type, id }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .drawing(let id): try c.encode("drawing", forKey: .type); try c.encode(id, forKey: .id)
        case .stamp(let id):   try c.encode("stamp",   forKey: .type); try c.encode(id, forKey: .id)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id   = try c.decode(UUID.self,   forKey: .id)
        let type = try c.decode(String.self, forKey: .type)
        self = type == "stamp" ? .stamp(id) : .drawing(id)
    }
}

// MARK: - PlacedStamp Codable

extension PlacedStamp: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, emoji, px, py, size, rotation, opacity
        case flipX, flipY, flipStep
        case customImageId, inlineImageData
        case stampText, fontName, fontStyle, textAlignment
        case textColor, textBgColor, stampWidth, stampHeight
        case snugWidthRatio, snugHeightRatio
        case shadowEnabled, shadowColor, shadowBlur, shadowOffsetX, shadowOffsetY
        case createdAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,              forKey: .id)
        try c.encode(emoji,           forKey: .emoji)
        try c.encode(Double(position.x), forKey: .px)
        try c.encode(Double(position.y), forKey: .py)
        try c.encode(Double(size),    forKey: .size)
        try c.encode(rotation,        forKey: .rotation)
        try c.encode(opacity,         forKey: .opacity)
        try c.encode(flipX,           forKey: .flipX)
        try c.encode(flipY,           forKey: .flipY)
        try c.encode(flipStep,        forKey: .flipStep)
        try c.encodeIfPresent(customImageId, forKey: .customImageId)
        try c.encodeIfPresent(inlineImage?.pngData(), forKey: .inlineImageData)
        try c.encodeIfPresent(stampText,    forKey: .stampText)
        try c.encodeIfPresent(fontName,     forKey: .fontName)
        try c.encode(fontStyle,             forKey: .fontStyle)
        try c.encode(textAlignment,         forKey: .textAlignment)
        try c.encode(CodableColor(textColor),   forKey: .textColor)
        try c.encode(CodableColor(textBgColor), forKey: .textBgColor)
        try c.encode(Double(stampWidth),    forKey: .stampWidth)
        try c.encode(Double(stampHeight),   forKey: .stampHeight)
        try c.encode(Double(snugWidthRatio),  forKey: .snugWidthRatio)
        try c.encode(Double(snugHeightRatio), forKey: .snugHeightRatio)
        try c.encode(shadowEnabled,               forKey: .shadowEnabled)
        try c.encode(CodableColor(shadowColor),   forKey: .shadowColor)
        try c.encode(shadowBlur,                  forKey: .shadowBlur)
        try c.encode(shadowOffsetX,               forKey: .shadowOffsetX)
        try c.encode(shadowOffsetY,               forKey: .shadowOffsetY)
        try c.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self,   forKey: .id)
        emoji          = try c.decode(String.self, forKey: .emoji)
        let px         = CGFloat(try c.decode(Double.self, forKey: .px))
        let py         = CGFloat(try c.decode(Double.self, forKey: .py))
        position       = CGPoint(x: px, y: py)
        size           = CGFloat(try c.decode(Double.self, forKey: .size))
        rotation       = try c.decode(Double.self, forKey: .rotation)
        opacity        = try c.decode(Double.self, forKey: .opacity)
        flipX          = try c.decode(Bool.self,   forKey: .flipX)
        flipY          = try c.decode(Bool.self,   forKey: .flipY)
        flipStep       = try c.decode(Int.self,    forKey: .flipStep)
        customImageId  = try c.decodeIfPresent(UUID.self,   forKey: .customImageId)
        if let data    = try c.decodeIfPresent(Data.self,   forKey: .inlineImageData) {
            inlineImage = UIImage(data: data)
        } else {
            inlineImage = nil
        }
        stampText      = try c.decodeIfPresent(String.self, forKey: .stampText)
        fontName       = try c.decodeIfPresent(String.self, forKey: .fontName)
        fontStyle      = try c.decode(String.self, forKey: .fontStyle)
        textAlignment  = try c.decode(String.self, forKey: .textAlignment)
        textColor      = try c.decode(CodableColor.self, forKey: .textColor).color
        textBgColor    = try c.decode(CodableColor.self, forKey: .textBgColor).color
        stampWidth     = CGFloat(try c.decode(Double.self, forKey: .stampWidth))
        stampHeight    = CGFloat(try c.decode(Double.self, forKey: .stampHeight))
        snugWidthRatio  = CGFloat(try c.decode(Double.self, forKey: .snugWidthRatio))
        snugHeightRatio = CGFloat(try c.decode(Double.self, forKey: .snugHeightRatio))
        // Shadow — decodeIfPresent so older .skadoodle files without shadow fields still load
        shadowEnabled  = try c.decodeIfPresent(Bool.self,         forKey: .shadowEnabled)  ?? false
        shadowColor    = (try c.decodeIfPresent(CodableColor.self, forKey: .shadowColor))?.color ?? .black
        shadowBlur     = try c.decodeIfPresent(Double.self,        forKey: .shadowBlur)     ?? 4.0
        shadowOffsetX  = try c.decodeIfPresent(Double.self,        forKey: .shadowOffsetX)  ?? 2.0
        shadowOffsetY  = try c.decodeIfPresent(Double.self,        forKey: .shadowOffsetY)  ?? 2.0
        let ts         = try c.decodeIfPresent(Double.self,        forKey: .createdAt)
        createdAt      = ts.map { Date(timeIntervalSince1970: $0) } ?? Date(timeIntervalSince1970: 0)
    }
}
