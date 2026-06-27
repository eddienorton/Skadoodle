//
//  StampCanvas.swift
//  snoodle
//
//  UIKit-based stamp interaction layer.

import UIKit
import SwiftUI

// MARK: - Text stamp font sizing

func fitTextFontSize(text: String, stampSize s: CGFloat, baseFontId: String?) -> CGFloat {
    let padding: CGFloat = s * 0.08
    let maxW = s - padding * 2
    let maxH = s - padding * 2
    var lo: CGFloat = 8
    var hi: CGFloat = s * 0.7
    let baseFont = TextStampFont.font(forId: baseFontId)
    for _ in 0..<12 {
        let mid = (lo + hi) / 2
        let font = baseFont.withSize(mid)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs, context: nil)
        if rect.height <= maxH { lo = mid } else { hi = mid }
    }
    return lo
}

// MARK: - StampItemUIView

class StampItemUIView: UIView, UIGestureRecognizerDelegate {
    var recentlyPinched: Bool = false

    var stampId: UUID
    var stamp: PlacedStamp {
        didSet {
            guard stamp.size.isFinite, stamp.size > 0 else { return }
            updateVisual()
        }
    }
    var hitImage: UIImage?

    var onDrag: (CGPoint) -> Void = { _ in }
    var onDragEnd: (CGPoint, CGPoint, CGVector) -> Void = { _, _, _ in }  // (startPos, finalPos, velocity)
    var onTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}

    var onDupe: () -> Void = {}

    private var dragStartStampPos: CGPoint = .zero
    private var dragStartTouchPos: CGPoint = .zero

    private let imageView = UIImageView()
    private let emojiLabel = UILabel()

    init(stamp: PlacedStamp) {
        self.stampId = stamp.id
        self.stamp = stamp
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        setupVisual()
        setupGestures()
        guard stamp.size.isFinite, stamp.size > 0 else { return }
        updateVisual()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Visual

    private func setupVisual() {
        imageView.contentMode = .scaleAspectFit
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)

        emojiLabel.textAlignment = .center
        emojiLabel.adjustsFontSizeToFitWidth = true
        emojiLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(emojiLabel)
    }

    func updateVisual() {
        let s = stamp.size
        guard s.isFinite, s > 0 else { return }

        // Update bounds for gesture hit-testing area only.
        // Visual rendering is handled by StampRenderView (SwiftUI layer).
        let dw = stamp.displayWidth
        let dh = stamp.displayHeight
        if abs(bounds.size.width - dw) > 0.5 || abs(bounds.size.height - dh) > 0.5 {
            transform = .identity
            bounds = CGRect(origin: .zero, size: CGSize(width: dw, height: dh))
        }
        imageView.isHidden = true
        emojiLabel.isHidden = true
        backgroundColor = .clear
        layer.cornerRadius = 0

        let flipTransform = CGAffineTransform(scaleX: stamp.flipX ? -1 : 1, y: stamp.flipY ? -1 : 1)
        let rotateTransform = CGAffineTransform(rotationAngle: stamp.rotation * .pi / 180)
        transform = flipTransform.concatenating(rotateTransform)
    }

    // MARK: - Alpha hit testing

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return false }
        // Transparent text stamps — accept any touch within bounding rect
        // (letter pixels too thin/sparse to reliably land two fingers for pinch)
        if stamp.isTextStamp && stamp.textBgColor == .clear {
            return bounds.contains(point)
        }
        guard let img = hitImage, let cgImage = img.cgImage else {
            return super.point(inside: point, with: event)
        }
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        guard imgW > 0, imgH > 0 else { return super.point(inside: point, with: event) }

        // Compute where the image actually sits inside bounds under scaleAspectFit
        let boundsW = bounds.width
        let boundsH = bounds.height
        let scale = min(boundsW / imgW, boundsH / imgH)
        let fitW = imgW * scale
        let fitH = imgH * scale
        let offsetX = (boundsW - fitW) / 2
        let offsetY = (boundsH - fitH) / 2
        let fitRect = CGRect(x: offsetX, y: offsetY, width: fitW, height: fitH)

        // If touch is in the letterbox area, it's transparent
        guard fitRect.contains(point) else { return false }

        // Map touch into image pixel space
        let px = Int((point.x - offsetX) / fitW * imgW)
        let pyUI = Int((point.y - offsetY) / fitH * imgH)
        let pyCG = Int(imgH) - pyUI - 1
        guard px >= 0, pyCG >= 0, px < Int(imgW), pyCG < Int(imgH) else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        ctx.draw(cgImage, in: CGRect(x: -CGFloat(px), y: -CGFloat(pyCG), width: imgW, height: imgH))
        return pixel[3] > 25
    }

    // MARK: - Gestures

    private func setupGestures() {
        // Pan gesture — only fires when hitTest returns this view (i.e. stamp is selected).
        // Non-selected stamps return nil from hitTest so touches pass through to drawing canvas.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.numberOfTapsRequired = 1
        addGestureRecognizer(twoFingerTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Allow simultaneous recognition only for non-pan gestures (pinch, rotate)
        // Returning false for pan prevents the sheet dismissal gesture from firing simultaneously
        if g is UIPanGestureRecognizer || other is UIPanGestureRecognizer { return false }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g is UITapGestureRecognizer {
            return touch.type != .pencil && touch.type != .stylus
        }
        return true
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let touchInSuper = g.location(in: superview)
        switch g.state {
        case .began:
            // Use UIKit center as source of truth, not stamp.position which may be stale
            dragStartStampPos = center
            dragStartTouchPos = touchInSuper
        case .changed:
            let newPos = CGPoint(
                x: dragStartStampPos.x + touchInSuper.x - dragStartTouchPos.x,
                y: dragStartStampPos.y + touchInSuper.y - dragStartTouchPos.y
            )
            // Move the UIView directly for smooth live feedback
            center = newPos
            // Also update model so selection indicator follows
            onDrag(newPos)
        case .ended, .cancelled:
            let vel = g.velocity(in: superview)
            let finalPos = center
            onDragEnd(dragStartStampPos, finalPos, CGVector(dx: vel.x, dy: vel.y))
        default: break
        }
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        // Guard against transparent-pixel taps. Without this, tapping transparent area inside
        // the bounding box causes a race: canvasTap deselects immediately, then this fires
        // ~350ms later (after double-tap-fail wait) and reselects because selectedStampId is nil.
        let pt = g.location(in: self)
        guard point(inside: pt, with: nil) else { return }
        onTap()
    }
    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) { onDoubleTap() }
    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard !recentlyPinched else { return }
        onDupe()
    }
}

