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
import SwiftUI

// MARK: - Timelapse Exporter

@MainActor
final class DoodleTimelapseExporter: ObservableObject {
    @Published var isExporting = false

    private var cancelled = false

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
        cancelled = false

        Task { [weak self] in
            guard let self else { return }
            let url = await self.buildVideo(
                document: document,
                pointSize: pointSize,
                pixelSize: pixelSize,
                date: date
            )
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
        let totalPoints = document.drawingLayers
            .flatMap { $0.lines }
            .reduce(0) { $0 + $1.points.count }

        let pointsPerFrame = max(3, totalPoints / 300)   // ~300 render steps for drawing
        let fadeSteps = 8

        var states: [TimelapseState] = []
        var completedLayers: [DrawingLayer] = []
        var completedStamps: [PlacedStamp] = []
        var completedOrder: [LayerEntry] = []

        for entry in document.layerOrder {
            switch entry {

            case .drawing(let id):
                guard let layer = document.drawingLayers.first(where: { $0.id == id }) else { continue }
                guard !layer.lines.isEmpty else {
                    completedLayers.append(layer)
                    completedOrder.append(.drawing(id))
                    continue
                }
                var drawnLines: [DrawingLine] = []
                for line in layer.lines {
                    guard !line.points.isEmpty else { drawnLines.append(line); continue }
                    var cursor = 0
                    while cursor < line.points.count {
                        let end = min(cursor + pointsPerFrame, line.points.count)
                        var partial = line
                        partial.points = Array(line.points[0..<end])
                        partial.widths  = Array(line.widths.prefix(end))
                        let partialLayer = DrawingLayer(
                            id: layer.id,
                            lines: drawnLines + [partial],
                            opacity: layer.opacity
                        )
                        states.append(TimelapseState(
                            drawingLayers: completedLayers + [partialLayer],
                            stamps: completedStamps,
                            layerOrder: completedOrder + [.drawing(id)]
                        ))
                        cursor = end
                    }
                    drawnLines.append(line)
                }
                completedLayers.append(layer)
                completedOrder.append(.drawing(id))

            case .stamp(let id):
                guard let stamp = document.placedStamps.first(where: { $0.id == id }) else { continue }
                for step in 1...fadeSteps {
                    var faded = stamp
                    faded.opacity = (Double(step) / Double(fadeSteps)) * stamp.opacity
                    states.append(TimelapseState(
                        drawingLayers: completedLayers,
                        stamps: completedStamps + [faded],
                        layerOrder: completedOrder + [.stamp(id)]
                    ))
                }
                completedStamps.append(stamp)
                completedOrder.append(.stamp(id))
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

        let states = buildStates(document: document)
        guard !states.isEmpty else { return nil }

        // Frame counts
        let contentFrames  = states.count
        let holdFrames     = 60    // 2s hold on finished doodle
        let dissolveFrames = 24    // 0.8s fade in dark overlay + branding
        let brandHoldFrames = 45   // 1.5s branding at full size
        let shrinkFrames   = 36    // 1.2s branding shrinks to footer
        let footerFrames   = 30    // 1s footer hold
        let outroFrames    = dissolveFrames + brandHoldFrames + shrinkFrames + footerFrames
        let totalFrames    = contentFrames + holdFrames + outroFrames

        // Canvas / bg
        let canvasUIColor: UIColor = {
            if let rgba = document.canvasColorRGBA {
                return UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
            }
            let fb: [UIColor] = [.white, .black, UIColor(white: 0.95, alpha: 1)]
            return fb[min(document.canvasColorIndex, fb.count - 1)]
        }()
        let bgImage  = document.backgroundImageData.flatMap { UIImage(data: $0) }
        let bgOffset = CGSize(width: document.backgroundOffsetX, height: document.backgroundOffsetY)

        // AVAssetWriter
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

        let fps: Int32 = 30

        func append(_ buffer: CVPixelBuffer, at frame: Int) async {
            while !writerInput.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }

        // ── Phase 1: Content ─────────────────────────────────────────────────

        var finalDoodleImage: UIImage? = nil
        var holdBuffer: CVPixelBuffer? = nil

        for (i, state) in states.enumerated() {
            if cancelled { writer.cancelWriting(); try? FileManager.default.removeItem(at: tempURL); return nil }

            let image = renderCanvasWithStamps(
                drawingLayers: state.drawingLayers,
                stamps: state.stamps,
                layerOrder: state.layerOrder,
                size: pointSize,
                canvasColor: canvasUIColor,
                backgroundImage: bgImage,
                backgroundOffset: bgOffset,
                bgOpacity: document.bgOpacity,
                bgBlur: document.bgBlur,
                bgBrightness: document.bgBrightness,
                bgSaturation: document.bgSaturation
            )

            if i == contentFrames - 1 { finalDoodleImage = image }

            guard let buf = pixelBuffer(from: image, pixelSize: pixelSize) else { continue }
            if i == contentFrames - 1 { holdBuffer = buf }
            await append(buf, at: i)
            if i % 10 == 0 { await Task.yield() }
        }

        // ── Phase 2: Hold ────────────────────────────────────────────────────

        if let holdBuf = holdBuffer {
            for h in 0..<holdFrames {
                if cancelled { break }
                await append(holdBuf, at: contentFrames + h)
                if h % 10 == 0 { await Task.yield() }
            }
        }

        // ── Phase 3: Outro ───────────────────────────────────────────────────

        guard let baseImage = finalDoodleImage else {
            writerInput.markAsFinished()
            await writer.finishWriting()
            return writer.status == .completed ? tempURL : nil
        }

        // Footer target: centered horizontally, near the bottom
        let footerY = pointSize.height * 0.42    // offset from center to place near bottom

        for o in 0..<outroFrames {
            if cancelled { break }

            let frameIndex = contentFrames + holdFrames + o

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
                  let buf = pixelBuffer(from: img, pixelSize: pixelSize) else { continue }

            await append(buf, at: frameIndex)
            if o % 10 == 0 { await Task.yield() }
        }

        // ── Finalize ─────────────────────────────────────────────────────────

        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return tempURL
    }

    // MARK: - Pixel Buffer

    private func pixelBuffer(from image: UIImage, pixelSize: CGSize) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(pixelSize.width), Int(pixelSize.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        if let cgImage = image.cgImage {
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: pixelSize))
        }
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

private func currentScreenScale() -> CGFloat {
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
        ZStack {
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: 30, height: 30)

            if exporter.isExporting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.5)
                    .tint(.white)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .offset(x: 1)
            }
        }
        .onTapGesture { startExport() }           // onTapGesture so it doesn't fight the tile's gesture
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
