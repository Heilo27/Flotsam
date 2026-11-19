import FlotsamBase
import Foundation
import Vision

/// `TextRecognitionPort` over Apple's Vision framework (FRD-007 FR-007-23, truth A3).
///
/// Entirely on this Mac: `VNRecognizeTextRequest` runs the system's built-in model and this type has no network code.
/// The text it returns goes to the search index and nowhere else. The request runs on a background-QoS queue, so a
/// backfill never competes with anything the user is doing, and it holds no state, so one instance serves every call.
///
/// Not unit tested against the real recogniser: it needs a real image and the system model. The decision about what
/// to do with a result (store, record as attempted, report) lives in `TextRecognitionIndexer`.
struct VisionTextRecognizer: TextRecognitionPort {
    private static let queue = DispatchQueue(label: "flotsam.ocr", qos: .background)

    func recognizeText(in imageData: Data) async -> FlotsamResult<String> {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.recognize(imageData))
            }
        }
    }

    /// Reads one image synchronously; the caller supplies the background queue.
    private static func recognize(_ imageData: Data) -> FlotsamResult<String> {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(data: imageData, options: [:]).perform([request])
        } catch {
            return .failure(
                FlotsamError(.stoIo001, "Image text could not be recognised", underlying: UnderlyingErrorInfo(error)))
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return .success(lines.joined(separator: "\n"))
    }
}
