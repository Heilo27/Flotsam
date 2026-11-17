import FlotsamBase
import Foundation

extension CaptureClassifier {
    /// FR-004-07: text saved from the editor. Rich representations are gone, so the kind is the FR-001-09 detection or
    /// plain text; the key is the FR-001-15 text key over the exact UTF-8 bytes.
    public static func classifyEditedText(_ text: String) -> ItemClassification {
        ItemClassification(
            kind: TypedTextDetector.detect(text) ?? .text, contentKey: ContentKey.text(Data(text.utf8)))
    }

    /// FR-004-11: one bundle member as an item of its own. Same file/folder rule as a single copied file
    /// (FR-001-12), same key as a one-path capture, so a later copy of that file dedupes against it.
    public static func classifyMember(path: String, isDirectory: Bool) -> ItemClassification {
        ItemClassification(kind: memberKind(path: path, isDirectory: isDirectory), contentKey: ContentKey.files(paths: [path]))
    }

    /// A directory is a `folder` unless it is a package (an app, a document bundle), which behaves as a `file`.
    static func memberKind(path: String, isDirectory: Bool) -> ItemKind {
        guard isDirectory,
              (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) != true
        else { return .file }
        return .folder
    }
}

extension ItemClassifiers {
    /// The classifiers the app uses: the capture rules themselves.
    public static let live = ItemClassifiers(
        editedText: { CaptureClassifier.classifyEditedText($0) },
        fileMember: { CaptureClassifier.classifyMember(path: $0, isDirectory: $1) })
}
