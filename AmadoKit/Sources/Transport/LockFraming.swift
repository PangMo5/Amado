import Foundation

/// Message framing for the stream socket. Envelope JSON is base64-for-`Data`
/// and therefore newline-free, so a single `\n` unambiguously delimits one
/// command. The client appends the delimiter; the agent reads up to it.
public enum LockFraming {
  public static let delimiter: UInt8 = 0x0A // "\n"

  /// Append the delimiter to a wire payload for transmission.
  public static func frame(_ payload: Data) -> Data {
    var framed = payload
    framed.append(delimiter)
    return framed
  }
}
