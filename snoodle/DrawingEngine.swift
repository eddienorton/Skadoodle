//
//  DrawingEngine.swift
//  snoodle
//

import SwiftUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine
import Vision

enum DualToneStyle: String, CaseIterable, Identifiable, Codable {
    case gradient    = "Gradient"
    case split       = "Split"
    case reactive    = "Reactive"
    case alternating = "Alternating"
    case braid       = "Braid"
    case trim        = "Trim"
    case hairy       = "Hairy"
    case thorns      = "Thorns"
    case bubble      = "Bubble"
    case stars       = "Stars"
    case tube        = "Tube"
    var id: String { rawValue }

    /// One precise icon per sub-style — the single source of truth for both
    /// the style-picker chips (DualToneStyleChip) and the main pen toolbar
    /// button, so whichever style is actually active is what's shown, not a
    /// single generic "Dual Tone" icon regardless of which of the 12 is on.
    var icon: String {
        switch self {
        case .gradient:    return "arrow.left.to.line.alt"
        case .split:       return "rectangle.split.2x1"
        case .reactive:    return "arrow.up.left.and.arrow.down.right"
        case .alternating: return "alternatingcurrent"
        case .braid:       return "link"
        case .trim:        return "line.3.horizontal"
        case .hairy:       return "sun.min"
        case .thorns:      return "bolt"
        case .bubble:      return "circle.grid.3x3"
        case .stars:       return "star"
        case .tube:        return "cylinder"
        }
    }
}

enum PenType: Equatable {
    case pencil
    case ink
    case brush
    case marker
    case chalk
    case neon
    case spray
    case watercolor
    case dotted
    case calligraphy
    case confetti
    case airbrush
    case dashed
    case hearts
    case sparkle
    case splatter
    case dualTone(DualToneStyle)

    var displayName: String {
        switch self {
        case .pencil:   return "Pencil"
        case .ink:      return "Ink"
        case .brush:    return "Brush"
        case .marker:   return "Marker"
        case .chalk:    return "Chalk"
        case .neon:     return "Neon"
        case .spray:    return "Spray"
        case .watercolor: return "Watercolor"
        case .dotted:   return "Dotted"
        case .calligraphy: return "Calligraphy"
        case .confetti: return "Confetti"
        case .airbrush: return "Airbrush"
        case .dashed:   return "Dashed"
        case .hearts:   return "Hearts"
        case .sparkle:  return "Sparkle"
        case .splatter: return "Splatter"
        case .dualTone: return "Dual Tone"
        }
    }

    var icon: String {
        switch self {
        case .pencil:   return "pencil"
        case .ink:      return "paintbrush.pointed"
        case .brush:    return "paintbrush"
        case .marker:   return "highlighter"
        case .chalk:    return "scribble"
        case .neon:     return "bolt.fill"
        case .spray:    return "aqi.medium"
        case .watercolor: return "drop.fill"
        case .dotted:   return "ellipsis"
        case .calligraphy: return "signature"
        case .confetti: return "sparkles"
        case .airbrush: return "wind"
        case .dashed:   return "square.dashed"
        case .hearts:   return "heart.fill"
        case .sparkle:  return "sparkle"
        case .splatter: return "burst.fill"
        case .dualTone(let style): return style.icon
        }
    }

    var isDualTone: Bool {
        if case .dualTone = self { return true }
        _ = self  // suppress exhaustiveness warning for new cases
        return false
    }

    var dualToneStyle: DualToneStyle {
        if case .dualTone(let s) = self { return s }
        return .gradient
    }
}

// MARK: - Layer Model

struct DrawingLayer: Identifiable {
    var id: UUID
    var lines: [DrawingLine]
    var opacity: Double = 1.0
    var createdAt: Date = Date()
    init(id: UUID = UUID(), lines: [DrawingLine] = [], opacity: Double = 1.0, createdAt: Date = Date()) {
        self.id = id
        self.lines = lines
        self.opacity = opacity
        self.createdAt = createdAt
    }
}

enum LayerEntry: Identifiable {
    case drawing(UUID)
    case stamp(UUID)
    var id: UUID {
        switch self {
        case .drawing(let id): return id
        case .stamp(let id): return id
        }
    }
}

struct CanvasSnapshot {
    var drawingLayers: [DrawingLayer]
    var stamps: [PlacedStamp]
    var layerOrder: [LayerEntry]
    var backgroundImage: UIImage? = nil
    var backgroundOffset: CGSize = .zero
    var bgOpacity: Double = 1.0
    var bgBlur: Double = 0.0
    var bgBrightness: Double = 0.0
    var bgSaturation: Double = 1.0
}

struct DrawingLine {
    var points: [CGPoint]
    var widths: [CGFloat]  // per-point width for pressure simulation
    var color: Color
    var lineWidth: CGFloat  // base width (used for eraser)
    var isEraser: Bool
    var penType: PenType = .pencil
    var colorB: Color = .blue   // second color for dualTone pens
    var timestamp: Date = Date()  // set at stroke commit; used for timelapse chronological ordering
}

// Holds mutable gesture flags that must be visible synchronously across events
// within a single gesture — @State value semantics would give stale snapshots.
private class DrawGestureState {
    var modeSwitch: Bool = false  // true after auto-switching from stamp mode mid-gesture
    var fired: Bool = false       // true after onStampModeDragOnEmpty was called this gesture
}

struct DrawingCanvas: View {
    @Binding var lines: [DrawingLine]           // active layer's lines; DrawingCanvas appends here
    var currentColor: Color
    @Binding var lineWidth: CGFloat
    @Binding var isEraser: Bool
    var canvasColor: Color = .white
    var backgroundImage: UIImage? = nil
    var backgroundOffset: CGSize = .zero
    var onBackgroundPan: ((CGSize) -> Void)? = nil
    var penType: PenType = .pencil
    var colorB: Color = .blue
    var currentStamps: [PlacedStamp] = []
    var isLongPressing: Bool = false
    var stampResizeTargetId: UUID? = nil
    var isStampSelected: Bool = false          // true when a stamp is selected; raises pencil movement threshold to suppress deselect-tap dots
    var drawingEnabled: Bool = true            // false in stamp/hand mode — disables all pen and finger drawing input
    var renderLines: Bool = false              // true = self-renders (DoodleStampCreatorView); false = external layer canvases render
    var onBeforeDraw: (() -> Void)? = nil      // called once at stroke start; caller should push undo snapshot
    var onEraserCommitted: ((DrawingLine) -> Void)? = nil  // called when an eraser stroke lands; caller may redirect to another layer
    var onStampModeDragOnEmpty: ((CGPoint) -> Bool)? = nil // called when stamp mode is on and drag starts; return true = switched to draw mode
    // Live pencil-pressure readout for calibration/debugging — fires on every pencil move with
    // (normalized pressure 0...1, the width multiplier actually applied to that point). Property
    // itself is unconditional (Swift doesn't reliably support #if around a single labeled argument
    // in a multi-line call's argument list — this avoids that entirely); DrawScreen only ever wires
    // real behavior into it inside #if DEBUG, so it's an inert always-nil-in-effect no-op in release.
    var onPencilPressureDebug: ((CGFloat, CGFloat) -> Void)? = nil
    // Fires once a stroke actually commits (pen lift), with the finalized line — not on mere
    // color selection. This is the hook for "recent colors" reordering: per direct decision,
    // selecting a color in the picker shouldn't reorder the row (felt jumpy while just
    // comparing colors), only actually drawing with it should — same mental model as stamps
    // reordering on placement, not on preview. Caller should skip line.isEraser strokes, since
    // the eraser's "color" is just the canvas color, not a real pen-color selection.
    var onStrokeCommitted: ((DrawingLine) -> Void)? = nil
    @Binding var currentLine: DrawingLine?     // live preview; updated during stroke, nil when idle

    @State private var lastPoint: CGPoint? = nil
    @State private var lastTime: Date? = nil
    @State private var lastSpeed: CGFloat? = nil
    @State private var redrawTrigger: Int = 0
    @State private var gestureState = DrawGestureState()  // class: mutations visible immediately across events

    var body: some View {
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        return Canvas { context, size in
            let _ = redrawTrigger
            // DoodleStampCreatorView uses renderLines=true; DrawScreen uses external layer canvases.
            if renderLines {
                for line in lines { drawLine(line, in: &context) }
                if let current = currentLine { drawLine(current, in: &context) }
            }
        }
        .allowsHitTesting(false)
        .background(canvasColor)
        .contentShape(Rectangle())
        // On iPhone, always attach a DragGesture so single-finger touches are consumed
        // by SwiftUI and can't escape to the sheet's interactive-dismissal recognizer.
        // When drawingEnabled is false (stamp/hand mode), the gesture exists but is a no-op.
        .gesture(isIPad ? nil : DragGesture(minimumDistance: 0)
            .onChanged { value in
                // canDraw is true if either drawing is normally enabled, or we auto-switched
                // from stamp mode mid-gesture (gestureState is class-based so mutations are
                // immediately visible to the next read, unlike @State value snapshots).
                if !drawingEnabled && !gestureState.modeSwitch && !gestureState.fired {
                    let moved = hypot(value.translation.width, value.translation.height)
                    if moved > 8 {
                        gestureState.fired = true
                        let didSwitch = onStampModeDragOnEmpty?(value.startLocation) ?? false
                        if didSwitch { gestureState.modeSwitch = true }
                    }
                }
                guard drawingEnabled || gestureState.modeSwitch else { return }
                guard !isLongPressing && stampResizeTargetId == nil else {
                    currentLine = nil; lastPoint = nil; lastTime = nil; lastSpeed = nil
                    return
                }
                let point = value.location
                let moved = hypot(value.translation.width, value.translation.height)
                // When a stamp was selected at stroke start, require 12pt before drawing
                // begins — same guard as iPad PencilTouchView — so a tap that deselects
                // a stamp doesn't leave a dot mark (pencil on iPhone can move ~3–12pt
                // and still register as a valid tap).
                let drawThreshold: CGFloat = isStampSelected ? 12 : 3
                if currentLine == nil {
                    if moved < drawThreshold { return }
                    onBeforeDraw?()
                    currentLine = DrawingLine(
                        points: [point],
                        widths: [lineWidth],
                        color: isEraser ? canvasColor : currentColor,
                        lineWidth: lineWidth,
                        isEraser: isEraser,
                        penType: isEraser ? .pencil : penType,
                        colorB: colorB
                    )
                } else {
                    currentLine?.points.append(point)
                    currentLine?.widths.append(lineWidth)
                }
                lastPoint = point
                lastTime = Date()
            }
            .onEnded { _ in
                let wasSwitched = gestureState.modeSwitch
                gestureState.modeSwitch = false; gestureState.fired = false  // reset for next gesture
                guard drawingEnabled || wasSwitched else { return }
                if var line = currentLine, line.points.count > 1 {
                    line.timestamp = Date()
                    lines.append(line)
                    if line.isEraser { onEraserCommitted?(line) } else { onStrokeCommitted?(line) }
                }
                currentLine = nil; lastPoint = nil; lastTime = nil; lastSpeed = nil
            }
        )

        .overlay(isIPad ? AnyView(PencilInputView(
                isLongPressing: isLongPressing,
                stampResizeTargetId: stampResizeTargetId,
                isStampSelected: isStampSelected,
                onBegan: { point, pressure, isPencil in
                    guard drawingEnabled else {
                        // Stamp mode: check once whether to auto-switch to draw mode
                        if !gestureState.fired {
                            gestureState.fired = true
                            let didSwitch = onStampModeDragOnEmpty?(point) ?? false
                            if didSwitch {
                                gestureState.modeSwitch = true
                                // Set up drawing start point so onMoved can draw immediately
                                lastPoint = point
                                lastTime = Date()
                                onBeforeDraw?()
                            }
                        }
                        return
                    }
                    guard !isLongPressing && stampResizeTargetId == nil else { return }
                    lastPoint = point
                    lastTime = Date()
                    // Snapshot before first touch — so onMoved never blocks the first frame
                    onBeforeDraw?()
                },
                onMoved: { point, pressure, isPencil in
                    guard drawingEnabled || gestureState.modeSwitch else { return }
                    guard !isLongPressing && stampResizeTargetId == nil else {
                        currentLine = nil; lastPoint = nil; lastTime = nil; lastSpeed = nil
                        return
                    }
                    let pointCount = currentLine?.points.count ?? 0
                    // Ramp over first 8 points to prevent initial blotch
                    let ramp = pointCount < 8 ? CGFloat(pointCount) / 8.0 : 1.0
                    // Pencil: pressure-sensitive width. Eraser/finger: exact lineWidth.
                    let targetW: CGFloat
                    if isEraser {
                        targetW = lineWidth
                    } else if isPencil && penType == .pencil {
                        // Pencil pressure model v5, per direct request — a pure constant additive
                        // boost (v4, +30 always) felt right for thin presets but "hardly noticeable"
                        // on the biggest ones. Hybrid now: boost = a flat constant PLUS a fraction of
                        // the selected thickness itself, so thin presets still get a big-feeling boost
                        // (dominated by the constant) while thick presets scale up more too (the ratio
                        // term catches up). Tuned so thickness 1's boost ≈ 50–60 and thickness 130's
                        // boost roughly doubles it: boostConstant=50, boostRatio=0.6 → thickness 1 boost
                        // ≈50.6 (max≈51.6), thickness 130 boost ≈128 (max≈258, ~2x). Both are first
                        // guesses, easy to retune once felt on device. `ramp` still eases in over the
                        // stroke's first 8 points so touch-down starts right at the floor.
                        //
                        // Deliberately gated to penType == .pencil, not just isPencil (real Apple
                        // Pencil hardware) — this formula's wide boost range was tuned specifically for
                        // the Pencil tool's own width. Every OTHER pen reads its rendered width back
                        // through pressureAt() as a multiplier on its own geometry (Neon's glow passes,
                        // Chalk's texture, Calligraphy's angle factor, every Dual Tone style, etc.) —
                        // those were all empirically tuned against the old, much narrower pressure band
                        // below, so feeding them this wide a range blew them out (Neon rendering "way
                        // too big" was the tell). Real Pencil hardware used with any pen OTHER than the
                        // Pencil tool falls through to the narrow band in the branch below instead.
                        let boostConstant: CGFloat = 50.0
                        let boostRatio: CGFloat = 0.6
                        let maxBoost = boostConstant + lineWidth * boostRatio
                        let fullRangeW = lineWidth + maxBoost * pressure
                        targetW = max(1.0, lineWidth + (fullRangeW - lineWidth) * ramp)
                        #if DEBUG
                        onPencilPressureDebug?(pressure, targetW / max(lineWidth, 0.01))
                        #endif
                    } else if isPencil {
                        // Real Apple Pencil hardware, but a pen other than Pencil is selected. Uses the
                        // original, narrow pressure band every other pen's own width multipliers were
                        // actually tuned against (roughly 0.3x-1.3x of the selected thickness) — not the
                        // wide v5 range above, which is Pencil-tool-specific. See the comment on the
                        // penType == .pencil branch for why this split exists.
                        let clampedPressure = min(pressure, 0.6 + ramp * 0.4)
                        let pressureScale = 0.3 + clampedPressure * 1.0
                        targetW = lineWidth * pressureScale
                    } else {
                        targetW = lineWidth * ramp + 1.0 * (1.0 - ramp)
                    }
                    if currentLine == nil, let start = lastPoint {
                        currentLine = DrawingLine(
                            points: [start, point],
                            widths: [1.0, 1.0],
                            color: isEraser ? canvasColor : currentColor,
                            lineWidth: lineWidth,
                            isEraser: isEraser,
                            penType: isEraser ? .pencil : penType,
                            colorB: colorB
                        )
                    } else {
                        currentLine?.points.append(point)
                        currentLine?.widths.append(targetW)
                    }
                    lastPoint = point
                    lastTime = Date()
                },
                onEnded: {
                    defer { gestureState.modeSwitch = false; gestureState.fired = false }
                    guard drawingEnabled || gestureState.modeSwitch else { return }
                    if let line = currentLine, line.points.count > 1 {
                        var finalLine = line
                        finalLine.timestamp = Date()
                        DispatchQueue.main.async {
                            var updated = lines
                            updated.append(finalLine)
                            lines = updated
                            redrawTrigger += 1
                            if finalLine.isEraser { onEraserCommitted?(finalLine) } else { onStrokeCommitted?(finalLine) }
                            // Clear live preview AFTER committed stroke lands in lines — prevents flicker
                            currentLine = nil
                        }
                    } else {
                        currentLine = nil
                    }
                    lastPoint = nil; lastTime = nil; lastSpeed = nil
                },
                onTwoFingerPan: backgroundImage != nil ? onBackgroundPan : nil
            )) : nil
        )
    }

