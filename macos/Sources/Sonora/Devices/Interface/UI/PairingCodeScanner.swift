@preconcurrency import AVFoundation
import SwiftUI

struct PairingCodeScanner: NSViewRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onError: onError)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.start(in: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator:
        NSObject,
        AVCaptureMetadataOutputObjectsDelegate,
        @unchecked Sendable
    {
        private let session = AVCaptureSession()
        private let onCode: (String) -> Void
        private let onError: (String) -> Void
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var hasDeliveredCode = false

        init(
            onCode: @escaping (String) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onCode = onCode
            self.onError = onError
        }

        func start(in view: NSView) {
            Task { @MainActor in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard granted else {
                    onError(
                        "Camera access is off. Enter the six-digit code instead."
                    )
                    return
                }
                configure(in: view)
            }
        }

        @MainActor
        private func configure(in view: NSView) {
            guard let camera = AVCaptureDevice.default(for: .video) else {
                onError("No camera is available on this Mac.")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input) else {
                    onError("Sonora couldn’t use this camera.")
                    return
                }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else {
                    onError("QR scanning is unavailable.")
                    return
                }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]

                let layer = AVCaptureVideoPreviewLayer(session: session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = view.bounds
                layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                view.wantsLayer = true
                view.layer?.addSublayer(layer)
                previewLayer = layer
                DispatchQueue.global(qos: .userInitiated).async { [session] in
                    session.startRunning()
                }
            } catch {
                onError(error.localizedDescription)
            }
        }

        func stop() {
            if session.isRunning {
                session.stopRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasDeliveredCode,
                  let object = metadataObjects.first
                    as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else {
                return
            }
            hasDeliveredCode = true
            onCode(value)
        }
    }
}
