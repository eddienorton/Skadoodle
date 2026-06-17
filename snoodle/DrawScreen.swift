//
//  DrawScreen.swift
//  snoodle
//

import SwiftUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine
import Photos
import Vision

// MARK: - Background History Manager
class BackgroundPhotoHistory: ObservableObject {
    static let shared = BackgroundPhotoHistory()
    private let fullKey = "canvasBgHistoryFull"
    private let thumbKey = "canvasBgHistoryThumbs"
    private let idKey = "canvasBgHistoryIds"
    private let maxCount = 20
    @Published var thumbnails: [UIImage] = []
    @Published var fullImages: [UIImage] = []

    init() { load() }

    /// Add with optional asset localIdentifier for reliable dedup.
    /// Heavy work (JPEG encode, UserDefaults write) runs off the main thread.
    func add(_ image: UIImage, assetId: String? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let full = self.resized(image, maxDim: 1600)
            let thumb = self.resized(image, maxDim: 200)
            let fullData = full.jpegData(compressionQuality: 0.85) ?? Data()
            let thumbData = thumb.jpegData(compressionQuality: 0.8) ?? Data()
            let idValue = assetId ?? ""

            var existingFull = self.loadRaw(key: self.fullKey)
            var existingThumbs = self.loadRaw(key: self.thumbKey)
            var existingIds = self.loadIds()

            // Dedup: if we have an assetId, match on that; otherwise exact data match
            let dupeIdx: [Int]
            if !idValue.isEmpty {
                dupeIdx = existingIds.indices.filter { existingIds[$0] == idValue }
            } else {
                dupeIdx = existingThumbs.indices.filter { existingThumbs[$0] == thumbData }
            }
            for i in dupeIdx.reversed() {
                if i < existingFull.count { existingFull.remove(at: i) }
                if i < existingThumbs.count { existingThumbs.remove(at: i) }
                if i < existingIds.count { existingIds.remove(at: i) }
            }

            existingFull.insert(fullData, at: 0)
            existingThumbs.insert(thumbData, at: 0)
            existingIds.insert(idValue, at: 0)

            if existingFull.count > maxCount {
                existingFull = Array(existingFull.prefix(maxCount))
                existingThumbs = Array(existingThumbs.prefix(maxCount))
                existingIds = Array(existingIds.prefix(maxCount))
            }

            self.save(existingFull, key: self.fullKey)
            self.save(existingThumbs, key: self.thumbKey)
            UserDefaults.standard.set(existingIds, forKey: self.idKey)
            DispatchQueue.main.async { self.load() }
        }
    }

    func moveToTop(at index: Int) {
        guard index < fullImages.count, index < thumbnails.count else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var existingFull = self.loadRaw(key: self.fullKey)
            var existingThumbs = self.loadRaw(key: self.thumbKey)
            var existingIds = self.loadIds()
            guard index < existingFull.count else { return }
            let full = existingFull.remove(at: index)
            let thumb = existingThumbs.remove(at: index)
            let id = existingIds.count > index ? existingIds.remove(at: index) : ""
            existingFull.insert(full, at: 0)
            existingThumbs.insert(thumb, at: 0)
            existingIds.insert(id, at: 0)
            self.save(existingFull, key: self.fullKey)
            self.save(existingThumbs, key: self.thumbKey)
            UserDefaults.standard.set(existingIds, forKey: self.idKey)
            DispatchQueue.main.async { self.load() }
        }
    }

    func remove(at index: Int) {
        guard index < thumbnails.count else { return }
        var existingFull = loadRaw(key: fullKey)
        var existingThumbs = loadRaw(key: thumbKey)
        var existingIds = loadIds()
        if index < existingFull.count { existingFull.remove(at: index) }
        if index < existingThumbs.count { existingThumbs.remove(at: index) }
        if index < existingIds.count { existingIds.remove(at: index) }
        save(existingFull, key: fullKey)
        save(existingThumbs, key: thumbKey)
        UserDefaults.standard.set(existingIds, forKey: idKey)
        load()
    }

    func fullImage(at index: Int) -> UIImage? {
        index < fullImages.count ? fullImages[index] : thumbnails[safe: index]
    }

    private func resized(_ image: UIImage, maxDim: CGFloat) -> UIImage {
        let scale = min(maxDim / image.size.width, maxDim / image.size.height, 1.0)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private func loadIds() -> [String] {
        UserDefaults.standard.stringArray(forKey: idKey) ?? []
    }

    private func loadRaw(key: String) -> [Data] {
        guard let encoded = UserDefaults.standard.data(forKey: key),
              let strings = try? JSONDecoder().decode([String].self, from: encoded) else { return [] }
        return strings.compactMap { Data(base64Encoded: $0) }
    }

    private func save(_ items: [Data], key: String) {
        if let encoded = try? JSONEncoder().encode(items.map { $0.base64EncodedString() }) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    private func load() {
        thumbnails = loadRaw(key: thumbKey).compactMap { UIImage(data: $0) }
        fullImages = loadRaw(key: fullKey).compactMap { UIImage(data: $0) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Subject Extraction (free function — safe to call from Task.detached)

func extractBgSubject(from image: UIImage) -> UIImage? {
    guard #available(iOS 17.0, *) else { return nil }
    guard let cgImage = image.cgImage else { return nil }
    let handler = VNImageRequestHandler(cgImage: cgImage)
    let request = VNGenerateForegroundInstanceMaskRequest()
    do { try handler.perform([request]) } catch { return nil }
    guard let observation = request.results?.first else { return nil }
    do {
        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances, from: handler)
        let originalCI = CIImage(cgImage: cgImage)
        let maskCI = CIImage(cvPixelBuffer: maskBuffer)
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return nil }
        blendFilter.setValue(originalCI, forKey: kCIInputImageKey)
        blendFilter.setValue(
            CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: originalCI.extent),
            forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskCI, forKey: kCIInputMaskImageKey)
        guard let output = blendFilter.outputImage else { return nil }
        let context = CIContext()
        guard let outCG = context.createCGImage(output, from: originalCI.extent) else { return nil }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
    } catch { return nil }
}

// MARK: - Extraction state (ObservableObject so @Published triggers reliable re-renders)

@MainActor
class ExtractionModel: ObservableObject {
    @Published var extractedSubject: UIImage? = nil
    @Published var isExtracting: Bool = false
    @Published var extractionFailed: Bool = false

    func start(for image: UIImage) async {
        guard !isExtracting, extractedSubject == nil else { return }
        isExtracting = true
        extractionFailed = false
        let img = image
        let result = await Task.detached(priority: .userInitiated) {
            extractBgSubject(from: img)
        }.value
        extractedSubject = result
        extractionFailed = result == nil
        isExtracting = false
    }
}

// MARK: - Background Editor

struct BackgroundEditorView: View {
    let backgroundImage: UIImage?
    let canvasColor: Color
    @Binding var bgOpacity: Double
    @Binding var bgBlur: Double
    @Binding var bgBrightness: Double
    @Binding var bgSaturation: Double
    var showCancel: Bool = false
    let lines: [DrawingLine]
    let stamps: [PlacedStamp]
    let canvasSize: CGSize
    var onExtractionResult: ((UIImage?) -> Void)? = nil
    var onCancel: () -> Void
    var onDone: () -> Void

    @State private var canvasSnapshot: UIImage? = nil
    @AppStorage("bgExtractionEnabled") private var extractionEnabled: Bool = false
    @StateObject private var extraction = ExtractionModel()

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Preview [+ side toggle on iPad]
            HStack(alignment: .center, spacing: 16) {

                // Full doodle preview
                GeometryReader { geo in
                    let pad: CGFloat = 16
                    let availW = geo.size.width - pad * 2
                    let availH = geo.size.height - pad * 2
                    ZStack {
                        // Canvas background color
                        canvasColor

                        // Background image with live effects
                        if let bgImg = backgroundImage {
                            let imgW = bgImg.size.width, imgH = bgImg.size.height
                            let scale = imgW > 0 && imgH > 0 ? max(availW / imgW, availH / imgH) : 1
                            Image(uiImage: bgImg)
                                .resizable()
                                .frame(width: imgW * scale, height: imgH * scale)
                                .frame(width: availW, height: availH, alignment: .center)
                                .clipped()
                                .blur(radius: bgBlur, opaque: true)
                                .brightness(bgBrightness)
                                .saturation(bgSaturation)
                                .opacity(bgOpacity)
                        }

                        // Extracted subject layer — sits above effects, no modifiers applied
                        if extractionEnabled, let subject = extraction.extractedSubject {
                            let imgW = subject.size.width, imgH = subject.size.height
                            let scale = imgW > 0 && imgH > 0 ? max(availW / imgW, availH / imgH) : 1
                            Image(uiImage: subject)
                                .resizable()
                                .frame(width: imgW * scale, height: imgH * scale)
                                .frame(width: availW, height: availH, alignment: .center)
                                .clipped()
                                .allowsHitTesting(false)
                        }

                        // Static canvas snapshot (strokes + stamps)
                        if let snap = canvasSnapshot {
                            Image(uiImage: snap)
                                .resizable()
                                .scaledToFit()
                                .frame(width: availW, height: availH)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: availW, height: availH)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                    .onAppear { renderSnapshot(size: CGSize(width: availW, height: availH)) }
                }
                .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 280 : .infinity)
                .frame(maxHeight: UIDevice.current.userInterfaceIdiom == .pad ? 260 : .infinity)

                // Extract Objects toggle — iPad only, sits beside the preview
                if UIDevice.current.userInterfaceIdiom == .pad {
                    if #available(iOS 17.0, *) {
                        VStack(spacing: 12) {
                            Image(systemName: "person.and.background.dotted")
                                .font(.system(size: 22))
                                .foregroundColor(.secondary)
                            Text("Extract\nObjects")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            if extraction.isExtracting {
                                ProgressView().scaleEffect(0.75)
                            }
                            Toggle("", isOn: $extractionEnabled)
                                .labelsHidden()
                                .tint(.purple)
                                .disabled(extraction.extractionFailed)
                                .onChange(of: extractionEnabled) { _, enabled in
                                    if enabled, let img = backgroundImage {
                                        Task { await extraction.start(for: img) }
                                    }
                                }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, UIDevice.current.userInterfaceIdiom == .pad ? 20 : 0)
            .padding(.top, UIDevice.current.userInterfaceIdiom == .pad ? 16 : 0)

            // MARK: Sliders + (iPhone: toggle row / iPad: reset button)
            ScrollView {
                VStack(spacing: 18) {

                    Group {
                        effectSlider(label: "Opacity", icon: "circle.lefthalf.filled",
                                     value: $bgOpacity, range: 0.05...1, displayPercent: true)

                        effectSlider(label: "Blur", icon: "aqi.low",
                                     value: $bgBlur, range: 0...20, displayPercent: false)

                        effectSlider(label: "Brightness", icon: "sun.max",
                                     value: $bgBrightness, range: -0.5...0.5, displayPercent: false)

                        effectSlider(label: "Saturation", icon: "drop.halffull",
                                     value: $bgSaturation,
                                     range: 0...1, displayPercent: true)
                    }
                    .disabled(extractionEnabled && extraction.isExtracting)
                    .opacity(extractionEnabled && extraction.isExtracting ? 0.4 : 1.0)

                    if UIDevice.current.userInterfaceIdiom == .pad {
                        // iPad: Reset button below sliders
                        HStack {
                            Spacer()
                            Button("Reset") {
                                bgOpacity = 1.0; bgBlur = 0.0; bgBrightness = 0.0; bgSaturation = 1.0
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                        }
                    } else {
                        // iPhone: full toggle + reset row (unchanged)
                        if #available(iOS 17.0, *) {
                            Divider()
                            HStack {
                                Image(systemName: "person.and.background.dotted")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .frame(width: 18)
                                Text("Extract Objects")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                if extraction.isExtracting {
                                    ProgressView()
                                        .scaleEffect(0.75)
                                        .padding(.leading, 4)
                                }
                                Toggle("", isOn: $extractionEnabled)
                                    .labelsHidden()
                                    .tint(.purple)
                                    .fixedSize()
                                    .padding(.leading, 6)
                                    .disabled(extraction.extractionFailed)
                                    .onChange(of: extractionEnabled) { _, enabled in
                                        if enabled, let img = backgroundImage {
                                            Task { await extraction.start(for: img) }
                                        }
                                    }
                                Spacer()
                                Button("Reset") {
                                    bgOpacity = 1.0; bgBlur = 0.0; bgBrightness = 0.0; bgSaturation = 1.0
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
            .frame(maxHeight: UIDevice.current.userInterfaceIdiom == .pad ? .infinity : 340)
        }
        .navigationTitle("Effects")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel", role: .cancel) { onCancel() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    onExtractionResult?(extractionEnabled ? extraction.extractedSubject : nil)
                    onDone()
                }
                .fontWeight(.semibold)
            }
        }
        .task(id: backgroundImage != nil) {
            guard extractionEnabled, let img = backgroundImage else { return }
            await extraction.start(for: img)
        }
    }

    @ViewBuilder
    func effectSlider(label: String, icon: String, value: Binding<Double>, range: ClosedRange<Double>, displayPercent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(displayPercent
                     ? "\(Int(value.wrappedValue * 100))%"
                     : String(format: "%.1f", value.wrappedValue))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            Slider(value: value, in: range)
                .tint(.purple)
        }
    }

    func renderSnapshot(size: CGSize) {
        let capturedLines = lines
        let capturedStamps = stamps
        let capturedSize = canvasSize
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = renderCanvasWithStamps(
                lines: capturedLines, stamps: capturedStamps, size: capturedSize,
                canvasColor: .clear, backgroundImage: nil
            )
            DispatchQueue.main.async { canvasSnapshot = snap }
        }
    }

}

struct CanvasColorPickerView: View {
    let currentIndex: Int
    let onSelect: (Int) -> Void
    var onPickPhoto: (() -> Void)? = nil
    var onPreviewPhoto: ((UIImage) -> Void)? = nil
    var onGoToEffects: ((Int) -> Void)? = nil
    var onApply: ((Int) -> Void)? = nil
    var onPickerCancel: (() -> Void)? = nil
    var onExtractStamps: ((UIImage) -> Void)? = nil
    var initialHistoryIndex: Int? = nil
    @Environment(\.dismiss) var dismiss
    @State private var selectedIndex: Int
    @State private var wipSelectedIndex: Int? = nil
    @ObservedObject private var history = BackgroundPhotoHistory.shared

    init(currentIndex: Int, onSelect: @escaping (Int) -> Void, onPickPhoto: (() -> Void)? = nil,
         onPreviewPhoto: ((UIImage) -> Void)? = nil, onGoToEffects: ((Int) -> Void)? = nil,
         onApply: ((Int) -> Void)? = nil, onPickerCancel: (() -> Void)? = nil,
         onExtractStamps: ((UIImage) -> Void)? = nil, initialHistoryIndex: Int? = nil) {
        self.currentIndex = currentIndex
        self.onSelect = onSelect
        self.onPickPhoto = onPickPhoto
        self.onPreviewPhoto = onPreviewPhoto
        self.onGoToEffects = onGoToEffects
        self.onApply = onApply
        self.onPickerCancel = onPickerCancel
        self.onExtractStamps = onExtractStamps
        self.initialHistoryIndex = initialHistoryIndex
        _selectedIndex = State(initialValue: currentIndex)
        _wipSelectedIndex = State(initialValue: initialHistoryIndex)
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                    // MARK: Color row (top)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(canvasColorOptions.indices, id: \.self) { i in
                                let color = canvasColorOptions[i]
                                Circle()
                                    .fill(color)
                                    .frame(width: 42, height: 42)
                                    .overlay(
                                        Group {
                                            if selectedIndex == i {
                                                ZStack {
                                                    Circle().stroke(Color.white, lineWidth: 3).padding(-3)
                                                    Circle().stroke(Color.blue, lineWidth: 3).padding(-7)
                                                }
                                            } else {
                                                Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                            }
                                        }
                                    )
                                    .shadow(color: .black.opacity(0.1), radius: 3)
                                    .onTapGesture {
                                        selectedIndex = i
                                        onSelect(i)
                                        dismiss()
                                    }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                    }

                    Divider().padding(.horizontal, 20).padding(.bottom, 8)

                    let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                    ScrollViewReader { proxy in
                    LazyVGrid(columns: cols, spacing: 10) {
                        // Plus cell — browse camera roll
                        Button {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                onPickPhoto?()
                            }
                        } label: {
                            GeometryReader { geo in
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.purple.opacity(0.08))
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.purple.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [4]))
                                    Image(systemName: "plus")
                                        .font(.system(size: 28))
                                        .foregroundColor(.purple)
                                }
                                .frame(width: geo.size.width, height: geo.size.width)
                            }
                            .aspectRatio(1, contentMode: .fit)
                        }

                        // Recent background thumbnails — tap goes straight to Effects
                        ForEach(history.thumbnails.indices, id: \.self) { i in
                            GeometryReader { geo in
                                Button {
                                    let img = history.fullImage(at: i) ?? history.thumbnails[i]
                                    onPreviewPhoto?(img)
                                    onGoToEffects?(i)
                                } label: {
                                    Image(uiImage: history.thumbnails[i])
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: geo.size.width, height: geo.size.width)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                                        )
                                }
                                .contextMenu {
                                    Button("Remove", role: .destructive) {
                                        history.remove(at: i)
                                    }
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .id(i)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    .onAppear {
                        if let idx = initialHistoryIndex {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                    } // ScrollViewReader
                }
        }
        .navigationTitle("Background")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") {
                    onPickerCancel?()
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Pen Studio