    private func drawLine(_ line: DrawingLine, in context: inout GraphicsContext) {
        renderLine(line, in: &context, canvasColor: canvasColor)
    }
}

// MARK: - Background effects cache for eraser
// Eraser shading paints the background image with effects applied. Cache the processed result
// so CIFilters aren't re-applied on every Canvas redraw (which fires at ~60fps during drawing).
// The cache always produces a FULLY OPAQUE image — when bgOpacity < 1, the image is pre-composited
// against baseColor so the erased area exactly matches the visual appearance of un-drawn regions,
// without double-opacity from the background image layer below in the ZStack.
private final class _BgEffectsImageCache {
    var sourceImage: UIImage?
    var opacity: Double = 1; var blur: Double = 0; var brightness: Double = 0; var saturation: Double = 1
    var baseColor: UIColor = .white
    var processed: UIImage?

    func get(_ img: UIImage, op: Double, bl: Double, br: Double, sa: Double, base: UIColor = .white) -> UIImage {
        let needsProcessing = op < 1.0 || bl > 0 || br != 0 || sa != 1.0
        guard needsProcessing else { return img }
        if let cached = processed,
           sourceImage === img,
           opacity == op, blur == bl, brightness == br, saturation == sa,
           baseColor == base { return cached }
        // Apply color/blur effects at full opacity first, then composite against base color.
        let colorProcessed = (bl > 0 || br != 0 || sa != 1.0)
            ? applyBgEffectsForExport(to: img, bgOpacity: 1.0, bgBlur: bl, bgBrightness: br, bgSaturation: sa)
            : img
        // Always bake into a fully opaque image — CI processing (especially CIGaussianBlur) can
        // produce a CGImage with an alpha channel even for fully-opaque source images. If the
        // cached image has any alpha < 1, .tiledImage shading paints semi-transparent eraser
        // strokes, leaving a gray film over whatever was drawn underneath.
        // Compositing order: white → canvas color (base) → image — matching the live canvas ZStack.
        // The opaque context initializes to black, so we must fill white first; otherwise a
        // semi-transparent canvas color composites over black and produces a wrong dark result.
        UIGraphicsBeginImageContextWithOptions(colorProcessed.size, true, colorProcessed.scale)
        defer { UIGraphicsEndImageContext() }
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: colorProcessed.size))
        base.setFill()
        UIRectFill(CGRect(origin: .zero, size: colorProcessed.size))
        colorProcessed.draw(at: .zero, blendMode: .normal, alpha: CGFloat(op))
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? colorProcessed
        sourceImage = img; opacity = op; blur = bl; brightness = br; saturation = sa; baseColor = base
        processed = result
        return result
    }
}
private let _bgEffectsImageCache = _BgEffectsImageCache()

/// Returns the background image pre-processed for eraser use — effects applied via CIFilter pipeline,
/// result baked fully opaque. Uses the shared cache so repeated calls with same params are free.
/// Pass the result to DrawingLayerCanvas as `backgroundImage` with default effect params
/// (bgOpacity:1, bgBlur:0, bgBrightness:0, bgSaturation:1) so drawEraserLine's needsProcessing
/// check is false and the image is used directly — identical to the video export path.
func processedBackgroundForEraser(
    _ img: UIImage,
    bgOpacity: Double, bgBlur: Double, bgBrightness: Double, bgSaturation: Double,
    canvasColor: Color
) -> UIImage {
    // Pre-composite canvasColor over white to produce a fully opaque base.
    // Matches the live canvas ZStack: canvasColor (possibly semi-transparent) sits over the white
    // system background. Passing a semi-transparent UIColor as the cache base requires UIKit to
    // composite it over white via UIRectFill — which can diverge from SwiftUI's compositing path
    // (different color spaces, P3 vs sRGB) and produce a slightly darker result.
    // Computing it here in sRGB via UIColor.getRed guarantees the same value as opaqueCanvasColor
    // in DrawScreen, eliminating the UIKit/SwiftUI color-space discrepancy.
    let ui = UIColor(canvasColor)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    let opaqueBase: UIColor = a >= 1.0 ? ui
        : UIColor(red: a*r + (1-a), green: a*g + (1-a), blue: a*b + (1-a), alpha: 1.0)
    return _bgEffectsImageCache.get(img, op: bgOpacity, bl: bgBlur, br: bgBrightness, sa: bgSaturation,
                                    base: opaqueBase)
}

