// DoodleVideoExport.swift
// Timelapse video export for Skadoodle.
//
// Video structure:
//   1. Drawing revealed stroke by stroke, stamps fade in — length proportional to content
//   2. 2-second hold on finished doodle
//   3. Outro: dark overlay fades in, branding appears centered (icon · Skadoodle · skadoodle.nyc · date)
//   4. Branding shrinks and slides to a small footer at the bottom, holds there

import AVFoundation
import AVKit
import Combine
import CoreImage
import Metal
import SwiftUI

// MARK: - Timelapse Exporter

@MainActor
final class DoodleTimelapseExporter: ObservableObject {
    @Published var isExporting = false
    @Published var progress: Double = 0      // 0.0 → 1.0 while exporting

    private var cancelled = false

    // Metal-backed CIContext shared across all frames — avoids per-frame GPU context setup
    private static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull()])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    func cancel() { cancelled = true }

    func export(
        document: SkadoodleDocument,
        pointSize: CGSize,      // canvas dimensions in points
        pixelSize: CGSize,      // video resolution (points × screen scale)
        date: Date,             // doodle creation date for the outro card
        completion: @escaping (URL?) -> Void
    ) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        cancelled = false

        Task { [weak self] in
            guard let self else { return }
            let url = await self.buildVideo(
                document: document,
                pointSize: pointSize,
                pixelSize: pixelSize,
                date: date
            )
            self.progress = url != nil ? 1 : 0
            self.isExporting = false
            completion(url)
        }
    }

    // MARK: - State Model

    private struct TimelapseState {
        var drawingLayers: [DrawingLayer]
        var stamps: [PlacedStamp]
        var layerOrder: [LayerEntry]
    }

    // MARK: - State Builder

    private func buildStates(document: SkadoodleDocument) -> [TimelapseState] {
        let totalPoints = document.drawingLayers.flatMap { $0.lines }.reduce(0) { $0 + $1.points.count }
        let pointsPerFrame = max(3, totalPoints / 300)   // ~300 render steps for drawing
        let fadeSteps = 8

        // ── 1. Flatten all strokes and stamps into a sorted timeline ──────────
        // Stroke timestamps: set at commit time in DrawingEngine (new files).
        // Old files: timestamp == epoch → stable sort preserves layer/insertion order.
        struct StrokeEntry { let line: DrawingLine; let layerId: UUID }
        enum Event {
            case stroke(StrokeEntry)
            case stamp(PlacedStamp)
            case chapter(ChapterBreak)
            case reorder(LayerOrderChange)
            var timestamp: Date {
                switch self {
                case .stroke(let s):   return s.line.timestamp
                case .stamp(let p):    return p.createdAt
                case .chapter(let c):  return c.timestamp
                case .reorder(let r):  return r.timestamp
                }
            }
        }

        var events: [Event] = []
        for layer in document.drawingLayers {
            for line in layer.lines { events.append(.stroke(StrokeEntry(line: line, layerId: layer.id))) }
        }
        for stamp in document.placedStamps { events.append(.stamp(stamp)) }
        for cb in document.chapterBreaks   { events.append(.chapter(cb)) }
        for rc in document.layerOrderChanges { events.append(.reorder(rc)) }
        events.sort { $0.timestamp < $1.timestamp }   // stable: equal timestamps keep insertion order

        // ── 2. Z-order: starts as document.layerOrder, updated by reorder events ──
        var zLayerOrder = document.layerOrder

        // Track accumulated lines per layer and stamps that have finished fading in
        var layerLines: [UUID: [DrawingLine]] = [:]
        var doneStamps: [PlacedStamp] = []

        // Build a renderable snapshot from current accumulated state.
        // overrideLines: substitute for layerLines while drawing a partial stroke.
        // fadingStamp:   in-progress stamp (not yet in doneStamps).
        func makeState(
            overrideLines: [UUID: [DrawingLine]]? = nil,
            fadingStamp: PlacedStamp? = nil
        ) -> TimelapseState {
            let ll = overrideLines ?? layerLines
            let layers: [DrawingLayer] = document.drawingLayers.compactMap { tmpl in
                guard let lines = ll[tmpl.id] else { return nil }
                return DrawingLayer(id: tmpl.id, lines: lines, opacity: tmpl.opacity, createdAt: tmpl.createdAt)
            }
            var stamps = doneStamps
            if let fs = fadingStamp { stamps.append(fs) }
            let activeIds   = Set(ll.keys)
            let doneIds     = Set(doneStamps.map { $0.id })
            let fadingId    = fadingStamp?.id
            let order = zLayerOrder.filter { entry in
                switch entry {
                case .drawing(let id): return activeIds.contains(id)
                case .stamp(let id):   return id == fadingId || doneIds.contains(id)
                }
            }
            return TimelapseState(drawingLayers: layers, stamps: stamps, layerOrder: order)
        }

        // ── 3. Process each event into frames ────────────────────────────────
        var states: [TimelapseState] = []

        for event in events {
            switch event {

            case .stroke(let entry):
                let line = entry.line
                let layerId = entry.layerId
                guard !line.points.isEmpty else {
                    layerLines[layerId, default: []].append(line)
                    continue
                }
                // Reveal this stroke point-by-point (chunked for ~300 total frames)
                var cursor = 0
                while cursor < line.points.count {
                    let end = min(cursor + pointsPerFrame, line.points.count)
                    var partial = line
                    partial.points = Array(line.points[0..<end])
                    partial.widths = Array(line.widths.prefix(end))
                    var tempLines = layerLines
                    tempLines[layerId, default: []].append(partial)
                    states.append(makeState(overrideLines: tempLines))
                    cursor = end
                }
                layerLines[layerId, default: []].append(line)

            case .stamp(let stamp):
                // Fade stamp in over fadeSteps frames
                for step in 1...fadeSteps {
                    var faded = stamp
                    faded.opacity = (Double(step) / Double(fadeSteps)) * stamp.opacity
                    states.append(makeState(fadingStamp: faded))
                }
                doneStamps.append(stamp)

            case .chapter(let cb):
                // Hold on current frame for the chapter break duration
                let holdFrameCount = max(1, Int(cb.holdDuration * 30))
                let holdState = makeState()
                for _ in 0..<holdFrameCount { states.append(holdState) }

            case .reorder(let rc):
                // User reordered layers — update z-order and emit one frame showing the new arrangement
                zLayerOrder = rc.layerOrder
                states.append(makeState())
            }
        }

        return states
    }

    // MARK: - Smoothstep (ease in-out)

    private func smoothstep(_ t: Double) -> Double {
        let c = max(0, min(1, t))
        return c * c * (3 - 2 * c)
    }

    // MARK: - Video Builder

    private func buildVideo(
        document: SkadoodleDocument,
        pointSize: CGSize,
        pixelSize: CGSize,
        date: Date
    ) async -> URL? {

        // Yield immediately so SwiftUI can render isExporting=true before we start blocking work
        await Task.yield()

        // ── Build sorted event list (same logic as buildStates) ──────────────
        let totalPoints = document.drawingLayers.flatMap { $0.lines }.reduce(0) { $0 + $1.points.count }
        let pointsPerFrame = max(3, totalPoints / 300)   // ~300 render steps for drawing
        let fadeSteps = 8

        struct StrokeEntry { let line: DrawingLine; let layerId: UUID }
        enum Event {
            case stroke(StrokeEntry)
            case stamp(PlacedStamp)
            case chapter(ChapterBreak)
            case reorder(LayerOrderChange)
            var timestamp: Date {
                switch self {
                case .stroke(let s):   return s.line.timestamp
                case .stamp(let p):    return p.createdAt
                case .chapter(let c):  return c.timestamp
                case .reorder(let r):  return r.timestamp
                }
            }
        }

        var events: [Event] = []
        for layer in document.drawingLayers {
            for line in layer.lines { events.append(.stroke(StrokeEntry(line: line, layerId: layer.id))) }
        }
        for stamp in document.placedStamps { events.append(.stamp(stamp)) }
        for cb in document.chapterBreaks   { events.append(.chapter(cb)) }
        for rc in document.layerOrderChanges { events.append(.reorder(rc)) }
        events.sort { $0.timestamp < $1.timestamp }

        // ── Estimate content frame count for progress tracking ───────────────
        // (exact count may differ slightly; only used for progress denominator)
        var estimatedContentFrames = 0
        for event in events {
            switch event {
            case .stroke(let entry):
                guard !entry.line.points.isEmpty else { continue }
                estimatedContentFrames += max(1, Int(ceil(Double(entry.line.points.count) / Double(pointsPerFrame))))
            case .stamp:
                estimatedContentFrames += fadeSteps
            case .chapter(let cb):
                estimatedContentFrames += max(1, Int(cb.holdDuration * 30))
            case .reorder:
                estimatedContentFrames += 1   // one frame to show the new arrangement
            }
        }
        guard estimatedContentFrames > 0 else { return nil }

        // Frame counts
        let holdFrames      = 60    // 2s hold on finished doodle
        let dissolveFrames  = 24    // 0.8s fade in dark overlay + branding
        let brandHoldFrames = 45    // 1.5s branding at full size
        let shrinkFrames    = 36    // 1.2s branding shrinks to footer
        let footerFrames    = 30    // 1s footer hold
        let outroFrames     = dissolveFrames + brandHoldFrames + shrinkFrames + footerFrames
        let totalFrames     = estimatedContentFrames + holdFrames + outroFrames

        // ── Canvas / bg ──────────────────────────────────────────────────────
        let canvasUIColor: UIColor = {
            if let rgba = document.canvasColorRGBA {
                return UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
            }
            let fb: [UIColor] = [.white, .black, UIColor(white: 0.95, alpha: 1)]
            return fb[min(document.canvasColorIndex, fb.count - 1)]
        }()
        let bgImage  = document.backgroundImageData.flatMap { UIImage(data: $0) }
        let bgOffset = CGSize(width: document.backgroundOffsetX, height: document.backgroundOffsetY)

        // ── AVAssetWriter ────────────────────────────────────────────────────
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skadoodle_timelapse_\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: tempURL, fileType: .mp4) else { return nil }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000]
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(pixelSize.width),
            kCVPixelBufferHeightKey as String: Int(pixelSize.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: bufferAttrs
        )
        guard writer.canAdd(writerInput) else { return nil }
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let pool = adaptor.pixelBufferPool   // reuse pre-allocated buffers; nil-safe fallback in pixelBuffer()
        let fps: Int32 = 30

        func append(_ buffer: CVPixelBuffer, at frame: Int) async {
            while !writerInput.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }

        // ── Image format for opaque compositing ──────────────────────────────
        let imgFormat = UIGraphicsImageRendererFormat.preferred()
        imgFormat.scale = currentScreenScale()
        imgFormat.opaque = true

        // ── Initialize runningComposite: blank canvas + background ───────────
        var runningComposite = UIGraphicsImageRenderer(size: pointSize, format: imgFormat).image { ctx in
            canvasUIColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: pointSize))
            if let bgImg = bgImage {
                let effectiveImg = applyBgEffectsForExport(
                    to: bgImg,
                    bgOpacity: document.bgOpacity,
                    bgBlur: document.bgBlur,
                    bgBrightness: document.bgBrightness,
                    bgSaturation: document.bgSaturation
                )
                effectiveImg.draw(in: CGRect(origin: .zero, size: pointSize))
            }
        }

        // ── Z-order: starts as document.layerOrder, updated by reorder events ──
        var zLayerOrder = document.layerOrder

        // Accumulated drawing state
        var layerLines: [UUID: [DrawingLine]] = [:]
        var doneStamps: [PlacedStamp] = []

        // bgBaseImage: the canvas + processed background with no drawing or stamps.
        // runningComposite at this point is exactly that (initialized above).
        // Used as the "paint" for eraser delta frames — reveals background in stroked area.
        let bgBaseImage = runningComposite

        // Transparent-background format for eraser deltas
        let eraserDeltaFormat = UIGraphicsImageRendererFormat.preferred()
        eraserDeltaFormat.scale = currentScreenScale()
        eraserDeltaFormat.opaque = false

        // Full re-render of accumulated state in current zLayerOrder.
        // overrideLines: substitute layerLines for partial-stroke animation in the fallback path.
        // Called for reorder events and for strokes on non-topmost layers.
        func rebuildComposite(overrideLines: [UUID: [DrawingLine]]? = nil) -> UIImage {
            let ll = overrideLines ?? layerLines
            let layers: [DrawingLayer] = document.drawingLayers.compactMap { tmpl in
                guard let lines = ll[tmpl.id] else { return nil }
                return DrawingLayer(id: tmpl.id, lines: lines, opacity: tmpl.opacity, createdAt: tmpl.createdAt)
            }
            let activeIds = Set(ll.keys)
            let doneIds   = Set(doneStamps.map { $0.id })
            let order = zLayerOrder.filter { entry in
                switch entry {
                case .drawing(let id): return activeIds.contains(id)
                case .stamp(let id):   return doneIds.contains(id)
                }
            }
            return renderCanvasWithStamps(
                drawingLayers: layers,
                stamps: doneStamps,
                layerOrder: order,
                size: pointSize,
                canvasColor: canvasUIColor,
                backgroundImage: bgImage,
                backgroundOffset: bgOffset,
                bgOpacity: document.bgOpacity,
                bgBlur: document.bgBlur,
                bgBrightness: document.bgBrightness,
                bgSaturation: document.bgSaturation
            )
        }

        // Returns true if there is any already-drawn content (layer or stamp) above layerId
        // in zLayerOrder. When true, incremental compositing would place the stroke on top
        // of that content — wrong. Fall back to rebuildComposite for correct z-order.
        func hasContentAbove(layerId: UUID) -> Bool {
            guard let layerIdx = zLayerOrder.firstIndex(where: { $0.id == layerId }) else { return false }
            let doneIds = Set(doneStamps.map { $0.id })
            for entry in zLayerOrder[(layerIdx + 1)...] {
                switch entry {
                case .drawing(let id): if layerLines[id] != nil { return true }
                case .stamp(let id):   if doneIds.contains(id)  { return true }
                }
            }
            return false
        }

        // ── Phase 1: Content ─────────────────────────────────────────────────

        var frameIndex = 0
        var holdBuffer: CVPixelBuffer? = nil

        for event in events {
            if cancelled { writer.cancelWriting(); try? FileManager.default.removeItem(at: tempURL); return nil }

            switch event {

            case .stroke(let entry):
                let line = entry.line
                let layerId = entry.layerId

                guard !line.points.isEmpty else {
                    // Zero-length stroke: accumulate without emitting a frame
                    layerLines[layerId, default: []].append(line)
                    continue
                }

                let needsFull = hasContentAbove(layerId: layerId)

                if needsFull {
                    // Optimized z-order–correct path — O(all_layers) setup, O(1) per chunk:
                    //
                    // 1. Pre-render belowComp (opaque) and aboveComp (transparent) once per stroke.
                    // 2. Pre-render prevLayerImg (all accumulated strokes for this layer) once per stroke.
                    // 3. Per chunk:
                    //    • Regular stroke: composite belowComp + prevLayerImg + partialDelta + aboveComp
                    //    • Eraser: punch the partial eraser path as a .destinationOut mask into
                    //      prevLayerImg → holeyImg; composite belowComp + holeyImg + aboveComp.
                    //      Holes in holeyImg are transparent → belowComp shows through (correct reveal).

                    guard let layerIdxInOrder = zLayerOrder.firstIndex(where: { $0.id == layerId }),
                          let layerTmpl = document.drawingLayers.first(where: { $0.id == layerId }) else {
                        layerLines[layerId, default: []].append(line); continue
                    }

                    let belowEntries = Array(zLayerOrder[0..<layerIdxInOrder])
                    let aboveEntries = Array(zLayerOrder[(layerIdxInOrder + 1)...])
                    let doneIds = Set(doneStamps.map { $0.id })

                    func splitLayers(_ entries: [LayerEntry]) -> [DrawingLayer] {
                        entries.compactMap { e -> DrawingLayer? in
                            guard case .drawing(let id) = e,
                                  let lines = layerLines[id],
                                  let tmpl  = document.drawingLayers.first(where: { $0.id == id })
                            else { return nil }
                            return DrawingLayer(id: id, lines: lines, opacity: tmpl.opacity, createdAt: tmpl.createdAt)
                        }
                    }
                    func splitStamps(_ entries: [LayerEntry]) -> [PlacedStamp] {
                        doneStamps.filter { s in entries.contains(where: { $0.id == s.id }) }
                    }
                    func splitOrder(_ entries: [LayerEntry]) -> [LayerEntry] {
                        entries.filter { e in
                            switch e {
                            case .drawing(let id): return layerLines[id] != nil
                            case .stamp(let id):   return doneIds.contains(id)
                            }
                        }
                    }

                    // Below: opaque — canvas + bg + all content below this layer
                    let belowComp = renderCanvasWithStamps(
                        drawingLayers: splitLayers(belowEntries), stamps: splitStamps(belowEntries),
                        layerOrder: splitOrder(belowEntries), size: pointSize,
                        canvasColor: canvasUIColor, backgroundImage: bgImage,
                        backgroundOffset: bgOffset,
                        bgOpacity: document.bgOpacity, bgBlur: document.bgBlur,
                        bgBrightness: document.bgBrightness, bgSaturation: document.bgSaturation
                    )
                    // Above: transparent — all content above this layer
                    let aboveComp = renderCanvasWithStamps(
                        drawingLayers: splitLayers(aboveEntries), stamps: splitStamps(aboveEntries),
                        layerOrder: splitOrder(aboveEntries), size: pointSize,
                        canvasColor: .clear, backgroundImage: nil, backgroundOffset: .zero,
                        bgOpacity: 1.0, bgBlur: 0.0, bgBrightness: 0.0, bgSaturation: 1.0
                    )

                    // prevLayerImg: all previously accumulated strokes in this layer, transparent bg.
                    // Pre-rendered once — per chunk only adds the small delta on top.
                    let prevLines = layerLines[layerId, default: []]
                    let prevLayerImg: UIImage = {
                        guard !prevLines.isEmpty else {
                            return UIGraphicsImageRenderer(size: pointSize, format: eraserDeltaFormat).image { _ in }
                        }
                        let prevLayer = DrawingLayer(id: layerId, lines: prevLines,
                                                     opacity: layerTmpl.opacity, createdAt: layerTmpl.createdAt)
                        return renderCanvasWithStamps(
                            drawingLayers: [prevLayer], stamps: [], layerOrder: [.drawing(layerId)],
                            size: pointSize, canvasColor: .clear, backgroundImage: nil,
                            backgroundOffset: .zero,
                            bgOpacity: 1.0, bgBlur: 0.0, bgBrightness: 0.0, bgSaturation: 1.0
                        )
                    }()

                    let eraserWidth = line.lineWidth
                    var cursor = 0
                    while cursor < line.points.count {
                        let end = min(cursor + pointsPerFrame, line.points.count)

                        let composited: UIImage
                        if line.isEraser {
                            // Build an opaque mask for the partial eraser path (points[0..<end]).
                            // .destinationOut will punch transparent holes into prevLayerImg at the
                            // eraser shape — holes then show belowComp when composited below.
                            let partialPts = Array(line.points[0..<end])
                            let eraserMask = UIGraphicsImageRenderer(size: pointSize, format: eraserDeltaFormat).image { ctx in
                                let cgCtx = ctx.cgContext
                                UIColor.black.setFill()
                                if partialPts.count == 1 {
                                    let pt = partialPts[0]; let r = eraserWidth / 2
                                    cgCtx.addEllipse(in: CGRect(x: pt.x - r, y: pt.y - r,
                                                                 width: eraserWidth, height: eraserWidth))
                                    cgCtx.fillPath()
                                } else {
                                    cgCtx.move(to: partialPts[0])
                                    for pt in partialPts.dropFirst() { cgCtx.addLine(to: pt) }
                                    cgCtx.setLineWidth(eraserWidth)
                                    cgCtx.setLineCap(.round)
                                    cgCtx.setLineJoin(.round)
                                    cgCtx.replacePathWithStrokedPath()
                                    cgCtx.fillPath()
                                }
                            }
                            let holeyImg = UIGraphicsImageRenderer(size: pointSize, format: eraserDeltaFormat).image { _ in
                                prevLayerImg.draw(at: .zero)
                                eraserMask.draw(at: .zero, blendMode: .destinationOut, alpha: 1.0)
                            }
                            composited = UIGraphicsImageRenderer(size: pointSize, format: imgFormat).image { _ in
                                belowComp.draw(at: .zero)
                                holeyImg.draw(at: .zero)
                                aboveComp.draw(at: .zero)
                            }
                        } else {
                            // Render only the growing partial stroke on transparent bg — O(1).
                            var partial = line
                            partial.points = Array(line.points[0..<end])
                            partial.widths = Array(line.widths.prefix(end))
                            let partialLayer = DrawingLayer(id: layerId, lines: [partial],
                                                            opacity: layerTmpl.opacity, createdAt: layerTmpl.createdAt)
                            let partialDelta = renderCanvasWithStamps(
                                drawingLayers: [partialLayer], stamps: [], layerOrder: [.drawing(layerId)],
                                size: pointSize, canvasColor: .clear, backgroundImage: nil,
                                backgroundOffset: .zero,
                                bgOpacity: 1.0, bgBlur: 0.0, bgBrightness: 0.0, bgSaturation: 1.0
                            )
                            composited = UIGraphicsImageRenderer(size: pointSize, format: imgFormat).image { _ in
                                belowComp.draw(at: .zero)
                                prevLayerImg.draw(at: .zero)
                                partialDelta.draw(at: .zero)
                                aboveComp.draw(at: .zero)
                            }
                        }

                        runningComposite = composited
                        guard let buf = pixelBuffer(from: composited, pixelSize: pixelSize, pool: pool) else {
                            cursor = end; continue
                        }
                        holdBuffer = buf
                        await append(buf, at: frameIndex)
                        frameIndex += 1
                        cursor = end

                        if frameIndex % 50 == 0 {
                            progress = Double(frameIndex) / Double(totalFrames)
                            await Task.yield()
                        }
                    }
                    layerLines[layerId, default: []].append(line)

                } else if line.isEraser {
                    // Fast incremental eraser delta: O(1) per chunk.
                    // Clips stroke path, paints bgBaseImage pixels inside → composites onto runningComposite.
                    let eraserWidth = line.lineWidth
                    var cursor = 0
                    while cursor < line.points.count {
                        let end = min(cursor + pointsPerFrame, line.points.count)
                        let segStart = cursor == 0 ? 0 : cursor - 1
                        let segPoints = Array(line.points[segStart..<end])

                        let eraserDelta = UIGraphicsImageRenderer(size: pointSize, format: eraserDeltaFormat).image { ctx in
                            guard !segPoints.isEmpty else { return }
                            let cgCtx = ctx.cgContext
                            cgCtx.saveGState()
                            if segPoints.count == 1 {
                                let pt = segPoints[0]
                                let r = eraserWidth / 2
                                cgCtx.addEllipse(in: CGRect(x: pt.x - r, y: pt.y - r,
                                                             width: eraserWidth, height: eraserWidth))
                                cgCtx.clip()
                            } else {
                                cgCtx.move(to: segPoints[0])
                                for pt in segPoints.dropFirst() { cgCtx.addLine(to: pt) }
                                cgCtx.setLineWidth(eraserWidth)
                                cgCtx.setLineCap(.round)
                                cgCtx.setLineJoin(.round)
                                cgCtx.replacePathWithStrokedPath()
                                cgCtx.clip()
                            }
                            bgBaseImage.draw(at: .zero)
                            cgCtx.restoreGState()
                        }
                        let composited = UIGraphicsImageRenderer(size: pointSize, format: imgFormat).image { _ in
                            runningComposite.draw(at: .zero)
                            eraserDelta.draw(at: .zero)
                        }
                        runningComposite = composited
                        guard let buf = pixelBuffer(from: composited, pixelSize: pixelSize, pool: pool) else {
                            cursor = end; continue
                        }
                        holdBuffer = buf
                        await append(buf, at: frameIndex)
                        frameIndex += 1
                        cursor = end

                        if frameIndex % 50 == 0 {
                            progress = Double(frameIndex) / Double(totalFrames)
                            await Task.yield()
                        }
                    }
                    layerLines[layerId, default: []].append(line)

                } else {
                    // Fast incremental stroke delta: render only this partial stroke, composite on top.
                    let layerOpacity   = document.drawingLayers.first(where: { $0.id == layerId })?.opacity   ?? 1.0
                    let layerCreatedAt = document.drawingLayers.first(where: { $0.id == layerId })?.createdAt ?? Date()
                    var cursor = 0
                    while cursor < line.points.count {
                        let end = min(cursor + pointsPerFrame, line.points.count)
                        var partial = line
                        partial.points = Array(line.points[0..<end])
                        partial.widths = Array(line.widths.prefix(end))

                        let deltaLayer = DrawingLayer(id: layerId, lines: [partial],
                                                      opacity: layerOpacity, createdAt: layerCreatedAt)
                        let deltaImg = renderCanvasWithStamps(
                            drawingLayers: [deltaLayer], stamps: [],
                            layerOrder: [.drawing(layerId)],
                            size: pointSize, canvasColor: UIColor.clear,
                            backgroundImage: nil, backgroundOffset: .zero,
                            bgOpacity: 1.0, bgBlur: 0.0, bgBrightness: 0.0, bgSaturation: 1.0
                        )
                        let composited = UIGraphicsImageRenderer(size: pointSize, format: imgFormat).image { _ in
                            runningComposite.draw(at: .zero)
                            deltaImg.draw(at: .zero)
                        }
                        runningComposite = composited
                        guard let buf = pixelBuffer(from: composited, pixelSize: pixelSize, pool: pool) else {
                            cursor = end; continue
                        }
                        holdBuffer = buf
                        await append(buf, at: frameIndex)
                        frameIndex += 1
                        cursor = end

                        if frameIndex % 50 == 0 {
                            progress = Double(frameIndex) / Double(totalFrames)
                            await Task.yield()
                        }
                    }
                    layerLines[layerId, default: []].append(line)
                }

            case .stamp(let stamp):
                // Pre-render stamp at its authored opacity on a transparent background — O(1)
                let stampDelta = renderCanvasWithStamps(
                    drawingLayers: [],
                    stamps: [stamp],
                    layerOrder: [.stamp(stamp.id)],
                    size: pointSize,
                    canvasColor: UIColor.clear,
                    backgroundImage: nil,
                    backgroundOffset: .zero,
                    bgOpacity: 1.0, bgBlur: 0.0, bgBrightness: 0.0, bgSaturation: 1.0
                )

                // Fade in over fadeSteps frames by compositing at increasing alpha
                for step in 1...fadeSteps {
                    if cancelled { break }
                    let stepAlpha = CGFloat(step) / CGFloat(fadeSteps)
                    let composited = UIGraphicsImageRenderer(size: pointSize, format: imgFormat).image { _ in
                        runningComposite.draw(at: .zero)
                        stampDelta.draw(at: .zero, blendMode: .normal, alpha: stepAlpha)
                    }
                    guard let buf = pixelBuffer(from: composited, pixelSize: pixelSize, pool: pool) else { continue }
                    holdBuffer = buf
                    await append(buf, at: frameIndex)
                    frameIndex += 1
                }

                // Bake stamp into runningComposite at full authored opacity
                runningComposite = UIGraphicsImageRenderer(size: pointSize, format: imgFormat).image { _ in
                    runningComposite.draw(at: .zero)
                    stampDelta.draw(at: .zero, blendMode: .normal, alpha: 1.0)
                }
                doneStamps.append(stamp)

            case .chapter(let cb):
                // Hold on current composite for the chapter break duration — reuse same pixel buffer
                let holdFrameCount = max(1, Int(cb.holdDuration * 30))
                guard let buf = pixelBuffer(from: runningComposite, pixelSize: pixelSize, pool: pool) else { continue }
                holdBuffer = buf
                for _ in 0..<holdFrameCount {
                    if cancelled { break }
                    await append(buf, at: frameIndex)
                    frameIndex += 1
                }

            case .reorder(let rc):
                // User reordered layers — update z-order and rebuild the composite so all
                // subsequent frames render content in the new arrangement.
                zLayerOrder = rc.layerOrder
                runningComposite = rebuildComposite()
                guard let buf = pixelBuffer(from: runningComposite, pixelSize: pixelSize, pool: pool) else { continue }
                holdBuffer = buf
                await append(buf, at: frameIndex)
                frameIndex += 1
            }

            // Yield for stamps/chapter/reorder events (strokes yield inside their own loop above)
            if frameIndex % 50 == 0 {
                progress = Double(frameIndex) / Double(totalFrames)
                await Task.yield()
            }
        }

        let contentFrames = frameIndex

        guard contentFrames > 0 else {
            writerInput.markAsFinished()
            await writer.finishWriting()
            return nil
        }

        // ── Phase 2: Hold ────────────────────────────────────────────────────

        if let holdBuf = holdBuffer {
            for h in 0..<holdFrames {
                if cancelled { break }
                await append(holdBuf, at: frameIndex + h)
                if h % 60 == 0 {
                    progress = Double(frameIndex + h) / Double(totalFrames)
                    await Task.yield()
                }
            }
        }
        frameIndex += holdFrames

        // ── Phase 3: Outro ───────────────────────────────────────────────────

        // runningComposite IS the final doodle — use it directly as the outro base image
        let baseImage = runningComposite

        // Footer target: centered horizontally, near the bottom
        let footerY = pointSize.height * 0.42    // offset from center to place near bottom

        for o in 0..<outroFrames {
            if cancelled { break }

            let absFrame = frameIndex + o

            let (darkAlpha, cardScale, cardY): (Double, CGFloat, CGFloat) = {
                if o < dissolveFrames {
                    // Fade in dark overlay and branding
                    let t = smoothstep(Double(o) / Double(dissolveFrames))
                    return (t, 1.0, 0)
                } else if o < dissolveFrames + brandHoldFrames {
                    // Full-size branding, centered
                    return (1.0, 1.0, 0)
                } else if o < dissolveFrames + brandHoldFrames + shrinkFrames {
                    // Shrink + slide to footer
                    let t = smoothstep(Double(o - dissolveFrames - brandHoldFrames) / Double(shrinkFrames))
                    let scale = CGFloat(1.0 - 0.72 * t)        // 1.0 → 0.28
                    let yOff  = CGFloat(t) * footerY
                    return (1.0, scale, yOff)
                } else {
                    // Footer hold: zoom up slightly after landing (pop effect)
                    let zoomFrames = 15
                    let localF = o - (dissolveFrames + brandHoldFrames + shrinkFrames)
                    if localF < zoomFrames {
                        let t = smoothstep(Double(localF) / Double(zoomFrames))
                        let scale = CGFloat(0.28 + 0.16 * t)    // 0.28 → 0.44
                        return (1.0, scale, footerY)
                    } else {
                        return (1.0, 0.44, footerY)
                    }
                }
            }()

            let view = OutroFrameView(
                baseImage: baseImage,
                darkAlpha: darkAlpha,
                cardScale: cardScale,
                cardYOffset: cardY,
                date: date,
                size: pointSize
            )
            .frame(width: pointSize.width, height: pointSize.height)
            .clipped()

            let renderer = ImageRenderer(content: view)
            renderer.scale = currentScreenScale()
            renderer.proposedSize = ProposedViewSize(width: pointSize.width, height: pointSize.height)

            guard let img = renderer.uiImage,
                  let buf = pixelBuffer(from: img, pixelSize: pixelSize, pool: pool) else { continue }

            await append(buf, at: absFrame)
            if o % 100 == 0 {
                progress = Double(absFrame) / Double(totalFrames)
                await Task.yield()
            }
        }

        // ── Finalize ─────────────────────────────────────────────────────────

        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return tempURL
    }

    // MARK: - Pixel Buffer

    private func pixelBuffer(from image: UIImage, pixelSize: CGSize, pool: CVPixelBufferPool? = nil) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { return nil }
        } else {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            guard CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(pixelSize.width), Int(pixelSize.height),
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &buffer
            ) == kCVReturnSuccess, let buffer else { return nil }
        }

        guard let buffer else { return nil }
        guard let cgImage = image.cgImage else { return nil }

        let ci = CIImage(cgImage: cgImage)
        Self.ciContext.render(ci, to: buffer, bounds: CGRect(origin: .zero, size: pixelSize),
                              colorSpace: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB())
        return buffer
    }
}

