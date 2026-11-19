import Foundation

/// Reads the text in an image, entirely on this Mac (FRD-007 FR-007-23, truth A3).
///
/// The text is for search only: the one caller is Storage's `TextRecognitionIndexer`, which stores it for the search
/// index and offers it to no editor, export or pasteboard. An implementation must not touch the network.
public protocol TextRecognitionPort: Sendable {
    /// The recognised lines, joined by newlines; empty when the image holds no text. A failure means this image could
    /// not be read (undecodable, or the system recogniser refused it); the caller records the attempt and moves on.
    func recognizeText(in imageData: Data) async -> FlotsamResult<String>
}
