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
import CoreImage
import CoreImage.CIFilterBuiltins

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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var existingFull = self.loadRaw(key: self.fullKey)
            var existingThumbs = self.loadRaw(key: self.thumbKey)
            var existingIds = self.loadIds()
            if index < existingFull.count { existingFull.remove(at: index) }
            if index < existingThumbs.count { existingThumbs.remove(at: index) }
            if index < existingIds.count { existingIds.remove(at: index) }
            self.save(existingFull, key: self.fullKey)
            self.save(existingThumbs, key: self.thumbKey)
            UserDefaults.standard.set(existingIds, forKey: self.idKey)
            DispatchQueue.main.async { self.load() }
        }
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
    let currentColor: Color
    let onSelectColor: (Color) -> Void
    var onPickPhoto: (() -> Void)? = nil
    var onPreviewPhoto: ((UIImage) -> Void)? = nil
    var onGoToEffects: ((Int) -> Void)? = nil
    var onApply: ((Int) -> Void)? = nil
    var onPickerCancel: (() -> Void)? = nil
    var onExtractStamps: ((UIImage) -> Void)? = nil
    var initialHistoryIndex: Int? = nil
    @Environment(\.dismiss) var dismiss
    @State private var selectedColor: Color
    @State private var wipSelectedIndex: Int? = nil
    @State private var recentColors: [Color] = RecentCanvasColors.load()
    @State private var showColorPicker = false
    @State private var pickerColor: Color = .white
    @ObservedObject private var history = BackgroundPhotoHistory.shared

    init(currentColor: Color, onSelectColor: @escaping (Color) -> Void, onPickPhoto: (() -> Void)? = nil,
         onPreviewPhoto: ((UIImage) -> Void)? = nil, onGoToEffects: ((Int) -> Void)? = nil,
         onApply: ((Int) -> Void)? = nil, onPickerCancel: (() -> Void)? = nil,
         onExtractStamps: ((UIImage) -> Void)? = nil, initialHistoryIndex: Int? = nil) {
        self.currentColor = currentColor
        self.onSelectColor = onSelectColor
        self.onPickPhoto = onPickPhoto
        self.onPreviewPhoto = onPreviewPhoto
        self.onGoToEffects = onGoToEffects
        self.onApply = onApply
        self.onPickerCancel = onPickerCancel
        self.onExtractStamps = onExtractStamps
        self.initialHistoryIndex = initialHistoryIndex
        _selectedColor = State(initialValue: currentColor)
        _wipSelectedIndex = State(initialValue: initialHistoryIndex)
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                    // MARK: Color row (top)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            Button {
                                pickerColor = selectedColor
                                showColorPicker = true
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color(UIColor.secondarySystemBackground))
                                        .frame(width: 42, height: 42)
                                        .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
                                    Image(systemName: "plus")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.primary)
                                }
                            }
                            .colorPickerSheet(isPresented: $showColorPicker, color: $pickerColor) { newColor in
                                recentColors = RecentCanvasColors.add(newColor)
                                selectedColor = newColor
                                onSelectColor(newColor)
                                dismiss()
                            }
                            ForEach(recentColors, id: \.self) { color in
                                ColorSwatchView(color: color, size: 42,
                                                isSelected: color.isApproximatelyEqual(to: selectedColor))
                                    .shadow(color: .black.opacity(0.1), radius: 3)
                                    .onTapGesture {
                                        selectedColor = color
                                        onSelectColor(color)
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
    @State private var recentColors: [Color] = RecentColors.load()
    @State private var showColorBPicker = false

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

                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(DualToneStyle.allCases) { style in
                                            DualToneStyleChip(style: style, isSelected: penType.dualToneStyle == style)
                                                .id(style.id)
                                                .onTapGesture {
                                                    selectedDualStyle = style
                                                    penType = .dualTone(style)
                                                    UserDefaults.standard.set(style.rawValue, forKey: "lastDualToneStyle")
                                                }
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                }
                                .onAppear {
                                    proxy.scrollTo(penType.dualToneStyle.id, anchor: .center)
                                }
                            }

                            // Second color picker
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Second Color")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 20)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        Button { showColorBPicker = true } label: {
                                            ZStack {
                                                Circle().fill(Color(UIColor.secondarySystemBackground))
                                                    .frame(width: 36, height: 36)
                                                Image(systemName: "plus.circle.fill")
                                                    .font(.system(size: 24))
                                                    .foregroundColor(.blue)
                                            }
                                        }
                                        .colorPickerSheet(isPresented: $showColorBPicker, color: $colorB) { picked in
                                            recentColors = RecentColors.add(picked)
                                            colorB = picked
                                        }
                                        ForEach(recentColors, id: \.self) { color in
                                            ColorSwatchView(color: color, size: 36,
                                                            isSelected: colorB.isApproximatelyEqual(to: color),
                                                            selectionColor: .purple)
                                                .shadow(color: .black.opacity(0.08), radius: 2)
                                                .onTapGesture {
                                                    colorB = color
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
        case .braid:       return "link"
        case .hairy:       return "sun.min"
        case .thorns:      return "bolt"
        case .zigzag:      return "waveform.path.ecg"
        case .bubble:      return "circle.grid.3x3"
        case .stars:       return "star"
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

// MARK: - Module-level stamp hit test (shared by canvas tap gesture and WindowPinchView)
private var _stampHitImageCache: [String: UIImage] = [:]

func stampHitTest(stamp: PlacedStamp, canvasPt: CGPoint) -> Bool {
    let halfDiag = hypot(stamp.displayWidth, stamp.displayHeight) / 2
    let dist = hypot(stamp.position.x - canvasPt.x, stamp.position.y - canvasPt.y)
    guard dist <= halfDiag else { return false }

    if stamp.isTextStamp && stamp.textBgColor == .clear {
        let dx = canvasPt.x - stamp.position.x
        let dy = canvasPt.y - stamp.position.y
        let angle = -stamp.rotation * .pi / 180
        let lx = dx * cos(angle) - dy * sin(angle) + stamp.displayWidth / 2
        let ly = dx * sin(angle) + dy * cos(angle) + stamp.displayHeight / 2
        return lx >= 0 && ly >= 0 && lx <= stamp.displayWidth && ly <= stamp.displayHeight
    }

    let hitImage: UIImage?
    if let inline = stamp.inlineImage {
        hitImage = inline
    } else if let customId = stamp.customImageId,
              let customStamp = CustomStampManager.shared.stamps.first(where: { $0.id == customId }) {
        hitImage = customStamp.image
    } else if let text = stamp.stampText {
        let hasBg = stamp.textBgColor != .clear
        let dw = stamp.displayWidth, dh = stamp.displayHeight
        let key = "txt_\(text.hashValue)_\(stamp.fontName ?? "system")_\(Int(dw))x\(Int(dh))_\(hasBg)"
        if let cached = _stampHitImageCache[key] {
            hitImage = cached
        } else {
            let fontSize = stamp.stampWidth > 0 ? stamp.size : fitTextFontSize(text: text, stampSize: dw, baseFontId: stamp.fontName)
            let fmt = UIGraphicsImageRendererFormat(); fmt.opaque = hasBg
            let img = UIGraphicsImageRenderer(size: CGSize(width: dw, height: dh), format: fmt).image { _ in
                if hasBg {
                    UIColor(stamp.textBgColor).setFill()
                    UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: dw, height: dh), cornerRadius: 8).fill()
                }
                let font = TextStampFont.font(forId: stamp.fontName, style: stamp.fontStyle).withSize(fontSize)
                let nsAlign: NSTextAlignment = stamp.textAlignment == "left" ? .left : stamp.textAlignment == "right" ? .right : .center
                let para = NSMutableParagraphStyle(); para.alignment = nsAlign; para.lineBreakMode = .byClipping
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(stamp.textColor), .paragraphStyle: para]
                let str = text as NSString
                let br = str.boundingRect(with: CGSize(width: dw - 20, height: dh - 10),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
                str.draw(with: CGRect(x: 10, y: (dh - br.height) / 2, width: dw - 20, height: br.height),
                         options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
            }
            _stampHitImageCache[key] = img; hitImage = img
        }
    } else {
        let key = "\(stamp.emoji)_\(Int(stamp.size))"
        if let cached = _stampHitImageCache[key] {
            hitImage = cached
        } else {
            let s = stamp.size
            let fmt = UIGraphicsImageRendererFormat(); fmt.opaque = false
            let img = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { _ in
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: s * 0.85)]
                let str = stamp.emoji as NSString
                let sz = str.size(withAttributes: attrs)
                str.draw(at: CGPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2), withAttributes: attrs)
            }
            _stampHitImageCache[key] = img; hitImage = img
        }
    }

    guard let img = hitImage, let cgImage = img.cgImage else { return true }

    let dx = canvasPt.x - stamp.position.x
    let dy = canvasPt.y - stamp.position.y
    let angle = -stamp.rotation * .pi / 180
    let lx = dx * cos(angle) - dy * sin(angle) + stamp.displayWidth / 2
    let ly = dx * sin(angle) + dy * cos(angle) + stamp.displayHeight / 2
    let imgW = CGFloat(cgImage.width), imgH = CGFloat(cgImage.height)
    let dw2 = stamp.displayWidth, dh2 = stamp.displayHeight
    let scale = min(dw2 / imgW, dh2 / imgH)
    let fitW = imgW * scale, fitH = imgH * scale
    let offX = (dw2 - fitW) / 2, offY = (dh2 - fitH) / 2
    guard lx >= offX, ly >= offY, lx < offX + fitW, ly < offY + fitH else { return false }
    let px = Int((lx - offX) / fitW * imgW)
    let pyUI = Int((ly - offY) / fitH * imgH)
    let pyCG = Int(imgH) - pyUI - 1
    guard px >= 0, pyCG >= 0, px < Int(imgW), pyCG < Int(imgH) else { return false }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
    ctx.draw(cgImage, in: CGRect(x: -CGFloat(px), y: -CGFloat(pyCG), width: imgW, height: imgH))
    return pixel[3] > 25
}

/// Run Vision instance segmentation on `image` and return each extracted object
/// paired with its origin in the source image's point coordinates.
/// Used by extractDrawingLayerAsStamp to position stamps at their original canvas location.
func extractObjectsWithOrigins(from image: UIImage) async -> [(image: UIImage, origin: CGPoint)] {
    let normalized = image.normalizedOrientation()
    guard let cgImage = normalized.cgImage else { return [] }
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
        guard let result = request.results?.first else { return [] }
        var found: [(image: UIImage, origin: CGPoint)] = []
        for index in result.allInstances {
            let maskHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            guard let maskBuffer = try? result.generateScaledMaskForImage(
                    forInstances: IndexSet([index]), from: maskHandler) else { continue }
            let maskCI = CIImage(cvPixelBuffer: maskBuffer)
            let originalCI = CIImage(cgImage: cgImage)
            let filter = CIFilter.blendWithMask()
            filter.inputImage = originalCI
            filter.maskImage = maskCI
            filter.backgroundImage = CIImage.empty()
            guard let output = filter.outputImage else { continue }
            let ctx = CIContext()
            guard let rendered = ctx.createCGImage(output, from: output.extent) else { continue }
            let full = UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
            if let (cropped, origin) = full.croppedToContentWithOrigin() {
                found.append((image: cropped, origin: origin))
            }
        }
        return found
    } catch {
        return []
    }
}