// MARK: - StampContainerView

class StampContainerView: UIView {

    var selectedStampId: UUID? = nil
    private var itemViews: [UUID: StampItemUIView] = [:]
    var onStampDrag: (UUID, CGPoint) -> Void = { _, _ in }
    var onStampDragEnd: (UUID, CGPoint, CGPoint, CGVector) -> Void = { _, _, _, _ in }  // (id, startPos, finalPos, velocity)
    var onStampTap: (UUID) -> Void = { _ in }
    var onStampDoubleTap: (UUID) -> Void = { _ in }
    var onStampDupe: (UUID) -> Void = { _ in }
    var onBringToFront: (UUID) -> Void = { _ in }
    var onCanvasTap: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        // Canvas tap to deselect — on the container itself, not stamp views
        let canvasTap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        canvasTap.cancelsTouchesInView = false
        addGestureRecognizer(canvasTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleCanvasTap(_ g: UITapGestureRecognizer) {
        // Only fire if tap didn't hit a stamp view
        let point = g.location(in: self)
        let hitStamp = subviews.reversed().first { view in
            guard let stampView = view as? StampItemUIView else { return false }
            let localPt = convert(point, to: stampView)
            return stampView.point(inside: localPt, with: nil)
        }
        if hitStamp == nil {
            onCanvasTap()
        }
    }

    // Only the selected (highlighted) stamp captures touches — so it can be dragged.
    // All other touches pass through to the drawing canvas.
    // Uses the snug rect as the hit area when a stamp is selected — matches exactly
    // what the user sees on screen. Tapping outside the snug rect (transparent padding)
    // returns nil so the touch falls through to the canvas and deselects.
    // Non-selected stamps use alpha-aware point(inside:) in the else branch above.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let selId = selectedStampId,
              let stampView = itemViews[selId] else { return nil }
        let localPt = stampView.convert(point, from: self)
        let snug = stampView.stamp.snugSize
        let dw = stampView.bounds.width
        let dh = stampView.bounds.height
        let snugRect = CGRect(
            x: (dw - snug.width) / 2,
            y: (dh - snug.height) / 2,
            width: snug.width,
            height: snug.height
        )
        return snugRect.contains(localPt) ? stampView : nil
    }

