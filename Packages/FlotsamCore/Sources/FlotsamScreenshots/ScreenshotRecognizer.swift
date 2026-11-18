import FlotsamBase
import Foundation

/// The one screenshot recognition rule (FRD-002 FR-002-06, ADR-0008). Live pickup, the reconcile scan and
/// "Import recent screenshots" all call `qualifies`, so the test is identical for the system folder, the Desktop
/// fallback and an override.
public enum ScreenshotRecognizer {
    /// The extended attribute macOS writes when it saves a screenshot. Spike S-8 (2026-11-17, macOS 26.7): present on
    /// the file the moment `screencapture` writes it, before Spotlight has indexed anything.
    public static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"

    /// Image extensions a screenshot can have, lower-cased.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic"]

    /// Whether a direct child of the watched folder is a screenshot.
    /// - Parameters:
    ///   - fileName: the last path component.
    ///   - attribute: the raw `screenCaptureAttribute` value, nil when absent.
    ///   - customPrefix: the `name` value of `com.apple.screencapture`, nil when unset.
    public static func qualifies(fileName: String, attribute: Data?, customPrefix: String?) -> Bool {
        guard hasCandidateName(fileName) else { return false }
        if let attribute { return isTrue(attribute) }
        return ScreenshotNamePrefixes.matches(fileName, customPrefix: customPrefix)
    }

    /// A hidden name: the temporary name macOS saves a screenshot under before it renames the file (FR-002-06, FR-002-08).
    public static func isHiddenName(_ fileName: String) -> Bool { fileName.hasPrefix(".") }

    /// FR-002-06 (a) and (b): not hidden (macOS writes a hidden temporary name, then renames) and an image extension.
    /// Needs no file-system call, so scanners use it to reject most of a busy folder before reading anything.
    public static func hasCandidateName(_ fileName: String) -> Bool {
        !isHiddenName(fileName) && imageExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// The attribute is a binary property list holding a boolean (or, on some writers, a number).
    static func isTrue(_ attribute: Data) -> Bool {
        let value = try? PropertyListSerialization.propertyList(from: attribute, options: [], format: nil)
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}

/// The single list of file-name prefixes that mark a screenshot when the attribute is absent (FR-002-06).
///
/// Source: the `Screenshot` entry of screencaptureui's `Localizable.loctable` on macOS 26.7, for every language the
/// system ships (spike S-8). Every language's file-name format starts with this word. "Screen Shot" is the name macOS
/// used before 12.
public enum ScreenshotNamePrefixes {
    public static let system: [String] = [
        "Screenshot", "Screen Shot",
        "لقطة الشاشة",  // ar
        "Captura de pantalla",  // ca, es, es_419, es_US
        "Snímek obrazovky",  // cs
        "Skærmbillede",  // da
        "Bildschirmfoto",  // de
        "Στιγμιότυπο οθόνης",  // el
        "Näyttökuva",  // fi
        "Capture d\u{2019}écran",  // fr, fr_CA (typographic apostrophe, as macOS writes it)
        "צילום מסך",  // he
        "स्क्रीनशॉट",  // hi
        "Slika zaslona",  // hr
        "Képernyőfotó",  // hu
        "Tangkapan Layar",  // id
        "スクリーンショット",  // ja
        "스크린샷",  // ko
        "Tangkapan Skrin",  // ms
        "Schermafbeelding",  // nl (the catalogue has a soft hyphen inside; see `normalized`)
        "Skjermbilde",  // no
        "Zrzut ekranu",  // pl
        "Captura de Tela",  // pt_BR
        "Captura de ecrã",  // pt_PT
        "Captură de ecran",  // ro
        "Снимок экрана",  // ru
        "Snímka obrazovky",  // sk
        "Posnetek zaslona",  // sl
        "Skärmavbild",  // sv
        "ภาพถ่ายหน้าจอ",  // th
        "Ekran Resmi",  // tr
        "Знімок екрана",  // uk
        "Ảnh màn hình",  // vi
        "截屏",  // zh_CN
        "螢幕截圖",  // zh_HK
        "截圖",  // zh_TW
    ]

    /// Whether `fileName` begins with the user's custom prefix or one of the system prefixes. Swift string comparison
    /// is canonical-equivalence aware, so a decomposed accent (NFD) matches its precomposed form.
    public static func matches(_ fileName: String, customPrefix: String?) -> Bool {
        let name = normalized(fileName)
        if let customPrefix, !customPrefix.isEmpty, name.hasPrefix(normalized(customPrefix)) { return true }
        return system.contains { name.hasPrefix($0) }
    }

    /// Drops the invisible characters the system catalogue puts in some names: the soft hyphen (U+00AD, Dutch) and
    /// the right-to-left mark (U+200F, which the Arabic format puts before the name).
    static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0 != "\u{00AD}" && $0 != "\u{200F}" }.map(Character.init))
    }
}