/// Returns the topmost stamp hit at canvasPt, respecting visual z-order from layerOrder.
/// layerOrder is bottom-first (last = topmost), so we iterate reversed().
func topmostStampHit(at pt: CGPoint, layerOrder: [LayerEntry], stamps: [PlacedStamp]) -> PlacedStamp? {
    for entry in layerOrder.reversed() {
        guard case .stamp(let sid) = entry,
              let s = stamps.first(where: { $0.id == sid }) else { continue }
        if stampHitTest(stamp: s, canvasPt: pt) { return s }
    }
    return nil
}

struct LayerOpacitySheet: View {
    let targetId: UUID?
    @Binding var drawingLayers: [DrawingLayer]
    @Binding var placedStamps: [PlacedStamp]
    let pushSnapshot: () -> Void

    @State private var sliderValue: Double = 1.0
    @State private var snapshotPushed: Bool = false

    private var currentOpacity: Double {
        if let id = targetId {
            if let idx = drawingLayers.firstIndex(where: { $0.id == id }) {
                return drawingLayers[idx].opacity
            } else if let idx = placedStamps.firstIndex(where: { $0.id == id }) {
                return placedStamps[idx].opacity
            }
        }
        return 1.0
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Layer Opacity")
                .font(.headline)
                .padding(.top, 20)
            HStack {
                Text("0%").font(.caption).foregroundColor(.secondary)
                Slider(value: $sliderValue, in: 0...1) { editing in
                    if editing && !snapshotPushed {
                        pushSnapshot()
                        snapshotPushed = true
                    }
                }
                Text("100%").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            Text("\(Int(sliderValue * 100))%")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .onAppear {
            sliderValue = currentOpacity
            snapshotPushed = false
        }
        .onChange(of: sliderValue) { newVal in
            guard let id = targetId else { return }
            if let idx = drawingLayers.firstIndex(where: { $0.id == id }) {
                drawingLayers[idx].opacity = newVal
            } else if let idx = placedStamps.firstIndex(where: { $0.id == id }) {
                placedStamps[idx].opacity = newVal
            }
        }
    }
}

struct DrawScreen: View {
    @EnvironmentObject var store: SnoodleStore
    @Binding var isPresented: Bool
    @Binding var selectedTab: Int
    var entryToEdit: SnoodleEntry? = nil

    // Drawing layers — new interleaved layer architecture.
    // The active layer is always the last .drawing entry in layerOrder.
    private static let _initialLayerId = UUID()
    @State private var drawingLayers: [DrawingLayer] = []
    @State private var layerOrder: [LayerEntry] = []
    @State private var currentLine: DrawingLine? = nil   // live preview during active stroke