struct PenStudioSheet: View {
    @Binding var penType: PenType
    @Binding var colorB: Color
    @Environment(\.dismiss) var dismiss

    // Local state for dual tone sub-selection
    @State private var selectedDualStyle: DualToneStyle = .gradient

    private let allPens: [PenType] = [.pencil, .ink, .brush, .marker, .chalk, .neon, .spray, .watercolor, .dotted, .dualTone(.gradient)]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // Pen type grid
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(allPens, id: \.displayName) { pen in
                            PenTypeCard(pen: pen, isSelected: penTypesMatch(penType, pen))
                                .onTapGesture {
                                    if pen.isDualTone {
                                        penType = .dualTone(selectedDualStyle)
                                        UserDefaults.standard.set("dualtone", forKey: "lastPenTypeName")
                                        UserDefaults.standard.set(selectedDualStyle.rawValue, forKey: "lastDualToneStyle")
                                    } else {
                                        penType = pen
                                        UserDefaults.standard.set(pen.displayName.lowercased(), forKey: "lastPenTypeName")
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Dual tone options — shown only when dual tone is selected
                    if penType.isDualTone {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Dual Tone Style")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(DualToneStyle.allCases) { style in
                                        DualToneStyleChip(style: style, isSelected: penType.dualToneStyle == style)
                                            .onTapGesture {
                                                selectedDualStyle = style
                                                penType = .dualTone(style)
                                                UserDefaults.standard.set(style.rawValue, forKey: "lastDualToneStyle")
                                            }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }

                            // Second color picker
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Second Color")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 20)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(paletteColors, id: \.self) { color in
                                            Circle()
                                                .fill(color)
                                                .frame(width: 36, height: 36)
                                                .overlay(
                                                    Group {
                                                        if colorB == color {
                                                            ZStack {
                                                                Circle().stroke(Color.white, lineWidth: 3).padding(-3)
                                                                Circle().stroke(Color.purple, lineWidth: 3).padding(-7)
                                                            }
                                                        } else {
                                                            Circle().stroke(Color.gray.opacity(0.25), lineWidth: 1)
                                                        }
                                                    }
                                                )
                                                .shadow(color: .black.opacity(0.08), radius: 2)
                                                .onTapGesture {
                                                    colorB = color
                                                    if let idx = paletteColors.firstIndex(where: { $0 == color }) {
                                                        UserDefaults.standard.set(idx, forKey: "lastColorBIndex")
                                                    }
                                                }
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Live preview
                    PenPreviewStrip(penType: penType, colorB: colorB)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                }
                .padding(.top, 20)
            }
            .navigationTitle("Pen Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if penType.isDualTone {
                    selectedDualStyle = penType.dualToneStyle
                }
            }
        }
        .presentationDetents(UIDevice.current.userInterfaceIdiom == .pad
            ? [.height(penType.isDualTone ? 643 : 427), .large]
            : (penType.isDualTone ? [.fraction(0.83), .large] : [.fraction(0.57), .large]))
        .frame(minHeight: UIDevice.current.userInterfaceIdiom == .pad ? (penType.isDualTone ? 643 : 427) : 0)
        .animation(.easeInOut(duration: 0.2), value: penType.isDualTone)
    }

    private func penTypesMatch(_ a: PenType, _ b: PenType) -> Bool {
        switch (a, b) {
        case (.pencil, .pencil), (.ink, .ink), (.brush, .brush),
             (.marker, .marker), (.chalk, .chalk),
             (.neon, .neon), (.spray, .spray),
             (.watercolor, .watercolor), (.dotted, .dotted): return true
        case (.dualTone, .dualTone): return true
        default: return false
        }
    }
}

