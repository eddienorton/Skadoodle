//
//  SnoodleAuth.swift
//  snoodle
//
//  Sign in and profile setup views
//

import SwiftUI
import AuthenticationServices
import FirebaseAuth
import FirebaseStorage

// MARK: - Sign In View

struct SignInView: View {
    @ObservedObject var auth = SnoodleAuthManager.shared
    @Environment(\.dismiss) var dismiss
    var onComplete: (() -> Void)? = nil
    var showCancel: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 12) {
                    Image("SnoodleIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
                        .cornerRadius(18)
                        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
                    Text("Join Skadoodle").font(.system(size: 32, weight: .bold))
                    Text("Sign in to share your doodles\nwith the world gallery")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    SignInWithAppleButton(.signIn) { request in
                        auth.handleSignInRequest(request)
                    } onCompletion: { result in
                        auth.handleSignInCompletion(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 400 : .infinity, minHeight: 50, maxHeight: 50)
                    .cornerRadius(12)
                    .padding(.horizontal, 40)

                    if auth.isLoading {
                        ProgressView()
                    }

                    if let error = auth.errorMessage {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                }

                Text("Your personal gallery never requires sign-in.\nOnly world gallery submissions need an account.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showCancel {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn {
                onComplete?()
                dismiss()
            }
        }
    }
}

// MARK: - Image Picker

struct ImagePickerView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss
    var sourceType: UIImagePickerController.SourceType = .photoLibrary

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = sourceType
        picker.allowsEditing = true
        if sourceType == .camera { picker.cameraDevice = .front }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePickerView
        init(_ parent: ImagePickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let edited = info[.editedImage] as? UIImage {
                parent.image = edited
            } else if let original = info[.originalImage] as? UIImage {
                parent.image = original
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
