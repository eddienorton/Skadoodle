// VideoTimelineView.swift
// Chapter break editor for Skadoodle timelapse video.
//
// Shows all drawing layers and stamps as a horizontal chip strip ordered by creation
// time. Chapter break markers sit between chips. Tap a gap between chips to insert
// a break there. Tap an existing break marker to edit duration or delete it.

import SwiftUI

// MARK: - Timeline entry (chip or chapter break)

private enum TimelineItem: Identifiable {
    case layer(DrawingLayer)
    case stamp(PlacedStamp)
    case chapter(ChapterBreak)

    var id: UUID {
        switch self {
        case .layer(let l):   return l.id
        case .stamp(let s):   return s.id
        case .chapter(let c): return c.id
        }
    }

    var timestamp: Date {
        switch self {
        case .layer(let l):   return l.createdAt
        case .stamp(let s):   return s.createdAt
        case .chapter(let c): return c.timestamp
        }
    }
}

// MARK: - VideoTimelineView

struct VideoTimelineView: View {
    let document: SkadoodleDocument
    @Binding var chapterBreaks: [ChapterBreak]
    let thumbnails: [UUID: UIImage]
    let canvasSize: CGSize
    @Environment(\.dismiss) private var dismiss

    @State private var editingBreak: ChapterBreak? = nil
    @StateObject private var exporter = DoodleTimelapseExporter()
    @State private var exportedURL: URL? = nil
    @State private var showPlayer = false

    /// Document with the latest chapter breaks (which may have been edited in this view).
    private var exportDocument: SkadoodleDocument {
        var d = document
        d.chapterBreaks = chapterBreaks
        return d
    }

    private var timelineItems: [TimelineItem] {
        var items: [TimelineItem] = []
        for layer in document.drawingLayers { items.append(.layer(layer)) }
        for stamp in document.placedStamps  { items.append(.stamp(stamp)) }
        for cb    in chapterBreaks          { items.append(.chapter(cb)) }
        return items.sorted { $0.timestamp < $1.timestamp }
    }

    // Insert a chapter break between items[index] and items[index+1].
    // Uses midpoint timestamp so it sorts exactly into that gap.
    private func insertBreak(after index: Int) {
        let items = timelineItems
        let leftT  = items[index].timestamp.timeIntervalSince1970
        let rightT = index + 1 < items.count
            ? items[index + 1].timestamp.timeIntervalSince1970
            : leftT + 2.0
        // If equal (old epoch files), nudge by small offset to maintain order
        let mid = leftT < rightT
            ? (leftT + rightT) / 2
            : leftT + Double(index + 1) * 0.001
        chapterBreaks.append(ChapterBreak(timestamp: Date(timeIntervalSince1970: mid)))
    }

    private var lastItemIsBreak: Bool {
        if case .chapter(_) = timelineItems.last { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Tap between chips to add a chapter pause. Tap a pause marker to edit or remove it.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 16)

                Divider()

                if timelineItems.isEmpty {
                    Spacer()
                    Text("No content yet — draw something first.")
                        .foregroundColor(.secondary)
                        .font(.system(size: 15))
                    Spacer()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(timelineItems.enumerated()), id: \.element.id) { index, item in
                                // The chip
                                switch item {
                                case .layer(let layer):
                                    LayerChip(layer: layer, thumbnail: thumbnails[layer.id])
                                case .stamp(let stamp):
                                    StampChip(stamp: stamp, thumbnail: thumbnails[stamp.id])
                                case .chapter(let cb):
                                    ChapterBreakChip(chapterBreak: cb) { editingBreak = cb }
                                }

                                // Tappable gap after each chip — only between two content chips
                                let nextIsBreak: Bool = {
                                    guard index + 1 < timelineItems.count else { return false }
                                    if case .chapter(_) = timelineItems[index + 1] { return true }
                                    return false
                                }()
                                if case .chapter(_) = item { } else if !nextIsBreak {
                                    InsertGap { insertBreak(after: index) }
                                }
                            }
                        }
                        .padding(.leading, 20)
                        .padding(.trailing, 8)
                        .padding(.vertical, 20)
                    }
                }

                Divider()

                if exporter.isExporting {
                    ProgressView(value: exporter.progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                }

                // "Add now" — appends a break after everything.
                // Disabled when the last item is already a chapter break (no consecutive breaks).
                Button {
                    chapterBreaks.append(ChapterBreak(timestamp: Date()))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                        Text("Add chapter break at end")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundColor(lastItemIsBreak ? .gray : .blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .disabled(lastItemIsBreak)
            }
            .navigationTitle("Video Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if exporter.isExporting {
                        Button { exporter.cancel() } label: {
                            Text("Cancel").font(.system(size: 15))
                        }
                    } else {
                        Button {
                            let scale = currentScreenScale()
                            let pixelSize = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
                            exporter.export(
                                document: exportDocument,
                                pointSize: canvasSize,
                                pixelSize: pixelSize,
                                date: Date()
                            ) { url in
                                guard let url else { return }
                                exportedURL = url
                                showPlayer = true
                            }
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.blue)
                        }
                        .disabled(timelineItems.isEmpty)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showPlayer, onDismiss: {
                if let url = exportedURL {
                    try? FileManager.default.removeItem(at: url)
                    exportedURL = nil
                }
            }) {
                if let url = exportedURL {
                    VideoPlayerView(url: url).ignoresSafeArea()
                }
            }
            .sheet(item: $editingBreak) { cb in
                ChapterBreakEditSheet(
                    chapterBreak: cb,
                    onUpdate: { updated, applyToAll in
                        if applyToAll {
                            // Apply the new hold duration to every chapter
                            // break, not just this one — each break keeps its
                            // own timestamp, only holdDuration is synced.
                            for i in chapterBreaks.indices {
                                chapterBreaks[i].holdDuration = updated.holdDuration
                            }
                        } else if let i = chapterBreaks.firstIndex(where: { $0.id == updated.id }) {
                            chapterBreaks[i] = updated
                        }
                        editingBreak = nil
                    },
                    onDelete: {
                        chapterBreaks.removeAll { $0.id == cb.id }
                        editingBreak = nil
                    }
                )
                .presentationDetents([.height(210)])
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Insert gap

private struct InsertGap: View {
    let onInsert: () -> Void
    @State private var flashed = false

    var body: some View {
        ZStack {
            // Invisible tap area
            Color.clear.frame(width: 24, height: 96)

            // Subtle vertical line — pulses blue briefly on tap
            RoundedRectangle(cornerRadius: 1)
                .fill(flashed ? Color.blue.opacity(0.7) : Color.gray.opacity(0.18))
                .frame(width: 2, height: 36)
                .animation(.easeOut(duration: 0.25), value: flashed)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            flashed = true
            onInsert()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { flashed = false }
        }
    }
}

// MARK: - Layer chip

private struct LayerChip: View {
    let layer: DrawingLayer
    let thumbnail: UIImage?
    private let chipSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
                    .frame(width: chipSize, height: chipSize)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))

                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: chipSize, height: chipSize)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if layer.lines.allSatisfy({ $0.isEraser }) {
                    Image(systemName: "eraser.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.gray.opacity(0.4))
                } else {
                    Image(systemName: "pencil")
                        .font(.system(size: 22))
                        .foregroundColor(.gray.opacity(0.5))
                }
            }
            Text("Layer")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Stamp chip