struct PenTypeCard: View {
    let pen: PenType
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.purple.opacity(0.12) : Color(UIColor.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? Color.purple : Color.clear, lineWidth: 2)
                    )
                    .frame(height: 68)

                Image(systemName: pen.icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(isSelected ? .purple : .primary)
            }
            Text(pen.displayName)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .purple : .secondary)
        }
    }
}

struct DualToneStyleChip: View {
    let style: DualToneStyle
    let isSelected: Bool

    var icon: String {
        switch style {
        case .gradient:    return "arrow.left.to.line.alt"
        case .split:       return "rectangle.split.2x1"
        case .reactive:    return "arrow.up.left.and.arrow.down.right"
        case .alternating: return "alternatingcurrent"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13))
            Text(style.rawValue).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Color.purple : Color(UIColor.secondarySystemBackground))
        .foregroundColor(isSelected ? .white : .primary)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isSelected ? Color.clear : Color.gray.opacity(0.25), lineWidth: 1)
        )
    }
}

struct PenPreviewStrip: View {
    let penType: PenType
    let colorB: Color

    private func previewLine(in size: CGSize) -> DrawingLine {
        let w = size.width, h = size.height
        let points = stride(from: 0.0, through: 1.0, by: 0.03).map { t in
            CGPoint(x: w * (0.08 + 0.84 * t),
                    y: h * (0.5 + 0.28 * sin(t * .pi * 2)))
        }
        return DrawingLine(
            points: Array(points),
            widths: (0..<points.count).map { _ in CGFloat(12) },
            color: .purple,
            lineWidth: 12,
            isEraser: false,
            penType: penType,
            colorB: colorB,
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)

            GeometryReader { geo in
                Canvas { context, size in
                    let line = previewLine(in: size)
                    renderLine(line, in: &context, canvasColor: .white)
                }
                .background(Color(UIColor.systemBackground))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                .frame(height: geo.size.height)
            }
            .frame(height: 72)
        }
    }
}

// MARK: - Draw Screen

/// Wraps ImagePickerView with a callback instead of a binding, for canvas background use
struct ImagePickerCallback: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePickerCallback
        init(_ parent: ImagePickerCallback) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.onPick(img)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct DrawScreen: View {
    @EnvironmentObject var store: SnoodleStore
    @Binding var isPresented: Bool
    @Binding var selectedTab: Int

    @State private var lines: [DrawingLine] = []
    @State private var lineWidth: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "lastLineWidth") == 0 ? 4 : UserDefaults.standard.double(forKey: "lastLineWidth"))
    @State private var isEraser: Bool = false
    @State private var isGeneratingCaption: Bool = false
    @State private var canvasSize: CGSize = CGSize(width: 300, height: 300)
    @State private var undoStack: [CanvasSnapshot] = []
    @State private var redoStack: [CanvasSnapshot] = []
    @AppStorage("lastCanvasColorIndex") private var canvasColorIndex: Int = 11
    @AppStorage("lastNonWhiteColorIndex") private var lastNonWhiteColorIndex: Int = 0  // black
    @AppStorage("lastPenColorIndex") private var selectedColorIndex: Int = 0

    // Result card state
    @State private var showResultCard: Bool = false
    @State private var resultCaption: String = ""
    @State private var resultKeywords: [String] = []
    @State private var resultImage: UIImage? = nil
    @State private var isEditingCaption: Bool = false
    @State private var aiFailed: Bool = false
    @FocusState private var captionFocused: Bool

    var currentColor: Color { paletteColors[selectedColorIndex] }
    var canvasColor: Color { canvasColorOptions[canvasColorIndex] }

    @State private var showCanvasBgSheet: Bool = false
    @State private var bgNavPath = NavigationPath()
    @State private var bgPickerWasApplied: Bool = false
    @State private var bgSegmentationItem: SegmentationItem? = nil
