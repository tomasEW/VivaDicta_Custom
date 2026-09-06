import Foundation
import OpenCCSwift

/// Applies a conservative Simplified-Chinese-to-Traditional-Chinese conversion
/// to text that is about to leave VivaDicta. The converter deliberately uses
/// OpenCC's generic `cn` -> `t` dictionaries rather than Taiwan phrase
/// rewriting, so product names and technical terminology are left alone where
/// possible.
@MainActor
public enum ChineseTextConverter {
    private static let converter = try? OpenCC.converter(from: "cn", to: "t")

    /// Returns Traditional Chinese when the bundled OpenCC converter is
    /// available. In the unlikely event converter initialization fails, the
    /// original text is preserved instead of blocking dictation.
    public static func traditionalized(_ text: String) -> String {
        converter?.convert(text) ?? text
    }
}