// MARK: - Outro Frame View

private struct OutroFrameView: View {
    let baseImage: UIImage
    let darkAlpha: Double       // 0 = doodle only, 1 = full dark overlay
    let cardScale: CGFloat      // 1 = full size, ~0.28 = small footer
    let cardYOffset: CGFloat    // 0 = centered, positive = toward bottom
    let date: Date
    let size: CGSize

    var body: some View {
        ZStack {
            // Final doodle as background
            Image(uiImage: baseImage)
                .resizable()
                .frame(width: size.width, height: size.height)

            // Dark overlay fades in
            Color.black.opacity(darkAlpha * 0.65)
                .frame(width: size.width, height: size.height)

            // Branding card
            VStack(spacing: 10) {
                appIconView
                Text("Skadoodle")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("skadoodle.nyc")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
                Text(formattedDate)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
            }
            .opacity(darkAlpha)
            .scaleEffect(cardScale)
            .offset(y: cardYOffset)
        }
    }

    @ViewBuilder
    private var appIconView: some View {
        if let icon = appIcon() {
            Image(uiImage: icon)
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
    }

    private func appIcon() -> UIImage? {
        // Try common asset names first
        if let img = UIImage(named: "AppIcon") { return img }
        // Fall back to reading from bundle info
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        return UIImage(named: last)
    }

    private var formattedDate: String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }
}