@State private var canvasBackgroundImage: UIImage? = nil
    @State private var backgroundOffset: CGSize = .zero
    @State private var backgroundDragStart: CGSize = .zero

    // Background effects (persisted so theme settings carry across sessions)
    @AppStorage("bgOpacity") private var bgOpacity: Double = 1.0
    @AppStorage("bgBlur") private var bgBlur: Double = 0.0
    @AppStorage("bgBrightness") private var bgBrightness: Double = 0.0
    @AppStorage("bgSaturation") private var bgSaturation: Double = 1.0
    @State private var showBgEditor: Bool = false
    // Saved state for cancel in background editor
    @State private var savedBgImage: UIImage? = nil
    @State private var savedBgOffset: CGSize = .zero
    @State private var pendingExtractedSubject: UIImage? = nil
    @State private var pendingBgHistoryIndex: Int? = nil
    @State private var savedBgOpacity: Double = 1.0
    @State private var savedBgBlur: Double = 0.0
    @State private var savedBgBrightness: Double = 0.0
    @State private var savedBgSaturation: Double = 1.0

    @State private var showCanvasImagePicker: Bool = false
    @StateObject private var auth = SnoodleAuthManager.shared
    @State private var showSignInForPost: Bool = false
    @State private var currentPenType: PenType = {
        let penName = UserDefaults.standard.string(forKey: "lastPenTypeName") ?? "pencil"
        let styleName = UserDefaults.standard.string(forKey: "lastDualToneStyle") ?? "Gradient"
        let style = DualToneStyle.allCases.first { $0.rawValue == styleName } ?? .gradient
        switch penName {
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
    @State private var dualToneColorB: Color = {
        let idx = UserDefaults.standard.integer(forKey: "lastColorBIndex")
        return idx < paletteColors.count ? paletteColors[idx] : .orange
    }()
    @State private var showPenStudio: Bool = false
    @State private var showThicknessPicker: Bool = false
    @State private var showClearSheet: Bool = false
    @AppStorage("lastSelectedStamp") private var selectedStamp: String = "⭐️"
    @AppStorage("lastCustomStampId") private var lastCustomStampIdString: String = ""
    @AppStorage("isCustomStampMode") private var isCustomStampMode: Bool = false
    @State private var placedStamps: [PlacedStamp] = []
    @State private var stampUndoStack: [[PlacedStamp]] = [] // unused - kept for DrawingCanvas binding
    @State private var stampRedoStack: [[PlacedStamp]] = [] // unused - kept for DrawingCanvas binding
    @State private var stampResizeStartSize: CGFloat = 0
    @State private var showStampMagicMenu: Bool = false
    @State private var showTextComposer: Bool = false
    @State private var editingStampId: UUID? = nil
    @State private var selectedStampId: UUID? = nil
    @State private var stampResizeTargetId: UUID? = nil
    @State private var stampRotatingId: UUID? = nil
    @State private var draggingStampId: UUID? = nil
    @State private var canvasOriginInWindow: CGPoint = .zero
    @State private var isLongPressing: Bool = false

    func resetBgEffects() {
        bgOpacity = 1.0; bgBlur = 0.0; bgBrightness = 0.0; bgSaturation = 1.0
    }

    func saveBgStateForCancel() {
        savedBgImage = canvasBackgroundImage
        savedBgOffset = backgroundOffset
        savedBgOpacity = bgOpacity
        savedBgBlur = bgBlur
        savedBgBrightness = bgBrightness
        savedBgSaturation = bgSaturation
    }

    func restoreSavedBgState() {
        canvasBackgroundImage = savedBgImage
        backgroundOffset = savedBgOffset
        bgOpacity = savedBgOpacity
        bgBlur = savedBgBlur
        bgBrightness = savedBgBrightness
        bgSaturation = savedBgSaturation
    }

    // stampView replaced by StampItemView struct below
    func handleDone() {
        let img = renderCanvasWithStamps(lines: lines, stamps: placedStamps, size: canvasSize, canvasColor: UIColor(canvasColor), backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation)
        resultImage = img
        isGeneratingCaption = true
        Task {
            let result = await callSnoodleAI(for: img)
            await MainActor.run {
                if result.caption == "My doodle" && result.keywords.isEmpty {
                    // AI failed — show card with empty caption, keyboard up
                    resultCaption = ""
                    resultKeywords = []
                    aiFailed = true
                    isEditingCaption = true
                } else {
                    resultCaption = result.caption
                    resultKeywords = result.keywords
                    aiFailed = false
                    isEditingCaption = false
                }
                isGeneratingCaption = false
                showResultCard = true
            }
        }
    }

    func saveEntry(post: Bool) {
        guard let img = resultImage, let data = img.jpegData(compressionQuality: 0.8) else { return }
        let caption = resultCaption.trimmingCharacters(in: .whitespaces)
        var entry = SnoodleEntry(
            caption: caption,
            keywords: resultKeywords,
            imageData: data
        )
        if post {
            guard auth.isSignedIn else {
                showSignInForPost = true
                return
            }
            // Switch to gallery immediately — world gallery will load
            // Navigate to world gallery — the live listener (started in onAppear)
            // will pick up the new doc automatically; no manual fetchRecent() needed.
            WorldGalleryManager.shared.submit(entry: entry) { docId, error in
                if error == nil {
                    entry.isSubmitted = true
                    entry.worldGalleryId = docId
                }
                SnoodleStore.shared.save(entry)
                // Fetch first, then show world gallery once data is ready
                WorldGalleryManager.shared.fetchRecent()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    WorldGalleryManager.shared.pendingShowWorld = true
                    self.selectedTab = 0
                }
            }
        } else {
            store.save(entry)
            WorldGalleryManager.shared.pendingShowWorld = false
            // Slight delay so @Published store.entries propagates to the
            // gallery view before it appears — prevents the "new doodle
            // missing until you switch tabs" glitch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                WorldGalleryManager.shared.pendingShowPrivate = true
                selectedTab = 0
            }
        }
        isPresented = false
    }

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

    // Extracted into its own function so the compiler can type-check the callbacks independently
    @ViewBuilder
    func stampMagicMenuView(id: UUID, stamp: PlacedStamp) -> some View {
        StampMagicMenu(
            stamp: stamp,
            canvasSize: canvasSize,
            onDismiss: {
                showStampMagicMenu = false
                selectedStampId = nil
            },
            onTransform: { transform in
                undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
                redoStack = []
                if let idx = placedStamps.firstIndex(where: { $0.id == id }) {
                    switch transform {
                    case .flipH:    placedStamps[idx].flipX.toggle()
                    case .flipV:    placedStamps[idx].flipY.toggle()
                    case .rotate90: placedStamps[idx].rotation = (placedStamps[idx].rotation + 90).truncatingRemainder(dividingBy: 360)
                    }
                }
                showStampMagicMenu = false
            },
            onDelete: {
                undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
                redoStack = []
                placedStamps.removeAll { $0.id == id }
                showStampMagicMenu = false
                selectedStampId = nil
            },
            onDupe: {
                undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
                redoStack = []
                if let idx = placedStamps.firstIndex(where: { $0.id == id }) {
                    let src = placedStamps[idx]
                    let dupePosX: CGFloat = min(src.position.x + src.size * 0.6, canvasSize.width  - src.size / 2)
                    let dupePosY: CGFloat = min(src.position.y + src.size * 0.6, canvasSize.height - src.size / 2)
                    var dupe = PlacedStamp(emoji: src.emoji, position: CGPoint(x: dupePosX, y: dupePosY), size: src.size,
                                          rotation: src.rotation, opacity: src.opacity,
                                          flipX: src.flipX, flipY: src.flipY, flipStep: src.flipStep,
                                          customImageId: src.customImageId,
                                          stampText: src.stampText, fontName: src.fontName,
                                          textColor: src.textColor, textBgColor: src.textBgColor,
                                          stampWidth: src.stampWidth, stampHeight: src.stampHeight)
                    dupe.inlineImage = src.inlineImage
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
                placedStamps[idx].rotation = (placedStamps[idx].rotation + degrees)
                    .truncatingRemainder(dividingBy: 360)
            }
        )
        .position(x: canvasSize.width / 2, y: canvasSize.height - 100)
        .zIndex(1000)
    }

    // Auto-place the current stamp centered on the canvas when selected from picker
    func autoPlaceStamp() {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
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

    func placeTextStamp(text: String, fontId: String, fontStyle: String, alignment: String, color: Color, bgColor: Color) {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
        redoStack = []

        // Compute natural content size honoring explicit line breaks
        let (natW, natH, fontSize) = naturalTextStampSize(
            text: text, fontId: fontId, fontStyle: fontStyle,
            maxWidth: canvasSize.width * 0.7
        )

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

    /// Measure text at a good starting font size, respecting ONLY explicit line breaks.
    /// Each line is measured independently — no word wrap.
    /// Returns (width, height, fontSize).
    func naturalTextStampSize(text: String, fontId: String, fontStyle: String, maxWidth: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let baseFontSize: CGFloat = 48
        let hPadding: CGFloat = 10
        let vPadding: CGFloat = 5
        let font = TextStampFont.font(forId: fontId, style: fontStyle).withSize(baseFontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        // Measure each explicit line using same options as the render call
        // (boundingRect with .usesLineFragmentOrigin/.usesFontLeading) so sizes agree.
        let lines = text.components(separatedBy: "\n")
        var maxLineW: CGFloat = 0
        var totalH: CGFloat = 0
        for line in lines {
            let str = (line.isEmpty ? " " : line) as NSString
            let br = str.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs, context: nil)
            maxLineW = max(maxLineW, ceil(br.width))
            totalH += ceil(br.height)
        }

        // Add line spacing between lines
        let lineSpacing: CGFloat = baseFontSize * 0.15 * CGFloat(max(lines.count - 1, 0))
        let w = maxLineW + hPadding * 2
        let h = totalH + lineSpacing + vPadding * 2
        return (w, h, baseFontSize)
    }

    /// Compute cover-fit rect for background image in canvas
    func backgroundDrawRect(imgSize: CGSize, canvasSize: CGSize, offset: CGSize) -> CGRect {
        guard imgSize.width > 0, imgSize.height > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        let scale = max(canvasSize.width / imgSize.width, canvasSize.height / imgSize.height)
        let drawW = imgSize.width * scale
        let drawH = imgSize.height * scale
        // Center + apply offset
        let x = (canvasSize.width - drawW) / 2 + offset.width
        let y = (canvasSize.height - drawH) / 2 + offset.height
        return CGRect(x: x, y: y, width: drawW, height: drawH)
    }

    /// Clamp offset so image never exposes canvas background on any side
    func clampedBackgroundOffset(_ offset: CGSize) -> CGSize {
        guard let img = canvasBackgroundImage else { return .zero }
        let scale = max(canvasSize.width / img.size.width, canvasSize.height / img.size.height)
        let drawW = img.size.width * scale
        let drawH = img.size.height * scale
        let maxX = max(0, (drawW - canvasSize.width) / 2)
        let maxY = max(0, (drawH - canvasSize.height) / 2)
        return CGSize(
            width: min(maxX, max(-maxX, offset.width)),
            height: min(maxY, max(-maxY, offset.height))
        )
    }

    var canvasColorButton: some View {
        ZStack {
            if let img = canvasBackgroundImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipped()
            } else {
                canvasColor
            }
        }
        .frame(width: 42, height: 42)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.5), lineWidth: 2))
        .onTapGesture {
            bgNavPath = NavigationPath()
            saveBgStateForCancel()
            showCanvasBgSheet = true
        }
        .onLongPressGesture {
            // Long-press: jump straight to background editor (image backgrounds only)
            if canvasBackgroundImage != nil {
                saveBgStateForCancel()
                showBgEditor = true
            } else {
                bgNavPath = NavigationPath()
                showCanvasBgSheet = true
            }
        }
        .sheet(isPresented: $showCanvasImagePicker) {
            ImagePickerCallback { image in
                BackgroundPhotoHistory.shared.add(image) // async internally — won't block
                canvasBackgroundImage = image
                backgroundOffset = .zero
                resetBgEffects()
                // Go straight to effects screen, same as tapping a thumbnail
                pendingBgHistoryIndex = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    bgNavPath.append(0)
                }
            }
        }
        .sheet(isPresented: $showCanvasBgSheet, onDismiss: {
            if !bgPickerWasApplied {
                restoreSavedBgState()
            }
            bgPickerWasApplied = false
        }) {
            NavigationStack(path: $bgNavPath) {
                CanvasColorPickerView(currentIndex: canvasColorIndex,
                    onSelect: { newIndex in
                        bgPickerWasApplied = true
                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
                        redoStack = []
                        canvasColorIndex = newIndex
                        canvasBackgroundImage = nil
                        backgroundOffset = .zero
                        resetBgEffects()
                    }, onPickPhoto: {
                        showCanvasImagePicker = true
                    }, onPreviewPhoto: { img in
                        canvasBackgroundImage = img
                        backgroundOffset = .zero
                        resetBgEffects()
                    }, onGoToEffects: { idx in
                        pendingBgHistoryIndex = idx
                        bgNavPath.append(0)
                    }, onApply: { idx in
                        bgPickerWasApplied = true
                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: savedBgImage, backgroundOffset: savedBgOffset))
                        redoStack = []
                        BackgroundPhotoHistory.shared.moveToTop(at: idx)
                        showCanvasBgSheet = false
                    }, onPickerCancel: {
                        bgPickerWasApplied = true // restore already done here; skip onDismiss restore
                        restoreSavedBgState()
                    }, onExtractStamps: { img in
                        // dismiss picker (onDismiss will restore canvas state), then launch segmentation
                        showCanvasBgSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            bgSegmentationItem = SegmentationItem(images: [img])
                        }
                    }, initialHistoryIndex: {
                        guard canvasBackgroundImage != nil else { return nil }
                        return BackgroundPhotoHistory.shared.fullImages.isEmpty ? nil : 0
                    }())
                    .navigationDestination(for: Int.self) { _ in
                        BackgroundEditorView(
                            backgroundImage: canvasBackgroundImage,
                            canvasColor: canvasColor,
                            bgOpacity: $bgOpacity,
                            bgBlur: $bgBlur,
                            bgBrightness: $bgBrightness,
                            bgSaturation: $bgSaturation,
                            lines: lines,
                            stamps: placedStamps,
                            canvasSize: canvasSize,
                            onExtractionResult: { subject in
                                pendingExtractedSubject = subject
                            },
                            onCancel: {
                                restoreSavedBgState()
                                pendingBgHistoryIndex = nil
                                pendingExtractedSubject = nil
                                showCanvasBgSheet = false
                            },
                            onDone: {
                                bgPickerWasApplied = true
                                let hasBgChange = pendingBgHistoryIndex != nil
                                let hasStamp = pendingExtractedSubject != nil
                                if hasBgChange || hasStamp {
                                    undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: savedBgImage, backgroundOffset: savedBgOffset))
                                    redoStack = []
                                }
                                if let idx = pendingBgHistoryIndex {
                                    BackgroundPhotoHistory.shared.moveToTop(at: idx)
                                    pendingBgHistoryIndex = nil
                                }
                                if let subject = pendingExtractedSubject {
                                    let result = subject.croppedToContentWithOrigin()
                                    let cropped = result?.image ?? subject
                                    let cropOrigin = result?.origin ?? .zero
                                    let savedStamp = CustomStampManager.shared.addStamp(image: cropped, source: .photo)
                                    // Same fill scale as embedded overlay
                                    let fillScale = subject.size.width > 0 && subject.size.height > 0
                                        ? max(canvasSize.width / subject.size.width, canvasSize.height / subject.size.height)
                                        : 1.0
                                    let displayW = cropped.size.width * fillScale
                                    let displayH = cropped.size.height * fillScale
                                    // Project crop center from full-image space to canvas space
                                    let imgOriginX = (canvasSize.width  - subject.size.width  * fillScale) / 2
                                    let imgOriginY = (canvasSize.height - subject.size.height * fillScale) / 2
                                    let stampX = imgOriginX + (cropOrigin.x + cropped.size.width  / 2) * fillScale
                                    let stampY = imgOriginY + (cropOrigin.y + cropped.size.height / 2) * fillScale
                                    var stamp = PlacedStamp(emoji: "📷", position: CGPoint(x: stampX, y: stampY), size: max(displayW, displayH))
                                    stamp.inlineImage = cropped
                                    stamp.customImageId = savedStamp?.id  // disk fallback for dupe
                                    stamp.stampWidth = displayW
                                    stamp.stampHeight = displayH
                                    placedStamps.append(stamp)
                                    pendingExtractedSubject = nil
                                }
                                showCanvasBgSheet = false
                            }
                        )
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $bgSegmentationItem) { item in
            ObjectSegmentationSheet(images: item.images) { cutouts in
                bgSegmentationItem = nil
                var lastStamp: CustomStamp? = nil
                for cutout in cutouts {
                    if let stamp = CustomStampManager.shared.addStamp(image: cutout) {
                        lastStamp = stamp
                    }
                }
                if let stamp = lastStamp {
                    lastCustomStampIdString = stamp.id.uuidString
                    isCustomStampMode = true
                }
            }
        }
        .sheet(isPresented: $showBgEditor) {
            NavigationView {
                BackgroundEditorView(
                    backgroundImage: canvasBackgroundImage,
                    canvasColor: canvasColor,
                    bgOpacity: $bgOpacity,
                    bgBlur: $bgBlur,
                    bgBrightness: $bgBrightness,
                    bgSaturation: $bgSaturation,
                    lines: lines,
                    stamps: placedStamps,
                    canvasSize: canvasSize,
                    onExtractionResult: { subject in
                        pendingExtractedSubject = subject
                    },
                    onCancel: {
                        restoreSavedBgState()
                        pendingExtractedSubject = nil
                        showBgEditor = false
                    },
                    onDone: {
                        if let subject = pendingExtractedSubject {
                            undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: savedBgImage, backgroundOffset: savedBgOffset))
                            redoStack = []
                            let result = subject.croppedToContentWithOrigin()
                            let cropped = result?.image ?? subject
                            let cropOrigin = result?.origin ?? .zero
                            let savedStamp = CustomStampManager.shared.addStamp(image: cropped, source: .photo)
                            // Same fill scale as embedded overlay
                            let fillScale = subject.size.width > 0 && subject.size.height > 0
                                ? max(canvasSize.width / subject.size.width, canvasSize.height / subject.size.height)
                                : 1.0
                            let displayW = cropped.size.width * fillScale
                            let displayH = cropped.size.height * fillScale
                            // Project crop center from full-image space to canvas space
                            let imgOriginX = (canvasSize.width  - subject.size.width  * fillScale) / 2
                            let imgOriginY = (canvasSize.height - subject.size.height * fillScale) / 2
                            let stampX = imgOriginX + (cropOrigin.x + cropped.size.width  / 2) * fillScale
                            let stampY = imgOriginY + (cropOrigin.y + cropped.size.height / 2) * fillScale
                            var stamp = PlacedStamp(emoji: "📷", position: CGPoint(x: stampX, y: stampY), size: max(displayW, displayH))
                            stamp.inlineImage = cropped
                            stamp.customImageId = savedStamp?.id  // disk fallback for dupe
                            stamp.stampWidth = displayW
                            stamp.stampHeight = displayH
                            placedStamps.append(stamp)
                            pendingExtractedSubject = nil
                        }
                        showBgEditor = false
                    }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        // Canvas color — always rendered first so bg image opacity tints correctly
                        canvasColor
                        // Background image layer — rendered here so SwiftUI modifiers apply cleanly
                        if let bgImg = canvasBackgroundImage {
                            let imgW = bgImg.size.width, imgH = bgImg.size.height
                            let scale = imgW > 0 && imgH > 0 ? max(geo.size.width / imgW, geo.size.height / imgH) : 1
                            Image(uiImage: bgImg)
                                .resizable()
                                .frame(width: imgW * scale, height: imgH * scale)
                                .offset(x: backgroundOffset.width, y: backgroundOffset.height)
                                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                                .clipped()
                                .blur(radius: bgBlur, opaque: true)
                                .brightness(bgBrightness)
                                .saturation(bgSaturation)
                                .opacity(bgOpacity)
                                .allowsHitTesting(false)
                        }
                        DrawingCanvas(lines: $lines, undoStack: $undoStack, redoStack: $redoStack, currentColor: currentColor,
                                      lineWidth: $lineWidth, isEraser: $isEraser,
                                      canvasColor: canvasBackgroundImage != nil ? .clear : canvasColor,
                                      backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, penType: currentPenType,
                                      colorB: dualToneColorB,
                                      currentStamps: placedStamps,
                                      isLongPressing: isLongPressing,
                                      stampResizeTargetId: stampResizeTargetId)
                            .contentShape(Rectangle())
                            .allowsHitTesting(!isLongPressing)
                            .simultaneousGesture(TapGesture().onEnded {
                                selectedStampId = nil
                                showStampMagicMenu = false
                            })


                            .background(GeometryReader { geo in
                                Color.clear
                                    .onAppear {
                                        let frame = geo.frame(in: .global)
                                        canvasOriginInWindow = CGPoint(x: frame.minX, y: frame.minY)
                                    }
                                    .onChange(of: geo.frame(in: .global)) { _, frame in
                                        canvasOriginInWindow = CGPoint(x: frame.minX, y: frame.minY)
                                    }
                            })
                            .onAppear { canvasSize = geo.size }
                            .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
                        // Stamps layer — clipped to canvas bounds
                        ZStack {
                        // Stamps — UIKit interaction layer for pixel-accurate hit testing
                        StampCanvasView(
                            stamps: $placedStamps,
                            selectedStampId: $selectedStampId,
                            showStampMagicMenu: $showStampMagicMenu,
                            undoStack: $undoStack,
                            redoStack: $redoStack,
                            lines: $lines,
                            backgroundImage: $canvasBackgroundImage,
                            backgroundOffset: $backgroundOffset,
                            canvasSize: canvasSize,
                            rotatingId: $stampRotatingId
                        )
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .allowsHitTesting(true)
                        // Selection indicator — pulsing crosshair at stamp center
                        if let selId = selectedStampId, showStampMagicMenu,
                           let selStamp = placedStamps.first(where: { $0.id == selId }) {
                            PulsingCrosshair()
                                .allowsHitTesting(false)
                                .position(selStamp.position)
                        }
                        // Magic menu renders on top of all stamps
                        if showStampMagicMenu, let id = selectedStampId,
                           let stamp = placedStamps.first(where: { $0.id == id }) {
                            stampMagicMenuView(id: id, stamp: stamp)
                        }
                        // Window-level pinch + long press
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
                                    undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
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
                            onBackgroundPanBegan: canvasBackgroundImage != nil ? {
                                undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
                                redoStack = []
                            } : nil,
                            onBackgroundPan: canvasBackgroundImage != nil ? { delta in
                                let newOffset = CGSize(
                                    width: backgroundOffset.width + delta.width,
                                    height: backgroundOffset.height + delta.height
                                )
                                backgroundOffset = clampedBackgroundOffset(newOffset)
                            } : nil
                        )
                        } // end stamps ZStack
                        .coordinateSpace(name: "stampCanvas")
                        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                        .fixedSize()
                        .clipped()
                    }
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.25), lineWidth: 1))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            // Background color button — slightly larger, clearly different
                            canvasColorButton
                                .padding(.leading, 16)

                            // Eraser — prominently placed next to background button
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

                        HStack(spacing: 12) {
                            // Text stamp button — "T"
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

                            // Stamp button — LEFT of pen, enters/exits stamp mode or opens picker
                            StampToolButton(
                                selectedStamp: $selectedStamp,
                                placedStamps: $placedStamps,
                                stampUndoStack: $stampUndoStack,
                                selectedCustomStampId: $lastCustomStampIdString,
                                isCustomStampMode: $isCustomStampMode,
                                canvasSize: canvasSize
                            )
                            .onChange(of: selectedStamp) { _, _ in
                                guard !isCustomStampMode else { return }
                                autoPlaceStamp()
                            }
                            .onChange(of: lastCustomStampIdString) { _, newId in
                                guard isCustomStampMode, !newId.isEmpty else { return }
                                autoPlaceStamp()
                            }

                            // Pen Studio button — always just opens pen studio
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
                            .sheet(isPresented: $showPenStudio) {
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
                                            // Edit existing — update in place, recompute dimensions
                                            undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
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
                                let snapshot = CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset)
                                redoStack.append(snapshot)
                                let last = undoStack.removeLast()
                                lines = last.lines
                                placedStamps = last.stamps
                                canvasBackgroundImage = last.backgroundImage
                                backgroundOffset = last.backgroundOffset
                            }) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(undoStack.isEmpty ? .gray.opacity(0.4) : .blue)
                            }
                            .disabled(undoStack.isEmpty)
                            Button(action: {
                                guard !redoStack.isEmpty else { return }
                                let snapshot = CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset)
                                undoStack.append(snapshot)
                                let last = redoStack.removeLast()
                                lines = last.lines
                                placedStamps = last.stamps
                                canvasBackgroundImage = last.backgroundImage
                                backgroundOffset = last.backgroundOffset
                            }) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(redoStack.isEmpty ? .gray.opacity(0.4) : .blue)
                            }
                            .disabled(redoStack.isEmpty)
                            Button("Clear") {
                                let thingCount = (lines.isEmpty ? 0 : 1) + (placedStamps.isEmpty ? 0 : 1) + (canvasBackgroundImage != nil ? 1 : 0)
                                if thingCount == 1 {
                                    // Only one thing — clear it directly, no sheet
                                    undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
                                    redoStack = []
                                    if canvasBackgroundImage != nil { canvasBackgroundImage = nil; backgroundOffset = .zero }
                                    else if !lines.isEmpty { lines = [] }
                                    else if !placedStamps.isEmpty { placedStamps = []; stampUndoStack = []; stampRedoStack = [] }
                                } else {
                                    showClearSheet = true
                                }
                            }
                            .foregroundColor(lines.isEmpty && placedStamps.isEmpty && canvasBackgroundImage == nil ? .gray.opacity(0.4) : .red)
                            .font(.system(size: 16, weight: .medium))
                            .disabled(lines.isEmpty && placedStamps.isEmpty && canvasBackgroundImage == nil)
                            .confirmationDialog("Clear Canvas", isPresented: $showClearSheet, titleVisibility: .visible) {
                                // Sheet only shown when 2+ things exist — Clear All always relevant
                                Button("Clear All", role: .destructive) {
                                    undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
                                    redoStack = []
                                    lines = []
                                    placedStamps = []
                                    stampUndoStack = []
                                    stampRedoStack = []
                                    canvasBackgroundImage = nil
                                    backgroundOffset = .zero
                                }
                                if canvasBackgroundImage != nil {
                                    Button("Clear Background", role: .destructive) {
                                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
                                        redoStack = []
                                        canvasBackgroundImage = nil
                                        backgroundOffset = .zero
                                    }
                                }
                                if !lines.isEmpty {
                                    Button("Clear Drawing", role: .destructive) {
                                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
                                        redoStack = []
                                        lines = []
                                    }
                                }
                                if !placedStamps.isEmpty {
                                    Button("Clear Stamps", role: .destructive) {
                                        undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset))
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

                // Dimming overlay when result card is showing
                if showResultCard || isGeneratingCaption {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // Generating spinner overlay
                if isGeneratingCaption {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white)
                        Text("Processing...")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                    }
                }

                // Result card
                if showResultCard {
                    VStack {
                        Spacer()
                        VStack(spacing: 20) {
                            // Caption row
                            HStack(alignment: .center, spacing: 10) {
                                if isEditingCaption {
                                    TextField(aiFailed ? "Add a caption..." : resultCaption, text: $resultCaption)
                                        .font(.system(size: 18, weight: .semibold))
                                        .multilineTextAlignment(.center)
                                        .focused($captionFocused)
                                        .onAppear {
                                            if aiFailed {
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                    captionFocused = true
                                                }
                                            }
                                        }
                                } else {
                                    Text(resultCaption.isEmpty ? "Untitled" : resultCaption)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .multilineTextAlignment(.center)
                                }
                                Button(action: {
                                    isEditingCaption = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        captionFocused = true
                                    }
                                }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 24)

                            // Action buttons
                            VStack(spacing: 12) {
                                Button(action: { saveEntry(post: true) }) {
                                    HStack {
                                        Image(systemName: "globe")
                                        Text("Post to Community")
                                    }
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(Color.purple)
                                    .cornerRadius(14)
                                }

                                Button(action: { saveEntry(post: false) }) {
                                    Text("Keep Private")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 16)
                                        .background(Color(.systemGray5))
                                        .cornerRadius(14)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 32)
                        }
                        .background(Color(.systemBackground))
                        .cornerRadius(24)
                        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: -4)
                        .padding(.horizontal, 0)
                    }
                    .transition(.move(edge: .bottom))
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showResultCard)
                }
                // Thickness picker — last in ZStack so it renders above everything
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
            .navigationTitle("New Doodle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        if showResultCard {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                showResultCard = false
                            }
                        } else {
                            isPresented = false
                        }
                    }
                    .disabled(isGeneratingCaption)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isGeneratingCaption {
                        ProgressView().scaleEffect(0.8)
                    } else if !showResultCard {
                        Button("Done") { handleDone() }
                            .disabled(lines.isEmpty && placedStamps.isEmpty && canvasBackgroundImage == nil)
                            .fontWeight(.bold)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isGeneratingCaption)
            .animation(.easeInOut(duration: 0.2), value: showResultCard)
            .sheet(isPresented: $showSignInForPost) {
                SignInView(onComplete: {
                    saveEntry(post: true)
                }, showCancel: true)
            }
        }
        .interactiveDismissDisabled(true)
    }
}