    @State private var lineWidth: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "lastLineWidth") == 0 ? 4 : UserDefaults.standard.double(forKey: "lastLineWidth"))
    @State private var otherWidth: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "lastEraserWidth") == 0 ? 20 : UserDefaults.standard.double(forKey: "lastEraserWidth"))
    @State private var isEraser: Bool = false
    @State private var showLayersPanel: Bool = false
    @State private var userSelectedLayerId: UUID? = nil
    /// True only when the user has explicitly tapped a drawing layer chip in the panel.
    /// Cleared on stamp placement and canvas tap so the next draw creates a new layer above any top stamp.
    @State private var explicitLayerSelection: Bool = false
    /// When set, onBeforeDraw inserts the new drawing layer just above this stamp id
    /// instead of appending to the top of the stack.
    @State private var pendingInsertAboveStampId: UUID? = nil
    @State private var layersPanelOffset: CGSize = .zero
    @State private var layersPanelBaseOffset: CGSize = .zero
    @State private var chipSwipeOffsets: [UUID: CGFloat] = [:]
    @State private var hiddenLayerIds: Set<UUID> = []
    @State private var isExtractingLayer: Bool = false
    @State private var opacityTargetId: UUID? = nil
    @State private var showOpacitySheet: Bool = false
    @State private var isGeneratingCaption: Bool = false
    @State private var showRestoreAlert: Bool = false
    @State private var showLegacyImportBanner: Bool = false
    @State private var canvasSize: CGSize = CGSize(width: 300, height: 300)
    @State private var undoStack: [CanvasSnapshot] = []
    @State private var redoStack: [CanvasSnapshot] = []
    @AppStorage("lastPenColorIndex") private var selectedColorIndex: Int = 0
    @State private var recentColors: [Color] = RecentColors.load()
    @State private var showPenColorPicker = false
    @State private var penPickerColor: Color = .black
    @State private var selectedCanvasColor: Color = RecentCanvasColors.loadSelected()
    @State private var recentCanvasColors: [Color] = RecentCanvasColors.load()
    @State private var showCanvasColorPicker = false
    @State private var canvasColorPickerColor: Color = .white

    // Result card state
    @State private var showResultCard: Bool = false
    @State private var resultCaption: String = ""
    @State private var resultKeywords: [String] = []
    @State private var resultImage: UIImage? = nil
    @State private var isEditingCaption: Bool = false
    @State private var aiFailed: Bool = false
    @FocusState private var captionFocused: Bool

    var currentColor: Color { selectedColorIndex < recentColors.count ? recentColors[selectedColorIndex] : .black }
    var canvasColor: Color { selectedCanvasColor }

    // MARK: - Layer helpers

    /// ID of the topmost drawing layer (active layer for new strokes).
    var activeDrawingLayerId: UUID? {
        // If the user explicitly selected a drawing layer, use it (if still in layerOrder)
        if let selected = userSelectedLayerId,
           layerOrder.contains(where: { if case .drawing(let id) = $0 { return id == selected } else { return false } }) {
            return selected
        }
        // Default: topmost drawing layer
        for entry in layerOrder.reversed() {
            if case .drawing(let id) = entry { return id }
        }
        return nil
    }

    /// Index into drawingLayers[] of the active layer.
    var activeDrawingLayerIndex: Int {
        guard let id = activeDrawingLayerId else { return 0 }
        return drawingLayers.firstIndex(where: { $0.id == id }) ?? 0
    }

    /// All visible lines flattened (used for BackgroundEditorView preview). Respects hidden layers.
    var allDrawingLines: [DrawingLine] { drawingLayers.filter { !hiddenLayerIds.contains($0.id) }.flatMap { $0.lines } }

    /// The layer that should receive the live eraser preview.
    var eraserTargetLayerId: UUID? {
        guard isEraser, currentLine != nil else { return activeDrawingLayerId }
        return activeDrawingLayerId
    }

    /// Remove a stamp entry from layerOrder after deletion.
    /// Adjacent drawing layers are valid state and are intentionally left as-is.
    func removeStampFromLayerOrder(_ id: UUID) {
        layerOrder.removeAll { entry in
            if case .stamp(let sid) = entry { return sid == id }
            return false
        }
    }

    /// Merge consecutive drawing entries in layerOrder into one.
    /// Not called automatically — adjacent drawing layers are valid state.
    /// Available for an explicit user-facing "Merge Layers" action in the future.
    func consolidateDrawingLayers() {
        var newOrder: [LayerEntry] = []
        var i = 0
        while i < layerOrder.count {
            if case .drawing(let firstId) = layerOrder[i] {
                // Collect IDs of any subsequent consecutive drawing entries
                var j = i + 1
                var idsToMerge: [UUID] = []
                while j < layerOrder.count, case .drawing(let nextId) = layerOrder[j] {
                    idsToMerge.append(nextId)
                    j += 1
                }
                // Merge their lines into firstId, then remove them
                if !idsToMerge.isEmpty,
                   let intoIdx = drawingLayers.firstIndex(where: { $0.id == firstId }) {
                    for mergeId in idsToMerge {
                        if let fromIdx = drawingLayers.firstIndex(where: { $0.id == mergeId }) {
                            drawingLayers[intoIdx].lines.append(contentsOf: drawingLayers[fromIdx].lines)
                        }
                    }
                    let removeIds = Set(idsToMerge)
                    drawingLayers.removeAll { removeIds.contains($0.id) }
                }
                newOrder.append(.drawing(firstId))
                i = j
            } else {
                newOrder.append(layerOrder[i])
                i += 1
            }
        }
        layerOrder = newOrder
    }

    // MARK: - Layers Panel

    /// SwiftUI Canvas thumbnail for a drawing layer — uses renderLine so pen types and eraser display correctly.
    @ViewBuilder
    func drawingLayerCanvas(lines: [DrawingLine], chipW: CGFloat, chipH: CGFloat) -> some View {
        let cw = max(canvasSize.width, 1)
        Canvas { context, size in
            let scale = size.width / cw   // width-based only — preserves horizontal positions
            context.concatenate(CGAffineTransform(scaleX: scale, y: scale))
            for line in lines {
                renderLine(line, in: &context, canvasColor: .white)
            }
        }
        .background(Color.white)
        .frame(width: chipW, height: chipH)
        .clipped()
    }

    func canDeleteLayerEntry(_ entry: LayerEntry) -> Bool {
        // All layers are deletable — if no drawing layers remain, onBeforeDraw lazily creates one on first stroke
        return true
    }

    /// Ensures a drawing layer is always highlighted in the panel.
    /// Called whenever the panel opens or layers change. No-op if a stamp is selected.
    func ensureLayerSelection() {
        guard selectedStampId == nil else { return }
        let validSelection = userSelectedLayerId.flatMap { id in
            layerOrder.first { if case .drawing(let eid) = $0 { return eid == id } else { return false } }
        }
        if validSelection == nil {
            userSelectedLayerId = layerOrder.reversed().compactMap {
                if case .drawing(let id) = $0 { return id } else { return nil }
            }.first
        }
    }

    /// Select a stamp and set up the correct drawing context above it.
    /// - If the entry immediately above the stamp is a draw layer → activate that layer.
    /// - If the entry immediately above is another stamp (or stamp is at top) →
    ///   set pendingInsertAboveStampId so onBeforeDraw inserts a new layer right there.
    func activateStamp(id: UUID) {
        selectedStampId = id
        showStampMagicMenu = true
        pendingInsertAboveStampId = nil
        guard let stampIdx = layerOrder.firstIndex(where: { $0.id == id }) else { return }
        let nextIdx = stampIdx + 1
        if nextIdx < layerOrder.count, case .drawing(let drawId) = layerOrder[nextIdx] {
            // Draw layer immediately above — use it directly.
            userSelectedLayerId = drawId
        } else {
            // Stamp above (or top of stack) — signal onBeforeDraw to insert here.
            pendingInsertAboveStampId = id
        }
    }

    func moveLayerEntry(_ entry: LayerEntry, by delta: Int) {
        guard let idx = layerOrder.firstIndex(where: { $0.id == entry.id }) else { return }
        let newIdx = idx + delta
        guard newIdx >= 0 && newIdx < layerOrder.count else { return }
        pushUndoSnapshot()
        layerOrder.swapAt(idx, newIdx)
    }

    func deleteLayerEntry(_ entry: LayerEntry) {
        pushUndoSnapshot()
        switch entry {
        case .drawing(let id):
            layerOrder.removeAll { if case .drawing(let eid) = $0 { return eid == id } else { return false } }
            drawingLayers.removeAll { $0.id == id }
            if userSelectedLayerId == id {
                // Select the topmost remaining drawing layer, or nil if none left
                userSelectedLayerId = layerOrder.reversed().compactMap {
                    if case .drawing(let lid) = $0 { return lid } else { return nil }
                }.first
            }
        case .stamp(let id):
            placedStamps.removeAll { $0.id == id }
            removeStampFromLayerOrder(id)
            if selectedStampId == id { selectedStampId = nil; showStampMagicMenu = false }
        }
        chipSwipeOffsets[entry.id] = 0
    }

    @ViewBuilder
    func stampChipContent(id: UUID, chipW: CGFloat, chipH: CGFloat) -> some View {
        if let stamp = placedStamps.first(where: { $0.id == id }) {
            let scale = chipW / max(canvasSize.width, 1)
            let scaled: PlacedStamp = {
                var s = stamp
                s.position = CGPoint(x: stamp.position.x * scale, y: stamp.position.y * scale)
                s.size = stamp.size * scale
                if stamp.stampWidth  > 0 { s.stampWidth  = stamp.stampWidth  * scale }
                if stamp.stampHeight > 0 { s.stampHeight = stamp.stampHeight * scale }
                return s
            }()
            ZStack {
                Color.white
                StampRenderView(stamp: scaled)
            }
            .frame(width: chipW, height: chipH)
            .clipped()
        }
    }

    @ViewBuilder
    func layerChipView(entry: LayerEntry) -> some View {
        let chipW: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 112 : 84
        // Maintain canvas aspect ratio, cap at 90pt so a few chips are always visible
        let chipH: CGFloat = chipW * max(canvasSize.height, 1) / max(canvasSize.width, 1)
        let isActive: Bool = {
            if case .drawing(let id) = entry { return id == userSelectedLayerId && selectedStampId == nil }
            if case .stamp(let id) = entry { return id == selectedStampId }
            return false
        }()

        let swipeOffset = chipSwipeOffsets[entry.id] ?? 0
        let deletable = canDeleteLayerEntry(entry)

        ZStack(alignment: .trailing) {
            // Red trash revealed behind chip when swiped left
            if deletable {
                Button {
                    deleteLayerEntry(entry)
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .frame(width: 44, height: chipH)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .opacity(swipeOffset < -8 ? 1 : 0)
            }

            // Chip content
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(UIColor.systemBackground))

                if case .drawing(let id) = entry,
                   let layer = drawingLayers.first(where: { $0.id == id }) {
                    if !layer.lines.isEmpty && layer.lines.allSatisfy({ $0.isEraser }) {
                        // Eraser-only layer — show eraser icon so user knows what it is
                        Image(systemName: "eraser.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.gray.opacity(0.5))
                    } else {
                        drawingLayerCanvas(lines: layer.lines, chipW: chipW, chipH: chipH)
                    }
                } else if case .stamp(let id) = entry {
                    stampChipContent(id: id, chipW: chipW, chipH: chipH)
                }
            }
            .frame(width: chipW, height: chipH)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? Color(UIColor.systemGray) : Color.clear, lineWidth: 2)
                .padding(2))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? Color.yellow : Color.gray.opacity(0.3),
                        lineWidth: isActive ? 3.5 : 1))
            .offset(x: swipeOffset)
            .contentShape(Path(CGRect(x: 0, y: 0, width: max(0, chipW + swipeOffset), height: chipH)))
            .overlay(
                HSwipeView(
                    currentOffset: swipeOffset,
                    chipWidth: chipW,
                    onChanged: { newOffset in
                        guard deletable else { return }
                        chipSwipeOffsets[entry.id] = max(min(newOffset, 0), -54)
                    },
                    onEnded: { newOffset in
                        guard deletable else { return }
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            // When already fully open, any rightward movement closes
                            if swipeOffset <= -40 {
                                chipSwipeOffsets[entry.id] = newOffset > -50 ? 0 : -54
                            } else {
                                chipSwipeOffsets[entry.id] = newOffset < -27 ? -54 : 0
                            }
                        }
                    }
                )
            )
            .onTapGesture {
                if swipeOffset != 0 {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        chipSwipeOffsets[entry.id] = 0
                    }
                    return
                }
                if case .drawing(let id) = entry {
                    userSelectedLayerId = id
                    explicitLayerSelection = true
                    selectedStampId = nil
                    showStampMagicMenu = false
                } else if case .stamp(let id) = entry {
                    activateStamp(id: id)
                }
            }
            // ··· menu and hidden badge — all layer types
            .overlay(alignment: .topTrailing) {
                if case .stamp(let id) = entry {
                    HStack(spacing: 3) {
                        if hiddenLayerIds.contains(id) {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.6), radius: 1)
                        }
                        Menu {
                            Button {
                                if hiddenLayerIds.contains(id) {
                                    hiddenLayerIds.remove(id)
                                } else {
                                    hiddenLayerIds.insert(id)
                                    // Deselect hidden stamp — close magic menu
                                    if selectedStampId == id {
                                        selectedStampId = nil
                                        showStampMagicMenu = false
                                    }
                                }
                            } label: {
                                Label(hiddenLayerIds.contains(id) ? "Show Stamp" : "Hide Stamp",
                                      systemImage: hiddenLayerIds.contains(id) ? "eye" : "eye.slash")
                            }
                            Button {
                                opacityTargetId = id
                                showOpacitySheet = true
                            } label: {
                                Label("Opacity", systemImage: "circle.lefthalf.filled")
                            }
                            Button {
                                duplicateStamp(id: id)
                            } label: {
                                Label("Duplicate Stamp", systemImage: "plus.rectangle.on.rectangle")
                            }
                            Button(role: .destructive) {
                                deleteLayerEntry(entry)
                            } label: {
                                Label("Delete Stamp", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.primary.opacity(0.7))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                    }
                    .padding(.top, 3)
                    .padding(.trailing, 3)
                }
            }
            .overlay(alignment: .center) {
                if case .stamp(let id) = entry, hiddenLayerIds.contains(id) {
                    Color.white.opacity(0.55)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if case .drawing(let id) = entry {
                    HStack(spacing: 3) {
                        // Eye-slash badge when hidden
                        if hiddenLayerIds.contains(id) {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.6), radius: 1)
                        }
                        // ··· menu
                        Menu {
                            Button {
                                if hiddenLayerIds.contains(id) {
                                    hiddenLayerIds.remove(id)
                                } else {
                                    hiddenLayerIds.insert(id)
                                    // Deselect hidden layer — move to topmost visible drawing layer
                                    if userSelectedLayerId == id {
                                        userSelectedLayerId = layerOrder.reversed().compactMap {
                                            if case .drawing(let lid) = $0, !hiddenLayerIds.contains(lid) { return lid }
                                            return nil
                                        }.first
                                    }
                                }
                            } label: {
                                Label(hiddenLayerIds.contains(id) ? "Show Layer" : "Hide Layer",
                                      systemImage: hiddenLayerIds.contains(id) ? "eye" : "eye.slash")
                            }
                            Button {
                                opacityTargetId = id
                                showOpacitySheet = true
                            } label: {
                                Label("Opacity", systemImage: "circle.lefthalf.filled")
                            }
                            Button {
                                duplicateDrawingLayer(layerId: id)
                            } label: {
                                Label("Duplicate Layer", systemImage: "plus.rectangle.on.rectangle")
                            }
                            Button {
                                extractDrawingLayerAsStamp(layerId: id)
                            } label: {
                                Label("Extract as Stamp", systemImage: "scissors")
                            }
                            .disabled(isExtractingLayer)
                            Button(role: .destructive) {
                                deleteLayerEntry(entry)
                            } label: {
                                Label("Delete Layer", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.primary.opacity(0.7))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                    }
                    .padding(.top, 3)
                    .padding(.trailing, 3)
                }
            }
            .overlay(alignment: .center) {
                if case .drawing(let id) = entry, hiddenLayerIds.contains(id) {
                    Color.white.opacity(0.55)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .allowsHitTesting(false)
                }
            }
            // Pencil badge — shows while a stroke is in progress on this layer
            .overlay(alignment: .bottomLeading) {
                if case .drawing(let id) = entry,
                   id == userSelectedLayerId,
                   currentLine != nil {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Circle().fill(Color.blue.opacity(0.85)))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: chipW, height: chipH)
    }

    @ViewBuilder
    var backgroundLayerChip: some View {
        let chipW: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 112 : 84
        let chipH: CGFloat = chipW * max(canvasSize.height, 1) / max(canvasSize.width, 1)
        ZStack {
            // Canvas color is always the base
            Rectangle().fill(canvasColor)
            // Background photo with all effects applied, matching the canvas
            if let bgImg = canvasBackgroundImage {
                Image(uiImage: bgImg)
                    .resizable()
                    .scaledToFill()
                    .frame(width: chipW, height: chipH)
                    .clipped()
                    .blur(radius: bgBlur * chipW / max(canvasSize.width, 1), opaque: true)
                    .brightness(bgBrightness)
                    .saturation(bgSaturation)
                    .opacity(bgOpacity)
            }
            // Label
            VStack {
                Spacer()
                Text("BG")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .padding(.bottom, 3)
            }
        }
        .frame(width: chipW, height: chipH)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(Color.gray.opacity(0.3), lineWidth: 1))
        .onTapGesture {
            bgNavPath = NavigationPath()
            saveBgStateForCancel()
            showCanvasBgSheet = true
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Button {
                    extractAllLayersAsStamps()
                } label: {
                    Label("Extract All as Stamps", systemImage: "square.on.square.badge.person.crop")
                }
                .disabled(isExtractingLayer)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .padding(.top, 3)
            .padding(.trailing, 3)
        }
    }

    // UIKit pan recognizer for the layers panel header drag — bypasses SwiftUI gesture tree
    // so window-level recognizers (WindowPinchView) can't interleave with it.
    struct PanDragView: UIViewRepresentable {
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize) -> Void

        func makeUIView(context: Context) -> UIView {
            let v = UIView()
            v.backgroundColor = .clear
            let pan = UIPanGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handle(_:)))
            pan.cancelsTouchesInView = true
            v.addGestureRecognizer(pan)
            return v
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.onChanged = onChanged
            context.coordinator.onEnded   = onEnded
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        class Coordinator: NSObject {
            var onChanged: ((CGSize) -> Void)?
            var onEnded:   ((CGSize) -> Void)?

            @objc func handle(_ g: UIPanGestureRecognizer) {
                let t = g.translation(in: g.view)
                let size = CGSize(width: t.x, height: t.y)
                switch g.state {
                case .changed:
                    onChanged?(size)
                case .ended, .cancelled:
                    onEnded?(size)
                    g.setTranslation(.zero, in: g.view)
                default: break
                }
            }
        }
    }

    // UIKit horizontal-only pan recognizer for chip swipe-to-delete.
    // The delegate refuses to begin if the gesture is predominantly vertical,
    // so vertical drags fall through to the ScrollView uninterrupted.
    struct HSwipeView: UIViewRepresentable {
        var currentOffset: CGFloat          // base offset captured at gesture start
        var chipWidth: CGFloat = 112        // full chip width (for hit-test pass-through calc)
        var onChanged: (CGFloat) -> Void    // new absolute offset during drag
        var onEnded:   (CGFloat) -> Void    // new absolute offset on release

        /// UIView subclass that passes touches through to the delete button
        /// when the chip is swiped open (touches land past the visible chip edge).
        class PassThroughView: UIView {
            var swipeOffset: CGFloat = 0
            var chipWidth: CGFloat = 112
            override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
                let visibleEdge = chipWidth + swipeOffset  // e.g. 112 + (-54) = 58
                if swipeOffset < -8 && point.x > visibleEdge {
                    return nil  // pass through to delete button below
                }
                return super.hitTest(point, with: event)
            }
        }

        func makeUIView(context: Context) -> PassThroughView {
            let v = PassThroughView()
            v.backgroundColor = .clear
            let pan = UIPanGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handle(_:)))
            pan.delegate = context.coordinator
            v.addGestureRecognizer(pan)
            return v
        }

        func updateUIView(_ uiView: PassThroughView, context: Context) {
            uiView.swipeOffset = currentOffset
            uiView.chipWidth   = chipWidth
            context.coordinator.baseOffset = currentOffset
            context.coordinator.onChanged  = onChanged
            context.coordinator.onEnded    = onEnded
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var baseOffset: CGFloat = 0
            var startOffset: CGFloat = 0
            var onChanged: ((CGFloat) -> Void)?
            var onEnded:   ((CGFloat) -> Void)?

            func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
                guard let pan = g as? UIPanGestureRecognizer else { return true }
                let v = pan.velocity(in: pan.view)
                // Allow swipes up to ~60° from horizontal (2:1 h:v ratio is too strict — use 1:2)
                return abs(v.x) > abs(v.y) * 0.5
            }

            @objc func handle(_ g: UIPanGestureRecognizer) {
                let t = g.translation(in: g.view)
                switch g.state {
                case .began:
                    startOffset = baseOffset
                case .changed:
                    onChanged?(startOffset + t.x)
                case .ended, .cancelled:
                    onEnded?(startOffset + t.x)
                    g.setTranslation(.zero, in: g.view)
                default: break
                }
            }
        }
    }

    @ViewBuilder
    var layersPanelView: some View {
        if showLayersPanel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Layers")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    // Add new drawing layer at top
                    Button {
                        pushUndoSnapshot()
                        let newLayer = DrawingLayer()
                        drawingLayers.append(newLayer)
                        layerOrder.append(.drawing(newLayer.id))
                        userSelectedLayerId = newLayer.id
                        selectedStampId = nil
                        showStampMagicMenu = false
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.blue)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showLayersPanel = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(
                    PanDragView(
                        onChanged: { t in
                            layersPanelOffset = CGSize(
                                width:  layersPanelBaseOffset.width  + t.width,
                                height: layersPanelBaseOffset.height + t.height
                            )
                        },
                        onEnded: { t in
                            layersPanelBaseOffset = CGSize(
                                width:  layersPanelBaseOffset.width  + t.width,
                                height: layersPanelBaseOffset.height + t.height
                            )
                        }
                    )
                )

                Divider()

                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(layerOrder.reversed())) { entry in
                            layerChipView(entry: entry)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                        }
                        .onMove { source, destination in
                            pushUndoSnapshot()
                            var reversed = Array(layerOrder.reversed())
                            let movedEntry = reversed[source.first!]
                            reversed.move(fromOffsets: source, toOffset: destination)
                            layerOrder = reversed.reversed()
                            switch movedEntry {
                            case .stamp(let id):
                                activateStamp(id: id)
                            case .drawing(let id):
                                userSelectedLayerId = id
                                explicitLayerSelection = true
                                selectedStampId = nil
                                showStampMagicMenu = false
                            }
                        }
                        backgroundLayerChip
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                            .moveDisabled(true)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, .constant(.active))
                    .frame(maxHeight: .infinity)
                    .onChange(of: selectedStampId) { _, newId in
                        if let id = newId {
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                    .onAppear { ensureLayerSelection() }
                }
            }
            .frame(width: UIDevice.current.userInterfaceIdiom == .pad ? 160 : 122)
            .frame(maxHeight: canvasSize.height - 48)
            .background(.thinMaterial)
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.2), radius: 10, x: -4, y: 0)
            .offset(layersPanelOffset)
            .animation(.none, value: layersPanelOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .transition(.opacity)
        }
    }

    /// True if all drawing layers are empty.
    var allLinesEmpty: Bool { drawingLayers.allSatisfy { $0.lines.isEmpty } }

    /// Extract all Vision objects from a drawing layer and place them as doodle stamps
    /// directly above the source layer in the layer order.
    func extractDrawingLayerAsStamp(layerId: UUID) {
        guard let layer = drawingLayers.first(where: { $0.id == layerId }),
              !layer.lines.isEmpty else { return }
        isExtractingLayer = true
        let lines = layer.lines
        let size = canvasSize
        Task {
            // Render this layer on white so Vision has good contrast
            let rendered = renderCanvas(lines: lines, size: size, canvasColor: .white)
            let objects = await extractObjectsWithOrigins(from: rendered)
            await MainActor.run {
                isExtractingLayer = false
                guard !objects.isEmpty else { return }
                pushUndoSnapshot()
                guard let sourceIdx = layerOrder.firstIndex(where: { $0.id == layerId }) else { return }
                var insertIdx = sourceIdx + 1
                for (img, origin) in objects {
                    guard let stamp = CustomStampManager.shared.addStamp(image: img, source: .doodle) else { continue }
                    // Center stamp at the object's original canvas position
                    let centerX = origin.x + img.size.width  / 2
                    let centerY = origin.y + img.size.height / 2
                    let stampSize = max(img.size.width, img.size.height)
                    var placed = PlacedStamp(emoji: "",
                                            position: CGPoint(x: centerX, y: centerY),
                                            size: stampSize)
                    placed.customImageId = stamp.id
                    placedStamps.append(placed)
                    layerOrder.insert(.stamp(placed.id), at: insertIdx)
                    insertIdx += 1
                    if let stampImg = stamp.image { scheduleSnugScan(for: placed.id, image: stampImg) }
                }
            }
        }
    }

    /// Duplicate a stamp — inserts an identical copy directly above the source in layerOrder.
    func duplicateStamp(id: UUID) {
        guard let stamp = placedStamps.first(where: { $0.id == id }),
              let orderIdx = layerOrder.firstIndex(where: { $0.id == id }) else { return }
        pushUndoSnapshot()
        var dupe = PlacedStamp(emoji: stamp.emoji,
                               position: CGPoint(x: stamp.position.x + 12, y: stamp.position.y + 12),
                               size: stamp.size)
        dupe.rotation = stamp.rotation
        dupe.opacity = stamp.opacity
        dupe.flipX = stamp.flipX; dupe.flipY = stamp.flipY; dupe.flipStep = stamp.flipStep
        dupe.customImageId = stamp.customImageId
        dupe.inlineImage = stamp.inlineImage
        dupe.stampText = stamp.stampText
        dupe.fontName = stamp.fontName
        dupe.fontStyle = stamp.fontStyle
        dupe.textAlignment = stamp.textAlignment
        dupe.textColor = stamp.textColor
        dupe.textBgColor = stamp.textBgColor
        dupe.stampWidth = stamp.stampWidth
        dupe.stampHeight = stamp.stampHeight
        dupe.snugWidthRatio = stamp.snugWidthRatio
        dupe.snugHeightRatio = stamp.snugHeightRatio
        placedStamps.append(dupe)
        layerOrder.insert(.stamp(dupe.id), at: orderIdx + 1)
        selectedStampId = dupe.id
        showStampMagicMenu = true
        if let img = dupe.inlineImage ?? dupe.customImageId.flatMap({ _ in CustomStampManager.shared.stamps.first(where: { $0.id == id })?.image }) {
            scheduleSnugScan(for: dupe.id, image: img)
        }
    }

    /// Duplicate a drawing layer — copies all lines to a new layer inserted directly above the source.
    func duplicateDrawingLayer(layerId: UUID) {
        guard let layer = drawingLayers.first(where: { $0.id == layerId }),
              let orderIdx = layerOrder.firstIndex(where: { $0.id == layerId }) else { return }
        pushUndoSnapshot()
        let newLayer = DrawingLayer(lines: layer.lines)
        drawingLayers.append(newLayer)
        layerOrder.insert(.drawing(newLayer.id), at: orderIdx + 1)
        userSelectedLayerId = newLayer.id
    }

    /// Double-tap on canvas background: flatten ALL visible layers (drawings + stamps) and extract as stamps.
    /// Places stamps on top of all existing layers. Only called when tap misses every stamp.
    func extractAllLayersAsStamps() {
        let visibleLayers = drawingLayers.filter { !hiddenLayerIds.contains($0.id) }
        let visibleLayerOrder = layerOrder.filter { entry in
            if case .drawing(let id) = entry { return !hiddenLayerIds.contains(id) }
            if case .stamp(let id) = entry { return !hiddenLayerIds.contains(id) }
            return true
        }
        let currentStamps = placedStamps
        guard !visibleLayers.flatMap({ $0.lines }).isEmpty || !currentStamps.isEmpty else { return }
        isExtractingLayer = true
        let size = canvasSize
        Task {
            // Render on white, no background image — gives Vision clean contrast
            let rendered = renderCanvasWithStamps(
                drawingLayers: visibleLayers, stamps: currentStamps, layerOrder: visibleLayerOrder,
                size: size, canvasColor: .white
            )
            let objects = await extractObjectsWithOrigins(from: rendered)
            await MainActor.run {
                isExtractingLayer = false
                guard !objects.isEmpty else { return }
                pushUndoSnapshot()
                var insertIdx = layerOrder.endIndex
                for (img, origin) in objects {
                    guard let stamp = CustomStampManager.shared.addStamp(image: img, source: .doodle) else { continue }
                    let centerX = origin.x + img.size.width  / 2
                    let centerY = origin.y + img.size.height / 2
                    let stampSize = max(img.size.width, img.size.height)
                    var placed = PlacedStamp(emoji: "",
                                            position: CGPoint(x: centerX, y: centerY),
                                            size: stampSize)
                    placed.customImageId = stamp.id
                    placedStamps.append(placed)
                    layerOrder.insert(.stamp(placed.id), at: insertIdx)
                    insertIdx += 1
                    if let stampImg = stamp.image { scheduleSnugScan(for: placed.id, image: stampImg) }
                }
                // Select the last placed stamp with snug rect + magic menu
                if let last = placedStamps.last {
                    selectedStampId = last.id
                    showStampMagicMenu = true
                }
            }
        }
    }

    /// Push undo snapshot and clear redo.
    // MARK: - .skadoodle save / load

    /// Serialize the current canvas to a SkadoodleDocument and return JSON Data.
    func saveSkadoodleData() -> Data? {
        let bgData = canvasBackgroundImage.flatMap { $0.jpegData(compressionQuality: 0.85) }
        let doc = SkadoodleDocument(
            drawingLayers: drawingLayers,
            placedStamps: placedStamps,
            layerOrder: layerOrder,
            hiddenLayerIds: Array(hiddenLayerIds),
            canvasColorRGBA: CodableColor(canvasColor),
            backgroundImageData: bgData,
            backgroundOffsetX: Double(backgroundOffset.width),
            backgroundOffsetY: Double(backgroundOffset.height),
            bgOpacity: bgOpacity,
            bgBlur: bgBlur,
            bgBrightness: bgBrightness,
            bgSaturation: bgSaturation
        )
        return try? JSONEncoder().encode(doc)
    }

    /// Restore canvas state from JSON Data previously produced by saveSkadoodleData().
    func restoreSkadoodleData(_ data: Data) {
        let doc: SkadoodleDocument
        guard let doc = try? JSONDecoder().decode(SkadoodleDocument.self, from: data) else { return }
        guard !doc.drawingLayers.isEmpty || !doc.placedStamps.isEmpty || doc.backgroundImageData != nil else {
            try? FileManager.default.removeItem(at: FileManager.currentSkadoodleURL)
            return
        }
        // Only push undo if there's something on the canvas worth preserving
        if !drawingLayers.isEmpty || !placedStamps.isEmpty { pushUndoSnapshot() }
        drawingLayers = doc.drawingLayers
        placedStamps = doc.placedStamps
        layerOrder = doc.layerOrder
        hiddenLayerIds = Set(doc.hiddenLayerIds)
        if let rgba = doc.canvasColorRGBA {
            selectedCanvasColor = rgba.color
        } else {
            selectedCanvasColor = canvasColorOptions[min(doc.canvasColorIndex, canvasColorOptions.count - 1)]
        }
        if let imgData = doc.backgroundImageData {
            canvasBackgroundImage = UIImage(data: imgData)
        } else {
            canvasBackgroundImage = nil
        }
        backgroundOffset = CGSize(width: doc.backgroundOffsetX, height: doc.backgroundOffsetY)
        bgOpacity = doc.bgOpacity
        bgBlur = doc.bgBlur
        bgBrightness = doc.bgBrightness
        bgSaturation = doc.bgSaturation
        selectedStampId = nil
        showStampMagicMenu = false
        pendingInsertAboveStampId = nil
        ensureLayerSelection()
    }

    func pushUndoSnapshot() {
        undoStack.append(CanvasSnapshot(
            drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder,
            backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset,
            bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation))
        redoStack = []
    }

    // Place a stamp: append to placedStamps + layerOrder.
    // No empty drawing layer is created here — one will be lazily created on first stroke via onBeforeDraw.
    func appendStampToLayer(_ stamp: PlacedStamp) {
        if showLegacyImportBanner { withAnimation { showLegacyImportBanner = false } }
        placedStamps.append(stamp)
        // Priority: insert above the selected stamp if one is selected,
        // otherwise insert above the selected drawing layer.
        // Falls back to top of stack if neither is valid.
        if let selStampId = selectedStampId,
           let selIdx = layerOrder.firstIndex(where: { $0.id == selStampId }) {
            layerOrder.insert(.stamp(stamp.id), at: selIdx + 1)
        } else if let selId = userSelectedLayerId,
           let selIdx = layerOrder.firstIndex(where: {
               if case .drawing(let id) = $0 { return id == selId } else { return false }
           }) {
            layerOrder.insert(.stamp(stamp.id), at: selIdx + 1)
        } else {
            layerOrder.append(.stamp(stamp.id))
        }
        // Clear explicit selection so the next stroke creates a new layer above the stamp
        explicitLayerSelection = false
    }

    // Lazy binding to the active drawing layer's lines. Evaluates activeDrawingLayerIndex
    // at access time (not at SwiftUI render time), so it picks up a layer that
    // onBeforeDraw just created before the first stroke point is written.
    var activeLayerLinesBinding: Binding<[DrawingLine]> {
        Binding(
            get: {
                guard !drawingLayers.isEmpty else { return [] }
                return drawingLayers[activeDrawingLayerIndex].lines
            },
            set: {
                guard !drawingLayers.isEmpty else { return }
                drawingLayers[activeDrawingLayerIndex].lines = $0
            }
        )
    }

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
    @ObservedObject private var auth = SnoodleAuthManager.shared
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
    @State private var showMenuTweak: Bool = false
    @AppStorage("stampPanelOffsetX_v3") private var savedMenuOffsetX: Double = 0
    @AppStorage("stampPanelOffsetY_v3") private var savedMenuOffsetY: Double = 0
    @State private var showTextComposer: Bool = false
    @State private var editingStampId: UUID? = nil
    @State private var selectedStampId: UUID? = nil
    @State private var isStampMode: Bool = false           // hand tool toggle: disables drawing, enables direct stamp drag
    @State private var showSnugDuringDrag: Bool = false    // true only if stamp was already selected when long-press drag began
    @State private var suppressCanvasTapAfterPlace: Bool = false
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
        // Hidden layers are excluded from the flattened export
        let visibleLayers = drawingLayers.filter { !hiddenLayerIds.contains($0.id) }
        let visibleLayerOrder = layerOrder.filter { entry in
            if case .drawing(let id) = entry { return !hiddenLayerIds.contains(id) }
            if case .stamp(let id) = entry { return !hiddenLayerIds.contains(id) }
            return true
        }
        let img = renderCanvasWithStamps(drawingLayers: visibleLayers, stamps: placedStamps, layerOrder: visibleLayerOrder, size: canvasSize, canvasColor: UIColor(canvasColor), backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation)
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
        // Save .skadoodle alongside the flat image for future re-editing
        if let skadoodleData = saveSkadoodleData() {
            try? skadoodleData.write(to: entry.skadoodleURL)
        }
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
        // Doodle saved to gallery — discard the auto-save so it won't be offered for resume
        try? FileManager.default.removeItem(at: FileManager.currentSkadoodleURL)
        isPresented = false
    }

    @ViewBuilder
    func colorCircle(_ color: Color) -> some View {
        let isSelected = !isEraser && currentColor.isApproximatelyEqual(to: color)
        ColorSwatchView(color: color, size: 30, isSelected: isSelected)
            .onTapGesture {
                if let i = recentColors.firstIndex(where: { $0.isApproximatelyEqual(to: color) }) {
                    selectedColorIndex = i
                }
                if isEraser { swap(&lineWidth, &otherWidth) }
                isEraser = false
            }
    }

    // Routes a single layerOrder entry to its SwiftUI renderer.
    // Split into sub-functions to keep each function simple for the type checker.
    @ViewBuilder
    func layerEntryView(_ entry: LayerEntry) -> some View {
        if case .drawing(let id) = entry { layerDrawingView(id: id) }
        else if case .stamp(let id) = entry { layerStampView(id: id) }
    }

    @ViewBuilder
    func layerDrawingView(id: UUID) -> some View {
        if !hiddenLayerIds.contains(id),
           let layer = drawingLayers.first(where: { $0.id == id }) {
            drawingLayerView(layer: layer)
                .opacity(layer.opacity)
        }
    }

    @ViewBuilder
    func layerStampView(id: UUID) -> some View {
        if !hiddenLayerIds.contains(id),
           let stamp = placedStamps.first(where: { $0.id == id }) {
            StampRenderView(stamp: stamp)
            // opacity is applied inside StampRenderView from stamp.opacity
        }
    }

    @ViewBuilder
    var activeMagicMenuView: some View {
        if showStampMagicMenu,
           let id = selectedStampId,
           let stamp = placedStamps.first(where: { $0.id == id }) {
            stampMagicMenuView(id: id, stamp: stamp)
        }
    }

    // Extracted to reduce body complexity
    @ViewBuilder
    var snugRectOverlay: some View {
        if (showStampMagicMenu || isLongPressing),
           let selId = selectedStampId,
           let selStamp = placedStamps.first(where: { $0.id == selId }) {
            Rectangle()
                .stroke(Color.black, lineWidth: 3)
                .overlay(Rectangle().stroke(Color.white, lineWidth: 1))
                .frame(width: selStamp.snugSize.width, height: selStamp.snugSize.height)
                .rotationEffect(.degrees(selStamp.rotation))
                .position(selStamp.position)
                .allowsHitTesting(false)
        }
    }

    // Extracted so the compiler can resolve DrawingLayerCanvas independently of the giant body ZStack
    @ViewBuilder
    func drawingLayerView(layer: DrawingLayer) -> some View {
        let liveLine: DrawingLine? = layer.id == eraserTargetLayerId ? currentLine : nil
        let bgColor: Color = canvasBackgroundImage != nil ? .clear : canvasColor
        DrawingLayerCanvas(lines: layer.lines, currentLine: liveLine, canvasColor: bgColor,
                           backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset)
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
                undoStack.append(CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation))
                redoStack = []
                if let idx = placedStamps.firstIndex(where: { $0.id == id }) {
                    switch transform {
                    case .flipH:    placedStamps[idx].flipX.toggle()
                    case .flipV:    placedStamps[idx].flipY.toggle()
                    case .rotate90: placedStamps[idx].rotation = (placedStamps[idx].rotation + 90).truncatingRemainder(dividingBy: 360)
                    }
                }
                // Keep selection + strip active after transform
            },
            onDelete: {
                undoStack.append(CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation))
                redoStack = []
                placedStamps.removeAll { $0.id == id }
                removeStampFromLayerOrder(id)
                showStampMagicMenu = false
                selectedStampId = nil
            },
            onDupe: {
                pushUndoSnapshot()
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
                    appendStampToLayer(dupe)
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
            },
            onMoveLayer: { forward, toExtreme in
                moveStampLayer(id: id, forward: forward, toExtreme: toExtreme)
            },
            showTweak: $showMenuTweak,
            initialOffset: CGSize(width: savedMenuOffsetX, height: savedMenuOffsetY),
            onOffsetSaved: { offset in
                savedMenuOffsetX = offset.width
                savedMenuOffsetY = offset.height
            }
        )
        // Centered vertically; x anchors the right edge of the panel (strip or strip+tweak)
        // 6pt from canvas right. Offset from accDrag/liveDrag moves it from here.
        .position(
            x: showMenuTweak
                ? canvasSize.width - (300 + 6 + 54) / 2 - 6   // strip + gap + tweak panel
                : canvasSize.width - 54 / 2 - 6,               // strip only
            y: canvasSize.height / 2
        )
        .zIndex(1000)
    }

    /// Move a stamp one step forward/backward in layerOrder.
    /// `forward` = toward front (higher index); `toExtreme` = jump all the way.
    func moveStampLayer(id: UUID, forward: Bool, toExtreme: Bool) {
        guard let currentIdx = layerOrder.firstIndex(where: { $0.id == id }) else { return }
        let targetIdx: Int
        if toExtreme {
            targetIdx = forward ? layerOrder.count - 1 : 0
        } else {
            targetIdx = forward ? min(currentIdx + 1, layerOrder.count - 1)
                                : max(currentIdx - 1, 0)
        }
        guard targetIdx != currentIdx else { return }
        pushUndoSnapshot()
        var newOrder = layerOrder
        let item = newOrder.remove(at: currentIdx)
        newOrder.insert(item, at: targetIdx)
        layerOrder = newOrder
    }

    // Auto-place the current stamp centered on the canvas when selected from picker
    /// Runs alpha-channel scan on a background thread and stores cached snug ratios
    /// back into the PlacedStamp identified by `stampId`.
    func scheduleSnugScan(for stampId: UUID, image: UIImage) {
        DispatchQueue.global(qos: .utility).async {
            guard let (wr, hr) = PlacedStamp.computeSnugRatios(from: image) else { return }
            DispatchQueue.main.async {
                if let idx = placedStamps.firstIndex(where: { $0.id == stampId }) {
                    placedStamps[idx].snugWidthRatio  = wr
                    placedStamps[idx].snugHeightRatio = hr
                }
            }
        }
    }

    /// Computes default placement size for a stamp.
    /// Target: visual height = 25% of canvas height.
    /// Cap: visual width must not exceed 25% of canvas width (prevents absurdly wide stamps).
    /// imageSize: actual pixel dimensions of the image (nil for emoji/square stamps).
    func defaultStampSize(imageSize: CGSize? = nil) -> CGFloat {
        let targetH = canvasSize.height * 0.25
        let maxW    = canvasSize.width  * 0.65   // generous cap — only clips very wide panoramics
        guard let img = imageSize, img.height > 0 else {
            // Emoji / unknown: square bounding box
            return min(targetH, maxW)
        }
        let ar = img.width / img.height   // aspect ratio
        if ar <= 1 {
            // Portrait or square: visual height = size, visual width = size * ar
            let size = targetH
            return (size * ar > maxW) ? maxW / ar : size
        } else {
            // Landscape: visual width = size, visual height = size / ar
            // To hit targetH visual height: size = targetH * ar
            let size = targetH * ar
            return min(size, maxW)
        }
    }

    /// Briefly suppress the window-level canvas-tap handler so sheet-dismiss touches
    /// don't deselect a stamp that was just placed from the picker.
    func suppressNextCanvasTap() {
        suppressCanvasTapAfterPlace = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            suppressCanvasTapAfterPlace = false
        }
    }

    func autoPlaceStamp() {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        pushUndoSnapshot()
        if isCustomStampMode, let customId = UUID(uuidString: lastCustomStampIdString) {
            let img = CustomStampManager.shared.stamps.first(where: { $0.id == customId })?.image
            let size = defaultStampSize(imageSize: img?.size)
            var stamp = PlacedStamp(emoji: "📷", position: center, size: size)
            stamp.customImageId = customId
            appendStampToLayer(stamp)
            selectedStampId = stamp.id
            if let img { scheduleSnugScan(for: stamp.id, image: img) }
        } else {
            let stamp = PlacedStamp(emoji: selectedStamp, position: center, size: defaultStampSize())
            appendStampToLayer(stamp)
            selectedStampId = stamp.id
        }
        isStampMode = true
        showStampMagicMenu = true
        suppressNextCanvasTap()
    }

    // Places multiple full-photo stamps staggered from canvas center (20pt cascade per stamp).
    func placeFullPhotoStamps(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        pushUndoSnapshot()
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let stagger: CGFloat = 20
        // Center the cascade so the group is visually centered on the canvas
        let offset = -CGFloat(ids.count - 1) * stagger / 2
        for (i, customId) in ids.enumerated() {
            let pos = CGPoint(x: center.x + offset + CGFloat(i) * stagger,
                              y: center.y + offset + CGFloat(i) * stagger)
            let img = CustomStampManager.shared.stamps.first(where: { $0.id == customId })?.image
            let size = defaultStampSize(imageSize: img?.size)
            var stamp = PlacedStamp(emoji: "📷", position: pos, size: size)
            stamp.customImageId = customId
            appendStampToLayer(stamp)
            selectedStampId = stamp.id  // last one ends up selected
            if let img { scheduleSnugScan(for: stamp.id, image: img) }
        }
        isStampMode = true
        showStampMagicMenu = true
        suppressNextCanvasTap()
    }

    // Places multiple emoji stamps staggered from canvas center.
    func placeMultipleEmojis(_ emojis: [String]) {
        guard !emojis.isEmpty else { return }
        pushUndoSnapshot()
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let stagger: CGFloat = 20
        let offset = -CGFloat(emojis.count - 1) * stagger / 2
        for (i, emoji) in emojis.enumerated() {
            let pos = CGPoint(x: center.x + offset + CGFloat(i) * stagger,
                              y: center.y + offset + CGFloat(i) * stagger)
            let stamp = PlacedStamp(emoji: emoji, position: pos, size: defaultStampSize())
            appendStampToLayer(stamp)
            selectedStampId = stamp.id
        }
        isStampMode = true
        showStampMagicMenu = true
        suppressNextCanvasTap()
    }

    func placeTextStamp(text: String, fontId: String, fontStyle: String, alignment: String, color: Color, bgColor: Color,
                        shadowEnabled: Bool = false, shadowColor: Color = .black, shadowBlur: Double = 4.0,
                        shadowOffsetX: Double = 2.0, shadowOffsetY: Double = 2.0) {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        pushUndoSnapshot()

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
        stamp.shadowEnabled = shadowEnabled
        stamp.shadowColor = shadowColor
        stamp.shadowBlur = shadowBlur
        stamp.shadowOffsetX = shadowOffsetX
        stamp.shadowOffsetY = shadowOffsetY
        stamp.stampWidth = natW
        stamp.stampHeight = natH
        appendStampToLayer(stamp)
        selectedStampId = stamp.id
        showStampMagicMenu = true
        suppressNextCanvasTap()
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
                CanvasColorPickerView(currentColor: selectedCanvasColor,
                    onSelectColor: { newColor in
                        bgPickerWasApplied = true
                        undoStack.append(CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation))
                        redoStack = []
                        selectedCanvasColor = newColor
                        recentCanvasColors = RecentCanvasColors.add(newColor)
                        RecentCanvasColors.saveSelected(newColor)
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
                        undoStack.append(CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: savedBgImage, backgroundOffset: savedBgOffset, bgOpacity: savedBgOpacity, bgBlur: savedBgBlur, bgBrightness: savedBgBrightness, bgSaturation: savedBgSaturation))
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
                            lines: allDrawingLines,
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
                                    undoStack.append(CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: savedBgImage, backgroundOffset: savedBgOffset, bgOpacity: savedBgOpacity, bgBlur: savedBgBlur, bgBrightness: savedBgBrightness, bgSaturation: savedBgSaturation))
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
                                    appendStampToLayer(stamp)
                                    scheduleSnugScan(for: stamp.id, image: cropped)
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
        .sheet(isPresented: $showOpacitySheet, onDismiss: {
            opacityTargetId = nil
        }) {
            LayerOpacitySheet(
                targetId: opacityTargetId,
                drawingLayers: $drawingLayers,
                placedStamps: $placedStamps,
                pushSnapshot: { pushUndoSnapshot() }
            )
            .presentationDetents([.height(180)])
            .presentationDragIndicator(.visible)
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
                    lines: allDrawingLines,
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
                            undoStack.append(CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: savedBgImage, backgroundOffset: savedBgOffset, bgOpacity: savedBgOpacity, bgBlur: savedBgBlur, bgBrightness: savedBgBrightness, bgSaturation: savedBgSaturation))
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
                            appendStampToLayer(stamp)
                            scheduleSnugScan(for: stamp.id, image: cropped)
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
                        // Input handler — no self-rendering; external layer canvases handle display
                        DrawingCanvas(
                            lines: activeLayerLinesBinding,
                            currentColor: currentColor,
                            lineWidth: $lineWidth,
                            isEraser: $isEraser,
                            canvasColor: canvasBackgroundImage != nil ? .clear : canvasColor,
                            backgroundImage: canvasBackgroundImage,
                            backgroundOffset: backgroundOffset,
                            penType: currentPenType,
                            colorB: dualToneColorB,
                            currentStamps: placedStamps,
                            isLongPressing: isLongPressing,
                            stampResizeTargetId: stampResizeTargetId,
                            isStampSelected: selectedStampId != nil,
                            drawingEnabled: !isStampMode,
                            onBeforeDraw: {
                                if showLegacyImportBanner { withAnimation { showLegacyImportBanner = false } }
                                pushUndoSnapshot()
                                // Create a new layer when:
                                // 1. No drawing layers exist (lazy first-stroke creation), or
                                // 2. Top of stack is a stamp and no drawing layer is selected / stamp is selected
                                //    (working at the front edge), or
                                // 3. pendingInsertAboveStampId is set — user selected a stamp whose immediate
                                //    neighbor above is another stamp; new layer inserts between them.
                                let topIsStamp = layerOrder.last.map { if case .stamp = $0 { return true } else { return false } } ?? false
                                let needsNewLayer = drawingLayers.isEmpty ||
                                    (topIsStamp && !explicitLayerSelection) ||
                                    pendingInsertAboveStampId != nil
                                if needsNewLayer {
                                    let newLayer = DrawingLayer()
                                    drawingLayers.append(newLayer)
                                    if let insertAbove = pendingInsertAboveStampId,
                                       let insertIdx = layerOrder.firstIndex(where: { $0.id == insertAbove }) {
                                        // Insert just above the target stamp, not at the top.
                                        layerOrder.insert(.drawing(newLayer.id), at: insertIdx + 1)
                                    } else {
                                        layerOrder.append(.drawing(newLayer.id))
                                    }
                                    pendingInsertAboveStampId = nil
                                    userSelectedLayerId = newLayer.id
                                    explicitLayerSelection = true   // prevent another new layer on the very next stroke
                                    selectedStampId = nil
                                    showStampMagicMenu = false
                                }
                            },
                            onEraserCommitted: { _ in },
                            onStampModeDragOnEmpty: { startPoint in
                                // Auto-switch to draw mode only when dragging on empty canvas in stamp mode.
                                // Returns true so the caller can start drawing immediately (without waiting
                                // for SwiftUI to re-render isStampMode change).
                                let hit = topmostStampHit(at: startPoint, layerOrder: layerOrder, stamps: placedStamps)
                                if hit == nil { isStampMode = false; return true }
                                return false
                            },
                            currentLine: $currentLine
                        )
                            .contentShape(Rectangle())
                            .allowsHitTesting(!isLongPressing)
                            .simultaneousGesture(
                                SpatialTapGesture()
                                    .onEnded { value in
                                        let loc = value.location
                                        if let hit = topmostStampHit(at: loc, layerOrder: layerOrder, stamps: placedStamps) {
                                            selectedStampId = hit.id
                                            showStampMagicMenu = true
                                        } else {
                                            selectedStampId = nil
                                            showStampMagicMenu = false
                                        }
                                    }
                            )
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

                        // Render all layers in z-order: drawings and stamps fully interleaved
                        ForEach(layerOrder) { entry in
                            layerEntryView(entry)
                        }

                        // Gesture-only overlay: transparent UIKit stamp interaction
                        ZStack {
                        StampCanvasView(
                            stamps: $placedStamps,
                            selectedStampId: $selectedStampId,
                            showStampMagicMenu: $showStampMagicMenu,
                            canvasSize: canvasSize,
                            rotatingId: $stampRotatingId,
                            layerOrder: layerOrder,
                            onBeforeStampChange: { pushUndoSnapshot() },
                            onStampDuped: { dupe in appendStampToLayer(dupe) },
                            onStampDeleted: { id in removeStampFromLayerOrder(id) }
                        )
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .allowsHitTesting(true)
                        // Selection indicator — snug bounding rect
                        snugRectOverlay
                        // Magic menu renders on top of all stamps
                        activeMagicMenuView
                        // Window-level pinch + long press
                        WindowPinchView(
                            placedStamps: $placedStamps,
                            stampResizeStartSize: $stampResizeStartSize,
                            stampResizeTargetId: $stampResizeTargetId,
                            stampRotatingId: $stampRotatingId,
                            canvasOrigin: canvasOriginInWindow,
                            canvasSize: canvasSize,
                            selectedStamp: selectedStamp,
                            onLongPress: { _ in },
                            isLongPressing: $isLongPressing,
                            showLayersPanel: showLayersPanel,
                            suppressCanvasTap: suppressCanvasTapAfterPlace,
                            isStampMode: isStampMode,
                            layerOrder: layerOrder,
                            selectedStampId: selectedStampId,
                            onLongPressStamp: { id in
                                // Only keep the snug rect during drag if the stamp was already selected
                                showSnugDuringDrag = (selectedStampId == id && showStampMagicMenu)
                                selectedStampId = id
                                showStampMagicMenu = false
                            },
                            onStampDragEnd: { id in
                                // Only restore selection+strip if stamp was already selected
                                // when the drag started (showSnugDuringDrag captures this).
                                if showSnugDuringDrag {
                                    selectedStampId = id
                                    showStampMagicMenu = true
                                } else {
                                    // Draw mode: clear the selectedStampId that onLongPressStamp set.
                                    // Without this, the stamp stays "selected" for hitTest and its
                                    // UIPanGestureRecognizer can drag it on the next single-finger touch.
                                    selectedStampId = nil
                                }
                                showSnugDuringDrag = false
                            },
                            onStampTap: { id in
                                activateStamp(id: id)
                            },
                            onCanvasTap: {
                                selectedStampId = nil
                                showStampMagicMenu = false
                                pendingInsertAboveStampId = nil
                                explicitLayerSelection = false
                                ensureLayerSelection()
                            },
                            onBeforeStampChange: { pushUndoSnapshot() },
                            onBackgroundPanBegan: canvasBackgroundImage != nil ? {
                                undoStack.append(CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation))
                                redoStack = []
                            } : nil,
                            onBackgroundPan: canvasBackgroundImage != nil ? { delta in
                                let newOffset = CGSize(
                                    width: backgroundOffset.width + delta.width,
                                    height: backgroundOffset.height + delta.height
                                )
                                backgroundOffset = clampedBackgroundOffset(newOffset)
                            } : nil,
                            onBackgroundDoubleTap: nil,  // extract moved to BG chip ··· menu
                            blockGestures: showTextComposer || showPenStudio || showBgEditor ||
                                showOpacitySheet || showCanvasBgSheet || showCanvasImagePicker ||
                                showSignInForPost || showPenColorPicker || showCanvasColorPicker
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
                                if !isEraser { swap(&lineWidth, &otherWidth) }
                                isEraser = true
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    // + opens system ColorPicker
                                    Button {
                                        penPickerColor = currentColor
                                        showPenColorPicker = true
                                    } label: {
                                        ZStack {
                                            Circle().fill(Color(UIColor.secondarySystemBackground))
                                                .frame(width: 30, height: 30)
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 22))
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .colorPickerSheet(isPresented: $showPenColorPicker, color: $penPickerColor) { picked in
                                        recentColors = RecentColors.add(picked)
                                        selectedColorIndex = 0
                                        if isEraser { swap(&lineWidth, &otherWidth) }
                                        isEraser = false
                                    }
                                    ForEach(recentColors, id: \.self) { color in
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
                                canvasSize: canvasSize,
                                onPlace: { autoPlaceStamp() },
                                onPlaceMultipleStamps: { ids in placeFullPhotoStamps(ids) },
                                onPlaceMultipleEmojis: { emojis in placeMultipleEmojis(emojis) }
                            )

                            // Pen Studio button — always just opens pen studio
                            Button(action: {
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
                                    initialTextColor: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.textColor
                                    },
                                    initialTextBgColor: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.textBgColor
                                    },
                                    initialShadowEnabled: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.shadowEnabled
                                    } ?? false,
                                    initialShadowColor: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.shadowColor
                                    } ?? .black,
                                    initialShadowBlur: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.shadowBlur
                                    } ?? 4.0,
                                    initialShadowOffsetX: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.shadowOffsetX
                                    } ?? 2.0,
                                    initialShadowOffsetY: editingStampId.flatMap { id in
                                        placedStamps.first(where: { $0.id == id })?.shadowOffsetY
                                    } ?? 2.0,
                                    onPlace: { text, fontId, fontStyle, alignment, color, bgColor, shEnabled, shColor, shBlur, shOffX, shOffY in
                                        if let editId = editingStampId,
                                           let idx = placedStamps.firstIndex(where: { $0.id == editId }) {
                                            // Edit existing — update in place, recompute dimensions
                                            undoStack.append(CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation))
                                            redoStack = []
                                            let (natW, natH, baseFontSize) = naturalTextStampSize(text: text, fontId: fontId, fontStyle: fontStyle, maxWidth: canvasSize.width * 0.7)
                                            let existingSize = placedStamps[idx].size
                                            let scale = existingSize / baseFontSize
                                            placedStamps[idx].stampText = text
                                            placedStamps[idx].fontName = fontId
                                            placedStamps[idx].fontStyle = fontStyle
                                            placedStamps[idx].textAlignment = alignment
                                            placedStamps[idx].textColor = color
                                            placedStamps[idx].textBgColor = bgColor
                                            placedStamps[idx].shadowEnabled = shEnabled
                                            placedStamps[idx].shadowColor = shColor
                                            placedStamps[idx].shadowBlur = shBlur
                                            placedStamps[idx].shadowOffsetX = shOffX
                                            placedStamps[idx].shadowOffsetY = shOffY
                                            placedStamps[idx].stampWidth = natW * scale
                                            placedStamps[idx].stampHeight = natH * scale
                                            selectedStampId = editId
                                            showStampMagicMenu = true
                                        } else {
                                            placeTextStamp(text: text, fontId: fontId, fontStyle: fontStyle, alignment: alignment, color: color, bgColor: bgColor, shadowEnabled: shEnabled, shadowColor: shColor, shadowBlur: shBlur, shadowOffsetX: shOffX, shadowOffsetY: shOffY)
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
                                let cur = CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation)
                                redoStack.append(cur)
                                let last = undoStack.removeLast()
                                drawingLayers = last.drawingLayers
                                placedStamps = last.stamps
                                layerOrder = last.layerOrder
                                canvasBackgroundImage = last.backgroundImage
                                backgroundOffset = last.backgroundOffset
                                bgOpacity = last.bgOpacity
                                bgBlur = last.bgBlur
                                bgBrightness = last.bgBrightness
                                bgSaturation = last.bgSaturation
                                // Revalidate selection — restored state may not have the previously selected layer/stamp
                                if let sid = selectedStampId, !placedStamps.contains(where: { $0.id == sid }) {
                                    selectedStampId = nil; showStampMagicMenu = false
                                }
                                ensureLayerSelection()
                            }) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(undoStack.isEmpty ? .gray.opacity(0.4) : .blue)
                            }
                            .disabled(undoStack.isEmpty)
                            Button(action: {
                                guard !redoStack.isEmpty else { return }
                                let cur = CanvasSnapshot(drawingLayers: drawingLayers, stamps: placedStamps, layerOrder: layerOrder, backgroundImage: canvasBackgroundImage, backgroundOffset: backgroundOffset, bgOpacity: bgOpacity, bgBlur: bgBlur, bgBrightness: bgBrightness, bgSaturation: bgSaturation)
                                undoStack.append(cur)
                                let last = redoStack.removeLast()
                                drawingLayers = last.drawingLayers
                                placedStamps = last.stamps
                                layerOrder = last.layerOrder
                                canvasBackgroundImage = last.backgroundImage
                                backgroundOffset = last.backgroundOffset
                                bgOpacity = last.bgOpacity
                                bgBlur = last.bgBlur
                                bgBrightness = last.bgBrightness
                                bgSaturation = last.bgSaturation
                                if let sid = selectedStampId, !placedStamps.contains(where: { $0.id == sid }) {
                                    selectedStampId = nil; showStampMagicMenu = false
                                }
                                ensureLayerSelection()
                            }) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(redoStack.isEmpty ? .gray.opacity(0.4) : .blue)
                            }
                            .disabled(redoStack.isEmpty)
                            Button("Clear") {
                                let thingCount = (allLinesEmpty ? 0 : 1) + (placedStamps.isEmpty ? 0 : 1) + (canvasBackgroundImage != nil ? 1 : 0)
                                if thingCount == 1 {
                                    // Only one thing — clear it directly, no sheet
                                    pushUndoSnapshot()
                                    if canvasBackgroundImage != nil {
                                        canvasBackgroundImage = nil; backgroundOffset = .zero
                                    } else if !allLinesEmpty {
                                        // Remove all drawing layers. Stamps keep their relative order.
                                        // First stroke after clear lazily creates a fresh drawing layer.
                                        let stampEntries = layerOrder.filter { if case .stamp = $0 { return true } else { return false } }
                                        drawingLayers = []
                                        layerOrder = stampEntries
                                        hiddenLayerIds = hiddenLayerIds.intersection(Set(placedStamps.map { $0.id }))
                                        userSelectedLayerId = nil
                                    } else if !placedStamps.isEmpty {
                                        // Only stamps — remove all stamps. Canvas is empty; first stroke creates a layer.
                                        placedStamps = []
                                        drawingLayers = []
                                        layerOrder = []
                                        stampUndoStack = []; stampRedoStack = []
                                        hiddenLayerIds = []
                                        selectedStampId = nil; showStampMagicMenu = false
                                        userSelectedLayerId = nil
                                    }
                                } else {
                                    showClearSheet = true
                                }
                            }
                            .foregroundColor(allLinesEmpty && placedStamps.isEmpty && canvasBackgroundImage == nil ? .gray.opacity(0.4) : .red)
                            .font(.system(size: 16, weight: .medium))
                            .disabled(allLinesEmpty && placedStamps.isEmpty && canvasBackgroundImage == nil)
                            .confirmationDialog("Clear Canvas", isPresented: $showClearSheet, titleVisibility: .visible) {
                                // Sheet only shown when 2+ things exist — Clear All always relevant
                                Button("Clear All", role: .destructive) {
                                    pushUndoSnapshot()
                                    drawingLayers = []
                                    layerOrder = []
                                    placedStamps = []
                                    stampUndoStack = []; stampRedoStack = []
                                    canvasBackgroundImage = nil
                                    backgroundOffset = .zero
                                    hiddenLayerIds = []
                                    selectedStampId = nil; showStampMagicMenu = false
                                    userSelectedLayerId = nil
                                }
                                if canvasBackgroundImage != nil {
                                    Button("Clear Background", role: .destructive) {
                                        pushUndoSnapshot()
                                        canvasBackgroundImage = nil
                                        backgroundOffset = .zero
                                    }
                                }
                                if !allLinesEmpty {
                                    Button("Clear Drawing", role: .destructive) {
                                        pushUndoSnapshot()
                                        // Remove all drawing layers. Stamps keep their relative order.
                                        // First stroke lazily creates a fresh drawing layer.
                                        let stampEntries = layerOrder.filter { if case .stamp = $0 { return true } else { return false } }
                                        drawingLayers = []
                                        layerOrder = stampEntries
                                        hiddenLayerIds = hiddenLayerIds.intersection(Set(placedStamps.map { $0.id }))
                                        userSelectedLayerId = nil
                                    }
                                }
                                if !placedStamps.isEmpty {
                                    Button("Clear Stamps", role: .destructive) {
                                        pushUndoSnapshot()
                                        placedStamps = []
                                        stampUndoStack = []; stampRedoStack = []
                                        // Remove stamp entries from layerOrder, keep drawing layers
                                        layerOrder = layerOrder.filter {
                                            if case .stamp = $0 { return false }
                                            return true
                                        }
                                        // Remove stamp IDs from hidden set
                                        hiddenLayerIds = hiddenLayerIds.intersection(Set(drawingLayers.map { $0.id }))
                                        selectedStampId = nil; showStampMagicMenu = false
                                    }
                                }
                                Button("Cancel", role: .cancel) {}
                            }

                            // Layers panel toggle
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showLayersPanel.toggle()
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(showLayersPanel ? Color.yellow : Color(UIColor.secondarySystemBackground))
                                        .frame(width: 38, height: 38)
                                        .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                                    Image(systemName: "square.3.layers.3d")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(showLayersPanel ? .black : .primary)
                                }
                            }

                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }
                    .padding(.top, 10)
                }

                // Layers side panel
                layersPanelView

                // Legacy import banner
                if showLegacyImportBanner {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                            Text("Original layers aren't available — opened as background image")
                                .font(.system(size: 13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button { withAnimation { showLegacyImportBanner = false } } label: {
                                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.orange.opacity(0.92))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                    .zIndex(5)
                    .allowsHitTesting(true)
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
                            ThicknessPanel(lineWidth: $lineWidth, storageKey: isEraser ? "lastEraserWidth" : "lastLineWidth", onSelect: { showThicknessPicker = false })
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
                            // Save unfinished work so it can be resumed next session
                            let hasContent = !drawingLayers.isEmpty || !placedStamps.isEmpty || canvasBackgroundImage != nil
                            if hasContent, let data = saveSkadoodleData() {
                                try? data.write(to: FileManager.currentSkadoodleURL)
                            } else {
                                // Canvas is empty — delete any stale auto-save so it won't
                                // be offered for resume (e.g. user deleted the only stamp).
                                try? FileManager.default.removeItem(at: FileManager.currentSkadoodleURL)
                            }
                            isPresented = false
                        }
                    }
                    .disabled(isGeneratingCaption)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !isGeneratingCaption && !showResultCard {
                        Button {
                            isStampMode.toggle()
                            if isStampMode {
                                // Entering stamp mode — deselect any active stamp to start clean
                                selectedStampId = nil
                                showStampMagicMenu = false
                            }
                        } label: {
                            Image(systemName: isStampMode ? "hand.point.up.left.fill" : "pencil.and.scribble")
                                .foregroundStyle(isStampMode ? Color.accentColor : .primary)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isGeneratingCaption {
                        ProgressView().scaleEffect(0.8)
                    } else if !showResultCard {
                        Button("Done") { handleDone() }
                            .disabled(allLinesEmpty && placedStamps.isEmpty && canvasBackgroundImage == nil)
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
        // Auto-save when app goes to background
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            let hasContent = !drawingLayers.isEmpty || !placedStamps.isEmpty || canvasBackgroundImage != nil
            guard hasContent else { return }
            if let data = saveSkadoodleData() {
                try? data.write(to: FileManager.currentSkadoodleURL)
            }
        }
        // Load entry for re-edit, or offer to restore last auto-saved session
        .onAppear {
            if let entry = entryToEdit {
                if entry.hasSkadoodleFile, let data = try? Data(contentsOf: entry.skadoodleURL) {
                    // Full layer restore — v2.2+ doodle
                    restoreSkadoodleData(data)
                } else {
                    // Legacy doodle — load flat image as canvas background
                    if let img = UIImage(contentsOfFile: entry.imageURL.path) {
                        canvasBackgroundImage = img
                    }
                    showLegacyImportBanner = true
                }
            } else {
                let url = FileManager.currentSkadoodleURL
                let isEmpty = drawingLayers.isEmpty && placedStamps.isEmpty && canvasBackgroundImage == nil
                if isEmpty && FileManager.default.fileExists(atPath: url.path) {
                    showRestoreAlert = true
                }
            }
        }
        .alert("Resume Last Doodle?", isPresented: $showRestoreAlert) {
            Button("Resume") {
                if let data = try? Data(contentsOf: FileManager.currentSkadoodleURL) {
                    restoreSkadoodleData(data)
                }
            }
            Button("Discard", role: .cancel) {
                try? FileManager.default.removeItem(at: FileManager.currentSkadoodleURL)
            }
        } message: {
            Text("You have an unfinished doodle from your last session.")
        }
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
    var showLayersPanel: Bool = false
    var suppressCanvasTap: Bool = false
    var isStampMode: Bool = false          // hand tool — longpress delay collapses to near-zero
    var layerOrder: [LayerEntry] = []
    var selectedStampId: UUID? = nil
    var onLongPressStamp: ((UUID) -> Void)? = nil
    var onStampDragEnd: ((UUID) -> Void)? = nil   // called after long-press drag ends; re-shows menu
    var onStampTap: ((UUID) -> Void)? = nil
    var onCanvasTap: (() -> Void)? = nil
    var onBeforeStampChange: (() -> Void)? = nil
    var onBackgroundPanBegan: (() -> Void)? = nil
    var onBackgroundPan: ((CGSize) -> Void)? = nil
    var onBackgroundDoubleTap: (() -> Void)? = nil
    var blockGestures: Bool = false     // true when any sheet/picker is open over the canvas

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
                longPress.minimumPressDuration = 0.4
                longPress.allowableMovement = 30
                longPress.cancelsTouchesInView = false
                longPress.delegate = context.coordinator
                window.addGestureRecognizer(longPress)
                context.coordinator.longPressRecognizer = longPress

                let doubleTap = UITapGestureRecognizer(
                    target: context.coordinator,
                    action: #selector(Coordinator.handleWindowDoubleTap(_:))
                )
                doubleTap.numberOfTapsRequired = 2
                doubleTap.cancelsTouchesInView = false
                doubleTap.delegate = context.coordinator
                window.addGestureRecognizer(doubleTap)
                context.coordinator.doubleTapRecognizer = doubleTap

                let tap = UITapGestureRecognizer(
                    target: context.coordinator,
                    action: #selector(Coordinator.handleWindowTap(_:))
                )
                tap.numberOfTapsRequired = 1
                tap.cancelsTouchesInView = false
                tap.delegate = context.coordinator
                tap.require(toFail: doubleTap)
                window.addGestureRecognizer(tap)
                context.coordinator.tapRecognizer = tap
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        // In stamp/hand mode, collapse longpress delay so stamps drag immediately.
        context.coordinator.longPressRecognizer?.minimumPressDuration = isStampMode ? 0.05 : 0.4
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
            if let tap = coordinator.tapRecognizer {
                window.removeGestureRecognizer(tap)
            }
            if let doubleTap = coordinator.doubleTapRecognizer {
                window.removeGestureRecognizer(doubleTap)
            }
        }
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: WindowPinchView
        var pinchRecognizer: UIPinchGestureRecognizer?
        var rotationRecognizer: UIRotationGestureRecognizer?
        var longPressRecognizer: UILongPressGestureRecognizer?
        var tapRecognizer: UITapGestureRecognizer?
        var doubleTapRecognizer: UITapGestureRecognizer?
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
        var longPressDragStartPos: CGPoint? = nil
        var longPressDragStarted: Bool = false

        init(_ parent: WindowPinchView) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { return true }

        // Pencil touches go straight to DrawingCanvas — never intercepted at window level.
        // Window-level recognizers (pinch, rotation, pan, long press) are finger-only.
        // For the tap recognizer: also reject taps that land on interactive UIKit/SwiftUI
        // elements (picker cells, buttons, scroll views) so they never reach handleWindowTap.
        // This prevents picker taps from deselecting a just-placed stamp — no SwiftUI state
        // or render-cycle timing involved; shouldReceive fires before the gesture begins.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard touch.type != .pencil && touch.type != .stylus else { return false }
            // Block all window-level gestures when a sheet or picker is open over the canvas.
            if parent.blockGestures { return false }
            var view: UIView? = touch.view
            while let v = view {
                // UICollectionView / UITableView are the concrete backing views for SwiftUI List.
                // Block ALL gesture recognizers (tap, pinch, rotation, pan) when a touch
                // lands inside one — this covers the layers panel for multi-finger gestures.
                if v is UICollectionView || v is UITableView { return false }
                // Button / Control checks only needed for the tap recognizer.
                if gestureRecognizer === tapRecognizer {
                    let name = String(describing: type(of: v))
                    if name.contains("Button") || name.contains("Control") { return false }
                }
                view = v.superview
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
                // Always use alpha-aware hit testing — even for the selected stamp.
                // This prevents transparent padding around a stamp from being targetable.
                var touchPoints: [CGPoint] = []
                for i in 0..<g.numberOfTouches {
                    let wp = g.location(ofTouch: i, in: nil)
                    touchPoints.append(CGPoint(x: wp.x - parent.canvasOrigin.x,
                                               y: wp.y - parent.canvasOrigin.y))
                }
                var votes: [UUID: Int] = [:]
                for pt in touchPoints {
                    if let winner = topmostStampHit(at: pt, layerOrder: parent.layerOrder, stamps: parent.placedStamps) {
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
                // Always use alpha-aware hit testing (same as pinch).
                var touchPoints: [CGPoint] = []
                for i in 0..<g.numberOfTouches {
                    let wp = g.location(ofTouch: i, in: nil)
                    touchPoints.append(CGPoint(x: wp.x - parent.canvasOrigin.x,
                                               y: wp.y - parent.canvasOrigin.y))
                }
                var votes: [UUID: Int] = [:]
                for pt in touchPoints {
                    if let winner = topmostStampHit(at: pt, layerOrder: parent.layerOrder, stamps: parent.placedStamps) {
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
                if let id = targetId, let _ = parent.placedStamps.first(where: { $0.id == id }) {
                }
                parent.stampRotatingId = nil
                targetId = nil
            default: break
            }
        }

        @objc func handleWindowDoubleTap(_ g: UITapGestureRecognizer) {
            guard !parent.showLayersPanel else { return }
            let windowPt = g.location(in: nil)
            let canvasX = windowPt.x - parent.canvasOrigin.x
            let canvasY = windowPt.y - parent.canvasOrigin.y
            guard canvasX >= 0 && canvasY >= 0 &&
                  canvasX <= parent.canvasSize.width &&
                  canvasY <= parent.canvasSize.height else { return }
            let loc = CGPoint(x: canvasX, y: canvasY)
            // Only fire on background — never when a stamp is under the tap
            guard topmostStampHit(at: loc, layerOrder: parent.layerOrder, stamps: parent.placedStamps) == nil else { return }
            parent.onBackgroundDoubleTap?()
        }

        @objc func handleWindowTap(_ g: UITapGestureRecognizer) {
            guard !parent.showLayersPanel else { return }
            let windowPt = g.location(in: nil)
            let canvasX = windowPt.x - parent.canvasOrigin.x
            let canvasY = windowPt.y - parent.canvasOrigin.y
            guard canvasX >= 0 && canvasY >= 0 &&
                  canvasX <= parent.canvasSize.width &&
                  canvasY <= parent.canvasSize.height else { return }
            let loc = CGPoint(x: canvasX, y: canvasY)
            if let hit = topmostStampHit(at: loc, layerOrder: parent.layerOrder, stamps: parent.placedStamps) {
                parent.onStampTap?(hit.id)
            } else {
                guard !parent.suppressCanvasTap else { return }
                parent.onCanvasTap?()
            }
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            // Always clean up on end/cancel regardless of touch location.
            // Only call onCanvasTap if a stamp drag was actually in progress —
            // prevents long-pressing UI elements (e.g. TweakRepeatButton) from
            // dismissing the magic menu when the press is released.
            if g.state == .ended || g.state == .cancelled {
                let draggedStampId = longPressStampId
                parent.isLongPressing = false
                longPressStampId = nil
                longPressStartLocation = nil
                longPressDragStartPos = nil
                longPressDragStarted = false
                // Re-show the magic strip for the stamp that was dragged (don't deselect).
                if let stampId = draggedStampId { parent.onStampDragEnd?(stampId) }
                return
            }

            let windowPt = g.location(in: nil)
            let canvasX = windowPt.x - parent.canvasOrigin.x
            let canvasY = windowPt.y - parent.canvasOrigin.y
            let loc = CGPoint(x: canvasX, y: canvasY)

            guard canvasX >= 0 && canvasY >= 0 &&
                  canvasX <= parent.canvasSize.width &&
                  canvasY <= parent.canvasSize.height else { return }

            switch g.state {
            case .began:
                let hit = topmostStampHit(at: loc, layerOrder: parent.layerOrder, stamps: parent.placedStamps)
                guard let hitStamp = hit else { return }
                parent.isLongPressing = true
                longPressStampId = hitStamp.id
                longPressStartLocation = loc
                longPressDragStartPos = hitStamp.position
                longPressDragStarted = false
                parent.onLongPressStamp?(hitStamp.id)

            case .changed:
                guard let id = longPressStampId,
                      let idx = parent.placedStamps.firstIndex(where: { $0.id == id }),
                      let startLoc = longPressStartLocation,
                      let startPos = longPressDragStartPos else { return }
                if !longPressDragStarted {
                    longPressDragStarted = true
                    parent.onBeforeStampChange?()
                }
                parent.placedStamps[idx].position = CGPoint(
                    x: startPos.x + loc.x - startLoc.x,
                    y: startPos.y + loc.y - startLoc.y
                )

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
            stampHitTest(stamp: stamp, canvasPt: canvasPt)
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
    var onBeforeChange: (() -> Void)? = nil
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
                .shadow(color: stamp.shadowEnabled ? stamp.shadowColor : .clear,
                        radius: stamp.shadowBlur,
                        x: stamp.shadowOffsetX,
                        y: stamp.shadowOffsetY)
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
                    onBeforeChange?()
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


// MARK: - Detail / Swipe View
// Single consolidated view for viewing doodles.
// Pass a list of entries (full gallery or just one day) and a starting index.
// Swipe left/right to navigate within that list.