// MARK: - Drawing Layer Canvas
// Renders one drawing layer's committed lines plus the optional live-preview stroke.
struct DrawingLayerCanvas: View {
    let lines: [DrawingLine]
    let currentLine: DrawingLine?
    let canvasColor: Color
    var backgroundImage: UIImage? = nil
    var backgroundOffset: CGSize = .zero
    var bgOpacity: Double = 1.0
    var bgBlur: Double = 0.0
    var bgBrightness: Double = 0.0
    var bgSaturation: Double = 1.0
    /// The solid canvas color rendered below the background image in the ZStack.
    /// Used by the eraser to pre-composite the image at bgOpacity → fully opaque pixels.
    var baseCanvasColor: Color = .white
    var body: some View {
        Canvas { context, size in
            for line in lines { renderLine(line, in: &context, canvasColor: canvasColor, backgroundImage: backgroundImage, backgroundOffset: backgroundOffset, canvasSize: size, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation, baseCanvasColor: baseCanvasColor) }
            // isLivePreview: true only for the actively-drawing stroke — this is the one line whose
            // point count is still growing frame to frame, which is what the flag exists to guard.
            if let c = currentLine { renderLine(c, in: &context, canvasColor: canvasColor, backgroundImage: backgroundImage, backgroundOffset: backgroundOffset, canvasSize: size, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation, baseCanvasColor: baseCanvasColor, isLivePreview: true) }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Eraser Solid View
// Used for eraser-only drawing layers. Unlike DrawingLayerCanvas, this has a transparent
// background and paints eraser paths as solid canvasColor strokes (normal blend mode).
// This lets the eraser visually cover stamps below without a solid white rectangle blocking them.
struct EraserSolidView: View {
    let lines: [DrawingLine]
    let currentLine: DrawingLine?
    let canvasColor: Color
    var body: some View {
        Canvas { context, _ in
            let allLines = lines + (currentLine.map { [$0] } ?? [])
            for line in allLines {
                let count = line.points.count
                let baseW = line.lineWidth
                if count == 1 {
                    let pt = line.points[0]
                    let rect = CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)
                    context.fill(Path(ellipseIn: rect), with: .color(canvasColor))
                } else {
                    for i in 1..<count {
                        var seg = Path()
                        seg.move(to: line.points[i-1])
                        seg.addLine(to: line.points[i])
                        context.stroke(seg, with: .color(canvasColor),
                                       style: StrokeStyle(lineWidth: baseW, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

// MARK: - Two Finger Pan Overlay (for background repositioning)
/// Passes through pencil touches and single-finger touches — only intercepts 2-finger finger touch
class TwoFingerOnlyView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Pass through pencil touches entirely
        if let touch = event?.allTouches?.first, touch.type == .pencil {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only handle if 2+ finger touches — pass single touch through
        if touches.count < 2 && (touches.first?.type != .pencil) {
            next?.touchesBegan(touches, with: event)
        } else {
            super.touchesBegan(touches, with: event)
        }
    }
}

struct TwoFingerPanView: UIViewRepresentable {
    var onChanged: (CGSize) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = TwoFingerOnlyView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isMultipleTouchEnabled = true
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: ((CGSize) -> Void)?
        var onEnded: (() -> Void)?
        private var startTranslation: CGPoint = .zero

        // Allow simultaneous recognition with everything below
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        // Only begin if we have exactly 2 touches
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            print("🟠 gestureRecognizerShouldBegin touches: \(g.numberOfTouches)")
            return g.numberOfTouches == 2
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            print("🟠 TwoFingerPan state: \(g.state.rawValue) touches: \(g.numberOfTouches)")
            switch g.state {
            case .began:
                startTranslation = g.translation(in: g.view)
            case .changed:
                let t = g.translation(in: g.view)
                let delta = CGSize(width: t.x - startTranslation.x, height: t.y - startTranslation.y)
                onChanged?(delta)
                startTranslation = t
            case .ended, .cancelled:
                onEnded?()
            default: break
            }
        }
    }
}

// MARK: - Pencil Input View
// Handles Apple Pencil and finger touch separately.
// Pencil → draws. Finger → ignored here (handled by stamp/gesture layer above).

struct PencilInputView: UIViewRepresentable {
    var isLongPressing: Bool
    var stampResizeTargetId: UUID?
    var isStampSelected: Bool = false
    var onBegan: (CGPoint, CGFloat, Bool) -> Void
    var onMoved: (CGPoint, CGFloat, Bool) -> Void
    var onEnded: () -> Void
    var onTwoFingerPan: ((CGSize) -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let view = PencilTouchView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isMultipleTouchEnabled = true
        view.isStampSelected = isStampSelected
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onTwoFingerPan = onTwoFingerPan
        // Two-finger pan
        let pan = UIPanGestureRecognizer(target: view, action: #selector(PencilTouchView.handleTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? PencilTouchView else { return }
        view.isStampSelected = isStampSelected
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onTwoFingerPan = onTwoFingerPan
    }
}

class PencilTouchView: UIView {
    var isStampSelected: Bool = false
    var onBegan: ((CGPoint, CGFloat, Bool) -> Void)?
    var onMoved: ((CGPoint, CGFloat, Bool) -> Void)?
    var onEnded: (() -> Void)?
    var onTwoFingerPan: ((CGSize) -> Void)?

    private var activeTouch: UITouch? = nil
    private var lastPanTranslation: CGPoint = .zero
    // Pencil-tap deselect guard: if a stamp was selected when touch began, defer
    // onBegan and suppress onMoved until the pencil moves ≥12pt. A pencil tap
    // that deselects a stamp can move up to ~12pt (still a valid iOS tap), which
    // would cross the 3pt draw threshold and leave a dot. Deferring onBegan means
    // no undo snapshot is pushed and no lastPoint is set for suppressed taps.
    private var touchBeganWithStampSelected: Bool = false
    private var touchBeginPoint: CGPoint = .zero
    private var deferredBeganArgs: (point: CGPoint, pressure: CGFloat, isPencil: Bool)? = nil

    @objc func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            lastPanTranslation = g.translation(in: self)
        case .changed:
            let t = g.translation(in: self)
            let delta = CGSize(width: t.x - lastPanTranslation.x, height: t.y - lastPanTranslation.y)
            onTwoFingerPan?(delta)
            lastPanTranslation = t
        default: break
        }
    }
    // On iPad, only Pencil draws. On iPhone, finger draws too.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if UIDevice.current.userInterfaceIdiom == .pad {
            if let touches = event?.allTouches {
                let fingerTouches = touches.filter { $0.type != .pencil && $0.type != .stylus }
                if fingerTouches.count == 1 && !touches.contains(where: { $0.type == .pencil || $0.type == .stylus }) {
                    return nil
                }
            } else {
                return nil
            }
        }
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil else { return }
        // Both finger and Pencil draw on all devices
        guard let touch = touches.first(where: { $0.type == .direct || $0.type == .pencil || $0.type == .stylus }) else { return }
        activeTouch = touch
        let point = activeTouch!.location(in: self)
        // Record whether a stamp is currently selected so touchesMoved can apply a
        // higher movement threshold. A pencil "deselect tap" can move ~3–12pt (still
        // recognized as a tap by iOS) which crosses the 3pt draw threshold and leaves
        // a dot. Requiring 12pt when stamp was selected prevents this.
        let isPencilTouch = activeTouch!.type == .pencil || activeTouch!.type == .stylus
        touchBeganWithStampSelected = isPencilTouch && isStampSelected
        touchBeginPoint = point
        // Pencil: use real pressure. Finger: fixed 0.5 (no pressure sensor).
        // force==0 falls back to 0.0, not 0.5 — a zero reading is a real Apple Pencil quirk at the
        // very start of contact (sensor hasn't stabilized yet) and right at lift-off (force dropping
        // toward zero), so it should read as "light/no pressure," not "medium." A 0.5 fallback was
        // harmless under the old ±30% pressure-scale formula but produces a large, obviously-wrong
        // mark under the new full-range mapping — this was the actual cause of the "max-thick ball
        // at the start/end of a stroke even with very little pressure" report.
        let pressure: CGFloat = activeTouch!.type == .pencil || activeTouch!.type == .stylus
            ? (activeTouch!.force > 0 ? activeTouch!.force / activeTouch!.maximumPossibleForce : 0.0)
            : 0.5
        if touchBeganWithStampSelected {
            // Defer: don't push undo snapshot or set lastPoint until we know this
            // is a real drag (≥12pt), not a deselect tap.
            deferredBeganArgs = (point, pressure, isPencilTouch)
        } else {
            onBegan?(point, pressure, isPencilTouch)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        let allTouches = event?.coalescedTouches(for: active) ?? [active]
        for touch in allTouches {
            let point = touch.location(in: self)
            // If touch began while a stamp was selected, suppress drawing until the
            // pencil has moved far enough that it's clearly a drag (not a deselect tap).
            if touchBeganWithStampSelected {
                let dist = hypot(point.x - touchBeginPoint.x, point.y - touchBeginPoint.y)
                if dist < 12 { continue }
                // Threshold crossed — real drag confirmed. Fire deferred onBegan so
                // lastPoint and undo snapshot are set before the first onMoved call.
                touchBeganWithStampSelected = false
                if let args = deferredBeganArgs {
                    onBegan?(args.point, args.pressure, args.isPencil)
                    deferredBeganArgs = nil
                }
            }
            // Pencil: use real pressure. Finger: fixed 0.5 (no pressure sensor).
            // See touchesBegan's comment above — force==0 falls back to 0.0, not 0.5.
            let pressure: CGFloat = touch.type == .pencil || touch.type == .stylus
                ? (touch.force > 0 ? touch.force / touch.maximumPossibleForce : 0.0)
                : 0.5
            let isPencilMove = touch.type == .pencil || touch.type == .stylus
            onMoved?(point, pressure, isPencilMove)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeTouch, touches.contains(active) else { return }
        activeTouch = nil
        touchBeganWithStampSelected = false
        deferredBeganArgs = nil
        onEnded?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouch = nil
        touchBeganWithStampSelected = false
        deferredBeganArgs = nil
        onEnded?()
    }
}

// MARK: - Shared Line Renderer



/// Single rendering function used by both the live SwiftUI Canvas and the UIImage export.
/// All pen types are implemented here so they stay in sync.
func renderLine(_ line: DrawingLine, in context: inout GraphicsContext, canvasColor: Color, backgroundImage: UIImage? = nil, backgroundOffset: CGSize = .zero, canvasSize: CGSize = .zero, bgOpacity: Double = 1.0, bgBlur: Double = 0.0, bgBrightness: Double = 0.0, bgSaturation: Double = 1.0, baseCanvasColor: Color = .white, isLivePreview: Bool = false) {
    guard line.points.count > 0 else { return }

    if line.isEraser {
        drawEraserLine(line, in: &context, canvasColor: canvasColor, backgroundImage: backgroundImage, backgroundOffset: backgroundOffset, canvasSize: canvasSize, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation, baseCanvasColor: baseCanvasColor)
        return
    }

    switch line.penType {
    case .pencil:
        // No taper at all — head or tail, live or committed — per direct request. WYSIWYG: if you
        // want a tapered pen-lift point at the end of a stroke, ease off the pencil yourself instead
        // of the app faking it. The head-taper zone had its own bug on top of that (see strokeTaper's
        // comment): its boundary is a fraction of the stroke's still-growing live length, so already-
        // drawn early points could drift back into the taper zone and get re-thinned mid-draw — the
        // reported "whole line wiggles while dragging." Suppressing both zones fixes that too.
        drawTaperedLine(line, color: line.color, in: &context, taperFraction: 0.2, minTaper: 0.08, opacity: 1.0, suppressTailTaperWhileLive: true, suppressHeadTaperWhileLive: true)
    case .ink:
        drawInkLine(line, in: &context)
    case .brush:
        drawBrushLine(line, in: &context)
    case .marker:
        drawMarkerLine(line, in: &context)
    case .chalk:
        drawChalkLine(line, in: &context)
    case .neon:
        drawNeonLine(line, in: &context)
    case .spray:
        drawSprayLine(line, in: &context)
    case .watercolor:
        drawWatercolorLine(line, in: &context)
    case .dotted:
        drawDottedLine(line, in: &context)
    case .calligraphy:
        drawCalligraphyLine(line, in: &context)
    case .confetti:
        drawConfettiLine(line, in: &context)
    case .airbrush:
        drawAirbrushLine(line, in: &context)
    case .dashed:
        drawDashedLine(line, in: &context)
    case .hearts:
        drawHeartsLine(line, in: &context)
    case .sparkle:
        drawSparkleLine(line, in: &context)
    case .splatter:
        drawSplatterLine(line, in: &context)
    case .dualTone(let style):
        drawDualToneLine(line, style: style, in: &context)
    }
}

/// Simulates a flat calligraphy nib held at a fixed angle. Unlike every other
/// pen here, width doesn't vary with pressure alone — it varies with the
/// *travel direction* of the stroke relative to the nib's fixed angle: full
/// width when travel is perpendicular to the nib edge, near-zero when travel
/// runs along it. That's the actual mechanic that makes calligraphy read as
/// calligraphy (bold diagonals, thin near-verticals/horizontals) rather than
/// just another pressure-tapered line.
///
/// **Bug fixed:** the first version computed travel angle from the tight
/// adjacent-point delta (points[i-1] to points[i]) — reported live as "the
/// angle doesn't matter, width is the same no matter what." That two-point
/// delta is dominated by natural hand jitter between consecutive raw touch
/// samples, which swings the local angle around somewhat randomly regardless
/// of the stroke's actual macro direction — a rapidly, near-randomly
/// fluctuating width across many short overlapping round-capped segments
/// visually averages out to what looks like one constant medium width,
/// exactly matching the report. Every other direction-dependent pen in this
/// file (.braid/.hairy/.thorns) avoids this by sampling a *wider* window —
/// points[i-1] to points[i+1] — for local direction, which smooths out that
/// jitter. Switched to the same convention here.
private func drawCalligraphyLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    let baseW = line.lineWidth
    let count = line.points.count
    guard count > 0 else { return }

    // 45° is the classic calligraphy nib hold. A constant is fine for v1 —
    // exposing it as a user-adjustable angle is a natural follow-up, not a
    // blocker for the core look.
    let nibAngle: CGFloat = .pi / 4
    let minWidthFraction: CGFloat = 0.12  // thinnest stroke never fully vanishes

    if count == 1 {
        let pt = line.points[0]
        let r = baseW * 0.5
        context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)),
                     with: .color(line.color))
        return
    }

    for i in 1..<count {
        let p0 = line.points[i-1], p1 = line.points[i]
        // Wider window for direction — same lo/hi convention as .braid/.hairy/
        // .thorns — instead of the raw (p0,p1) delta, which is too noisy.
        let lo = max(0, i-1), hi = min(count-1, i+1)
        let dx = line.points[hi].x - line.points[lo].x
        let dy = line.points[hi].y - line.points[lo].y
        let travelAngle = (dx == 0 && dy == 0) ? atan2(p1.y - p0.y, p1.x - p0.x) : atan2(dy, dx)
        let angleFactor = abs(sin(travelAngle - nibAngle))
        // No taper — same "no changes after it's laid down" rule as every other pen fixed this
        // session. Contributed to the reported "more pronounced delay" alongside the live-recompute
        // bug itself.
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.15, suppressTail: true, suppressHead: true)
        let w = baseW * max(minWidthFraction, angleFactor) * max(0.08, taper) * pressureAt(i, in: line)

        var seg = Path()
        seg.move(to: p0)
        seg.addLine(to: p1)
        context.stroke(seg, with: .color(line.color),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
}

/// Small rotated confetti pieces scattered along the path — no core stroke,
/// same "the pieces ARE the stroke" convention as .bubble/.stars. Colors
/// cycle through 4 deterministic variants built from the two colors the user
/// actually picked (colorA, colorB, and a lightened blend of each) rather
/// than arbitrary random RGB — keeps confetti relating to the chosen palette
/// instead of looking unrelated to it. Rotation/size/perpendicular-and-along
/// jitter all use the same sin-hash deterministic pseudo-random technique as
/// .hairy/.thorns (seeded by an incrementing piece index, so it's stable
/// frame to frame, not re-randomized on every redraw).
private func drawConfettiLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    let baseW = line.lineWidth
    let count = line.points.count
    guard count > 0 else { return }

    if count == 1 {
        let pt = line.points[0]
        context.fill(confettiPiece(center: pt, size: baseW * 0.55, rotation: 0),
                     with: .color(line.color))
        return
    }

    let pieceSize    = baseW * 0.55
    let pieceSpacing = baseW * 1.1

    var arcLen = [CGFloat](repeating: 0, count: count)
    for i in 1..<count {
        arcLen[i] = arcLen[i-1] + hypot(line.points[i].x - line.points[i-1].x,
                                         line.points[i].y - line.points[i-1].y)
    }

    var nextPieceAt: CGFloat = 0
    var pieceIdx = 0
    for i in 0..<count {
        guard arcLen[i] >= nextPieceAt else { continue }
        nextPieceAt += pieceSpacing

        let pt = line.points[i]
        let lo = max(0, i-1), hi = min(count-1, i+1)
        let ddx = line.points[hi].x - line.points[lo].x
        let ddy = line.points[hi].y - line.points[lo].y
        let dlen = hypot(ddx, ddy)
        let nx: CGFloat = dlen > 0 ? -ddy / dlen : 0
        let ny: CGFloat = dlen > 0 ?  ddx / dlen : 1

        let s = CGFloat(pieceIdx)
        let rRot  = fabs(sin(s * 91.3  + 1.7))
        let rSize = fabs(sin(s * 43.9  + 2.3))
        let rSide =      sin(s * 17.1  + 3.1)   // signed — which side of the path it lands on
        let rAlong = fabs(sin(s * 61.7 + 4.4))

        let pressure = pressureAt(i, in: line)
        let size = pieceSize * (0.6 + rSize * 0.7) * pressure
        let rotation = rRot * 2 * CGFloat.pi
        let perpOffset = rSide * pieceSize * 0.9
        let alongOffset = (rAlong - 0.5) * pieceSize * 0.6
        let center = CGPoint(x: pt.x + nx * perpOffset - ny * alongOffset,
                              y: pt.y + ny * perpOffset + nx * alongOffset)

        let color: Color
        switch pieceIdx % 4 {
        case 0:  color = line.color
        case 1:  color = line.colorB
        case 2:  color = blendColors(line.color, .white, t: 0.45)
        default: color = blendColors(line.colorB, .white, t: 0.45)
        }

        // Every third piece is a small circle instead of a rounded rect —
        // classic confetti mixes both shapes, keeps it from reading as a
        // single stamped repeating unit.
        let shape: Path = pieceIdx % 3 == 0
            ? Path(ellipseIn: CGRect(x: center.x - size/2, y: center.y - size/2, width: size, height: size))
            : confettiPiece(center: center, size: size, rotation: rotation)
        context.fill(shape, with: .color(color))
        pieceIdx += 1
    }
}

/// A small rotated rounded-rect confetti piece centered at `center`.
private func confettiPiece(center: CGPoint, size: CGFloat, rotation: CGFloat) -> Path {
    let rect = CGRect(x: -size/2, y: -size/3, width: size, height: size * 0.66)
    let piece = Path(roundedRect: rect, cornerRadius: size * 0.15)
    let transform = CGAffineTransform(rotationAngle: rotation)
        .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    return piece.applying(transform)
}

// A stroke's taper (both head AND tail) is computed as a fraction of the CURRENT total point
// count — while a stroke is still actively growing, that denominator changes on every redraw, so
// a fixed point's fractional position `t` keeps drifting even though its real pressure never
// changed. This causes two distinct bugs: (1) tail — the newest point (wherever the pen currently
// is) always sits at t≈1, so it's permanently taper-thinned no matter how hard you press; (2) head
// — for a point already drawn, `i` stays fixed but `count` keeps growing, so `t = i/(count-1)`
// keeps *shrinking* over time, meaning an early point that already settled at full width can drift
// back inside the taper zone and get artificially re-thinned well after the fact — visible as the
// whole stroke "wiggling" while actively drawing. suppressTail/suppressHead skip each check
// independently so a live in-progress render pass can opt out of either or both.
private func strokeTaper(i: Int, count: Int, taperFraction: CGFloat, suppressTail: Bool = false, suppressHead: Bool = false) -> CGFloat {
    let t = CGFloat(i) / CGFloat(max(count - 1, 1))
    if !suppressHead, t < taperFraction { return t / taperFraction }
    if !suppressTail, t > (1.0 - taperFraction) { return (1.0 - t) / taperFraction }
    return 1.0
}

private func drawEraserLine(_ line: DrawingLine, in context: inout GraphicsContext, canvasColor: Color, backgroundImage: UIImage? = nil, backgroundOffset: CGSize = .zero, canvasSize: CGSize = .zero, bgOpacity: Double = 1.0, bgBlur: Double = 0.0, bgBrightness: Double = 0.0, bgSaturation: Double = 1.0, baseCanvasColor: Color = .white) {
    let baseW = line.lineWidth
    let count = line.points.count

    // Determine what the eraser paints.
    // Background image takes priority over solid canvas color so eraser works correctly
    // in both the live canvas (canvasColor=.clear when bg image set) and the export path
    // (canvasColor=solid but backgroundImage still present).
    // The cache produces a fully opaque composite (image at bgOpacity over baseCanvasColor)
    // so erased pixels exactly match undrawn regions without double-opacity from the bg layer below.
    let shading: GraphicsContext.Shading
    if let bgImg = backgroundImage, canvasSize.width > 0, canvasSize.height > 0,
       bgImg.size.width > 0, bgImg.size.height > 0 {
        // Cover-fit the image to canvas, matching the SwiftUI background layer rendering exactly.
        // bgImg.size is in points (UIImage.size always returns points regardless of image scale).
        let effectiveImg = _bgEffectsImageCache.get(bgImg, op: bgOpacity, bl: bgBlur, br: bgBrightness, sa: bgSaturation, base: UIColor(baseCanvasColor))
        let coverScale = max(canvasSize.width / effectiveImg.size.width, canvasSize.height / effectiveImg.size.height)
        let scaledW = effectiveImg.size.width * coverScale
        let scaledH = effectiveImg.size.height * coverScale
        // Center then apply user pan offset — same as the SwiftUI layer
        let originX = (canvasSize.width - scaledW) / 2 + backgroundOffset.width
        let originY = (canvasSize.height - scaledH) / 2 + backgroundOffset.height
        shading = .tiledImage(Image(uiImage: effectiveImg),
                              origin: CGPoint(x: originX, y: originY),
                              scale: coverScale)
    } else if canvasColor != Color.clear {
        shading = .color(canvasColor)
    } else {
        return  // canvas is clear with no background — nothing to erase to
    }

    if count == 1 {
        let pt = line.points[0]
        let rect = CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)
        context.fill(Path(ellipseIn: rect), with: shading)
    } else {
        for i in 1..<count {
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: shading,
                           style: StrokeStyle(lineWidth: baseW, lineCap: .round, lineJoin: .round))
        }
    }
}

