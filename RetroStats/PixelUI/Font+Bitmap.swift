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

extension Font {
    static func bitmap(_ size: CGFloat) -> Font {
        _ = RetroBitmapFont.registered
        return .custom(RetroBitmapFont.postScriptName, size: size)
    }
}
