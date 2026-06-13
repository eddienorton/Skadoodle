//
//  CustomStampViews.swift
//  snoodle
//

import SwiftUI
import PhotosUI

// MARK: - Object Segmentation Sheet

struct ObjectSegmentationSheet: View {
    let images: [UIImage]
    let onSelect: ([UIImage]) -> Void
    @StateObject private var model = ObjectSegmentationModel()
    @Environment(\.dismiss) var dismiss
    @State private var selectedIds: Set<UUID> = []

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
                await model.processAll(images: images)
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