private func drawTaperedLine(_ line: DrawingLine, color: Color, in context: inout GraphicsContext,
                              taperFraction: CGFloat, minTaper: CGFloat, opacity: CGFloat,
                              suppressTailTaperWhileLive: Bool = false, suppressHeadTaperWhileLive: Bool = false) {
    let baseW = line.lineWidth
    let count = line.points.count
    if count == 1 {
        let pt = line.points[0]
        let pressure = line.widths.first.map { $0 / baseW } ?? 1.0
        let r = (baseW * pressure) / 2
        let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)
        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
        return
    }
    // Group consecutive points with similar widths into single path segments
    // to avoid overlapping round caps blotching at slow speeds
    var i = 1
    while i < count {
        let taper = strokeTaper(i: i, count: count, taperFraction: taperFraction, suppressTail: suppressTailTaperWhileLive, suppressHead: suppressHeadTaperWhileLive)
        let pressure = i < line.widths.count ? line.widths[i] / baseW : 1.0
        let w = baseW * max(minTaper, taper) * pressure
        // Extend path as long as width stays within 15% of current
        var path = Path()
        path.move(to: line.points[i-1])
        path.addLine(to: line.points[i])
        var j = i + 1
        while j < count {
            let nextTaper = strokeTaper(i: j, count: count, taperFraction: taperFraction, suppressTail: suppressTailTaperWhileLive, suppressHead: suppressHeadTaperWhileLive)
            let nextPressure = j < line.widths.count ? line.widths[j] / baseW : 1.0
            let nextW = baseW * max(minTaper, nextTaper) * nextPressure
            if abs(nextW - w) / max(w, 0.01) > 0.15 { break }
            path.addLine(to: line.points[j])
            j += 1
        }
        context.stroke(path, with: .color(color.opacity(opacity)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        i = j
    }
}

private func drawInkLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    // Very sharp taper — starts and ends at a fine point, stays full width in middle
    let baseW = line.lineWidth
    let count = line.points.count
    if count == 1 {
        let pt = line.points[0]
        context.fill(Path(ellipseIn: CGRect(x: pt.x-1, y: pt.y-1, width: 2, height: 2)), with: .color(line.color))
        return
    }
    for i in 1..<count {
        // No taper — head or tail, live or committed. Same "no changes after it's laid down" rule
        // as Pencil: taper's old fraction-of-still-growing-length math meant an already-drawn point's
        // width could silently shift on a later redraw with no new pressure applied. Oscillation below
        // is untouched by this — it's a fixed function of point index, not of the live/growing count,
        // so it doesn't have the same bug and stays as Ink's actual character.
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.3, suppressTail: true, suppressHead: true)
        let pressure = i < line.widths.count ? line.widths[i] / baseW : 1.0
        // Ink oscillates slightly in width as if flow is uneven
        let oscillation: CGFloat = 1.0 + 0.12 * sin(CGFloat(i) * 0.8)
        let w = max(0.5, baseW * max(0.02, taper) * pressure * oscillation)
        var seg = Path()
        seg.move(to: line.points[i-1])
        seg.addLine(to: line.points[i])
        context.stroke(seg, with: .color(line.color),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
}

// Returns pressure multiplier at point index i. Falls back to 1.0 if no pressure data.
private func pressureAt(_ i: Int, in line: DrawingLine) -> CGFloat {
    guard i < line.widths.count, line.lineWidth > 0 else { return 1.0 }
    return line.widths[i] / line.lineWidth
}

private func drawBrushLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    // Wide, dramatic taper with soft opacity edge — draws multiple passes at decreasing opacity
    let baseW = line.lineWidth
    let count = line.points.count

    // Core stroke — full opacity, tapered. No taper live or committed — same "no changes after
    // it's laid down" rule as Pencil/Ink; see strokeTaper's own comment for the mechanism.
    drawTaperedLine(line, color: line.color, in: &context, taperFraction: 0.35, minTaper: 0.0, opacity: 0.85, suppressTailTaperWhileLive: true, suppressHeadTaperWhileLive: true)

    // Soft halo pass — wider, lower opacity for brush bleed effect. Same suppression applied here too —
    // this loop has its own independent strokeTaper call, not routed through drawTaperedLine above.
    if count > 1 {
        for i in 1..<count {
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.35, suppressTail: true, suppressHead: true)
            let w = baseW * max(0.0, taper) * 1.6 * pressureAt(i, in: line)
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: .color(line.color.opacity(0.18)),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }
    }
}

private func drawMarkerLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    // Flat, consistent width — slight transparency so overlapping strokes darken
    let baseW = line.lineWidth
    let count = line.points.count
    if count == 1 {
        let pt = line.points[0]
        let rect = CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)
        context.fill(Path(ellipseIn: rect), with: .color(line.color.opacity(0.72)))
        return
    }
    for i in 1..<count {
        var seg = Path()
        seg.move(to: line.points[i-1])
        seg.addLine(to: line.points[i])
        let w = baseW * pressureAt(i, in: line)
        context.stroke(seg, with: .color(line.color.opacity(0.72)),
                       style: StrokeStyle(lineWidth: w, lineCap: .square, lineJoin: .miter))
    }
}

private func drawChalkLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    // Rough, broken texture — skip some segments and vary opacity/width randomly
    // Use deterministic pseudo-random based on point index so re-renders are stable
    let baseW = line.lineWidth
    let count = line.points.count
    if count == 1 {
        let pt = line.points[0]
        let rect = CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)
        context.fill(Path(ellipseIn: rect), with: .color(line.color.opacity(0.6)))
        return
    }
    for i in 1..<count {
        // Seeded pseudo-random using point position for stable re-renders
        let seed = Int(line.points[i].x * 7 + line.points[i].y * 13) & 0xFF
        let skip = seed % 5 == 0   // drop ~20% of segments for broken look
        if skip { continue }
        let opacity = 0.45 + CGFloat(seed % 40) / 100.0  // 0.45 – 0.85
        let widthVar = 0.7 + CGFloat(seed % 30) / 100.0  // 0.7 – 1.0
        // No taper — head or tail, live or committed. This was the "fills in a bit after your pen
        // has moved from that area" bug: the mark right under the pen tip was always taper-thinned
        // (tail zone, floored at 0.3x), then snapped back to full width once that point aged out of
        // the tail zone as the stroke kept growing. Same class as Pencil/Ink/Brush's fix.
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.15, suppressTail: true, suppressHead: true)
        let w = baseW * widthVar * max(0.3, taper) * pressureAt(i, in: line)

        // Slight jitter offset for rough texture
        let jx = CGFloat((seed % 7) - 3) * 0.4
        let jy = CGFloat(((seed / 7) % 7) - 3) * 0.4
        var seg = Path()
        seg.move(to: CGPoint(x: line.points[i-1].x + jx, y: line.points[i-1].y + jy))
        seg.addLine(to: CGPoint(x: line.points[i].x + jx, y: line.points[i].y + jy))
        context.stroke(seg, with: .color(line.color.opacity(opacity)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
}


private func drawNeonLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    // Thin bright core + wide soft glow halo
    let baseW = line.lineWidth
    let count = line.points.count
    if count == 1 {
        let pt = line.points[0]
        let glowR = baseW * 3
        context.fill(Path(ellipseIn: CGRect(x: pt.x - glowR, y: pt.y - glowR, width: glowR*2, height: glowR*2)),
                     with: .color(line.color.opacity(0.15)))
        context.fill(Path(ellipseIn: CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)),
                     with: .color(line.color))
        return
    }
    // Three passes: outer glow, mid glow, bright core
    let passes: [(widthMult: CGFloat, opacity: CGFloat)] = [(5.0, 0.07), (2.8, 0.18), (0.9, 1.0)]
    for pass in passes {
        for i in 1..<count {
            // No taper — same rule as every other pen fixed this session.
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.15, suppressTail: true, suppressHead: true)
            let w = baseW * pass.widthMult * max(0.2, taper) * pressureAt(i, in: line)
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: .color(line.color.opacity(pass.opacity)),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }
    }
}

private func drawSprayLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    // Scatter dots in a radius; density inversely proportional to speed (slower = denser)
    // All seed math uses pure UInt64 to avoid overflow crashes
    let baseW = line.lineWidth
    let count = line.points.count
    let radius = baseW * 2.2

    func sprayHash(_ a: Int, _ b: Int) -> UInt64 {
        var s = UInt64(bitPattern: Int64(a)) &* 2654435761 &+ UInt64(bitPattern: Int64(b)) &* 40503
        s ^= s >> 16
        s = s &* 0x45d9f3b
        s ^= s >> 16
        return s
    }

    if count == 1 {
        let pt = line.points[0]
        for k in 0..<12 {
            let s = sprayHash(0, k)
            let angle = CGFloat(s & 0xFFFF) / 65535.0 * .pi * 2
            let r = radius * CGFloat((s >> 16) & 0xFFFF) / 65535.0
            let dotR = baseW * 0.18
            context.fill(Path(ellipseIn: CGRect(
                x: pt.x + r * cos(angle) - dotR,
                y: pt.y + r * sin(angle) - dotR,
                width: dotR*2, height: dotR*2)),
                with: .color(line.color.opacity(0.7)))
        }
        return
    }
    for i in 1..<count {
        let p0 = line.points[i-1], p1 = line.points[i]
        let ddx = p1.x - p0.x, ddy = p1.y - p0.y
        let speed = sqrt(ddx*ddx + ddy*ddy)
        let dotCount = max(2, Int(14 - speed * 0.4))
        for k in 0..<dotCount {
            let s = sprayHash(i, k)
            let angle = CGFloat(s & 0xFFFF) / 65535.0 * .pi * 2
            let r = radius * CGFloat((s >> 16) & 0xFFFF) / 65535.0
            let cx = p1.x + r * cos(angle)
            let cy = p1.y + r * sin(angle)
            let dotR = baseW * (0.12 + CGFloat((s >> 32) & 0xFF) / 2550.0) * pressureAt(i, in: line)
            let opacity = 0.4 + CGFloat((s >> 40) & 0xFF) / 637.0
            context.fill(Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR, width: dotR*2, height: dotR*2)),
                         with: .color(line.color.opacity(opacity)))
        }
    }
}

/// Same drag-to-build-coverage feel as Spray (denser where you move slower/
/// linger over an area), but lays down soft, feathered blobs instead of many
/// small hard-edged dots — repeated passes blend and darken smoothly rather
/// than accumulating visible speckle texture.
///
/// **Perf note (fixed after real-device slowdown report):** the first version
/// drew every blob inside one `context.drawLayer { layer.addFilter(.blur(...)) }`
/// scope per stroke, matching Trim/Tube's technique. That's fine for Trim
/// (2 continuous strokes per layer) but wrong here — a single airbrush
/// stroke can pack hundreds of blobs into one layer, and `DrawingLayerCanvas`
/// re-runs every past line's render function on *every* canvas redraw (e.g.
/// every touch-move while drawing something else entirely), so an
/// accumulating off-screen Gaussian blur pass over a huge shape, repeated
/// every frame, for every airbrush stroke ever drawn on that layer, is what
/// was compounding into real slowdown. Rebuilt to draw each blob as a
/// `.radialGradient` fill (opaque center fading to transparent edge)
/// instead — a native GPU shading primitive, not an off-screen blur filter,
/// so the soft edge is "free" per blob rather than one expensive whole-layer
/// post-process. Blob count per segment also eased back (was up to 6, now
/// up to 4) as extra headroom.
private func drawAirbrushLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    let baseW = line.lineWidth
    let count = line.points.count
    let radius = baseW * 1.6

    func airbrushHash(_ a: Int, _ b: Int) -> UInt64 {
        var s = UInt64(bitPattern: Int64(a)) &* 2654435761 &+ UInt64(bitPattern: Int64(b)) &* 40503
        s ^= s >> 16
        s = s &* 0x45d9f3b
        s ^= s >> 16
        return s
    }

    func drawBlob(center: CGPoint, radius blobR: CGFloat, opacity: Double) {
        guard blobR > 0 else { return }
        let path = Path(ellipseIn: CGRect(x: center.x - blobR, y: center.y - blobR, width: blobR*2, height: blobR*2))
        let gradient = Gradient(stops: [
            .init(color: line.color.opacity(opacity), location: 0),
            .init(color: line.color.opacity(opacity * 0.35), location: 0.65),
            .init(color: line.color.opacity(0), location: 1)
        ])
        context.fill(path, with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: blobR))
    }

    if count == 1 {
        let pt = line.points[0]
        let r = baseW * 0.9 * pressureAt(0, in: line)
        drawBlob(center: pt, radius: r, opacity: 0.6)
        return
    }
    for i in 1..<count {
        let p0 = line.points[i-1], p1 = line.points[i]
        let ddx = p1.x - p0.x, ddy = p1.y - p0.y
        let speed = sqrt(ddx*ddx + ddy*ddy)
        let blobCount = max(1, Int(4 - speed * 0.2))
        let pressure = pressureAt(i, in: line)
        for k in 0..<blobCount {
            let s = airbrushHash(i, k)
            let angle = CGFloat(s & 0xFFFF) / 65535.0 * .pi * 2
            let r = radius * CGFloat((s >> 16) & 0xFFFF) / 65535.0
            let cx = p1.x + r * cos(angle)
            let cy = p1.y + r * sin(angle)
            let blobR = baseW * (0.55 + CGFloat((s >> 32) & 0xFF) / 850.0) * pressure
            let opacity = 0.30 + CGFloat((s >> 40) & 0xFF) / 850.0
            drawBlob(center: CGPoint(x: cx, y: cy), radius: blobR, opacity: opacity)
        }
    }
}

/// A single continuous path for the whole stroke, stroked once with a native
/// dash pattern — cheap (one draw call regardless of stroke length, same
/// class of technique as Tube's rebuild) and gives a genuinely continuous
/// dash rhythm along the path, unlike dashing each short segment
/// independently (which would restart the dash phase every segment and
/// never look continuous). Trade-off: since it's one stroke call for the
/// whole line, width is flat rather than tapering per-point with pressure —
/// same trade-off Tube already accepts for the same reason.
private func drawDashedLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    let baseW = line.lineWidth
    let count = line.points.count
    if count == 1 {
        let pt = line.points[0]
        context.fill(Path(ellipseIn: CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)),
                     with: .color(line.color))
        return
    }
    var path = Path()
    path.move(to: line.points[0])
    for i in 1..<count { path.addLine(to: line.points[i]) }
    let dashLen = max(2, baseW * 1.4)
    let gapLen  = max(2, baseW * 1.1)
    context.stroke(path, with: .color(line.color),
                   style: StrokeStyle(lineWidth: baseW, lineCap: .butt, lineJoin: .round, dash: [dashLen, gapLen]))
}

/// Small repeating heart shapes strung along the path at arc-length
/// intervals — same spacing convention as Dotted/Bubble/Stars. Uses the
/// classic closed-form parametric heart curve (x = 16sin³t, y = 13cos t −
/// 5cos 2t − 2cos 3t − cos 4t) rather than a hand-built bezier/arc
/// approximation — verified visually before writing this (rendered the
/// exact formula with matplotlib) rather than trusting hand-typed control
/// points for a shape this fiddly to get right by eye alone.
private func heartPath(center: CGPoint, size: CGFloat, rotation: CGFloat) -> Path {
    var path = Path()
    let segments = 16
    let scale = size / 16.0   // formula's natural x-amplitude is ±16
    for i in 0...segments {
        let t = CGFloat(i) / CGFloat(segments) * 2 * .pi
        let hx = 16 * pow(sin(t), 3)
        let hy = -(13 * cos(t) - 5 * cos(2*t) - 2 * cos(3*t) - cos(4*t))  // flip: formula's +y is up, canvas +y is down
        let rx = hx * cos(rotation) - hy * sin(rotation)
        let ry = hx * sin(rotation) + hy * cos(rotation)
        let pt = CGPoint(x: center.x + rx * scale, y: center.y + ry * scale)
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    path.closeSubpath()
    return path
}

private func drawHeartsLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    let baseW = line.lineWidth
    let count = line.points.count
    if count == 1 {
        let pt = line.points[0]
        context.fill(heartPath(center: pt, size: baseW * 0.9, rotation: 0), with: .color(line.color))
        return
    }
    let heartSize    = baseW * 0.9
    let heartSpacing = baseW * 1.7

    var arcLen = [CGFloat](repeating: 0, count: count)
    for i in 1..<count {
        arcLen[i] = arcLen[i-1] + hypot(line.points[i].x - line.points[i-1].x,
                                         line.points[i].y - line.points[i-1].y)
    }

    var nextAt: CGFloat = 0
    var idx = 0
    for i in 0..<count {
        guard arcLen[i] >= nextAt else { continue }
        nextAt += heartSpacing
        let pt = line.points[i]
        let pressure = pressureAt(i, in: line)
        // Deterministic slight rotation variation, same sin-hash convention as Hairy/Thorns/Stars
        let rot = (fabs(sin(CGFloat(idx) * 91.7 + 1.3)) - 0.5) * 0.5
        context.fill(heartPath(center: pt, size: heartSize * pressure, rotation: rot), with: .color(line.color))
        idx += 1
    }
}

