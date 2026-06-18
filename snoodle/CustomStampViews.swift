//
//  CustomStampViews.swift
//  snoodle
//

import SwiftUI
import PhotosUI
import UIKit

// MARK: - Object Segmentation Sheet

struct ObjectSegmentationSheet: View {
    let images: [UIImage]
    let preProcessedObjects: [SegmentedObject]?   // non-nil = skip Vision processing
    let onSelect: ([UIImage]) -> Void
    @StateObject private var model = ObjectSegmentationModel()
    @Environment(\.dismiss) var dismiss
    @State private var selectedIds: Set<UUID> = []

    /// Convenience init for raw images (StampToolButton photo flow).
    init(images: [UIImage], onSelect: @escaping ([UIImage]) -> Void) {
        self.images = images
        self.preProcessedObjects = nil
        self.onSelect = onSelect
    }

    /// Init for already-processed objects (DoodleStampCreatorView 2+ object flow).
    init(preProcessedObjects: [SegmentedObject], onSelect: @escaping ([UIImage]) -> Void) {
        self.images = []
        self.preProcessedObjects = preProcessedObjects
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationView {
            Group {
                if model.isProcessing {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(model.progressText)
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                } else if let error = model.error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .padding()
                        Button("Try Another Photo") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 0) {
                        Text("Tap objects to select, then tap Add")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 12)

                        let columns = [GridItem(.adaptive(minimum: 120), spacing: 16)]
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(model.objects) { obj in
                                    let isSelected = selectedIds.contains(obj.id)
                                    Button {
                                        if isSelected {
                                            selectedIds.remove(obj.id)
                                        } else {
                                            selectedIds.insert(obj.id)
                                        }
                                    } label: {
                                        ZStack(alignment: .topTrailing) {
                                            ZStack {
                                                CheckerboardView()
                                                    .frame(width: 120, height: 120)
                                                    .cornerRadius(12)
                                                Image(uiImage: obj.thumbnail)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 110, height: 110)
                                            }
                                            .cornerRadius(12)
                                            .overlay(RoundedRectangle(cornerRadius: 12)
                                                .stroke(isSelected ? Color.purple : Color.gray.opacity(0.3),
                                                        lineWidth: isSelected ? 3 : 1))
                                            .shadow(color: .black.opacity(0.1), radius: 4)
                                            .opacity(isSelected ? 1.0 : 0.85)

                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 24))
                                                    .foregroundColor(.purple)
                                                    .background(Color.white.clipShape(Circle()))
                                                    .offset(x: 6, y: -6)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(16)
                        }

                        if !selectedIds.isEmpty {
                            Button {
                                let selected = model.objects
                                    .filter { selectedIds.contains($0.id) }
                                    .map { $0.image }
                                onSelect(selected)
                            } label: {
                                Text("Add \(selectedIds.count) Stamp\(selectedIds.count == 1 ? "" : "s")")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.purple)
                                    .cornerRadius(14)
                                    .padding(.horizontal, 16)
                            }
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: selectedIds.isEmpty)
                }
            }
            .navigationTitle("Choose Objects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !model.objects.isEmpty {
                        Button(selectedIds.count == model.objects.count ? "Deselect All" : "Select All") {
                            if selectedIds.count == model.objects.count {
                                selectedIds.removeAll()
                            } else {
                                selectedIds = Set(model.objects.map { $0.id })
                            }
                        }
                    }
                }
            }
            .task {
                if let pre = preProcessedObjects {
                    // Already processed — load directly, no Vision work needed
                    model.load(preProcessed: pre)
                } else {
                    await model.processAll(images: images)
                    // Single object from photo flow — bypass picker
                    if model.objects.count == 1 {
                        onSelect([model.objects[0].image])
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Checkerboard (shows transparency)

struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let tileSize: CGFloat = 8
            var isLight = true
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                isLight = Int(y / tileSize) % 2 == 0
                while x < size.width {
                    let color = isLight ? Color.white : Color(white: 0.85)
                    context.fill(Path(CGRect(x: x, y: y, width: tileSize, height: tileSize)), with: .color(color))
                    isLight.toggle()
                    x += tileSize
                }
                y += tileSize
            }
        }
    }
}

// MARK: - Camera View