// MARK: - Screen helpers (UIScreen.main deprecated in iOS 16)

func currentScreenScale() -> CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first?.screen.scale ?? 2.0
}

private func currentScreenBounds() -> CGRect {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first?.screen.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
}

// MARK: - Shared export params helper

private func exportParams(for entry: SnoodleEntry) -> (document: SkadoodleDocument, pointSize: CGSize, pixelSize: CGSize)? {
    guard entry.hasSkadoodleFile,
          let data = try? Data(contentsOf: entry.skadoodleURL),
          let document = try? JSONDecoder().decode(SkadoodleDocument.self, from: data)
    else { return nil }

    let scale = currentScreenScale()
    let screenBounds = currentScreenBounds()
    let pointSize: CGSize = {
        if let img = UIImage(data: entry.imageData) {
            return CGSize(width: img.size.width / scale, height: img.size.height / scale)
        }
        return screenBounds.size
    }()
    let pixelSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    return (document, pointSize, pixelSize)
}

// MARK: - Timelapse Button (detail view — exports to share sheet)

/// Drop-in button for SnoodleDetailView's action bar.
/// Disabled (dimmed) for pre-v2.2 doodles that have no .skadoodle file.
struct TimelapseButton: View {
    let entry: SnoodleEntry
    @StateObject private var exporter = DoodleTimelapseExporter()