    func syncStamps(_ stamps: [PlacedStamp], draggingId: UUID?, rotatingId: UUID?, imageProvider: (PlacedStamp) -> UIImage?) {
        let newIds = Set(stamps.map { $0.id })

        for id in Set(itemViews.keys).subtracting(newIds) {
            itemViews[id]?.removeFromSuperview()
            itemViews.removeValue(forKey: id)
        }

        for (zIndex, stamp) in stamps.enumerated() {
            guard stamp.size.isFinite, stamp.size > 0 else { continue }
            let view: StampItemUIView
            if let existing = itemViews[stamp.id] {
                view = existing
            } else {
                view = StampItemUIView(stamp: stamp)
                view.onDrag         = { [weak self] pos in self?.onStampDrag(stamp.id, pos) }
                view.onDragEnd      = { [weak self] startPos, pos, vel in self?.onStampDragEnd(stamp.id, startPos, pos, vel) }
                view.onTap          = { [weak self] in self?.onStampTap(stamp.id) }
                view.onDoubleTap    = { [weak self] in self?.onStampDoubleTap(stamp.id) }
                view.onDupe         = { [weak self] in self?.onStampDupe(stamp.id) }
                addSubview(view)
                itemViews[stamp.id] = view
            }

            view.stamp = stamp
            view.hitImage = imageProvider(stamp)

            // Only protect during 1-finger pan — pan owns position, setting center
            // during pan fights the gesture. All other gestures update stamp.position
            // in the model so syncStamps center updates are correct and needed.
            let isActive = stamp.id == draggingId
            if !isActive {
                if abs(view.center.x - stamp.position.x) > 1 || abs(view.center.y - stamp.position.y) > 1 {
                }
                view.center = stamp.position
            }

            let targetIndex = min(zIndex, subviews.count - 1)
            if let cur = subviews.firstIndex(of: view), cur != targetIndex {
                insertSubview(view, at: targetIndex)
            }
        }
    }
}

// MARK: - StampCanvasView

