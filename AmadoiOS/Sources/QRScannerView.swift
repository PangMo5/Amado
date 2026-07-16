@preconcurrency import AVFoundation
import SwiftUI
import UIKit

// MARK: - QRScannerView

/// A camera QR scanner presented as a sheet. Calls `onScan` once with the first
/// QR payload it reads. `@preconcurrency import AVFoundation` because the
/// capture delegate and session types predate `Sendable`; the delegate is
/// pinned to the main queue so the UI callback is safe.
struct QRScannerView: UIViewControllerRepresentable {
  let onScan: (String) -> Void

  func makeUIViewController(context _: Context) -> ScannerViewController {
    let controller = ScannerViewController()
    controller.onScan = onScan
    return controller
  }

  func updateUIViewController(_: ScannerViewController, context _: Context) { }
}

// MARK: - ScannerViewController

final class ScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {

  // MARK: Internal

  var onScan: ((String) -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    guard
      let device = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input)
    else { return }
    session.addInput(input)

    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else { return }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]

    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    previewLayer = layer
    view.layer.addSublayer(layer)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    guard !session.isRunning else { return }
    // `startRunning` blocks, so keep it off the main thread.
    let session = session
    Task.detached(priority: .userInitiated) {
      session.startRunning()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if session.isRunning {
      session.stopRunning()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
  }

  func metadataOutput(
    _: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from _: AVCaptureConnection,
  ) {
    guard
      !didScan,
      let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
      let value = object.stringValue
    else { return }
    didScan = true
    onScan?(value)
  }

  // MARK: Private

  private let session = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var didScan = false

}