    var body: some View {
        if exporter.isExporting {
            Button(action: { exporter.cancel() }) {
                ZStack {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(.white.opacity(0.6))
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                        .offset(x: 9, y: -9)
                }
                .frame(width: 28, height: 28)
            }
        } else {
            Button(action: startExport) {
                Image(systemName: "film")
                    .font(.system(size: 22))
                    .foregroundColor(entry.hasSkadoodleFile ? .white.opacity(0.8) : .white.opacity(0.2))
            }
            .disabled(!entry.hasSkadoodleFile)
        }
    }

    private func startExport() {
        guard let p = exportParams(for: entry) else { return }
        exporter.export(document: p.document, pointSize: p.pointSize, pixelSize: p.pixelSize, date: entry.timestamp) { url in
            guard let url else { return }
            presentVideoShareSheet(url: url)
        }
    }
}

// MARK: - Tile Play Badge (gallery grid — exports then plays inline)

/// Small play badge for SnoodleTile bottom-right corner.
/// Only rendered when entry.hasSkadoodleFile. Tap → generate → full-screen player.
struct TilePlayBadge: View {
    let entry: SnoodleEntry
    @StateObject private var exporter = DoodleTimelapseExporter()
    @State private var exportedURL: URL? = nil
    @State private var showPlayer = false