struct StampCanvasView: UIViewRepresentable {
    @Binding var stamps: [PlacedStamp]
    @Binding var selectedStampId: UUID?
    @Binding var showStampMagicMenu: Bool
    let canvasSize: CGSize
    @Binding var rotatingId: UUID?
    /// Stamp z-order from DrawScreen's layerOrder; empty = fall back to stamps array order.
    var layerOrder: [LayerEntry] = []
    /// Called before any stamp mutation; caller should push an undo snapshot.
    var onBeforeStampChange: (() -> Void)? = nil
    /// Called when a stamp dupe is created; caller appends it to its own collection and updates layerOrder.
    var onStampDuped: ((PlacedStamp) -> Void)? = nil
    /// Called after a stamp is deleted (double-tap); caller should remove it from layerOrder.
    var onStampDeleted: ((UUID) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> StampContainerView {
        let container = StampContainerView(frame: CGRect(origin: .zero, size: canvasSize))
        container.onStampDrag      = { id, pos in context.coordinator.handleDrag(id: id, pos: pos) }
        container.onStampDragEnd   = { id, startPos, pos, vel in context.coordinator.handleDragEnd(id: id, startPos: startPos, pos: pos, velocity: vel) }
        container.onStampTap       = { id in context.coordinator.handleTap(id: id) }
        container.onStampDoubleTap = { id in context.coordinator.handleDoubleTap(id: id) }
        container.onStampDupe      = { id in context.coordinator.handleDupe(id: id) }
        container.onBringToFront   = { id in context.coordinator.handleBringToFront(id: id) }
        container.onCanvasTap      = { context.coordinator.handleCanvasTap() }
        return container
    }

    func updateUIView(_ uiView: StampContainerView, context: Context) {
        context.coordinator.parent = self
        uiView.frame = CGRect(origin: .zero, size: canvasSize)
        uiView.selectedStampId = selectedStampId
        // Order UIKit gesture views by layerOrder so touch priority matches visual z-order.
        // Falls back to stamps array order when layerOrder is empty (e.g. DoodleStampCreatorView).
        let orderedStamps: [PlacedStamp]
        if layerOrder.isEmpty {
            orderedStamps = stamps
        } else {
            orderedStamps = layerOrder.compactMap { entry -> PlacedStamp? in
                guard case .stamp(let id) = entry else { return nil }
                return stamps.first(where: { $0.id == id })
            }
        }
        uiView.syncStamps(
            orderedStamps,
            draggingId: context.coordinator.draggingId,
            rotatingId: rotatingId
        ) { stamp in
            if let img = stamp.inlineImage { return img }
            if let customId = stamp.customImageId {
                return CustomStampManager.shared.stamps.first(where: { $0.id == customId })?.image
            }
            return context.coordinator.emojiImage(for: stamp)
        }
    }

    // MARK: Coordinator

    class Coordinator: NSObject {
        var parent: StampCanvasView
        private var emojiCache: [String: UIImage] = [:]
        var draggingId: UUID? = nil

        init(_ parent: StampCanvasView) { self.parent = parent }

        func emojiImage(for stamp: PlacedStamp) -> UIImage {
            let s = stamp.size
            guard s.isFinite, s > 0 else { return UIImage() }
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false

            if let text = stamp.stampText {
                // Text stamp — content-sized, respects explicit line breaks
                let bgColor = UIColor(stamp.textBgColor)
                let hasBg = bgColor != .clear
                let dw = stamp.displayWidth
                let dh = stamp.displayHeight
                let shadowKey = stamp.shadowEnabled ? "_sh\(Int(stamp.shadowBlur*10))_\(Int(stamp.shadowOffsetX*10))_\(Int(stamp.shadowOffsetY*10))_\(CodableColor(stamp.shadowColor).r.hashValue)" : "_nosh"
                let key = "txt_\(text.hashValue)_\(stamp.fontName ?? "system")_\(stamp.fontStyle)_\(stamp.textAlignment)_\(Int(dw))x\(Int(dh))_\(hasBg)\(shadowKey)"
                if let cached = emojiCache[key] { return cached }
                // Font size is stored in stamp.size for content-sized stamps
                let fontSize = stamp.stampWidth > 0 ? stamp.size : fitTextFontSize(text: text, stampSize: s, baseFontId: stamp.fontName)
                let font = TextStampFont.font(forId: stamp.fontName, style: stamp.fontStyle).withSize(fontSize)
                let color = UIColor(stamp.textColor)
                let fmt = UIGraphicsImageRendererFormat()
                fmt.opaque = hasBg && !stamp.shadowEnabled  // opaque=false when shadow extends outside bg
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: dw, height: dh), format: fmt)
                let img = renderer.image { _ in
                    if hasBg {
                        bgColor.setFill()
                        UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: dw, height: dh),
                                     cornerRadius: 8).fill()
                    }
                    let nsAlignment: NSTextAlignment = stamp.textAlignment == "left" ? .left : stamp.textAlignment == "right" ? .right : .center
                    let para = NSMutableParagraphStyle()
                    para.alignment = nsAlignment
                    para.lineBreakMode = .byClipping
                    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
                    if stamp.shadowEnabled {
                        let sh = NSShadow()
                        sh.shadowColor = UIColor(stamp.shadowColor)
                        sh.shadowBlurRadius = CGFloat(stamp.shadowBlur)
                        sh.shadowOffset = CGSize(width: stamp.shadowOffsetX, height: stamp.shadowOffsetY)
                        attrs[.shadow] = sh
                    }
                    let hPad: CGFloat = 10
                    let vPad: CGFloat = 5
                    let str = text as NSString
                    let br = str.boundingRect(
                        with: CGSize(width: dw - hPad * 2, height: dh - vPad * 2),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: attrs, context: nil)
                    str.draw(with: CGRect(x: hPad, y: (dh - ceil(br.height)) / 2,
                                          width: dw - hPad * 2, height: dh - vPad * 2),
                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                             attributes: attrs, context: nil)
                }
                emojiCache[key] = img
                return img
            } else {
                // Emoji stamp
                let key = "\(stamp.emoji)_\(Int(s))"
                if let cached = emojiCache[key] { return cached }
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: format)
                let img = renderer.image { _ in
                    let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: s * 0.85)]
                    let str = stamp.emoji as NSString
                    let sz = str.size(withAttributes: attrs)
                    str.draw(at: CGPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2),
                             withAttributes: attrs)
                }
                emojiCache[key] = img
                return img
            }
        }

        func handleDrag(id: UUID, pos: CGPoint) {
            if draggingId == nil {
                // First event of this drag — snapshot before any position change
                parent.onBeforeStampChange?()
            }
            draggingId = id
            guard let idx = parent.stamps.firstIndex(where: { $0.id == id }) else { return }
            parent.stamps[idx].position = pos
        }

        func handleDragEnd(id: UUID, startPos: CGPoint, pos: CGPoint, velocity: CGVector) {
            guard let idx = parent.stamps.firstIndex(where: { $0.id == id }) else {
                draggingId = nil
                return
            }
            let speed = hypot(velocity.dx, velocity.dy)
            if speed > 800 {
                // Flip in place — restore to drag-start position so stamp doesn't jump
                parent.stamps[idx].position = startPos
                if abs(velocity.dx) > abs(velocity.dy) {
                    parent.stamps[idx].flipX.toggle()
                } else {
                    parent.stamps[idx].flipY.toggle()
                }
            } else {
                parent.stamps[idx].position = pos
            }
            // Clear draggingId AFTER setting position so syncStamps
            // doesn't snap view.center to the old position for one frame
            draggingId = nil
        }

        func handleTap(id: UUID) {
            if parent.selectedStampId == id && parent.showStampMagicMenu {
                parent.selectedStampId = nil
                parent.showStampMagicMenu = false
            } else {
                parent.selectedStampId = id
                parent.showStampMagicMenu = true
                handleBringToFront(id: id)
            }
        }

        func handleDoubleTap(id: UUID) {
            parent.onBeforeStampChange?()
            parent.stamps.removeAll { $0.id == id }
            if parent.selectedStampId == id {
                parent.selectedStampId = nil
                parent.showStampMagicMenu = false
            }
            parent.onStampDeleted?(id)
        }

        func handleDupe(id: UUID) {
            guard let idx = parent.stamps.firstIndex(where: { $0.id == id }) else { return }
            parent.onBeforeStampChange?()
            let src = parent.stamps[idx]
            var dupe = PlacedStamp(
                emoji: src.emoji,
                position: CGPoint(
                    x: min(src.position.x + src.size * 0.4, parent.canvasSize.width - src.size / 2),
                    y: min(src.position.y + src.size * 0.4, parent.canvasSize.height - src.size / 2)
                ),
                size: src.size,
                rotation: src.rotation,
                opacity: src.opacity,
                flipX: src.flipX,
                flipY: src.flipY,
                flipStep: src.flipStep,
                customImageId: src.customImageId,
                stampText: src.stampText,
                fontName: src.fontName,
                textColor: src.textColor,
                textBgColor: src.textBgColor,
                stampWidth: src.stampWidth,
                stampHeight: src.stampHeight
            )
            dupe.inlineImage = src.inlineImage
            if let onDuped = parent.onStampDuped {
                // Caller handles append + layerOrder update
                onDuped(dupe)
            } else {
                parent.stamps.append(dupe)
            }
            parent.selectedStampId = dupe.id
            parent.showStampMagicMenu = true
        }

        func handleBringToFront(id: UUID) {
            // Z-order is determined by layerOrder in DrawScreen; no reordering needed.
        }

        func handleCanvasTap() {
            parent.selectedStampId = nil
            parent.showStampMagicMenu = false
        }
    }
}