// MARK: - Stamp Pinch View
// Pass-through view that only intercepts multi-touch (pinch), lets single touch fall through to SwiftUI
class PassThroughView: UIView {}

// MARK: - Window Level Pinch
// Attaches UIPinchGestureRecognizer to the window, bypassing hitTest completely
struct WindowPinchView: UIViewRepresentable {
    @Binding var placedStamps: [PlacedStamp]
    @Binding var stampResizeStartSize: CGFloat
    @Binding var stampResizeTargetId: UUID?
    @Binding var stampRotatingId: UUID?
    var canvasOrigin: CGPoint
    var canvasSize: CGSize
    var selectedStamp: String
    var onLongPress: (CGPoint) -> Void
    @Binding var isLongPressing: Bool
    var onBackgroundPanBegan: (() -> Void)? = nil
    var onBackgroundPan: ((CGSize) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            if let window = view.window {
                let pinch = UIPinchGestureRecognizer(
                    target: context.coordinator,
                    action: #selector(Coordinator.handlePinch(_:))
                )
                pinch.delegate = context.coordinator
                window.addGestureRecognizer(pinch)
                context.coordinator.pinchRecognizer = pinch

                let pan = UIPanGestureRecognizer(
                    target: context.coordinator,
                    action: #selector(Coordinator.handleBackgroundPan(_:))
                )
                pan.minimumNumberOfTouches = 2
                pan.maximumNumberOfTouches = 2
                pan.delegate = context.coordinator
                pan.cancelsTouchesInView = false
                window.addGestureRecognizer(pan)
                context.coordinator.backgroundPanRecognizer = pan

                let rotation = UIRotationGestureRecognizer(
                    target: context.coordinator,
                    action: #selector(Coordinator.handleRotation(_:))
                )
                rotation.delegate = context.coordinator
                window.addGestureRecognizer(rotation)
                context.coordinator.rotationRecognizer = rotation

                let longPress = UILongPressGestureRecognizer(
                    target: context.coordinator,
                    action: #selector(Coordinator.handleLongPress(_:))
                )
                longPress.minimumPressDuration = 0.6
                longPress.allowableMovement = 10
                longPress.cancelsTouchesInView = false
                longPress.delegate = context.coordinator
                window.addGestureRecognizer(longPress)
                context.coordinator.longPressRecognizer = longPress
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let window = uiView.window ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first {
            if let pinch = coordinator.pinchRecognizer {
                window.removeGestureRecognizer(pinch)
            }
            if let rotation = coordinator.rotationRecognizer {
                window.removeGestureRecognizer(rotation)
            }
            if let longPress = coordinator.longPressRecognizer {
                window.removeGestureRecognizer(longPress)
            }
            if let bgPan = coordinator.backgroundPanRecognizer {
                window.removeGestureRecognizer(bgPan)
            }
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: WindowPinchView
        var pinchRecognizer: UIPinchGestureRecognizer?
        var rotationRecognizer: UIRotationGestureRecognizer?
        var longPressRecognizer: UILongPressGestureRecognizer?
        var backgroundPanRecognizer: UIPanGestureRecognizer?
        private var lastPanTranslation: CGPoint = .zero
        var startCentroid: CGPoint = .zero
        var startPosition: CGPoint = .zero
        var startSize: CGFloat = 0
        var startWidth: CGFloat = 0
        var startHeight: CGFloat = 0
        var targetId: UUID? = nil
        var startRotation: Double = 0
        var longPressStampId: UUID? = nil
        var longPressStartLocation: CGPoint? = nil
        var emojiHitCache: [String: UIImage] = [:]

        init(_ parent: WindowPinchView) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { return true }

        // Pencil never triggers long press stamp placement — finger only
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer is UILongPressGestureRecognizer {
                return touch.type != .pencil && touch.type != .stylus
            }
            return true
        }

        @objc func handleBackgroundPan(_ g: UIPanGestureRecognizer) {
            // Only pan background if no stamp is being resized
            guard parent.stampResizeTargetId == nil else { return }
            switch g.state {
            case .began:
                lastPanTranslation = g.translation(in: g.view)
                parent.onBackgroundPanBegan?()
            case .changed:
                let t = g.translation(in: g.view)
                let delta = CGSize(width: t.x - lastPanTranslation.x, height: t.y - lastPanTranslation.y)
                parent.onBackgroundPan?(delta)
                lastPanTranslation = t
            default: break
            }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began:
                let c = centroid(g)
                // Collect individual touch points
                var touchPoints: [CGPoint] = []
                for i in 0..<g.numberOfTouches {
                    let wp = g.location(ofTouch: i, in: nil)
                    touchPoints.append(CGPoint(x: wp.x - parent.canvasOrigin.x,
                                               y: wp.y - parent.canvasOrigin.y))
                }
                // Pick the topmost stamp (last in array = highest z) that any finger
                // lands on — using opaque pixel test, falling back to bounding box.
                // For each touch point, find the topmost stamp whose opaque
                // pixel is actually hit (same logic as StampContainerView.hitTest).
                // The stamp that wins the most touch points becomes the target.
                var votes: [UUID: Int] = [:]
                for pt in touchPoints {
                    if let winner = parent.placedStamps.reversed().first(where: { stampHit(stamp: $0, canvasPt: pt) }) {
                        votes[winner.id, default: 0] += 1
                    }
                }
                let targetId2 = votes.max(by: { $0.value < $1.value })?.key
                let target = parent.placedStamps.first(where: { $0.id == targetId2 })
                if let stamp = target {
                    cancelAllStampPans()
                    targetId = stamp.id
                    startSize = stamp.size
                    startWidth = stamp.stampWidth
                    startHeight = stamp.stampHeight
                    startCentroid = c
                    startPosition = stamp.position
                    parent.stampResizeStartSize = stamp.size
                    parent.stampResizeTargetId = stamp.id
                    g.scale = 1.0
                }
            case .changed:
                guard g.numberOfTouches >= 2, let id = targetId,
                      let idx = parent.placedStamps.firstIndex(where: { $0.id == id }) else { return }
                let current = centroid(g)
                // Pinch controls size and position via centroid.
                // Safe now that UIPanGestureRecognizer is 1-finger only — no conflict.
                parent.placedStamps[idx].size = max(startSize * g.scale, 20)
                if startWidth > 0 {
                    parent.placedStamps[idx].stampWidth = max(startWidth * g.scale, 40)
                    parent.placedStamps[idx].stampHeight = max(startHeight * g.scale, 20)
                }
                parent.placedStamps[idx].position = CGPoint(
                    x: startPosition.x + (current.x - startCentroid.x),
                    y: startPosition.y + (current.y - startCentroid.y)
                )
            case .ended, .cancelled:
                if let window = g.view {
                    func findStampViews(_ view: UIView) -> [StampItemUIView] {
                        var found = view.subviews.compactMap { $0 as? StampItemUIView }
                        for sub in view.subviews { found += findStampViews(sub) }
                        return found
                    }
                    for sv in findStampViews(window) {
                        sv.recentlyPinched = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            sv.recentlyPinched = false
                        }
                    }
                }
                targetId = nil
                parent.stampResizeStartSize = 0
                parent.stampResizeTargetId = nil
            default: break
            }
        }