struct CameraView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            print("📷 CameraView: didFinishPicking — image=\(image != nil ? "YES" : "NIL")")
            // Dismiss the picker FIRST, then fire onCapture in the completion.
            // Calling onCapture immediately while the picker is still on screen
            // causes the segmentation sheet to open into a dead view context → white screen.
            picker.dismiss(animated: true) {
                print("📷 CameraView: picker dismissed, firing onCapture")
                self.onCapture(image)
            }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            print("📷 CameraView: cancelled")
            picker.dismiss(animated: true) {
                self.onCapture(nil)
            }
        }
    }
}

// MARK: - Doodle Stamp Creator

struct DoodleStampCreatorView: View {
    let onDone: (Bool) -> Void   // true = stamps were added, false = cancelled

    // Drawing state
    @State private var lines: [DrawingLine] = []
    @AppStorage("doodleLineWidth") private var savedLineWidth: Double = 4
    @State private var lineWidth: CGFloat = 4
    @AppStorage("doodleIsEraser") private var isEraser: Bool = false
    @State private var canvasSize: CGSize = CGSize(width: 300, height: 300)
    @State private var undoStack: [CanvasSnapshot] = []
    @State private var redoStack: [CanvasSnapshot] = []

    // Pen
    @State private var currentPenType: PenType = {
        let name = UserDefaults.standard.string(forKey: "doodleLastPenTypeName") ?? "pencil"
        let styleName = UserDefaults.standard.string(forKey: "doodleLastDualToneStyle") ?? "Gradient"
        let style = DualToneStyle.allCases.first { $0.rawValue == styleName } ?? .gradient
        switch name {
        case "ink":        return .ink
        case "brush":      return .brush
        case "marker":     return .marker
        case "chalk":      return .chalk
        case "neon":       return .neon
        case "spray":      return .spray
        case "watercolor": return .watercolor
        case "dotted":     return .dotted
        case "dualtone":   return .dualTone(style)
        default:           return .pencil
        }
    }()
    @State private var dualToneColorB: Color = .orange
    @State private var showPenStudio: Bool = false
    @AppStorage("doodleStampColorIndex") private var selectedColorIndex: Int = 0

    // Stamps
    @AppStorage("doodleStampLastEmoji") private var selectedStamp: String = "⭐️"
    @AppStorage("doodleLastCustomStampId") private var lastCustomStampIdString: String = ""
    @AppStorage("doodleIsCustomStampMode") private var isCustomStampMode: Bool = false
    @State private var placedStamps: [PlacedStamp] = []
    @State private var stampUndoStack: [[PlacedStamp]] = []
    @State private var stampRedoStack: [[PlacedStamp]] = []
    @State private var stampResizeStartSize: CGFloat = 0
    @State private var showStampMagicMenu: Bool = false
    @State private var showMenuTweak: Bool = false
    @AppStorage("doodleMenuOffsetX") private var savedMenuOffsetX: Double = 0
    @AppStorage("doodleMenuOffsetY") private var savedMenuOffsetY: Double = 0
    @State private var selectedStampId: UUID? = nil
    @State private var stampResizeTargetId: UUID? = nil
    @State private var stampRotatingId: UUID? = nil
    @State private var canvasOriginInWindow: CGPoint = .zero
    @State private var isLongPressing: Bool = false

    // Text stamps
    @State private var showTextComposer: Bool = false
    @State private var editingStampId: UUID? = nil

    // Tracing background (shown on canvas for reference; never included in export)
    @State private var tracingImage: UIImage? = nil
    @State private var tracingPickerItem: PhotosPickerItem? = nil

    // UI
    @State private var showThicknessPicker: Bool = false
    @State private var showClearSheet: Bool = false

    // Extraction
    @State private var isExtracting: Bool = false
    @State private var preProcessedSegmentation: PreProcessedSegmentation? = nil

    @ObservedObject private var customManager = CustomStampManager.shared

    private var currentColor: Color { paletteColors[selectedColorIndex] }
    private var canvasIsEmpty: Bool { lines.isEmpty && placedStamps.isEmpty }