/// Small four-pointed twinkle/sparkle glyphs (✦) strung along the path at
/// arc-length intervals — same spacing/pressure/jitter convention as Hearts.
/// Deliberately sharp and angular (straight-line vertices between an outer
/// and inner radius, not a curve) so it reads distinctly from Hearts' soft
/// curves and from the Dual Tone "Stars" style's rounded five-point shape —
/// a classic "magic sparkle" look. Replaces Chevron per direct request
/// (Chevron worked fine, just wasn't wanted in the Pattern lineup anymore).
private func sparklePath(center: CGPoint, size: CGFloat, rotation: CGFloat) -> Path {
    var path = Path()
    let outerR = size * 0.5
    let innerR = outerR * 0.35
    for i in 0..<8 {
        let angle = CGFloat(i) * (.pi / 4) - .pi / 2 + rotation  // start pointing up
        let r = (i % 2 == 0) ? outerR : innerR
        let pt = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    path.closeSubpath()
    return path
}

private func drawSparkleLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    let baseW = line.lineWidth
    let count = line.points.count
    if count == 1 {
        let pt = line.points[0]
        context.fill(sparklePath(center: pt, size: baseW * 0.9, rotation: 0), with: .color(line.color))
        return
    }
    let sparkleSize    = baseW * 0.9
    let sparkleSpacing = baseW * 1.7

    var arcLen = [CGFloat](repeating: 0, count: count)
    for i in 1..<count {
        arcLen[i] = arcLen[i-1] + hypot(line.points[i].x - line.points[i-1].x,
                                         line.points[i].y - line.points[i-1].y)
    }

    var nextAt: CGFloat = 0
    var idx = 0
    for i in 0..<count {
        guard arcLen[i] >= nextAt else { continue }
        nextAt += sparkleSpacing
        let pt = line.points[i]
        let pressure = pressureAt(i, in: line)
        // Deterministic rotation variation, same sin-hash convention as Hearts/Hairy/Thorns
        let rot = fabs(sin(CGFloat(idx) * 63.1 + 2.7)) * (.pi / 4)
        context.fill(sparklePath(center: pt, size: sparkleSize * pressure, rotation: rot), with: .color(line.color))
        idx += 1
    }
}

/// Spray/Airbrush-style scatter — same speed-based density and per-dot hash
/// placement as `drawSprayLine` (denser where you move slower/linger) — but
/// each dot's color is picked from a 4-way cycle instead of always
/// `line.color`: `line.color`, `line.colorB`, and a lightened blend of each
/// via the same `blendColors` helper Confetti already uses. Reuses Confetti's
/// established "two colors you picked in Pen Studio, plus their lightened
/// blends" color set, so every multi-color pen in the app draws from the
/// same palette convention. Unlike Confetti's fixed sin-hash 0-1-2-3
/// sequence, the color pick here comes from unused high bits (48-64) of
/// Spray's own per-dot hash — bits 0-16/16-32/32-40/40-48 are already spoken
/// for by angle/radius/dotR/opacity, see `drawSprayLine` above — so color
/// varies dot-to-dot within a single burst rather than cycling in a fixed
/// order, reading as genuinely scattered rather than a repeating stripe.
private func drawSplatterLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    let baseW = line.lineWidth
    let count = line.points.count
    let radius = baseW * 2.2

    func splatterHash(_ a: Int, _ b: Int) -> UInt64 {
        var s = UInt64(bitPattern: Int64(a)) &* 2654435761 &+ UInt64(bitPattern: Int64(b)) &* 40503
        s ^= s >> 16
        s = s &* 0x45d9f3b
        s ^= s >> 16
        return s
    }

    func splatterColor(_ s: UInt64) -> Color {
        switch (s >> 50) & 0x3 {
        case 0:  return line.color
        case 1:  return line.colorB
        case 2:  return blendColors(line.color, .white, t: 0.45)
        default: return blendColors(line.colorB, .white, t: 0.45)
        }
    }

    if count == 1 {
        let pt = line.points[0]
        for k in 0..<12 {
            let s = splatterHash(0, k)
            let angle = CGFloat(s & 0xFFFF) / 65535.0 * .pi * 2
            let r = radius * CGFloat((s >> 16) & 0xFFFF) / 65535.0
            let dotR = baseW * 0.18
            context.fill(Path(ellipseIn: CGRect(
                x: pt.x + r * cos(angle) - dotR,
                y: pt.y + r * sin(angle) - dotR,
                width: dotR*2, height: dotR*2)),
                with: .color(splatterColor(s).opacity(0.7)))
        }
        return
    }
    for i in 1..<count {
        let p0 = line.points[i-1], p1 = line.points[i]
        let ddx = p1.x - p0.x, ddy = p1.y - p0.y
        let speed = sqrt(ddx*ddx + ddy*ddy)
        let dotCount = max(2, Int(14 - speed * 0.4))
        for k in 0..<dotCount {
            let s = splatterHash(i, k)
            let angle = CGFloat(s & 0xFFFF) / 65535.0 * .pi * 2
            let r = radius * CGFloat((s >> 16) & 0xFFFF) / 65535.0
            let cx = p1.x + r * cos(angle)
            let cy = p1.y + r * sin(angle)
            let dotR = baseW * (0.12 + CGFloat((s >> 32) & 0xFF) / 2550.0) * pressureAt(i, in: line)
            let opacity = 0.4 + CGFloat((s >> 40) & 0xFF) / 637.0
            context.fill(Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR, width: dotR*2, height: dotR*2)),
                         with: .color(splatterColor(s).opacity(opacity)))
        }
    }
}