    var body: some View {
        Group {
            if exporter.isExporting {
                // Full-width progress bar along the bottom edge of the tile
                ProgressView(value: exporter.progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(height: 3)
                    .background(Color.black.opacity(0.25))
                    .clipShape(Capsule())
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .animation(.linear(duration: 0.1), value: exporter.progress)
            } else {
                // Play circle pinned to trailing edge
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.55))
                            .frame(width: 30, height: 30)
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .offset(x: 1)
                    }
                    .padding(6)
                }
                .onTapGesture { startExport() }
            }
        }
        .fullScreenCover(isPresented: $showPlayer, onDismiss: cleanup) {
            if let url = exportedURL {
                VideoPlayerView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    private func startExport() {
        guard !exporter.isExporting, let p = exportParams(for: entry) else { return }
        exporter.export(document: p.document, pointSize: p.pointSize, pixelSize: p.pixelSize, date: entry.timestamp) { url in
            guard let url else { return }
            exportedURL = url
            showPlayer = true
        }
    }

    private func cleanup() {
        if let url = exportedURL {
            try? FileManager.default.removeItem(at: url)
            exportedURL = nil
        }
    }
}

// MARK: - Video Player (full-screen AVPlayerViewController)

struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.showsPlaybackControls = true
        vc.player?.play()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - Share sheet

private func presentVideoShareSheet(url: URL) {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let root = windowScene.windows.first?.rootViewController else { return }
    var top = root
    while let presented = top.presentedViewController { top = presented }

    let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    av.completionWithItemsHandler = { _, _, _, _ in
        try? FileManager.default.removeItem(at: url)
    }
    if let popover = av.popoverPresentationController {
        popover.sourceView = top.view
        popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
    top.present(av, animated: true)
}