        @objc func handleRotation(_ g: UIRotationGestureRecognizer) {
            switch g.state {
            case .began:
                let c = rotationCentroid(g)
                var touchPoints: [CGPoint] = []
                for i in 0..<g.numberOfTouches {
                    let wp = g.location(ofTouch: i, in: nil)
                    touchPoints.append(CGPoint(x: wp.x - parent.canvasOrigin.x,
                                               y: wp.y - parent.canvasOrigin.y))
                }
                var votes: [UUID: Int] = [:]
                for pt in touchPoints {
                    if let winner = parent.placedStamps.reversed().first(where: { stampHit(stamp: $0, canvasPt: pt) }) {
                        votes[winner.id, default: 0] += 1
                    }
                }
                let targetId2 = votes.max(by: { $0.value < $1.value })?.key
                let target = parent.placedStamps.first(where: { $0.id == targetId2 })
                if let stamp = target {
                    cancelAllStampPans()
                    targetId = stamp.id
                    startRotation = stamp.rotation
                    startPosition = stamp.position
                    startCentroid = c
                    parent.stampRotatingId = stamp.id
                    g.rotation = 0
                }
            case .changed:
                guard let id = targetId,
                      let idx = parent.placedStamps.firstIndex(where: { $0.id == id }) else { return }
                parent.placedStamps[idx].rotation = startRotation + Double(g.rotation) * 180 / .pi
            case .ended, .cancelled:
                if let id = targetId, let stamp = parent.placedStamps.first(where: { $0.id == id }) {
                }
                parent.stampRotatingId = nil
                targetId = nil
            default: break
            }
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            let windowPt = g.location(in: nil)
            let canvasX = windowPt.x - parent.canvasOrigin.x
            let canvasY = windowPt.y - parent.canvasOrigin.y
            let loc = CGPoint(x: canvasX, y: canvasY)

            // Only handle if touch is within canvas bounds
            guard canvasX >= 0 && canvasY >= 0 &&
                  canvasX <= parent.canvasSize.width &&
                  canvasY <= parent.canvasSize.height else {
                return
            }

            switch g.state {
            case .began:
                parent.isLongPressing = true
                parent.onLongPress(loc)
                longPressStampId = parent.placedStamps.last?.id
                longPressStartLocation = loc

            case .changed:
                guard let id = longPressStampId,
                      let idx = parent.placedStamps.firstIndex(where: { $0.id == id }) else { return }
                parent.placedStamps[idx].position = loc

            case .ended, .cancelled:
                parent.isLongPressing = false
                longPressStampId = nil
                longPressStartLocation = nil

            default: break
            }
        }

