#if canImport(CoreImage) && !os(watchOS)
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Renders a pairing secret's base64 as a QR code so the phone can pair by
/// scanning the Mac's screen instead of copy/paste. Kept in the shared core so
/// the mac (display) and iOS (verify what it scanned) agree on the encoding —
/// the plain base64 string, nothing else.
///
/// Excluded from watchOS: the QR generator filter isn't available there, and
/// the watch pairs by relaying through the already-paired phone anyway.
public enum PairingQR {
  /// A crisp QR `CGImage` for `text`, or nil if generation fails. `scale`
  /// enlarges the (tiny) native output so SwiftUI can draw it without blur.
  public static func image(for text: String, scale: CGFloat = 12) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return CIContext().createCGImage(scaled, from: scaled.extent)
  }
}
#endif