private func drawWatercolorLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    // Multiple semi-transparent passes: wide soft wash + medium body + thin edge darkening
    let baseW = line.lineWidth
    let count = line.points.count
    if count == 1 {
        let pt = line.points[0]
        let r = baseW * 1.4
        context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)),
                     with: .color(line.color.opacity(0.25)))
        return
    }
    // Pass 1: wide soft wet wash. No taper — head or tail, live or committed, same rule as every
    // other pen fixed this session. This was the "long after I stop moving the pen, the line keeps
    // getting thinner" bug: a stationary-but-still-touching pen keeps firing near-duplicate points at
    // nearly the same spot, which keeps growing the live point count, which kept re-triggering the
    // tail-zone thinning on every redraw even with zero actual movement.
    for i in 1..<count {
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.3, suppressTail: true, suppressHead: true)
        let seed = Int(line.points[i].x * 3 + line.points[i].y * 7) & 0xFF
        let wVar = 0.85 + CGFloat(seed % 30) / 100.0
        let w = baseW * 2.2 * wVar * max(0.1, taper) * pressureAt(i, in: line)
        var seg = Path()
        seg.move(to: line.points[i-1])
        seg.addLine(to: line.points[i])
        context.stroke(seg, with: .color(line.color.opacity(0.13)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
    // Pass 2: medium body
    for i in 1..<count {
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.25, suppressTail: true, suppressHead: true)
        let w = baseW * 1.2 * max(0.1, taper) * pressureAt(i, in: line)
        var seg = Path()
        seg.move(to: line.points[i-1])
        seg.addLine(to: line.points[i])
        context.stroke(seg, with: .color(line.color.opacity(0.22)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
    // Pass 3: thin edge darkening for pigment-pooling effect
    for i in 1..<count {
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.1, suppressTail: true, suppressHead: true)
        let w = baseW * 0.35 * max(0.05, taper) * pressureAt(i, in: line)
        var seg = Path()
        seg.move(to: line.points[i-1])
        seg.addLine(to: line.points[i])
        context.stroke(seg, with: .color(line.color.opacity(0.35)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
}

private func drawDottedLine(_ line: DrawingLine, in context: inout GraphicsContext) {
    // Evenly spaced dots along the path
    let baseW = line.lineWidth
    let count = line.points.count
    let dotR = baseW * 0.55
    let spacing = baseW * 1.6
    if count == 1 {
        let pt = line.points[0]
        context.fill(Path(ellipseIn: CGRect(x: pt.x - dotR, y: pt.y - dotR, width: dotR*2, height: dotR*2)),
                     with: .color(line.color))
        return
    }
    var accumulated: CGFloat = 0
    for i in 1..<count {
        let p0 = line.points[i-1], p1 = line.points[i]
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let segLen = sqrt(dx*dx + dy*dy)
        guard segLen > 0 else { continue }
        var t = (spacing - accumulated) / segLen
        while t <= 1.0 {
            let x = p0.x + dx * t
            let y = p0.y + dy * t
            // No taper — same rule as every other pen this session. Caught late: this was the
            // same "fills in a bit after your pen has moved from that area" bug as Chalk, just not
            // yet reported since it was only checked for the pressure→size relationship.
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.15, suppressTail: true, suppressHead: true)
            let r = dotR * max(0.3, taper) * pressureAt(i, in: line)
            context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r*2, height: r*2)),
                         with: .color(line.color))
            t += spacing / segLen
        }
        accumulated = (1.0 - (t - spacing / segLen)) * segLen
        if accumulated >= spacing { accumulated = 0 }
    }
}

private func drawDualToneLine(_ line: DrawingLine, style: DualToneStyle, in context: inout GraphicsContext) {
    let count = line.points.count
    let baseW = line.lineWidth
    guard count > 0 else { return }

    switch style {

    case .gradient:
        // Color shifts smoothly from colorA at start to colorB at end
        if count == 1 {
            let pt = line.points[0]
            let rect = CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)
            context.fill(Path(ellipseIn: rect), with: .color(line.color))
            return
        }
        for i in 1..<count {
            let t = CGFloat(i) / CGFloat(count - 1)
            let blended = blendColors(line.color, line.colorB, t: t)
            // Width taper suppressed same as everywhere else — separate from the `t` color-position
            // question above, which is still an open design call, not yet resolved.
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2, suppressTail: true, suppressHead: true)
            let w = baseW * max(0.08, taper) * pressureAt(i, in: line)
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: .color(blended),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }

    case .split:
        // Two parallel strokes side by side — A above, B below (perpendicular to direction)
        if count == 1 {
            let pt = line.points[0]
            let hw = baseW * 0.3
            context.fill(Path(ellipseIn: CGRect(x: pt.x - hw, y: pt.y - hw, width: hw*2, height: hw*2)), with: .color(line.color))
            context.fill(Path(ellipseIn: CGRect(x: pt.x - hw + hw, y: pt.y - hw, width: hw*2, height: hw*2)), with: .color(line.colorB))
            return
        }
        for i in 1..<count {
            let p0 = line.points[i-1], p1 = line.points[i]
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let len = sqrt(dx*dx + dy*dy)
            guard len > 0 else { continue }
            let nx = -dy / len, ny = dx / len  // perpendicular unit vector
            let offset = baseW * 0.28
            // No taper — head or tail, live or committed. Same rule as every other pen this session.
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2, suppressTail: true, suppressHead: true)
            let w = (baseW * 0.55) * max(0.08, taper) * pressureAt(i, in: line)
            // Stroke A
            var segA = Path()
            segA.move(to: CGPoint(x: p0.x + nx*offset, y: p0.y + ny*offset))
            segA.addLine(to: CGPoint(x: p1.x + nx*offset, y: p1.y + ny*offset))
            context.stroke(segA, with: .color(line.color),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            // Stroke B
            var segB = Path()
            segB.move(to: CGPoint(x: p0.x - nx*offset, y: p0.y - ny*offset))
            segB.addLine(to: CGPoint(x: p1.x - nx*offset, y: p1.y - ny*offset))
            context.stroke(segB, with: .color(line.colorB),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }

    case .reactive:
        // Color shifts based on stroke direction — horizontal→colorA, vertical→colorB
        if count == 1 {
            let pt = line.points[0]
            let rect = CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)
            context.fill(Path(ellipseIn: rect), with: .color(line.color))
            return
        }
        for i in 1..<count {
            let p0 = line.points[i-1], p1 = line.points[i]
            let dx = abs(p1.x - p0.x), dy = abs(p1.y - p0.y)
            let total = dx + dy
            // t=0 → horizontal (colorA), t=1 → vertical (colorB)
            let t = total > 0 ? dy / total : 0.5
            let blended = blendColors(line.color, line.colorB, t: t)
            // No taper — same rule as every other pen this session.
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2, suppressTail: true, suppressHead: true)
            let w = baseW * max(0.08, taper) * pressureAt(i, in: line)
            var seg = Path()
            seg.move(to: p0)
            seg.addLine(to: p1)
            context.stroke(seg, with: .color(blended),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }

    case .alternating:
        // Colors pulse A/B every N segments
        if count == 1 {
            let pt = line.points[0]
            let rect = CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)
            context.fill(Path(ellipseIn: rect), with: .color(line.color))
            return
        }
        // Pulse length is a fixed distance tied to the thickness setting, not the stroke's total
        // length — the old `count / 12` made the band size depend on how long the stroke ended up
        // being, which isn't known yet while still drawing, so already-drawn bands would visibly
        // resize as the stroke grew. Arc-length based now, same spacing convention as Bubble/Stars/
        // Hearts, so it's fixed and predictable from the very first segment.
        let pulseDist = max(2.0, baseW * 1.5)
        var altArcLen = [CGFloat](repeating: 0, count: count)
        for i in 1..<count {
            altArcLen[i] = altArcLen[i-1] + hypot(line.points[i].x - line.points[i-1].x,
                                                   line.points[i].y - line.points[i-1].y)
        }
        for i in 1..<count {
            let pulse = Int(altArcLen[i] / pulseDist) % 2 == 0
            let segColor = pulse ? line.color : line.colorB
            // No taper — same rule as every other pen this session.
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2, suppressTail: true, suppressHead: true)
            let w = baseW * max(0.08, taper) * pressureAt(i, in: line)
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: .color(segColor),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }

    case .braid:
        // Two strands weave over/under each other like a rope braid.
        // Each strand follows a sinusoidal offset perpendicular to the stroke direction.
        // Drawing order alternates every half-period so the "over" strand switches at each crossing.
        // Pressure scales both strand width and amplitude (heavy press = wider braid).
        if count == 1 {
            let pt = line.points[0]
            let rect = CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)
            context.fill(Path(ellipseIn: rect), with: .color(line.color))
            return
        }
        let strandW   = baseW * 0.52
        let amplitude = baseW * 0.28
        let period    = baseW * 2.0
        let halfPeriod = period / 2

        var arcLen = [CGFloat](repeating: 0, count: count)
        for i in 1..<count {
            arcLen[i] = arcLen[i-1] + hypot(line.points[i].x - line.points[i-1].x,
                                             line.points[i].y - line.points[i-1].y)
        }

        // Precompute strand positions — amplitude varies with both taper and pressure
        var ptsA = [CGPoint](repeating: .zero, count: count)
        var ptsB = [CGPoint](repeating: .zero, count: count)
        for i in 0..<count {
            let pt  = line.points[i]
            let s   = arcLen[i]
            let ang = (s / period) * 2 * CGFloat.pi
            let lo  = max(0, i - 1), hi = min(count - 1, i + 1)
            let dx  = line.points[hi].x - line.points[lo].x
            let dy  = line.points[hi].y - line.points[lo].y
            let len = hypot(dx, dy)
            let nx  = len > 0 ? -dy / len : 0.0
            let ny  = len > 0 ?  dx / len : 1.0
            // No taper — same rule as every other pen this session.
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.15, suppressTail: true, suppressHead: true)
            let amp   = amplitude * taper * pressureAt(i, in: line)
            let sv    = sin(ang)
            ptsA[i] = CGPoint(x: pt.x + nx * amp * sv,  y: pt.y + ny * amp * sv)
            ptsB[i] = CGPoint(x: pt.x - nx * amp * sv,  y: pt.y - ny * amp * sv)
        }

        // Draw in half-period batches, segment-by-segment so strand width varies with pressure.
        // Two passes per batch (A then B, or B then A) preserve the over/under layering.
        var batchStart = 0
        while batchStart < count - 1 {
            let startHP = Int(arcLen[batchStart] / halfPeriod)
            var batchEnd = batchStart + 1
            while batchEnd < count - 1 && Int(arcLen[batchEnd] / halfPeriod) == startHP {
                batchEnd += 1
            }
            let drawEnd = min(batchEnd, count - 1)
            guard batchStart + 1 <= drawEnd else { batchStart = batchEnd; continue }

            func drawStrand(_ pts: [CGPoint], color: Color) {
                for j in (batchStart + 1)...drawEnd {
                    let w = strandW * pressureAt(j, in: line)
                    var seg = Path()
                    seg.move(to: pts[j-1])
                    seg.addLine(to: pts[j])
                    context.stroke(seg, with: .color(color),
                                   style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                }
            }

            if startHP % 2 == 0 {
                drawStrand(ptsA, color: line.color)
                drawStrand(ptsB, color: line.colorB)
            } else {
                drawStrand(ptsB, color: line.colorB)
                drawStrand(ptsA, color: line.color)
            }
            batchStart = batchEnd
        }

    case .trim:
        // Three parallel adjacent lines — the middle line uses the live
        // canvas pen color (colorA), the two outer lines use the second
        // color set in Pen Studio (colorB) with a soft blur, giving a
        // soft-edged trim flanking a crisp core line. Started life as a
        // standalone "Gold Trim" pen (nested bevel rings + rope seam +
        // scalloped bumps, modeled on the Daily Doodle hero card's frame)
        // but was simplified and folded into Dual Tone per direct
        // feedback — the fixed bronze/gold palette and the bump dots are
        // both gone; colors now come from whatever colorA/colorB the user
        // has picked, same as every other Dual Tone style. Perpendicular
        // offset direction uses the same wider lo/hi window as
        // .braid/.hairy/.thorns to avoid raw-delta jitter.
        if count == 1 {
            let pt = line.points[0]
            let r = baseW * 0.22
            context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)),
                         with: .color(line.color))
            return
        }
        let trimLineW  = baseW * 0.32
        let trimSpacing = baseW * 0.36   // brought closer per feedback — was 0.55
        let trimBlur   = baseW * 0.12

        // Outer two lines — blurred, colorB. Both drawn inside one
        // drawLayer/blur scope so all their overlapping segments
        // composite into one solid shape *before* the blur is applied,
        // rather than blurring each short round-capped segment
        // individually (which would show seams/scalloping).
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: max(0.5, trimBlur)))
            for i in 1..<count {
                let p0 = line.points[i-1], p1 = line.points[i]
                let lo = max(0, i-1), hi = min(count-1, i+1)
                let dx = line.points[hi].x - line.points[lo].x
                let dy = line.points[hi].y - line.points[lo].y
                let len = hypot(dx, dy)
                guard len > 0 else { continue }
                let nx = -dy/len, ny = dx/len
                // No taper — same rule as every other pen this session.
                let taper = strokeTaper(i: i, count: count, taperFraction: 0.15, suppressTail: true, suppressHead: true)
                let w = trimLineW * max(0.15, taper) * pressureAt(i, in: line)
                let off = trimSpacing * max(0.15, taper) * pressureAt(i, in: line)

                var left = Path()
                left.move(to: CGPoint(x: p0.x - nx*off, y: p0.y - ny*off))
                left.addLine(to: CGPoint(x: p1.x - nx*off, y: p1.y - ny*off))
                layer.stroke(left, with: .color(line.colorB),
                             style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))

                var right = Path()
                right.move(to: CGPoint(x: p0.x + nx*off, y: p0.y + ny*off))
                right.addLine(to: CGPoint(x: p1.x + nx*off, y: p1.y + ny*off))
                layer.stroke(right, with: .color(line.colorB),
                             style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
        }

        // Middle line — crisp, colorA, drawn on top of the blurred pair.
        for i in 1..<count {
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.15, suppressTail: true, suppressHead: true)
            let w = trimLineW * max(0.15, taper) * pressureAt(i, in: line)
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: .color(line.color),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }

    case .hairy:
        // Core stroke (colorA) with perpendicular hairs of varying length/angle (colorB).
        // Pressure scales core width and hair size.
        if count == 1 {
            let pt = line.points[0]
            context.fill(Path(ellipseIn: CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)), with: .color(line.color))
            return
        }
        let hairCoreW   = baseW * 0.35
        let hairW       = baseW * 0.13
        let hairBaseLen = baseW * 0.4   // shortened per feedback — was 1.1
        let hairSpacing = baseW * 0.75

        var hairArcLen = [CGFloat](repeating: 0, count: count)
        for i in 1..<count {
            hairArcLen[i] = hairArcLen[i-1] + hypot(line.points[i].x - line.points[i-1].x,
                                                     line.points[i].y - line.points[i-1].y)
        }

        // Core stroke — segment-by-segment for pressure response. No taper — same rule as
        // every other pen this session.
        for i in 1..<count {
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2, suppressTail: true, suppressHead: true)
            let w = hairCoreW * max(0.08, taper) * pressureAt(i, in: line)
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: .color(line.color),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }

        // Hairs at arc-length intervals — size scales with pressure at that point
        var nextHairAt: CGFloat = 0
        var hairSeed = 0
        for i in 0..<count {
            guard hairArcLen[i] >= nextHairAt else { continue }
            nextHairAt += hairSpacing

            let pt = line.points[i]
            let lo = max(0, i-1), hi = min(count-1, i+1)
            let ddx = line.points[hi].x - line.points[lo].x
            let ddy = line.points[hi].y - line.points[lo].y
            let dlen = hypot(ddx, ddy)
            guard dlen > 0 else { continue }
            let nx = -ddy / dlen, ny = ddx / dlen

            let s = CGFloat(hairSeed)
            let r1 = fabs(sin(s * 127.1 + 1.0))
            let r2 = fabs(sin(s * 311.7 + 2.0))
            let r3 = fabs(sin(s * 73.3  + 3.0))
            let r4 = fabs(sin(s * 199.3 + 4.0))
            hairSeed += 1

            let pressure = pressureAt(i, in: line)
            let lenA = hairBaseLen * (0.5 + r1 * 0.8) * pressure
            let lenB = hairBaseLen * (0.4 + r3 * 0.7) * pressure
            let angA = (r2 - 0.5) * 0.5
            let angB = (r4 - 0.5) * 0.5

            let dAxP =  nx * cos(angA) - ny * sin(angA)
            let dAyP =  nx * sin(angA) + ny * cos(angA)
            let dBxN = -nx * cos(angB) + ny * sin(angB)
            let dByN = -nx * sin(angB) - ny * cos(angB)

            var h = Path()
            h.move(to: pt)
            h.addLine(to: CGPoint(x: pt.x + dAxP * lenA, y: pt.y + dAyP * lenA))
            h.move(to: pt)
            h.addLine(to: CGPoint(x: pt.x + dBxN * lenB, y: pt.y + dByN * lenB))
            context.stroke(h, with: .color(line.colorB),
                           style: StrokeStyle(lineWidth: hairW * pressure, lineCap: .round))
        }

    case .thorns:
        // Core stroke (colorA) with alternating backward-angled spikes (colorB), like a bramble.
        // Pressure scales core width and thorn size.
        if count == 1 {
            let pt = line.points[0]
            context.fill(Path(ellipseIn: CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)), with: .color(line.color))
            return
        }
        let thornCoreW  = baseW * 0.4
        let thornW      = baseW * 0.22
        let thornLen    = baseW * 1.3
        let thornSpace  = baseW * 1.8
        let backLean: CGFloat = 0.45

        var thornArcLen = [CGFloat](repeating: 0, count: count)
        for i in 1..<count {
            thornArcLen[i] = thornArcLen[i-1] + hypot(line.points[i].x - line.points[i-1].x,
                                                       line.points[i].y - line.points[i-1].y)
        }

        // Core stroke — segment-by-segment for pressure response. No taper — same rule as
        // every other pen this session.
        for i in 1..<count {
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2, suppressTail: true, suppressHead: true)
            let w = thornCoreW * max(0.08, taper) * pressureAt(i, in: line)
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: .color(line.color),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }

        // Thorns — size scales with pressure at placement point
        var nextThornAt: CGFloat = thornSpace * 0.5
        var thornIdx = 0
        for i in 1..<count {
            guard thornArcLen[i] >= nextThornAt else { continue }
            nextThornAt += thornSpace

            let pt = line.points[i]
            let lo = max(0, i-1), hi = min(count-1, i+1)
            let tdx = line.points[hi].x - line.points[lo].x
            let tdy = line.points[hi].y - line.points[lo].y
            let tlen = hypot(tdx, tdy)
            guard tlen > 0 else { continue }
            let fdx = tdx / tlen, fdy = tdy / tlen

            let side: CGFloat = thornIdx % 2 == 0 ? 1 : -1
            let px = -fdy * side - backLean * fdx
            let py =  fdx * side - backLean * fdy
            let plen = hypot(px, py)
            let pressure = pressureAt(i, in: line)

            var thorn = Path()
            thorn.move(to: pt)
            thorn.addLine(to: CGPoint(x: pt.x + (px / plen) * thornLen * pressure,
                                      y: pt.y + (py / plen) * thornLen * pressure))
            context.stroke(thorn, with: .color(line.colorB),
                           style: StrokeStyle(lineWidth: thornW * pressure, lineCap: .round))
            thornIdx += 1
        }

    case .bubble:
        // Filled circles strung along the path — like pearls. No core stroke.
        // Alternating colorA/colorB. Pressure scales radius.
        if count == 1 {
            let pt = line.points[0]
            let r = baseW * 0.5
            context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)), with: .color(line.color))
            return
        }
        let bubbleR       = baseW * 0.5
        let bubbleSpacing = baseW * 1.3   // arc-length between bubble centers

        var bubbleArcLen = [CGFloat](repeating: 0, count: count)
        for i in 1..<count {
            bubbleArcLen[i] = bubbleArcLen[i-1] + hypot(line.points[i].x - line.points[i-1].x,
                                                          line.points[i].y - line.points[i-1].y)
        }

        var nextBubbleAt: CGFloat = 0
        var bubbleIdx = 0
        for i in 0..<count {
            guard bubbleArcLen[i] >= nextBubbleAt else { continue }
            nextBubbleAt += bubbleSpacing
            let pt = line.points[i]
            let r = bubbleR * pressureAt(i, in: line)
            let color = bubbleIdx % 2 == 0 ? line.color : line.colorB
            context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)),
                         with: .color(color))
            bubbleIdx += 1
        }

    case .stars:
        // Filled 5-pointed stars along the path. Alternating colorA/colorB.
        // Pressure scales size. Slight rotation variation per star.
        if count == 1 {
            let pt = line.points[0]
            context.fill(starPath(center: pt, outerR: baseW * 0.55, innerR: baseW * 0.22, rotation: 0),
                         with: .color(line.color))
            return
        }
        let starOuter   = baseW * 0.55
        let starInner   = starOuter * 0.4
        let starSpacing = baseW * 1.4

        var starArcLen = [CGFloat](repeating: 0, count: count)
        for i in 1..<count {
            starArcLen[i] = starArcLen[i-1] + hypot(line.points[i].x - line.points[i-1].x,
                                                      line.points[i].y - line.points[i-1].y)
        }

        var nextStarAt: CGFloat = 0
        var starIdx = 0
        for i in 0..<count {
            guard starArcLen[i] >= nextStarAt else { continue }
            nextStarAt += starSpacing
            let pt = line.points[i]
            let pressure = pressureAt(i, in: line)
            let outer = starOuter * pressure
            let inner = starInner * pressure
            // Deterministic rotation variation
            let rot = CGFloat(starIdx) * 0.37  // irrational step keeps each star oriented differently
            let color = starIdx % 2 == 0 ? line.color : line.colorB
            context.fill(starPath(center: pt, outerR: outer, innerR: inner, rotation: rot),
                         with: .color(color))
            starIdx += 1
        }

    case .tube:
        // N genuinely continuous whole-path lines, each stroked exactly
        // once — not per-segment redraws. The previous version restroked
        // all N parallel lines at every point-to-point segment (up to
        // `lineCount` × `count` separate `context.stroke` calls for one
        // pen stroke), flagged directly: "your line consists of a zillion
        // lines... if you do a lot of it the app will become less and
        // less responsive... its kinda dangerous." Rebuilt on Eddie's own
        // described technique: precompute each point's outward normal
        // once (same wider lo/hi window every direction-dependent pen in
        // this file uses), then for each of the N line indices build one
        // continuous offset `Path` spanning every point in the stroke and
        // stroke it a single time in that line's fixed gradient color —
        // "a number of parallel lines whereby you manually change the
        // color of the line to what the proper gradient graduation color
        // would be... if it had 11 lines numbered 0-10, 0 and 10 would
        // both be [the edge color], 1 and 9 a step closer, ... til you got
        // to 5 which would be [the center color]." Total stroke calls for
        // the whole style: exactly `lineCount`, regardless of how many
        // points are in the stroke.
        //
        // Trade-off, called out rather than hidden: this style no longer
        // tapers to a point at the stroke's start/end the way every
        // per-segment pen in this file does — a single Path+StrokeStyle
        // stroke can't vary width along its own length without building a
        // custom filled variable-width shape, which would reintroduce the
        // same per-point cost this rebuild is specifically avoiding. Also
        // no longer reacts to live pressure along the stroke for the same
        // reason — width is fixed per line for the whole stroke.
        if count == 1 {
            let pt = line.points[0]
            let r = baseW * 0.5
            context.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)),
                         with: .color(line.color))
            return
        }
        var tubeLineCount = Int(baseW.rounded())
        if tubeLineCount % 2 == 0 { tubeLineCount += 1 }         // force odd — always a true center line
        tubeLineCount = max(3, min(tubeLineCount, 25))           // sane bounds at extreme thickness slider values
        let tubeHalf = tubeLineCount / 2
        let tubeSlotWidth = baseW / CGFloat(tubeLineCount)
        let tubeLineW = max(0.6, tubeSlotWidth * 1.15)   // slight overlap so adjacent lines don't leave hairline gaps

        var tubeNormals = [(CGFloat, CGFloat)](repeating: (0, 1), count: count)
        for i in 0..<count {
            let lo = max(0, i-1), hi = min(count-1, i+1)
            let dx = line.points[hi].x - line.points[lo].x
            let dy = line.points[hi].y - line.points[lo].y
            let len = hypot(dx, dy)
            tubeNormals[i] = len > 0 ? (-dy/len, dx/len) : (0, 1)
        }

        for lineIdx in -tubeHalf...tubeHalf {
            let t = CGFloat(abs(lineIdx)) / CGFloat(tubeHalf)   // 0 at center, 1 at outer edge
            let color = blendColors(line.color, line.colorB, t: t)
            let offset = CGFloat(lineIdx) * tubeSlotWidth
            var path = Path()
            for i in 0..<count {
                let (nx, ny) = tubeNormals[i]
                let pt = CGPoint(x: line.points[i].x + nx * offset, y: line.points[i].y + ny * offset)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: tubeLineW, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Build a filled 5-pointed star path centered at `center`.
private func starPath(center: CGPoint, outerR: CGFloat, innerR: CGFloat, rotation: CGFloat) -> Path {
    var path = Path()
    for i in 0..<10 {
        let angle = rotation + CGFloat(i) * .pi / 5 - .pi / 2
        let r = i % 2 == 0 ? outerR : innerR
        let pt = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    path.closeSubpath()
    return path
}

/// Linearly interpolate between two SwiftUI Colors at t ∈ [0,1]
private func blendColors(_ a: Color, _ b: Color, t: CGFloat) -> Color {
    let uiA = UIColor(a), uiB = UIColor(b)
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    uiA.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    uiB.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return Color(red: Double(r1 + (r2-r1)*t),
                 green: Double(g1 + (g2-g1)*t),
                 blue: Double(b1 + (b2-b1)*t),
                 opacity: Double(a1 + (a2-a1)*t))
}

// MARK: - Render to UIImage

/// Returns a set of gestural starter lines scaled to the canvas size.
/// Each call picks a random starter so the canvas feels fresh each time.
func makeStuckLines(in size: CGSize, color: Color = .black) -> [DrawingLine] {
    let w = size.width, h = size.height
    let all = stuckStarters(w: w, h: h, color: color)
    return all[Int.random(in: 0..<all.count)]
}

// Split into multiple functions to avoid Swift type-checker timeout
private func stuckStarters(w: CGFloat, h: CGFloat, color: Color) -> [[DrawingLine]] {
    var result = stuckStartersA(w: w, h: h, color: color)
    result += stuckStartersB(w: w, h: h, color: color)
    result += stuckStartersC(w: w, h: h, color: color)
    return result
}

private func stuckStartersA(w: CGFloat, h: CGFloat, color: Color) -> [[DrawingLine]] {
    return [
        // 1. Lazy S-curve
        [DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                CGPoint(x: w * (0.25 + 0.5 * sin(t * .pi)), y: h * (0.15 + 0.7 * t))
            },
            widths: (0..<21).map { _ in CGFloat.random(in: 3...6) },
            color: color, lineWidth: 4, isEraser: false
        )],
        // 2. Two crossing arcs
        [DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.06).map { t in
                CGPoint(x: w * (0.1 + 0.8 * t), y: h * (0.35 + 0.3 * sin(t * .pi)))
            },
            widths: (0..<18).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.06).map { t in
                CGPoint(x: w * (0.15 + 0.7 * t), y: h * (0.65 - 0.25 * sin(t * .pi)))
            },
            widths: (0..<18).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 3. Loose spiral fragment
        [DrawingLine(
            points: stride(from: 0.0, through: 3.5, by: 0.12).map { t in
                let r = w * (0.05 + 0.08 * t)
                return CGPoint(x: w * 0.5 + r * cos(t * 1.8), y: h * 0.45 + r * sin(t * 1.8))
            },
            widths: (0..<30).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 4. Wobbly horizontal + bump
        [DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                CGPoint(x: w * (0.1 + 0.8 * t), y: h * (0.5 + 0.04 * sin(t * 5 * .pi)))
            },
            widths: (0..<21).map { _ in CGFloat.random(in: 3...6) },
            color: color, lineWidth: 4, isEraser: false
        ),
        DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.08).map { t in
                CGPoint(x: w * (0.35 + 0.3 * t), y: h * (0.5 - 0.2 * sin(t * .pi)))
            },
            widths: (0..<14).map { _ in CGFloat.random(in: 2...4) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 5. Lopsided oval
        [DrawingLine(
            points: stride(from: 0.0, through: 2 * Double.pi, by: 0.18).map { t in
                CGPoint(x: w * (0.5 + 0.32 * cos(t)), y: h * (0.45 + 0.22 * sin(t)))
            },
            widths: (0..<36).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 6. Zigzag
        [DrawingLine(
            points: (0..<12).map { i in
                let t = CGFloat(i) / 11.0
                return CGPoint(x: w * (0.1 + 0.8 * t), y: h * (i % 2 == 0 ? 0.3 : 0.65))
            },
            widths: (0..<12).map { _ in CGFloat.random(in: 3...6) },
            color: color, lineWidth: 4, isEraser: false
        )],
        // 7. Figure-8
        [DrawingLine(
            points: stride(from: 0.0, through: 2 * Double.pi, by: 0.15).map { t in
                CGPoint(x: w * (0.5 + 0.25 * sin(t)), y: h * (0.5 + 0.22 * sin(2 * t)))
            },
            widths: (0..<43).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 8. Y-fork
        [DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.1).map { t in
                CGPoint(x: w * 0.5, y: h * (0.8 - 0.4 * t))
            },
            widths: (0..<11).map { _ in CGFloat.random(in: 3...6) },
            color: color, lineWidth: 4, isEraser: false
        ),
        DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.1).map { t in
                CGPoint(x: w * (0.5 - 0.25 * t), y: h * (0.4 - 0.2 * t))
            },
            widths: (0..<11).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.1).map { t in
                CGPoint(x: w * (0.5 + 0.25 * t), y: h * (0.4 - 0.2 * t))
            },
            widths: (0..<11).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 9. Loose scribbled rectangle
        [DrawingLine(
            points: [
                CGPoint(x: w*0.2, y: h*0.25), CGPoint(x: w*0.78, y: h*0.27),
                CGPoint(x: w*0.80, y: h*0.72), CGPoint(x: w*0.19, y: h*0.70),
                CGPoint(x: w*0.21, y: h*0.26)
            ],
            widths: (0..<5).map { _ in CGFloat.random(in: 3...6) },
            color: color, lineWidth: 4, isEraser: false
        )],
        // 10. Wave
        [DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.04).map { t in
                CGPoint(x: w * (0.05 + 0.9 * t), y: h * (0.5 + 0.18 * sin(t * 3 * .pi)))
            },
            widths: (0..<26).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
    ]
}

private func stuckStartersB(w: CGFloat, h: CGFloat, color: Color) -> [[DrawingLine]] {
    return [
        // 11. Hook / fishhook
        [DrawingLine(
            points: stride(from: 0.0, through: 1.5 * Double.pi, by: 0.12).map { t in
                CGPoint(x: w * (0.5 + 0.28 * cos(t)), y: h * (0.4 + 0.28 * sin(t)))
            } + [CGPoint(x: w * 0.5, y: h * 0.15), CGPoint(x: w * 0.5, y: h * 0.75)],
            widths: (0..<25).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 12. Star burst
        (0..<6).map { i -> DrawingLine in
            let angle = Double(i) * .pi / 3.0
            return DrawingLine(
                points: [
                    CGPoint(x: w * 0.5, y: h * 0.45),
                    CGPoint(x: w * (0.5 + 0.3 * cos(angle)), y: h * (0.45 + 0.3 * sin(angle)))
                ],
                widths: [CGFloat.random(in: 2...5), CGFloat.random(in: 2...5)],
                color: color, lineWidth: 3, isEraser: false
            )
        },
        // 13. Two wobbly parallel lines
        [DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.06).map { t in
                CGPoint(x: w * (0.1 + 0.8 * t), y: h * (0.38 + 0.03 * sin(t * 4 * .pi)))
            },
            widths: (0..<18).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.06).map { t in
                CGPoint(x: w * (0.1 + 0.8 * t), y: h * (0.58 + 0.03 * sin(t * 4 * .pi + 1)))
            },
            widths: (0..<18).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 14. Loose teardrop
        [DrawingLine(
            points: stride(from: 0.0, through: 2 * Double.pi, by: 0.15).map { t in
                let r = h * 0.22 * (1 - 0.4 * cos(t))
                return CGPoint(x: w * 0.5 + r * sin(t), y: h * 0.45 - r * cos(t))
            },
            widths: (0..<43).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 15. Random cluster of short marks
        (0..<5).map { _ -> DrawingLine in
            let cx = CGFloat.random(in: 0.2...0.8)
            let cy = CGFloat.random(in: 0.2...0.8)
            let angle = Double.random(in: 0...(2 * .pi))
            let len: CGFloat = 0.12
            return DrawingLine(
                points: [
                    CGPoint(x: w * (cx - len * CGFloat(cos(angle))), y: h * (cy - len * CGFloat(sin(angle)))),
                    CGPoint(x: w * (cx + len * CGFloat(cos(angle))), y: h * (cy + len * CGFloat(sin(angle))))
                ],
                widths: [CGFloat.random(in: 3...7), CGFloat.random(in: 3...7)],
                color: color, lineWidth: 4, isEraser: false
            )
        },
        // 16. Snail shell
        [DrawingLine(
            points: stride(from: 0.0, through: 4.0, by: 0.1).map { t in
                let r = w * max(0.01, 0.28 - 0.06 * t)
                return CGPoint(x: w * 0.5 + r * cos(t * 2.2), y: h * 0.48 + r * sin(t * 2.2))
            },
            widths: (0..<41).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 17. Lightning bolt
        [DrawingLine(
            points: [
                CGPoint(x: w*0.55, y: h*0.12), CGPoint(x: w*0.35, y: h*0.48),
                CGPoint(x: w*0.52, y: h*0.48), CGPoint(x: w*0.30, y: h*0.88)
            ],
            widths: (0..<4).map { _ in CGFloat.random(in: 4...7) },
            color: color, lineWidth: 5, isEraser: false
        )],
        // 18. Eye shape
        [DrawingLine(
            points: stride(from: 0.0, through: Double.pi, by: 0.12).map { t in
                CGPoint(x: w * (0.2 + 0.6 * t / .pi), y: h * (0.48 - 0.18 * sin(t)))
            },
            widths: (0..<27).map { _ in CGFloat.random(in: 2...4) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: stride(from: 0.0, through: Double.pi, by: 0.12).map { t in
                CGPoint(x: w * (0.2 + 0.6 * t / .pi), y: h * (0.48 + 0.18 * sin(t)))
            },
            widths: (0..<27).map { _ in CGFloat.random(in: 2...4) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 19. Tall narrow arch
        [DrawingLine(
            points: stride(from: 0.0, through: Double.pi, by: 0.1).map { t in
                CGPoint(x: w * (0.5 + 0.22 * cos(t)), y: h * (0.55 - 0.38 * sin(t)))
            },
            widths: (0..<32).map { _ in CGFloat.random(in: 3...5) },
            color: color, lineWidth: 4, isEraser: false
        )],
        // 20. Three stacked humps
        [DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.04).map { t in
                CGPoint(x: w * (0.1 + 0.8 * t), y: h * (0.55 - 0.22 * sin(t * 3 * .pi)))
            },
            widths: (0..<26).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
    ]
}

private func stuckStartersC(w: CGFloat, h: CGFloat, color: Color) -> [[DrawingLine]] {
    return [
        // 21. Lollipop
        [DrawingLine(
            points: stride(from: 0.0, through: 2 * Double.pi, by: 0.2).map { t in
                CGPoint(x: w * (0.5 + 0.18 * cos(t)), y: h * (0.3 + 0.18 * sin(t)))
            },
            widths: (0..<32).map { _ in CGFloat.random(in: 2...4) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: [CGPoint(x: w*0.5, y: h*0.48), CGPoint(x: w*0.5, y: h*0.82)],
            widths: [CGFloat.random(in: 3...5), CGFloat.random(in: 3...5)],
            color: color, lineWidth: 4, isEraser: false
        )],
        // 22. Infinity symbol
        [DrawingLine(
            points: stride(from: 0.0, through: 2 * Double.pi, by: 0.1).map { t in
                let denom = 1 + sin(t) * sin(t)
                return CGPoint(x: w * (0.5 + 0.28 * cos(t) / denom),
                               y: h * (0.5 + 0.18 * sin(t) * cos(t) / denom))
            },
            widths: (0..<63).map { _ in CGFloat.random(in: 2...4) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 23. Arrow pointing right
        [DrawingLine(
            points: [CGPoint(x: w*0.1, y: h*0.5), CGPoint(x: w*0.78, y: h*0.5)],
            widths: [CGFloat.random(in: 3...5), CGFloat.random(in: 3...5)],
            color: color, lineWidth: 4, isEraser: false
        ),
        DrawingLine(
            points: [CGPoint(x: w*0.58, y: h*0.32), CGPoint(x: w*0.80, y: h*0.5), CGPoint(x: w*0.58, y: h*0.68)],
            widths: (0..<3).map { _ in CGFloat.random(in: 3...5) },
            color: color, lineWidth: 4, isEraser: false
        )],
        // 24. Crescent moon
        [DrawingLine(
            points: stride(from: -0.6, through: 0.6, by: 0.08).map { t in
                CGPoint(x: w * (0.5 + 0.22 * cos(t * 2.5)), y: h * (0.5 + 0.32 * sin(t * 2.5)))
            },
            widths: (0..<16).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: stride(from: -0.45, through: 0.45, by: 0.09).map { t in
                CGPoint(x: w * (0.56 + 0.18 * cos(t * 3.0)), y: h * (0.5 + 0.28 * sin(t * 3.0)))
            },
            widths: (0..<11).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 25. Staircase
        [DrawingLine(
            points: [
                CGPoint(x: w*0.15, y: h*0.75), CGPoint(x: w*0.15, y: h*0.58),
                CGPoint(x: w*0.35, y: h*0.58), CGPoint(x: w*0.35, y: h*0.42),
                CGPoint(x: w*0.55, y: h*0.42), CGPoint(x: w*0.55, y: h*0.28),
                CGPoint(x: w*0.75, y: h*0.28)
            ],
            widths: (0..<7).map { _ in CGFloat.random(in: 3...5) },
            color: color, lineWidth: 4, isEraser: false
        )],
        // 26. DNA helix
        [DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                CGPoint(x: w * (0.35 + 0.15 * sin(t * 3 * .pi)), y: h * (0.1 + 0.8 * t))
            },
            widths: (0..<21).map { _ in CGFloat.random(in: 2...4) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                CGPoint(x: w * (0.65 - 0.15 * sin(t * 3 * .pi)), y: h * (0.1 + 0.8 * t))
            },
            widths: (0..<21).map { _ in CGFloat.random(in: 2...4) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 27. Mushroom
        [DrawingLine(
            points: stride(from: 0.0, through: Double.pi, by: 0.1).map { t in
                CGPoint(x: w * (0.5 + 0.32 * cos(t)), y: h * (0.42 - 0.26 * sin(t)))
            },
            widths: (0..<32).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: [CGPoint(x: w*0.38, y: h*0.42), CGPoint(x: w*0.38, y: h*0.75),
                     CGPoint(x: w*0.62, y: h*0.75), CGPoint(x: w*0.62, y: h*0.42)],
            widths: (0..<4).map { _ in CGFloat.random(in: 2...4) },
            color: color, lineWidth: 3, isEraser: false
        )],
        // 28. Comet
        [DrawingLine(
            points: stride(from: 0.0, through: 2 * Double.pi, by: 0.2).map { t in
                CGPoint(x: w * (0.62 + 0.12 * cos(t)), y: h * (0.38 + 0.12 * sin(t)))
            },
            widths: (0..<32).map { _ in CGFloat.random(in: 2...4) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: stride(from: 0.0, through: 1.0, by: 0.08).map { t in
                CGPoint(x: w * (0.62 - 0.48 * t), y: h * (0.38 + 0.22 * t))
            },
            widths: (0..<13).map { _ in CGFloat.random(in: 1...4) },
            color: color, lineWidth: 2, isEraser: false
        )],
        // 29. Question mark
        [DrawingLine(
            points: stride(from: 0.0, through: 1.5 * Double.pi, by: 0.12).map { t in
                CGPoint(x: w * (0.5 + 0.18 * cos(t + Double.pi/2)),
                        y: h * (0.32 + 0.18 * sin(t + Double.pi/2)))
            } + [CGPoint(x: w*0.5, y: h*0.52), CGPoint(x: w*0.5, y: h*0.64)],
            widths: (0..<16).map { _ in CGFloat.random(in: 2...5) },
            color: color, lineWidth: 3, isEraser: false
        ),
        DrawingLine(
            points: [CGPoint(x: w*0.5, y: h*0.74), CGPoint(x: w*0.5, y: h*0.78)],
            widths: [CGFloat.random(in: 4...6), CGFloat.random(in: 4...6)],
            color: color, lineWidth: 5, isEraser: false
        )],
        // 30. Mountain range
        [DrawingLine(
            points: [
                CGPoint(x: w*0.05, y: h*0.75), CGPoint(x: w*0.25, y: h*0.35),
                CGPoint(x: w*0.42, y: h*0.62), CGPoint(x: w*0.58, y: h*0.22),
                CGPoint(x: w*0.75, y: h*0.58), CGPoint(x: w*0.95, y: h*0.75)
            ],
            widths: (0..<6).map { _ in CGFloat.random(in: 3...5) },
            color: color, lineWidth: 4, isEraser: false
        )],
    ]
}


func renderCanvas(lines: [DrawingLine], size: CGSize, canvasColor: UIColor = .white) -> UIImage {
    // Use SwiftUI ImageRenderer so all pen types (brush, chalk, dual-tone, etc.)
    // go through the same renderLine path as the live Canvas.
    let canvasSwiftUI = Color(canvasColor)
    let view = Canvas { context, _ in
        for line in lines {
            renderLine(line, in: &context, canvasColor: canvasSwiftUI)
        }
    }
    .frame(width: size.width, height: size.height)
    .background(canvasSwiftUI)

    let renderer = ImageRenderer(content: view)
    renderer.scale = UITraitCollection.current.displayScale
    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
    if let uiImage = renderer.uiImage { return uiImage }

    // Fallback: simple CGContext render (pencil-style only)
    let fallback = UIGraphicsImageRenderer(size: size)
    return fallback.image { ctx in
        canvasColor.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        let c = ctx.cgContext
        c.setLineCap(.round); c.setLineJoin(.round)
        for line in lines {
            guard !line.points.isEmpty else { continue }
            let strokeColor = UIColor(line.isEraser ? canvasSwiftUI : line.color)
            c.setStrokeColor(strokeColor.cgColor)
            if line.points.count == 1 {
                let pt = line.points[0]
                let w = line.lineWidth
                c.fillEllipse(in: CGRect(x: pt.x-w/2, y: pt.y-w/2, width: w, height: w))
            } else {
                for i in 1..<line.points.count {
                    c.setLineWidth(line.lineWidth)
                    c.beginPath()
                    c.move(to: line.points[i-1])
                    c.addLine(to: line.points[i])
                    c.strokePath()
                }
            }
        }
    }
}

// MARK: - AI Caption

// MARK: - AI Provider Abstraction

protocol AIProvider {
    func generateCaptionAndKeywords(for image: UIImage) async -> (caption: String, keywords: [String])
}

// MARK: - Gemini Provider

class GeminiProvider: AIProvider {
    let apiKey: String

    init(apiKey: String = snoodleGeminiKey) {
        self.apiKey = apiKey
    }

    func generateCaptionAndKeywords(for image: UIImage) async -> (caption: String, keywords: [String]) {
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            return ("A mysterious doodle", [])
        }
        let base64 = imageData.base64EncodedString()
        let prompt = #"Look at this doodle. Respond with ONLY valid JSON, no markdown, no explanation. Format: {"caption": "witty diary-style title max 8 words", "keywords": ["tag1","tag2","tag3","tag4","tag5","tag6"]} Keywords should describe what you see: subjects, mood, colors, style, actions."#

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inline_data": ["mime_type": "image/jpeg", "data": base64]],
                    ["text": prompt]
                ]
            ]]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return ("Untitled doodle", [])
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return ("My doodle", []) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        // Retry transient failures (rate-limit / overload) and surface the real error.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                if status == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidates = json["candidates"] as? [[String: Any]],
                       let content = candidates.first?["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]],
                       let text = parts.first?["text"] as? String {
                        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "```json", with: "")
                            .replacingOccurrences(of: "```", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if let jsonData2 = clean.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: jsonData2) as? [String: Any] {
                            let caption = (parsed["caption"] as? String ?? "My doodle")
                                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                            let keywords = parsed["keywords"] as? [String] ?? []
                            return (caption, keywords)
                        }
                        print("⚠️ Gemini: HTTP 200 but caption JSON didn't parse. Body: \(String(data: data, encoding: .utf8) ?? "<none>")")
                    } else {
                        // 200 with no candidates usually means a safety block or empty response.
                        print("⚠️ Gemini: HTTP 200 but no candidates (possible safety block). Body: \(String(data: data, encoding: .utf8) ?? "<none>")")
                    }
                    return ("My doodle", [])   // got a usable-status response we can't parse — retrying won't help
                } else if status == 429 || status == 500 || status == 503 {
                    // Transient: rate-limited or overloaded. Log and retry with backoff.
                    print("⚠️ Gemini transient error \(status), attempt \(attempt)/\(maxAttempts). Body: \(String(data: data, encoding: .utf8) ?? "<none>")")
                    if attempt < maxAttempts {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                        continue
                    }
                } else {
                    // Non-retryable (bad request, auth, model not found, etc.)
                    print("❌ Gemini error \(status). Body: \(String(data: data, encoding: .utf8) ?? "<none>")")
                    return ("My doodle", [])
                }
            } catch {
                print("❌ Gemini network error, attempt \(attempt)/\(maxAttempts): \(error.localizedDescription)")
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
                    continue
                }
            }
        }
        return ("My doodle", [])
    }
}

// MARK: - Vision Provider (on-device, instant)

class VisionProvider: AIProvider {

    // Identifiers that describe subject matter (not style/medium) — used to build the caption.
    private static let subjectPrefixes: [String] = [
        "person", "animal", "cat", "dog", "bird", "fish", "insect",
        "food", "fruit", "vegetable", "drink",
        "vehicle", "car", "truck", "boat", "airplane",
        "building", "house", "architecture",
        "plant", "flower", "tree", "nature", "landscape",
        "face", "body", "hand",
        "furniture", "clothing",
        "music", "sport", "technology"
    ]

    func generateCaptionAndKeywords(for image: UIImage) async -> (caption: String, keywords: [String]) {
        guard let cgImage = image.cgImage else { return ("My doodle", []) }

        return await Task.detached(priority: .userInitiated) {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let observations = request.results as? [VNClassificationObservation]
            else { return ("My doodle", []) }

            // Keep observations above confidence threshold, drop very generic ones
            let threshold: Float = 0.15
            let blocked: Set<String> = ["illustration", "art", "drawing", "image",
                                        "picture", "graphic", "design", "visual", "color"]
            let hits = observations
                .filter { $0.confidence >= threshold && !blocked.contains($0.identifier.lowercased()) }
                .prefix(10)
                .map { $0.identifier
                    .replacingOccurrences(of: "_", with: " ")
                    .lowercased() }

            // Caption: use the first hit that sounds like a subject, or just the top hit
            let subjectHit = hits.first { h in
                VisionProvider.subjectPrefixes.contains(where: { h.hasPrefix($0) })
            }
            let captionSubject = subjectHit ?? hits.first ?? "something interesting"
            let caption = "A doodle of \(captionSubject)"
            let keywords = Array(hits.prefix(6))
            return (caption, keywords)
        }.value
    }
}

// MARK: - AI Manager

// Key lives in Secrets.swift (gitignored) — see that file to rotate
func getAIProvider() -> AIProvider {
    // User can override with their own key in Settings (power users only)
    let userKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
    let key = userKey.isEmpty ? snoodleGeminiKey : userKey
    return GeminiProvider(apiKey: key)
}

let genericKeywords: Set<String> = ["doodle", "drawing", "sketch", "illustration", "art", "artwork", "image", "picture", "scribble", "line", "lines", "black and white", "black", "white"]

func callSnoodleAI(for image: UIImage) async -> (caption: String, keywords: [String]) {
    let result = await getAIProvider().generateCaptionAndKeywords(for: image)
    let filtered = result.keywords.filter { !genericKeywords.contains($0.lowercased()) }
    return (result.caption, filtered)
}

// MARK: - Palette

let paletteColors: [Color] = [
    // Original colors — indices unchanged (white moved to index 1, others shift by 1)
    .black, .white, .red, .orange, .yellow, .green, .blue, .purple,
    Color(red: 0.53, green: 0.81, blue: 0.98),          // light blue
    .brown, Color(red: 0.96, green: 0.76, blue: 0.63),  // flesh/skin
    Color(white: 0.5),                                   // gray
    // Extended palette
    Color(red: 1.0,  green: 0.41, blue: 0.71),          // hot pink
    Color(red: 0.85, green: 0.44, blue: 0.84),          // orchid/violet
    Color(red: 0.0,  green: 0.75, blue: 0.75),          // teal
    Color(red: 0.0,  green: 0.50, blue: 0.50),          // dark teal
    Color(red: 0.13, green: 0.55, blue: 0.13),          // forest green
    Color(red: 0.60, green: 0.80, blue: 0.20),          // lime green
    Color(red: 0.10, green: 0.10, blue: 0.44),          // navy
    Color(red: 0.69, green: 0.19, blue: 0.38),          // maroon/wine
    Color(red: 1.0,  green: 0.84, blue: 0.0),           // gold
    Color(red: 0.85, green: 0.65, blue: 0.13),          // dark gold
    Color(red: 0.25, green: 0.25, blue: 0.25),          // dark gray
    Color(red: 0.85, green: 0.85, blue: 0.85),          // light gray
]

// MARK: - Canvas Color Picker

// Canvas uses same palette as pen colors for consistency
let canvasColorOptions: [Color] = paletteColors

// MARK: - Recent Colors

/// Shared persistent recent-colors list, seeded from paletteColors on first run.
/// Every color picker's "+" button calls RecentColors.add(_:) to prepend the
/// picked color and keep the list trimmed to 20.
struct RecentColors {
    static let key = "recentColors_v1"
    static let max = 20

    static func load() -> [Color] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([CodableColor].self, from: data),
              !list.isEmpty else {
            save(paletteColors)
            return paletteColors
        }
        return list.map { $0.color }
    }

    @discardableResult
    static func add(_ color: Color) -> [Color] {
        var colors = load()
        let c = CodableColor(color)
        colors.removeAll {
            let e = CodableColor($0)
            return abs(e.r - c.r) < 0.002 && abs(e.g - c.g) < 0.002 &&
                   abs(e.b - c.b) < 0.002 && abs(e.a - c.a) < 0.002
        }
        colors.insert(color, at: 0)
        if colors.count > max { colors = Array(colors.prefix(max)) }
        save(colors)
        return colors
    }

    static func save(_ colors: [Color]) {
        if let data = try? JSONEncoder().encode(colors.map { CodableColor($0) }) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Recent Canvas Colors

/// Persistent recent-colors list for the canvas background color picker.
/// Seeded from canvasColorOptions on first run; also tracks the last-selected color
/// so it survives app restarts without needing an index into a fixed array.
struct RecentCanvasColors {
    static let listKey     = "recentCanvasColors_v1"
    static let selectedKey = "selectedCanvasColor_v1"
    static let max = 20

    static func load() -> [Color] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let list = try? JSONDecoder().decode([CodableColor].self, from: data),
              !list.isEmpty else {
            save(canvasColorOptions)
            return canvasColorOptions
        }
        return list.map { $0.color }
    }

    /// Load the most-recently chosen canvas color, migrating from the old index-based key.
    static func loadSelected() -> Color {
        if let data = UserDefaults.standard.data(forKey: selectedKey),
           let cc = try? JSONDecoder().decode(CodableColor.self, from: data) {
            return cc.color
        }
        // Migrate: old AppStorage key "lastCanvasColorIndex" (default 11 = gray)
        if UserDefaults.standard.object(forKey: "lastCanvasColorIndex") != nil {
            let idx = UserDefaults.standard.integer(forKey: "lastCanvasColorIndex")
            return canvasColorOptions[min(idx, canvasColorOptions.count - 1)]
        }
        return canvasColorOptions[11] // gray — original default
    }

    static func saveSelected(_ color: Color) {
        if let data = try? JSONEncoder().encode(CodableColor(color)) {
            UserDefaults.standard.set(data, forKey: selectedKey)
        }
    }

    @discardableResult
    static func add(_ color: Color) -> [Color] {
        var colors = load()
        colors.removeAll { $0.isApproximatelyEqual(to: color) }
        colors.insert(color, at: 0)
        if colors.count > max { colors = Array(colors.prefix(max)) }
        save(colors)
        return colors
    }

    static func save(_ colors: [Color]) {
        if let data = try? JSONEncoder().encode(colors.map { CodableColor($0) }) {
            UserDefaults.standard.set(data, forKey: listKey)
        }
    }
}

// MARK: - Color equality helper

extension Color {
    /// Approximate RGBA equality (tolerates floating-point round-trip drift).
    func isApproximatelyEqual(to other: Color) -> Bool {
        let a = CodableColor(self), b = CodableColor(other)
        return abs(a.r - b.r) < 0.002 && abs(a.g - b.g) < 0.002 &&
               abs(a.b - b.b) < 0.002 && abs(a.a - b.a) < 0.002
    }
}

// MARK: - Color Swatch (checkerboard for alpha < 1)

/// Circular color swatch. Shows a gray checkerboard behind colors with
/// opacity < 1 — the standard iOS convention for transparency.
struct ColorSwatchView: View {
    let color: Color
    let size: CGFloat
    var isSelected: Bool = false
    var selectionColor: Color = .blue

    private var hasAlpha: Bool { CodableColor(color).a < 0.995 }

    var body: some View {
        ZStack {
            if hasAlpha {
                CheckerboardView(tileSize: max(3, size / 8))
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
            Circle().fill(color)
            if isSelected {
                Circle().stroke(Color.white,        lineWidth: 2.5).padding(-2.5)
                Circle().stroke(selectionColor,     lineWidth: 2.5).padding(-5.5)
            } else {
                Circle().stroke(
                    color.isApproximatelyEqual(to: .white)
                        ? Color.black.opacity(0.25) : Color.gray.opacity(0.2),
                    lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
    }
}

struct CheckerboardView: View {
    var tileSize: CGFloat = 6
    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width  / tileSize))
            let rows = Int(ceil(size.height / tileSize))
            for row in 0..<rows {
                for col in 0..<cols {
                    let light = (row + col) % 2 == 0
                    let rect = CGRect(x: CGFloat(col) * tileSize,
                                     y: CGFloat(row) * tileSize,
                                     width: tileSize, height: tileSize)
                    context.fill(Path(rect), with: .color(light ? .white : Color(white: 0.78)))
                }
            }
        }
    }
}

