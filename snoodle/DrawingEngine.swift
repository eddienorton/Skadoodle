//
//  DrawingEngine.swift
//  snoodle
//

import SwiftUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine

enum DualToneStyle: String, CaseIterable, Identifiable {
    case gradient    = "Gradient"
    case split       = "Split"
    case reactive    = "Reactive"
    case alternating = "Alternating"
    var id: String { rawValue }
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
        case .dualTone: return "wand.and.stars"
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
    init(id: UUID = UUID(), lines: [DrawingLine] = []) {
        self.id = id
        self.lines = lines
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
}

struct DrawingLine {
    var points: [CGPoint]
    var widths: [CGFloat]  // per-point width for pressure simulation
    var color: Color
    var lineWidth: CGFloat  // base width (used for eraser)
    var isEraser: Bool
    var penType: PenType = .pencil
    var colorB: Color = .blue   // second color for dualTone pens
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
    var renderLines: Bool = false              // true = self-renders (DoodleStampCreatorView); false = external layer canvases render
    var onBeforeDraw: (() -> Void)? = nil      // called once at stroke start; caller should push undo snapshot
    var onEraserCommitted: ((DrawingLine) -> Void)? = nil  // called when an eraser stroke lands; caller may redirect to another layer
    @Binding var currentLine: DrawingLine?     // live preview; updated during stroke, nil when idle

    @State private var lastPoint: CGPoint? = nil
    @State private var lastTime: Date? = nil
    @State private var lastSpeed: CGFloat? = nil
    @State private var redrawTrigger: Int = 0

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
        .gesture(isIPad ? nil : DragGesture(minimumDistance: 0)
            .onChanged { value in
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
                if let line = currentLine, line.points.count > 1 {
                    lines.append(line)
                    if line.isEraser { onEraserCommitted?(line) }
                }
                currentLine = nil; lastPoint = nil; lastTime = nil; lastSpeed = nil
            }
        )