    // MARK: - Color circle (matches DrawScreen)
    @ViewBuilder
    func colorCircle(_ color: Color) -> some View {
        let idx = paletteColors.firstIndex(where: { $0 == color })
        let isSelected = idx == selectedColorIndex && !isEraser
        Circle()
            .fill(color)
            .frame(width: 30, height: 30)
            .overlay(Group {
                if isSelected {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 3).padding(-3)
                        Circle().stroke(Color.blue, lineWidth: 3).padding(-6)
                    }
                } else if color == Color.white {
                    Circle().stroke(Color.black.opacity(0.3), lineWidth: 1)
                }
            })
            .onTapGesture {
                if let i = idx { selectedColorIndex = i }
                isEraser = false
                selectedStampId = nil
            }
    }

    // MARK: - Auto-place stamp at canvas center
    func autoPlaceStamp() {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
        redoStack = []
        if isCustomStampMode, let customId = UUID(uuidString: lastCustomStampIdString) {
            var stamp = PlacedStamp(emoji: "📷", position: center, size: 158)
            stamp.customImageId = customId
            placedStamps.append(stamp)
            selectedStampId = stamp.id
        } else {
            let stamp = PlacedStamp(emoji: selectedStamp, position: center, size: 126)
            placedStamps.append(stamp)
            selectedStampId = stamp.id
        }
        showStampMagicMenu = true
    }

    // MARK: - Place text stamp
    func placeTextStamp(text: String, fontId: String, fontStyle: String, alignment: String, color: Color, bgColor: Color) {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
        redoStack = []
        let (natW, natH, fontSize) = naturalTextStampSize(text: text, fontId: fontId, fontStyle: fontStyle, maxWidth: canvasSize.width * 0.7)
        var stamp = PlacedStamp(emoji: "✏️", position: center, size: fontSize)
        stamp.stampText = text
        stamp.fontName = fontId
        stamp.fontStyle = fontStyle
        stamp.textAlignment = alignment
        stamp.textColor = color
        stamp.textBgColor = bgColor
        stamp.stampWidth = natW
        stamp.stampHeight = natH
        placedStamps.append(stamp)
        selectedStampId = stamp.id
        showStampMagicMenu = true
    }

    // MARK: - Measure text stamp natural size
    func naturalTextStampSize(text: String, fontId: String, fontStyle: String, maxWidth: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let baseFontSize: CGFloat = 48
        let hPadding: CGFloat = 10
        let vPadding: CGFloat = 5
        let font = TextStampFont.font(forId: fontId, style: fontStyle).withSize(baseFontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textLines = text.components(separatedBy: "\n")
        var maxLineW: CGFloat = 0
        var totalH: CGFloat = 0
        for line in textLines {
            let str = (line.isEmpty ? " " : line) as NSString
            let br = str.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs, context: nil)
            maxLineW = max(maxLineW, ceil(br.width))
            totalH += ceil(br.height)
        }
        let w = min(maxLineW + hPadding * 2, maxWidth)
        let h = totalH + vPadding * 2
        return (w, h, baseFontSize)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {

                    // ── Canvas ──────────────────────────────────────────────
                    GeometryReader { geo in
                        Color.white
                        // Tracing reference layer — faint B&W, never composited into export
                        if let tracing = tracingImage {
                            Image(uiImage: tracing)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .grayscale(1.0)
                                .opacity(0.25)
                                .allowsHitTesting(false)
                        }
                        DrawingCanvas(
                            lines: $lines,
                            undoStack: $undoStack,
                            redoStack: $redoStack,
                            currentColor: isEraser ? (tracingImage != nil ? .clear : .white) : currentColor,
                            lineWidth: $lineWidth,
                            isEraser: $isEraser,
                            canvasColor: tracingImage != nil ? .clear : .white,
                            penType: currentPenType,
                            colorB: dualToneColorB,
                            currentStamps: placedStamps,
                            isLongPressing: isLongPressing,
                            stampResizeTargetId: stampResizeTargetId
                        )
                        .contentShape(Rectangle())
                        .allowsHitTesting(!isLongPressing)
                        .simultaneousGesture(TapGesture().onEnded {
                            selectedStampId = nil
                            showStampMagicMenu = false
                        })
                        .background(GeometryReader { geo2 in
                            Color.clear
                                .onAppear {
                                    let frame = geo2.frame(in: .global)
                                    canvasOriginInWindow = CGPoint(x: frame.minX, y: frame.minY)
                                }
                                .onChange(of: geo2.frame(in: .global)) { _, frame in
                                    canvasOriginInWindow = CGPoint(x: frame.minX, y: frame.minY)
                                }
                        })
                        .onAppear {
                            canvasSize = geo.size
                            lineWidth = CGFloat(savedLineWidth)
                        }
                        .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
                        .onChange(of: lineWidth) { _, new in savedLineWidth = Double(new) }

                        ZStack {
                            StampCanvasView(
                                stamps: $placedStamps,
                                selectedStampId: $selectedStampId,
                                showStampMagicMenu: $showStampMagicMenu,
                                undoStack: $undoStack,
                                redoStack: $redoStack,
                                lines: $lines,
                                backgroundImage: .constant(nil),
                                backgroundOffset: .constant(.zero),
                                canvasSize: canvasSize,
                                rotatingId: $stampRotatingId
                            )
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .allowsHitTesting(true)

                            if let selId = selectedStampId, showStampMagicMenu,
                               let selStamp = placedStamps.first(where: { $0.id == selId }) {
                                PulsingCrosshair()
                                    .allowsHitTesting(false)
                                    .position(selStamp.position)
                            }

                            if showStampMagicMenu, let id = selectedStampId,
                               let stamp = placedStamps.first(where: { $0.id == id }) {
                                StampMagicMenu(
                                    stamp: stamp,
                                    canvasSize: canvasSize,
                                    onDismiss: {
                                        showStampMagicMenu = false
                                        selectedStampId = nil
                                    },
                                    onTransform: { transform in
                                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
                                        redoStack = []
                                        if let idx = placedStamps.firstIndex(where: { $0.id == id }) {
                                            switch transform {
                                            case .flipH: placedStamps[idx].flipX.toggle()
                                            case .flipV: placedStamps[idx].flipY.toggle()
                                            case .rotate90: placedStamps[idx].rotation = (placedStamps[idx].rotation + 90).truncatingRemainder(dividingBy: 360)
                                            }
                                        }
                                        showStampMagicMenu = false
                                    },
                                    onDelete: {
                                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
                                        redoStack = []
                                        placedStamps.removeAll { $0.id == id }
                                        showStampMagicMenu = false
                                        selectedStampId = nil
                                    },
                                    onDupe: {
                                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
                                        redoStack = []
                                        if let idx = placedStamps.firstIndex(where: { $0.id == id }) {
                                            var dupe = placedStamps[idx]
                                            dupe = PlacedStamp(
                                                emoji: dupe.emoji,
                                                position: CGPoint(
                                                    x: min(dupe.position.x + dupe.size * 0.6, canvasSize.width - dupe.size / 2),
                                                    y: min(dupe.position.y + dupe.size * 0.6, canvasSize.height - dupe.size / 2)
                                                ),
                                                size: dupe.size,
                                                rotation: dupe.rotation,
                                                opacity: dupe.opacity,
                                                flipX: dupe.flipX,
                                                flipY: dupe.flipY,
                                                flipStep: dupe.flipStep,
                                                customImageId: dupe.customImageId,
                                                stampText: dupe.stampText,
                                                fontName: dupe.fontName,
                                                textColor: dupe.textColor,
                                                textBgColor: dupe.textBgColor,
                                                stampWidth: dupe.stampWidth,
                                                stampHeight: dupe.stampHeight
                                            )
                                            placedStamps.append(dupe)
                                            selectedStampId = dupe.id
                                        }
                                        showStampMagicMenu = true
                                    },
                                    onEdit: {
                                        editingStampId = id
                                        showStampMagicMenu = false
                                        showTextComposer = true
                                    },
                                    onNudge: { delta in
                                        guard let idx = placedStamps.firstIndex(where: { $0.id == id }) else { return }
                                        placedStamps[idx].position.x = max(0, min(canvasSize.width,  placedStamps[idx].position.x + delta.width))
                                        placedStamps[idx].position.y = max(0, min(canvasSize.height, placedStamps[idx].position.y + delta.height))
                                    },
                                    onResizeBy: { delta in
                                        guard let idx = placedStamps.firstIndex(where: { $0.id == id }) else { return }
                                        let oldSize = max(placedStamps[idx].size, 1)
                                        placedStamps[idx].size = max(20, placedStamps[idx].size + delta)
                                        let ratio = placedStamps[idx].size / oldSize
                                        if placedStamps[idx].stampWidth  > 0 { placedStamps[idx].stampWidth  *= ratio }
                                        if placedStamps[idx].stampHeight > 0 { placedStamps[idx].stampHeight *= ratio }
                                    },
                                    onRotateBy: { degrees in
                                        guard let idx = placedStamps.firstIndex(where: { $0.id == id }) else { return }
                                        placedStamps[idx].rotation = (placedStamps[idx].rotation + degrees).truncatingRemainder(dividingBy: 360)
                                    },
                                    showTweak: $showMenuTweak,
                                    initialOffset: CGSize(width: savedMenuOffsetX, height: savedMenuOffsetY),
                                    onOffsetSaved: { offset in
                                        savedMenuOffsetX = offset.width
                                        savedMenuOffsetY = offset.height
                                    }
                                )
                                .position(
                                    x: canvasSize.width / 2,
                                    y: showMenuTweak ? canvasSize.height - 96 : canvasSize.height - 84
                                )
                                .zIndex(1000)
                            }

                            WindowPinchView(
                                placedStamps: $placedStamps,
                                stampResizeStartSize: $stampResizeStartSize,
                                stampResizeTargetId: $stampResizeTargetId,
                                stampRotatingId: $stampRotatingId,
                                canvasOrigin: canvasOriginInWindow,
                                canvasSize: canvasSize,
                                selectedStamp: selectedStamp,
                                onLongPress: { loc in
                                    let hits = placedStamps.filter { s in
                                        let dx = loc.x - s.position.x
                                        let dy = loc.y - s.position.y
                                        return sqrt(dx*dx + dy*dy) <= s.size * 0.5 * 0.75
                                    }
                                    if hits.isEmpty {
                                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
                                        redoStack = []
                                        if isCustomStampMode, let customId = UUID(uuidString: lastCustomStampIdString) {
                                            var stamp = PlacedStamp(emoji: "📷", position: loc, size: 158)
                                            stamp.customImageId = customId
                                            placedStamps.append(stamp)
                                        } else {
                                            placedStamps.append(PlacedStamp(emoji: selectedStamp, position: loc, size: 126))
                                        }
                                    }
                                },
                                isLongPressing: $isLongPressing,
                                onBackgroundPanBegan: nil,
                                onBackgroundPan: nil
                            )
                        }
                        .coordinateSpace(name: "stampCanvas")
                        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                        .fixedSize()
                        .clipped()
                    }
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.25), lineWidth: 1))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // ── Toolbar ─────────────────────────────────────────────
                    VStack(spacing: 10) {

                        // Row 1: tracing bg + eraser + color palette
                        HStack(spacing: 8) {
                            // Tracing background picker
                            ZStack(alignment: .topTrailing) {
                                PhotosPicker(selection: $tracingPickerItem, matching: .images) {
                                    ZStack {
                                        Circle()
                                            .fill(tracingImage != nil ? Color.blue.opacity(0.15) : Color(white: 0.95))
                                            .frame(width: 38, height: 38)
                                            .overlay(Circle().stroke(tracingImage != nil ? Color.blue : Color.gray.opacity(0.4),
                                                                     lineWidth: tracingImage != nil ? 2.5 : 1))
                                        Image(systemName: tracingImage != nil ? "photo.fill" : "photo")
                                            .font(.system(size: 18))
                                            .foregroundColor(tracingImage != nil ? .blue : .gray)
                                    }
                                }
                                .onChange(of: tracingPickerItem) { _, item in
                                    Task {
                                        if let item,
                                           let data = try? await item.loadTransferable(type: Data.self),
                                           let img = UIImage(data: data) {
                                            await MainActor.run { tracingImage = img }
                                        }
                                        await MainActor.run { tracingPickerItem = nil }
                                    }
                                }
                                if tracingImage != nil {
                                    Button { tracingImage = nil } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.red)
                                            .background(Color.white.clipShape(Circle()))
                                    }
                                    .offset(x: 4, y: -4)
                                }
                            }
                            .padding(.leading, 16)

                            ZStack {
                                Circle()
                                    .fill(isEraser ? Color.blue.opacity(0.15) : Color(white: 0.95))
                                    .frame(width: 38, height: 38)
                                    .overlay(Circle().stroke(isEraser ? Color.blue : Color.gray.opacity(0.4),
                                                             lineWidth: isEraser ? 2.5 : 1))
                                Image(systemName: "eraser.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(isEraser ? .blue : .gray)
                            }
                            .onTapGesture {
                                selectedStampId = nil
                                isEraser = true
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(paletteColors, id: \.self) { color in
                                        colorCircle(color)
                                    }
                                }
                                .padding(.leading, 9)
                                .padding(.trailing, 16)
                                .padding(.vertical, 8)
                            }
                            .padding(.trailing, 4)
                        }

                        // Row 2: T | stamp | pen | thickness | undo | redo | clear
                        HStack(spacing: 12) {
                            Button {
                                showTextComposer = true
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(UIColor.secondarySystemBackground))
                                        .frame(width: 38, height: 38)
                                        .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                    Text("T")
                                        .font(.system(size: 20, weight: .bold, design: .serif))
                                        .foregroundColor(.primary)
                                }
                            }

                            StampToolButton(
                                selectedStamp: $selectedStamp,
                                placedStamps: $placedStamps,
                                stampUndoStack: $stampUndoStack,
                                selectedCustomStampId: $lastCustomStampIdString,
                                isCustomStampMode: $isCustomStampMode,
                                canvasSize: canvasSize,
                                allowDoodleCreation: false,
                                onPlace: { autoPlaceStamp() }
                            )

                            Button(action: {
                                selectedStampId = nil
                                showPenStudio = true
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(Color(UIColor.secondarySystemBackground))
                                        .frame(width: 34, height: 34)
                                        .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                    Image(systemName: currentPenType.icon)
                                        .font(.system(size: 20))
                                        .foregroundColor(.primary)
                                }
                            }
                            .sheet(isPresented: $showPenStudio, onDismiss: {
                                if currentPenType.isDualTone {
                                    UserDefaults.standard.set("dualtone", forKey: "doodleLastPenTypeName")
                                    UserDefaults.standard.set(currentPenType.dualToneStyle.rawValue, forKey: "doodleLastDualToneStyle")
                                } else {
                                    UserDefaults.standard.set(currentPenType.displayName.lowercased(), forKey: "doodleLastPenTypeName")
                                }
                            }) {
                                PenStudioSheet(penType: $currentPenType, colorB: $dualToneColorB)
                                    .presentationDragIndicator(.visible)
                            }
                            .sheet(isPresented: $showTextComposer, onDismiss: {
                                editingStampId = nil
                            }) {
                                TextComposerSheet(
                                    initialText: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.stampText
                                    },
                                    initialFontStyle: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.fontStyle
                                    },
                                    initialAlignment: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.textAlignment
                                    },
                                    onPlace: { text, fontId, fontStyle, alignment, color, bgColor in
                                        if let editId = editingStampId,
                                           let idx = placedStamps.firstIndex(where: { $0.id == editId }) {
                                            undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
                                            redoStack = []
                                            let (natW, natH, fontSize) = naturalTextStampSize(text: text, fontId: fontId, fontStyle: fontStyle, maxWidth: canvasSize.width * 0.7)
                                            placedStamps[idx].stampText = text
                                            placedStamps[idx].fontName = fontId
                                            placedStamps[idx].fontStyle = fontStyle
                                            placedStamps[idx].textAlignment = alignment
                                            placedStamps[idx].textColor = color
                                            placedStamps[idx].textBgColor = bgColor
                                            placedStamps[idx].size = fontSize
                                            placedStamps[idx].stampWidth = natW
                                            placedStamps[idx].stampHeight = natH
                                            selectedStampId = editId
                                            showStampMagicMenu = true
                                        } else {
                                            placeTextStamp(text: text, fontId: fontId, fontStyle: fontStyle, alignment: alignment, color: color, bgColor: bgColor)
                                        }
                                        showTextComposer = false
                                        editingStampId = nil
                                    }
                                )
                            }

                            Button {
                                showThicknessPicker.toggle()
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(UIColor.secondarySystemBackground))
                                        .frame(width: 34, height: 34)
                                    Circle()
                                        .fill(Color.primary)
                                        .frame(width: min(lineWidth, 24), height: min(lineWidth, 24))
                                }
                            }

                            Button(action: {
                                guard !undoStack.isEmpty else { return }
                                let snapshot = CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero)
                                redoStack.append(snapshot)
                                let last = undoStack.removeLast()
                                lines = last.lines
                                placedStamps = last.stamps
                            }) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(undoStack.isEmpty ? .gray.opacity(0.4) : .blue)
                            }
                            .disabled(undoStack.isEmpty)

                            Button(action: {
                                guard !redoStack.isEmpty else { return }
                                let snapshot = CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero)
                                undoStack.append(snapshot)
                                let last = redoStack.removeLast()
                                lines = last.lines
                                placedStamps = last.stamps
                            }) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(redoStack.isEmpty ? .gray.opacity(0.4) : .blue)
                            }
                            .disabled(redoStack.isEmpty)

                            Button("Clear") {
                                let thingCount = (lines.isEmpty ? 0 : 1) + (placedStamps.isEmpty ? 0 : 1)
                                if thingCount == 1 {
                                    undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
                                    redoStack = []
                                    if !lines.isEmpty { lines = [] }
                                    else { placedStamps = []; stampUndoStack = []; stampRedoStack = [] }
                                } else {
                                    showClearSheet = true
                                }
                            }
                            .foregroundColor(canvasIsEmpty ? .gray.opacity(0.4) : .red)
                            .font(.system(size: 16, weight: .medium))
                            .disabled(canvasIsEmpty)
                            .confirmationDialog("Clear Canvas", isPresented: $showClearSheet, titleVisibility: .visible) {
                                Button("Clear All", role: .destructive) {
                                    undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
                                    redoStack = []
                                    lines = []
                                    placedStamps = []
                                    stampUndoStack = []
                                    stampRedoStack = []
                                }
                                if !lines.isEmpty {
                                    Button("Clear Drawing", role: .destructive) {
                                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
                                        redoStack = []
                                        lines = []
                                    }
                                }
                                if !placedStamps.isEmpty {
                                    Button("Clear Stamps", role: .destructive) {
                                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: nil, backgroundOffset: .zero))
                                        redoStack = []
                                        placedStamps = []
                                        stampUndoStack = []
                                        stampRedoStack = []
                                    }
                                }
                                Button("Cancel", role: .cancel) {}
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }
                    .padding(.top, 10)
                }

                // ThicknessPanel — last in ZStack so it renders above everything
                if showThicknessPicker {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { showThicknessPicker = false }
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            ThicknessPanel(lineWidth: $lineWidth, onSelect: { showThicknessPicker = false })
                                .frame(width: 160)
                            Spacer()
                        }
                        .padding(.bottom, 175)
                    }
                }
            }
            .navigationTitle("Draw a Stamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { onDone(false) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isExtracting = true
                        let img = renderCanvasWithStamps(
                            lines: lines, stamps: placedStamps, size: canvasSize, canvasColor: .white
                        )
                        Task {
                            let model = ObjectSegmentationModel()
                            await model.processAll(images: [img])
                            await MainActor.run {
                                isExtracting = false
                                if model.objects.count == 1 {
                                    // Single object — place immediately, no sheet
                                    _ = customManager.addStamp(image: model.objects[0].image, source: .doodle)
                                    onDone(true)
                                } else if !model.objects.isEmpty {
                                    // Multiple objects — show picker with pre-processed results
                                    preProcessedSegmentation = PreProcessedSegmentation(objects: model.objects)
                                }
                                // 0 objects: model.error set; user stays on canvas to try again
                            }
                        }
                    } label: {
                        if isExtracting {
                            ProgressView().tint(.accentColor)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "scissors")
                                Text("Extract")
                            }
                            .fontWeight(.semibold)
                        }
                    }
                    .disabled(canvasIsEmpty || isExtracting)
                }
            }
        }
        .sheet(item: $preProcessedSegmentation) { item in
            ObjectSegmentationSheet(preProcessedObjects: item.objects) { cutouts in
                preProcessedSegmentation = nil
                for cutout in cutouts {
                    _ = customManager.addStamp(image: cutout, source: .doodle)
                }
                onDone(true)
            }
        }
    }
}
