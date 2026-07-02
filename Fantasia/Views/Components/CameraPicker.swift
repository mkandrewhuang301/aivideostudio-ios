// CameraPicker.swift
// Fantasia
// UIViewControllerRepresentable wrapper for UIImagePickerController camera capture.
// Used by GenerateView's paperclip menu to attach a reference photo/video via camera.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraPicker: UIViewControllerRepresentable {
    var allowsVideo: Bool
    var onCapture: (Data, Bool) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = allowsVideo ? [UTType.image.identifier, UTType.movie.identifier] : [UTType.image.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer { picker.dismiss(animated: true) }

            if let videoURL = info[.mediaURL] as? URL, let data = try? Data(contentsOf: videoURL) {
                parent.onCapture(data, true)
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data, false)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onCancel()
        }
    }
}