// MARK: - SwiftUI stamp renderer (one per layerOrder .stamp entry)

struct StampRenderView: View {
    let stamp: PlacedStamp

    var body: some View {
        stampContent
            .frame(width: stamp.displayWidth, height: stamp.displayHeight)
            .scaleEffect(x: stamp.flipX ? -1 : 1, y: stamp.flipY ? -1 : 1)
            .rotationEffect(.degrees(stamp.rotation))
            .opacity(stamp.opacity)
            .position(stamp.position)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var stampContent: some View {
        if let img = stamp.inlineImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if let customId = stamp.customImageId,
                  let cs = CustomStampManager.shared.stamps.first(where: { $0.id == customId }),
                  let img = cs.image {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else if stamp.stampText != nil {
            StampTextRenderView(stamp: stamp)
        } else {
            Text(stamp.emoji)
                .font(.system(size: stamp.size * 0.80))
                .frame(width: stamp.size, height: stamp.size)
        }
    }
}

/// UIViewRepresentable label for text stamps — mirrors the UIKit rendering path exactly.
struct StampTextRenderView: UIViewRepresentable {
    let stamp: PlacedStamp

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        let label = UILabel()
        label.tag = 1
        label.numberOfLines = 0
        label.lineBreakMode = .byClipping
        label.adjustsFontSizeToFitWidth = false
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(label)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let text = stamp.stampText,
              let label = container.viewWithTag(1) as? UILabel else { return }
        let s = stamp.size
        let fontSize = stamp.stampWidth > 0 ? s : fitTextFontSize(text: text, stampSize: s, baseFontId: stamp.fontName)
        label.text = text
        label.font = TextStampFont.font(forId: stamp.fontName, style: stamp.fontStyle).withSize(fontSize)
        label.textColor = UIColor(stamp.textColor)
        label.textAlignment = stamp.textAlignment == "left" ? .left : stamp.textAlignment == "right" ? .right : .center
        let bg = UIColor(stamp.textBgColor)
        container.backgroundColor = bg == .clear ? .clear : bg
        container.layer.cornerRadius = bg == .clear ? 0 : 8
        // Shadow applied to label layer; masksToBounds must be false when shadow is visible
        if stamp.shadowEnabled {
            label.layer.shadowColor = UIColor(stamp.shadowColor).cgColor
            label.layer.shadowOpacity = 1.0
            label.layer.shadowRadius = CGFloat(stamp.shadowBlur)
            label.layer.shadowOffset = CGSize(width: stamp.shadowOffsetX, height: stamp.shadowOffsetY)
            container.layer.masksToBounds = false
        } else {
            label.layer.shadowOpacity = 0
            container.layer.masksToBounds = bg != .clear
        }
    }
}