        .overlay(isIPad ? AnyView(PencilInputView(
                isLongPressing: isLongPressing,
                stampResizeTargetId: stampResizeTargetId,
                isStampSelected: isStampSelected,
                onBegan: { point, pressure, isPencil in
                    guard !isLongPressing && stampResizeTargetId == nil else { return }
                    lastPoint = point
                    lastTime = Date()
                    // Snapshot before first touch — so onMoved never blocks the first frame
                    onBeforeDraw?()
                },
                onMoved: { point, pressure, isPencil in
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
                    } else if isPencil {
                        let clampedPressure = min(pressure, 0.6 + ramp * 0.4)
                        let pressureScale = 0.3 + clampedPressure * 1.0  // 0.3x–1.3x
                        targetW = max(1.0, lineWidth * pressureScale * ramp)
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
                    if let line = currentLine, line.points.count > 1 {
                        let finalLine = line
                        DispatchQueue.main.async {
                            var updated = lines
                            updated.append(finalLine)
                            lines = updated
                            redrawTrigger += 1
                            if finalLine.isEraser { onEraserCommitted?(finalLine) }
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

// MARK: - Drawing Layer Canvas
// Renders one drawing layer's committed lines plus the optional live-preview stroke.
struct DrawingLayerCanvas: View {
    let lines: [DrawingLine]
    let currentLine: DrawingLine?
    let canvasColor: Color
    var body: some View {
        Canvas { context, size in
            for line in lines { renderLine(line, in: &context, canvasColor: canvasColor) }
            if let c = currentLine { renderLine(c, in: &context, canvasColor: canvasColor) }
        }
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
        // Pencil: use real pressure. Finger: fixed 0.5 (no pressure sensor)
        let pressure: CGFloat = activeTouch!.type == .pencil || activeTouch!.type == .stylus
            ? (activeTouch!.force > 0 ? activeTouch!.force / activeTouch!.maximumPossibleForce : 0.5)
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
            // Pencil: use real pressure. Finger: fixed 0.5 (no pressure sensor)
            let pressure: CGFloat = touch.type == .pencil || touch.type == .stylus
                ? (touch.force > 0 ? touch.force / touch.maximumPossibleForce : 0.5)
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
func renderLine(_ line: DrawingLine, in context: inout GraphicsContext, canvasColor: Color) {
    guard line.points.count > 0 else { return }

    if line.isEraser {
        drawEraserLine(line, in: &context, canvasColor: canvasColor)
        return
    }

    switch line.penType {
    case .pencil:
        drawTaperedLine(line, color: line.color, in: &context, taperFraction: 0.2, minTaper: 0.08, opacity: 1.0)
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
    case .dualTone(let style):
        drawDualToneLine(line, style: style, in: &context)
    }
}

private func strokeTaper(i: Int, count: Int, taperFraction: CGFloat) -> CGFloat {
    let t = CGFloat(i) / CGFloat(max(count - 1, 1))
    if t < taperFraction { return t / taperFraction }
    if t > (1.0 - taperFraction) { return (1.0 - t) / taperFraction }
    return 1.0
}

private func drawEraserLine(_ line: DrawingLine, in context: inout GraphicsContext, canvasColor: Color) {
    let baseW = line.lineWidth
    let count = line.points.count
    // Use .clear blend mode — punches transparent holes revealing background/photo below
    context.blendMode = .clear
    if count == 1 {
        let pt = line.points[0]
        let rect = CGRect(x: pt.x - baseW/2, y: pt.y - baseW/2, width: baseW, height: baseW)
        context.fill(Path(ellipseIn: rect), with: .color(.white))
    } else {
        for i in 1..<count {
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: .color(.white),
                           style: StrokeStyle(lineWidth: baseW, lineCap: .round, lineJoin: .round))
        }
    }
    context.blendMode = .normal
}

private func drawTaperedLine(_ line: DrawingLine, color: Color, in context: inout GraphicsContext,
                              taperFraction: CGFloat, minTaper: CGFloat, opacity: CGFloat) {
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
        let taper = strokeTaper(i: i, count: count, taperFraction: taperFraction)
        let pressure = i < line.widths.count ? line.widths[i] / baseW : 1.0
        let w = baseW * max(minTaper, taper) * pressure
        // Extend path as long as width stays within 15% of current
        var path = Path()
        path.move(to: line.points[i-1])
        path.addLine(to: line.points[i])
        var j = i + 1
        while j < count {
            let nextTaper = strokeTaper(i: j, count: count, taperFraction: taperFraction)
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
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.3)
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

    // Core stroke — full opacity, tapered
    drawTaperedLine(line, color: line.color, in: &context, taperFraction: 0.35, minTaper: 0.0, opacity: 0.85)

    // Soft halo pass — wider, lower opacity for brush bleed effect
    if count > 1 {
        for i in 1..<count {
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.35)
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
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.15)
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
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.15)
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
    // Pass 1: wide soft wet wash
    for i in 1..<count {
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.3)
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
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.25)
        let w = baseW * 1.2 * max(0.1, taper) * pressureAt(i, in: line)
        var seg = Path()
        seg.move(to: line.points[i-1])
        seg.addLine(to: line.points[i])
        context.stroke(seg, with: .color(line.color.opacity(0.22)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
    // Pass 3: thin edge darkening for pigment-pooling effect
    for i in 1..<count {
        let taper = strokeTaper(i: i, count: count, taperFraction: 0.1)
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
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.15)
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
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2)
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
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2)
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
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2)
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
        let pulseLen = max(3, count / 12)  // pulse length scales with stroke length
        for i in 1..<count {
            let pulse = (i / pulseLen) % 2 == 0
            let segColor = pulse ? line.color : line.colorB
            let taper = strokeTaper(i: i, count: count, taperFraction: 0.2)
            let w = baseW * max(0.08, taper) * pressureAt(i, in: line)
            var seg = Path()
            seg.move(to: line.points[i-1])
            seg.addLine(to: line.points[i])
            context.stroke(seg, with: .color(segColor),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }
    }
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

