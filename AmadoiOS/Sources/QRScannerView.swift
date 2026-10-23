// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: MPL-2.0

@preconcurrency import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - QRScannerView

/// A camera QR scanner presented as a sheet. Calls `onScan` once with the first
/// QR payload it reads. `@preconcurrency import AVFoundation` because the
/// capture types predate `Sendable`. Session configuration and start/stop run
/// on one serial queue; preview updates and scan callbacks run on the main queue.
struct QRScannerView: UIViewControllerRepresentable {
  let onScan: (String) -> Void

  func makeUIViewController(context _: Context) -> ScannerViewController {
    let controller = ScannerViewController()
    controller.onScan = onScan
    return controller
  }

  func updateUIViewController(_ controller: ScannerViewController, context _: Context) {
    controller.onScan = onScan
  }
}

// MARK: - ScannerViewController

final class ScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {

  // MARK: Internal

  var onScan: ((String) -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    previewLayer = layer
    view.layer.addSublayer(layer)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .preferredFont(forTextStyle: .body)
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.textColor = .white
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 0
    view.addSubview(statusLabel)
    NSLayoutConstraint.activate([
      statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      statusLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    isVisible = true

    if #available(iOS 27.1, *) {
      // Camera position alone doesn't describe its direction after changing displays.
      directionCoordinator = AVCaptureDeviceDirectionCoordinator(
        view: view,
        deviceTypes: [.builtInWideAngleCamera, .builtInOuterUltraWideCamera, .builtInInnerUltraWideCamera],
      ) { [weak self] directions in
        MainActor.assumeIsolated {
          self?.selectCamera(from: directions)
        }
      }
    } else {
      configureCamera(uniqueID: nil)
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    isVisible = false
    isReadyToScan = false
    cameraRequestID = UUID()
    directionCoordinator = nil
    rotationObservation = nil
    rotationCoordinator = nil
    selectedCameraID = nil

    stopSession()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
    updatePreviewRotation()
  }

  func metadataOutput(
    _: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection,
  ) {
    guard
      isVisible,
      isReadyToScan,
      !didScan,
      let input = connection.inputPorts.first?.input as? AVCaptureDeviceInput,
      input.device.uniqueID == activeCameraID,
      let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
      let value = object.stringValue
    else { return }
    didScan = true
    onScan?(value)
  }

  // MARK: Private

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "dev.PangMo5.Amado.QRScanner", qos: .userInitiated)
  private let statusLabel = UILabel()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var directionCoordinator: AnyObject?
  private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
  private var rotationObservation: NSKeyValueObservation?
  private var selectedCameraID: String?
  private var activeCameraID: String?
  private var cameraRequestID = UUID()
  private var isVisible = false
  private var isReadyToScan = false
  private var didScan = false

  @available(iOS 27.1, *)
  private func selectCamera(from directions: AVCaptureDeviceDirectionMap) {
    guard isVisible else { return }
    let cameras = directions.backwardFacingDeviceDescriptors
    if let selectedCameraID, cameras.contains(where: { $0.uniqueID == selectedCameraID }) {
      return
    }
    guard let camera = cameras.first else {
      selectedCameraID = nil
      cameraRequestID = UUID()
      showCameraError(
        String(localized: "No camera is available in this position. Open or close your iPhone to continue scanning.")
      )
      stopSession()
      return
    }
    configureCamera(uniqueID: camera.uniqueID)
  }

  private func configureCamera(uniqueID: String?) {
    selectedCameraID = uniqueID
    let requestID = UUID()
    cameraRequestID = requestID
    isReadyToScan = false
    statusLabel.text = nil
    previewLayer?.isHidden = true
    let session = session
    let onFailure: @Sendable () -> Void = { [weak self] in
      DispatchQueue.main.async { [weak self] in
        guard let self, isVisible, cameraRequestID == requestID else { return }
        selectedCameraID = nil
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let message = authorization == .denied || authorization == .restricted
          ? String(localized: "Allow Camera access in Settings, then reopen the scanner.")
          : String(localized: "Camera unavailable. Reopen the scanner to try again.")
        showCameraError(message)
        stopSession()
      }
    }

    sessionQueue.async { [weak self] in
      let device: AVCaptureDevice? =
        if let uniqueID {
          AVCaptureDevice(uniqueID: uniqueID)
        } else {
          AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
      guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
        onFailure()
        return
      }

      session.beginConfiguration()
      for previousInput in session.inputs {
        session.removeInput(previousInput)
      }
      guard session.canAddInput(input) else {
        session.commitConfiguration()
        onFailure()
        return
      }
      session.addInput(input)

      if session.outputs.isEmpty {
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
          session.commitConfiguration()
          onFailure()
          return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
      }
      session.commitConfiguration()
      if !session.isRunning {
        session.startRunning()
      }
      guard session.isRunning else {
        onFailure()
        return
      }

      DispatchQueue.main.async { [weak self] in
        guard let self, isVisible, cameraRequestID == requestID, let previewLayer else { return }
        activeCameraID = device.uniqueID
        rotationObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator
          .observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
              self?.updatePreviewRotation()
            }
          }
        updatePreviewRotation()
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
          connection.automaticallyAdjustsVideoMirroring = false
          connection.isVideoMirrored = false
        }
        previewLayer.isHidden = false
        isReadyToScan = true
      }
    }
  }

  private func updatePreviewRotation() {
    guard let rotationCoordinator, let connection = previewLayer?.connection else { return }
    let angle = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
    if connection.isVideoRotationAngleSupported(angle) {
      connection.videoRotationAngle = angle
    }
  }

  private func showCameraError(_ message: String) {
    isReadyToScan = false
    previewLayer?.isHidden = true
    statusLabel.text = message
  }

  private func stopSession() {
    let session = session
    sessionQueue.async {
      if session.isRunning {
        session.stopRunning()
      }
    }
  }

}