private struct StampChip: View {
    let stamp: PlacedStamp
    let thumbnail: UIImage?
    private let chipSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
                    .frame(width: chipSize, height: chipSize)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))

                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: chipSize, height: chipSize)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let img = stamp.inlineImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: chipSize - 12, height: chipSize - 12)
                } else if let text = stamp.stampText {
                    Text(text.prefix(6))
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(4)
                } else {
                    Text(stamp.emoji)
                        .font(.system(size: 32))
                }
            }
            Text("Stamp")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Chapter break chip

private struct ChapterBreakChip: View {
    let chapterBreak: ChapterBreak
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Rectangle()
                    .fill(Color.blue.opacity(0.7))
                    .frame(width: 3, height: 72)
                    .clipShape(Capsule())

                Circle()
                    .fill(Color.blue)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "clock")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    )
            }
            .frame(width: 44, height: 72)

            Text(chapterBreak.holdDuration == floor(chapterBreak.holdDuration) ? "\(Int(chapterBreak.holdDuration))s" : String(format: "%.1fs", chapterBreak.holdDuration))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.blue)
        }
        .padding(.horizontal, 4)
        .onTapGesture { onTap() }
    }
}

// MARK: - Chapter break edit sheet

private struct ChapterBreakEditSheet: View {
    let chapterBreak: ChapterBreak
    // Second param: whether "apply to all" was checked when Save was tapped.
    let onUpdate: (ChapterBreak, Bool) -> Void
    let onDelete: () -> Void

    @State private var duration: Double
    // Defaults unchecked — applying to every break is the less common case,
    // shouldn't be an accidental default when someone's just tweaking one.
    @State private var applyToAll: Bool = false

    init(chapterBreak: ChapterBreak, onUpdate: @escaping (ChapterBreak, Bool) -> Void, onDelete: @escaping () -> Void) {
        self.chapterBreak = chapterBreak
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        _duration = State(initialValue: chapterBreak.holdDuration)
    }

    private let durations: [Double] = [0.5, 1, 1.5, 2, 3, 4, 5, 6]

    var body: some View {
        VStack(spacing: 12) {
            Text("Chapter Pause")
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 14)

            HStack(spacing: 8) {
                ForEach(durations, id: \.self) { d in
                    Button {
                        duration = d
                    } label: {
                        Text(d == floor(d) ? "\(Int(d))s" : String(format: "%.1fs", d))
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 38, height: 38)
                            .background(duration == d ? Color.blue : Color(white: 0.93))
                            .foregroundColor(duration == d ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
            }

            Button {
                applyToAll.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: applyToAll ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18))
                        .foregroundColor(applyToAll ? .blue : .secondary)
                    Text("Apply this time to all chapter breaks")
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Divider()

            HStack(spacing: 20) {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Text("Remove break")
                        .font(.system(size: 15))
                }

                Spacer()

                Button {
                    var updated = chapterBreak
                    updated.holdDuration = duration
                    onUpdate(updated, applyToAll)
                } label: {
                    Text("Save")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
    }
}