        /// Cancels all active pan gestures on StampItemUIViews so they don't
        /// fight with a window-level pinch/rotation.
        func cancelAllStampPans() {
            guard let window = pinchRecognizer?.view else { return }
            func findStampViews(_ view: UIView) -> [StampItemUIView] {
                var found = view.subviews.compactMap { $0 as? StampItemUIView }
                for sub in view.subviews { found += findStampViews(sub) }
                return found
            }
            for sv in findStampViews(window) {
                for gr in sv.gestureRecognizers ?? [] {
                    if let pan = gr as? UIPanGestureRecognizer {
                        pan.isEnabled = false
                        pan.isEnabled = true   // disable+enable cancels an in-flight gesture
                    }
                }
            }
        }

        /// Returns true if canvasPt lands on an opaque pixel of stamp,
        /// falling back to bounding box if no image is available.
        func stampHit(stamp: PlacedStamp, canvasPt: CGPoint) -> Bool {
            // Quick bounding-box reject — use half diagonal of display rect
            let halfDiag = hypot(stamp.displayWidth, stamp.displayHeight) / 2
            let dist = hypot(stamp.position.x - canvasPt.x, stamp.position.y - canvasPt.y)
            guard dist <= halfDiag else { return false }

            // Transparent text stamps — hittable anywhere in bounding rect
            if stamp.isTextStamp && stamp.textBgColor == .clear {
                let dx = canvasPt.x - stamp.position.x
                let dy = canvasPt.y - stamp.position.y
                let angle = -stamp.rotation * .pi / 180
                let lx = dx * cos(angle) - dy * sin(angle) + stamp.displayWidth / 2
                let ly = dx * sin(angle) + dy * cos(angle) + stamp.displayHeight / 2
                return lx >= 0 && ly >= 0 && lx <= stamp.displayWidth && ly <= stamp.displayHeight
            }

            // Get hit image
            let hitImage: UIImage?
            if let customId = stamp.customImageId,
               let customStamp = CustomStampManager.shared.stamps.first(where: { $0.id == customId }) {
                hitImage = customStamp.image
            } else if let text = stamp.stampText {
                // Text stamp — render with background so whole box is hittable when bg set
                let hasBg = stamp.textBgColor != .clear
                let dw = stamp.displayWidth
                let dh = stamp.displayHeight
                let key = "txt_\(text.hashValue)_\(stamp.fontName ?? "system")_\(Int(dw))x\(Int(dh))_\(hasBg)"
                if let cached = emojiHitCache[key] {
                    hitImage = cached
                } else {
                    let fontSize = stamp.stampWidth > 0 ? stamp.size : fitTextFontSize(text: text, stampSize: dw, baseFontId: stamp.fontName)
                    let fmt = UIGraphicsImageRendererFormat()
                    fmt.opaque = hasBg
                    let img = UIGraphicsImageRenderer(size: CGSize(width: dw, height: dh), format: fmt).image { _ in
                        if hasBg {
                            UIColor(stamp.textBgColor).setFill()
                            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: dw, height: dh),
                                         cornerRadius: 8).fill()
                        }
                        let font = TextStampFont.font(forId: stamp.fontName, style: stamp.fontStyle).withSize(fontSize)
                        let nsAlignment: NSTextAlignment = stamp.textAlignment == "left" ? .left : stamp.textAlignment == "right" ? .right : .center
                        let para = NSMutableParagraphStyle()
                        para.alignment = nsAlignment
                        para.lineBreakMode = .byClipping
                        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(stamp.textColor), .paragraphStyle: para]
                        let str = text as NSString
                        let hPad: CGFloat = 10
                        let vPad: CGFloat = 5
                        let br = str.boundingRect(with: CGSize(width: dw - hPad * 2, height: dh - vPad * 2),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: attrs, context: nil)
                        str.draw(with: CGRect(x: hPad, y: (dh - br.height) / 2,
                                              width: dw - hPad * 2, height: br.height),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                 attributes: attrs, context: nil)
                    }
                    emojiHitCache[key] = img
                    hitImage = img
                }
            } else {
                // Emoji stamp
                let key = "\(stamp.emoji)_\(Int(stamp.size))"
                if let cached = emojiHitCache[key] {
                    hitImage = cached
                } else {
                    let s = stamp.size
                    let format = UIGraphicsImageRendererFormat()
                    format.opaque = false
                    let img = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: format).image { _ in
                        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: s * 0.85)]
                        let str = stamp.emoji as NSString
                        let sz = str.size(withAttributes: attrs)
                        str.draw(at: CGPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2), withAttributes: attrs)
                    }
                    emojiHitCache[key] = img
                    hitImage = img
                }
            }

            guard let img = hitImage, let cgImage = img.cgImage else { return true }

            // Rotate touch point into stamp-local space
            let dx = canvasPt.x - stamp.position.x
            let dy = canvasPt.y - stamp.position.y
            let angle = -stamp.rotation * .pi / 180
            let ux = dx * cos(angle) - dy * sin(angle)
            let uy = dx * sin(angle) + dy * cos(angle)
            // lx/ly are in stamp-local coords (0,0) = top-left of stamp square
            let lx = ux + stamp.displayWidth / 2
            let ly = uy + stamp.displayHeight / 2

            let imgW = CGFloat(cgImage.width)
            let imgH = CGFloat(cgImage.height)
            let dw2 = stamp.displayWidth
            let dh2 = stamp.displayHeight

            // Account for scaleAspectFit — image may not fill full stamp rect
            let scale = min(dw2 / imgW, dh2 / imgH)
            let fitW = imgW * scale
            let fitH = imgH * scale
            let offsetX = (dw2 - fitW) / 2
            let offsetY = (dh2 - fitH) / 2

            // Reject if touch is in letterbox area
            guard lx >= offsetX, ly >= offsetY,
                  lx < offsetX + fitW, ly < offsetY + fitH else { return false }

            let px = Int((lx - offsetX) / fitW * imgW)
            let pyUI = Int((ly - offsetY) / fitH * imgH)
            let pyCG = Int(imgH) - pyUI - 1
            guard px >= 0, pyCG >= 0, px < Int(imgW), pyCG < Int(imgH) else { return false }

            var pixel = [UInt8](repeating: 0, count: 4)
            guard let ctx = CGContext(data: &pixel, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return true }
            ctx.draw(cgImage, in: CGRect(x: -CGFloat(px), y: -CGFloat(pyCG), width: imgW, height: imgH))
            return pixel[3] > 25
        }

        func rotationCentroid(_ g: UIRotationGestureRecognizer) -> CGPoint {
            guard g.numberOfTouches >= 2 else { return .zero }
            let p0 = g.location(ofTouch: 0, in: nil)
            let p1 = g.location(ofTouch: 1, in: nil)
            let inWindow = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            return CGPoint(x: inWindow.x - parent.canvasOrigin.x, y: inWindow.y - parent.canvasOrigin.y)
        }

        func centroid(_ g: UIPinchGestureRecognizer) -> CGPoint {
            // Get position in window coordinates then convert to canvas coordinates
            let inWindow: CGPoint
            if g.numberOfTouches >= 2 {
                let p0 = g.location(ofTouch: 0, in: nil)
                let p1 = g.location(ofTouch: 1, in: nil)
                inWindow = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            } else if g.numberOfTouches == 1 {
                inWindow = g.location(ofTouch: 0, in: nil)
            } else {
                return .zero
            }
            // Convert from window to canvas coordinates
            return CGPoint(x: inWindow.x - parent.canvasOrigin.x, y: inWindow.y - parent.canvasOrigin.y)
        }
    }
}

// Synchronous flag readable by both .updating and .onEnded without going through
// SwiftUI state (which requires async dispatch and causes race conditions)
// UIView that overrides hitTest to skip transparent pixels on stamps.
// Wraps the stamps ZStack so touches on transparent areas fall through
// to the stamp below — something SwiftUI gesture system can't do.

private final class StampDragState {
    var isOpaque: Bool = true
    var startLocation: CGPoint? = nil
}

