//
//  CustomStampManager.swift
//  snoodle
//
//  Custom photo stamps — individual object extraction via Vision instance segmentation
//

import SwiftUI
import Vision
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Combine

// MARK: - Stamp Source

enum StampSource: String, Codable {
    case photo, doodle
}

// MARK: - Custom Stamp Model

struct CustomStamp: Identifiable, Codable {
    let id: UUID
    let filename: String  // UUID.png in Documents
    var dateAdded: Date
    var source: StampSource

    init(id: UUID = UUID(), filename: String, dateAdded: Date = Date(), source: StampSource = .photo) {
        self.id = id
        self.filename = filename
        self.dateAdded = dateAdded
        self.source = source
    }

    // Custom decoder: default source to .photo so existing saved stamps decode cleanly
    enum CodingKeys: String, CodingKey { case id, filename, dateAdded, source }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,   forKey: .id)
        filename  = try c.decode(String.self, forKey: .filename)
        dateAdded = try c.decode(Date.self,   forKey: .dateAdded)
        source    = try c.decodeIfPresent(StampSource.self, forKey: .source) ?? .photo
    }

    var imageURL: URL {
        CustomStampManager.shared.documentsURL.appendingPathComponent(filename)
    }

    var image: UIImage? {
        UIImage(contentsOfFile: imageURL.path)
    }
}

// MARK: - Manager

class CustomStampManager: ObservableObject {
    static let shared = CustomStampManager()
    @Published var stamps: [CustomStamp] = []

    var photoStamps: [CustomStamp]  { stamps.filter { $0.source == .photo } }
    var doodleStamps: [CustomStamp] { stamps.filter { $0.source == .doodle } }

    let documentsURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("custom_stamps")
    }()

    private let metadataURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("custom_stamps_metadata.json")
    }()

    init() {
        // Create directory if needed
        try? FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let loaded = try? JSONDecoder().decode([CustomStamp].self, from: data) else { return }
        stamps = loaded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(stamps) else { return }
        try? data.write(to: metadataURL)
    }

    func addStamp(image: UIImage, maxDimension: CGFloat = 600, source: StampSource = .photo) -> CustomStamp? {
        let downsampled = image.downsampled(toMaxDimension: maxDimension)
        guard let png = downsampled.pngData() else { return nil }
        let id = UUID()
        let filename = "\(id.uuidString).png"
        let url = documentsURL.appendingPathComponent(filename)
        guard (try? png.write(to: url)) != nil else { return nil }
        let stamp = CustomStamp(id: id, filename: filename, source: source)
        stamps.insert(stamp, at: 0)
        save()
        return stamp
    }

    func delete(_ stamp: CustomStamp) {
        try? FileManager.default.removeItem(at: stamp.imageURL)
        stamps.removeAll { $0.id == stamp.id }
        save()
    }
}

// MARK: - Object Segmentation

struct SegmentedObject: Identifiable {
    let id = UUID()
    let index: Int
    let image: UIImage
    let thumbnail: UIImage
}

class ObjectSegmentationModel: ObservableObject {
    @Published var objects: [SegmentedObject] = []
    @Published var isProcessing = false
    @Published var error: String? = nil
    @Published var progressText: String = "Finding objects…"

    /// Load pre-processed objects directly — skips Vision processing entirely.
    @MainActor
    func load(preProcessed: [SegmentedObject]) {
        objects = preProcessed
        isProcessing = false
        error = nil
    }

    func processAll(images: [UIImage]) async {
        await MainActor.run {
            isProcessing = true
            error = nil
            objects = []
            progressText = images.count > 1 ? "Photo 1 of \(images.count)…" : "Finding objects…"
        }

        var allFound: [SegmentedObject] = []

        for (i, image) in images.enumerated() {
            if images.count > 1 {
                await MainActor.run {
                    progressText = "Photo \(i + 1) of \(images.count)…"
                }
            }
            let found = await extractObjects(from: image)
            allFound.append(contentsOf: found)
        }

        await MainActor.run {
            objects = allFound
            if objects.isEmpty {
                error = "No distinct objects found"
            }
            isProcessing = false
        }
    }

