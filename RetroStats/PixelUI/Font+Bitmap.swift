import CoreText
import SwiftUI

enum RetroBitmapFont {
    static let postScriptName = "RetroBitmapA-Regular"

    static let registered: Bool = {
        let bundles = [Bundle.main, Bundle(for: BundleMarker.self)]
        guard let url = bundles.lazy.compactMap({ bundle in
            bundle.url(forResource: "RetroBitmapA", withExtension: "ttf", subdirectory: "Fonts")
                ?? bundle.url(forResource: "RetroBitmapA", withExtension: "ttf")
        }).first else {
            diagnostic("RetroBitmapA.ttf is missing from the app bundle")
            return false
        }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            diagnostic("RetroBitmapA registration failed: \(reason)")
            return false
        }
        return true
    }()

    private final class BundleMarker {}
}

/// User-selectable size multiplier for all dashboard text. Persisted by raw value.
enum FontScale: String, CaseIterable {
    case small, normal, large
    static let key = "fontScale"
    static var current = FontScale(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .normal

    var factor: CGFloat {
        switch self {
        case .small: return 0.85
        case .normal: return 1
        case .large: return 1.25
        }
    }
    var label: String {
        switch self {
        case .small: return "Small"
        case .normal: return "Normal"
        case .large: return "Large"
        }
    }
}

extension Font {
    /// `scaled: false` keeps a fixed size, e.g. the menu bar readout whose width is fixed.
    static func bitmap(_ size: CGFloat, scaled: Bool = true) -> Font {
        _ = RetroBitmapFont.registered
        return .custom(RetroBitmapFont.postScriptName, size: scaled ? size * FontScale.current.factor : size)
    }
}