// MARK: - Stamp Item View
struct StampItemView: View {
    @Binding var stamp: PlacedStamp
    @Binding var selectedStampId: UUID?
    @Binding var showStampMagicMenu: Bool
    @Binding var stampResizeStartSize: CGFloat
    @Binding var stampResizeTargetId: UUID?
    @Binding var undoStack: [CanvasSnapshot]
    @Binding var redoStack: [CanvasSnapshot]
    @Binding var lines: [DrawingLine]
    @Binding var placedStamps: [PlacedStamp]
    let canvasSize: CGSize
    @Binding var draggingStampId: UUID?

    // @GestureState updates the view on every frame during drag — the SwiftUI way
    @GestureState private var dragOffset: CGSize = .zero
    private let dragState = StampDragState()
    @State private var emojiImage: UIImage? = nil
    @State private var lastTapTime: TimeInterval = 0
    @State private var lastTouchWasOpaque: Bool = true

    var isSelected: Bool { selectedStampId == stamp.id }

    // Render the emoji to a UIImage at the stamp's current size for alpha testing
    func hitTestImage() -> UIImage? {
        if let customId = stamp.customImageId,
           let customStamp = CustomStampManager.shared.stamps.first(where: { $0.id == customId }) {
            return customStamp.image
        }
        return emojiImage
    }

    func renderEmojiImage(size: CGFloat) -> UIImage {
        let s = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: s)
        return renderer.image { _ in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.85)
            ]
            let str = stamp.emoji as NSString
            let strSize = str.size(withAttributes: attrs)
            let origin = CGPoint(x: (size - strSize.width) / 2, y: (size - strSize.height) / 2)
            str.draw(at: origin, withAttributes: attrs)
        }
    }

    @ViewBuilder
    var stampContent: some View {
        if let customId = stamp.customImageId,
           let customStamp = CustomStampManager.shared.stamps.first(where: { $0.id == customId }),
           let img = customStamp.image {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else if let text = stamp.stampText {
            Text(text)
                .font(textStampSwiftUIFont(fontId: stamp.fontName, fontStyle: stamp.fontStyle, size: stamp.size * 0.55))
                .foregroundColor(stamp.textColor)
                .multilineTextAlignment(stamp.textAlignment == "left" ? .leading : stamp.textAlignment == "right" ? .trailing : .center)
                .lineLimit(nil)
                .minimumScaleFactor(0.3)
                .frame(width: stamp.size, height: stamp.size)
                .background(stamp.textBgColor == .clear ? Color.clear : stamp.textBgColor)
                .cornerRadius(stamp.textBgColor == .clear ? 0 : 8)
        } else {
            Text(stamp.emoji)
                .font(.system(size: stamp.size))
        }
    }

    func textStampSwiftUIFont(fontId: String?, fontStyle: String, size: CGFloat) -> Font {
        let isBold   = fontStyle == "bold"   || fontStyle == "bolditalic"
        let isItalic = fontStyle == "italic" || fontStyle == "bolditalic"

        func apply(_ base: Font) -> Font {
            var f = base
            if isBold   { f = f.bold() }
            if isItalic { f = f.italic() }
            return f
        }

        switch fontId {
        case "system":      return apply(.system(size: size))
        case "rounded":     return apply(.system(size: size, weight: .regular, design: .rounded))
        case "serif":       return apply(.custom("Georgia", size: size))
        case "mono":        return apply(.system(size: size, design: .monospaced))
        case "handwriting": return apply(.custom("SnellRoundhand", size: size))
        case "futura":      return apply(.custom("Futura-Medium", size: size))
        case "typewriter":  return apply(.custom("AmericanTypewriter", size: size))
        case "avenir":      return apply(.custom("Avenir-Book", size: size))
        case "chalkboard":  return apply(.custom("ChalkboardSE-Regular", size: size))
        case "didot":       return apply(.custom("Didot", size: size))
        case "marker":      return apply(.custom("MarkerFelt-Thin", size: size))
        case "gillsans":    return apply(.custom("GillSans", size: size))
        default:            return apply(.system(size: size))
        }
    }

    func isOpaqueAt(_ canvasPt: CGPoint, in image: UIImage) -> Bool {
        let dx = canvasPt.x - stamp.position.x
        let dy = canvasPt.y - stamp.position.y
        let angle = -stamp.rotation * .pi / 180
        let ux = dx * cos(angle) - dy * sin(angle)
        let uy = dx * sin(angle) + dy * cos(angle)
        let lx = ux + stamp.size / 2
        let ly = uy + stamp.size / 2
        guard let cgImage = image.cgImage else { return true }
        let imgPixelW = CGFloat(cgImage.width)
        let imgPixelH = CGFloat(cgImage.height)
        let px = Int(lx / stamp.size * imgPixelW)
        let pyUI = Int(ly / stamp.size * imgPixelH)
        let pyCG = Int(imgPixelH) - pyUI - 1
        guard px >= 0, pyCG >= 0, px < Int(imgPixelW), pyCG < Int(imgPixelH) else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1,
                                   bitsPerComponent: 8, bytesPerRow: 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }
        ctx.draw(cgImage, in: CGRect(x: -CGFloat(px), y: -CGFloat(pyCG), width: imgPixelW, height: imgPixelH))
        return pixel[3] > 25
    }

    var body: some View {
        // Single unified gesture handles tap, double-tap, and drag.
        // minimumDistance: 8 so pencil/finger drawing passes through untouched.
        // startLocation captured in updating so onEnded has it for alpha check.
        let dragGesture = DragGesture(minimumDistance: 8, coordinateSpace: .named("stampCanvas"))
            .updating($dragOffset) { val, state, _ in
                if let img = hitTestImage() {
                    let opaque = isOpaqueAt(val.startLocation, in: img)
                    dragState.isOpaque = opaque
                    if dragState.startLocation == nil {
                        DispatchQueue.main.async {
                            dragState.startLocation = val.startLocation
                            self.lastTouchWasOpaque = opaque
                        }
                    }
                    guard opaque else { return }
                } else {
                    dragState.isOpaque = true
                }
                state = val.translation
                if draggingStampId == nil {
                    DispatchQueue.main.async { draggingStampId = stamp.id }
                }
            }
            .onEnded { val in
                draggingStampId = nil
                dragState.startLocation = nil
                guard dragState.isOpaque else {
                    dragState.isOpaque = true
                    return
                }
                let vx = val.predictedEndTranslation.width - val.translation.width
                let vy = val.predictedEndTranslation.height - val.translation.height
                let speed = hypot(vx, vy)
                let stampId = stamp.id
                if speed > 200 {
                    if let idx = placedStamps.firstIndex(where: { $0.id == stampId }) {
                        if abs(vx) > abs(vy) {
                            placedStamps[idx].flipX.toggle()
                        } else {
                            placedStamps[idx].flipY.toggle()
                        }
                    }
                } else {
                    if let idx = placedStamps.firstIndex(where: { $0.id == stampId }) {
                        placedStamps[idx].position = CGPoint(
                            x: placedStamps[idx].position.x + val.translation.width,
                            y: placedStamps[idx].position.y + val.translation.height
                        )
                    }
                }
            }

        ZStack {
            stampContent
                .scaleEffect(x: stamp.flipX ? -1 : 1, y: stamp.flipY ? -1 : 1)
                .rotationEffect(.degrees(stamp.rotation))
                .frame(width: stamp.displayWidth, height: stamp.displayHeight)
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .gesture(TapGesture(count: 2).onEnded {
                    guard lastTouchWasOpaque else { return }
                    undoStack.append(CanvasSnapshot(lines: lines, stamps: placedStamps))
                    redoStack = []
                    placedStamps.removeAll { $0.id == stamp.id }
                    selectedStampId = nil
                    showStampMagicMenu = false
                })
                .simultaneousGesture(TapGesture(count: 1).onEnded {
                    let now = Date().timeIntervalSinceReferenceDate
                    let isDouble = (now - lastTapTime) < 0.35
                    lastTapTime = now
                    if isDouble { return }
                    guard lastTouchWasOpaque else {
                        selectedStampId = nil
                        showStampMagicMenu = false
                        return
                    }
                    selectedStampId = stamp.id
                    showStampMagicMenu = true
                    bringToFront()
                })
                .onAppear {
                    if stamp.customImageId == nil {
                        emojiImage = renderEmojiImage(size: stamp.size)
                    }
                }
                .position(CGPoint(
                    x: stamp.position.x + dragOffset.width,
                    y: stamp.position.y + dragOffset.height
                ))
            if isSelected && showStampMagicMenu {
                stampContent
                    .scaleEffect(x: stamp.flipX ? -1 : 1, y: stamp.flipY ? -1 : 1)
                    .rotationEffect(.degrees(stamp.rotation))
                    .frame(width: stamp.displayWidth, height: stamp.displayHeight)
                    .colorMultiply(Color(red: 0.45, green: 0.85, blue: 1.0))
                    .opacity(0.55)
                    .allowsHitTesting(false)
                    .position(CGPoint(
                        x: stamp.position.x + dragOffset.width,
                        y: stamp.position.y + dragOffset.height
                    ))
            }
        }
    }

    func bringToFront() {
        guard let idx = placedStamps.firstIndex(where: { $0.id == stamp.id }),
              idx != placedStamps.count - 1 else { return }
        let s = placedStamps.remove(at: idx)
        placedStamps.append(s)
    }
}

// MARK: - Pulsing Crosshair

struct PulsingCrosshair: View {
    @State private var pulsing = false

    var body: some View {
        let crossSize: CGFloat = 30
        let outerWidth: CGFloat = 6
        let innerWidth: CGFloat = 3

        ZStack {
            // White outer lines
            Rectangle()
                .fill(Color.white)
                .frame(width: crossSize, height: outerWidth)
            Rectangle()
                .fill(Color.white)
                .frame(width: outerWidth, height: crossSize)
            // Black inner lines
            Rectangle()
                .fill(Color.black)
                .frame(width: crossSize, height: innerWidth)
            Rectangle()
                .fill(Color.black)
                .frame(width: innerWidth, height: crossSize)
        }
        .scaleEffect(pulsing ? 1.45 : 0.85)
        .opacity(pulsing ? 1.0 : 0.6)
        .animation(
            .easeInOut(duration: 0.65).repeatForever(autoreverses: true),
            value: pulsing
        )
        .onAppear { pulsing = true }
    }
}

// MARK: - Detail / Swipe View
// Single consolidated view for viewing doodles.
// Pass a list of entries (full gallery or just one day) and a starting index.
// Swipe left/right to navigate within that list.