    // Keep single-image entry point for camera flow
    func process(image: UIImage) async {
        await processAll(images: [image])
    }

    private func extractObjects(from image: UIImage) async -> [SegmentedObject] {
        let normalizedImage = image.normalizedOrientation()
        guard let cgImage = normalizedImage.cgImage else { return [] }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return [] }

            var found: [SegmentedObject] = []
            for index in result.allInstances {
                if let cutout = extractObject(index: index, from: result, originalImage: normalizedImage, cgImage: cgImage) {
                    let thumb = cutout.thumbnailed(to: CGSize(width: 120, height: 120))
                    found.append(SegmentedObject(index: index, image: cutout, thumbnail: thumb ?? cutout))
                }
            }
            return found
        } catch {
            return []
        }
    }

    private func extractObject(index: Int, from result: VNInstanceMaskObservation, originalImage: UIImage, cgImage: CGImage) -> UIImage? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard let maskBuffer = try? result.generateScaledMaskForImage(forInstances: IndexSet([index]), from: handler) else {
            return nil
        }

        let maskCI = CIImage(cvPixelBuffer: maskBuffer)
        let originalCI = CIImage(cgImage: cgImage)

        // Apply mask
        let filter = CIFilter.blendWithMask()
        filter.inputImage = originalCI
        filter.maskImage = maskCI
        filter.backgroundImage = CIImage.empty()

        guard let output = filter.outputImage else { return nil }

        let context = CIContext()
        // Crop to actual content bounds
        let extent = output.extent
        guard let rendered = context.createCGImage(output, from: extent) else { return nil }

        let full = UIImage(cgImage: rendered)
        return full.croppedToContent()
    }
}

// MARK: - UIImage Extensions

extension UIImage {
    /// Redraw image so orientation is always .up — fixes rotated Vision results
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return normalized
    }
    /// Returns the cropped image and its top-left origin within the receiver (point coordinates).
    func croppedToContentWithOrigin() -> (image: UIImage, origin: CGPoint)? {
        guard let cgImage = cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                if pixels[(y * width + x) * 4 + 3] > 10 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX && maxY > minY else { return nil }
        let padding = 4
        let cropX = max(0, minX - padding)
        let cropY = max(0, minY - padding)
        let cropW = min(width - cropX, maxX - minX + padding * 2)
        let cropH = min(height - cropY, maxY - minY + padding * 2)
        guard let cgCropped = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) else { return nil }
        let croppedImage = UIImage(cgImage: cgCropped, scale: scale, orientation: imageOrientation)
        let origin = CGPoint(x: CGFloat(cropX) / scale, y: CGFloat(cropY) / scale)
        return (croppedImage, origin)
    }

    /// Crop transparent padding to content bounds
    func croppedToContent() -> UIImage? {
        guard let cgImage = cgImage else { return self }
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = pixels[(y * width + x) * 4 + 3]
                if alpha > 10 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX > minX && maxY > minY else { return self }
        let padding = 4
        let cropRect = CGRect(x: max(0, minX - padding), y: max(0, minY - padding),
                              width: min(width, maxX - minX + padding * 2),
                              height: min(height, maxY - minY + padding * 2))
        guard let cropped = cgImage.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: cropped, scale: scale, orientation: imageOrientation)
    }

    func downsampled(toMaxDimension maxDim: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDim else { return self }
        let scale = maxDim / longest
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: newSize))
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }

    func thumbnailed(to size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        let aspect = self.size.width / self.size.height
        var drawRect = CGRect.zero
        if aspect > 1 {
            drawRect = CGRect(x: 0, y: (size.height - size.width/aspect)/2, width: size.width, height: size.width/aspect)
        } else {
            drawRect = CGRect(x: (size.width - size.height*aspect)/2, y: 0, width: size.height*aspect, height: size.height)
        }
        draw(in: drawRect)
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
