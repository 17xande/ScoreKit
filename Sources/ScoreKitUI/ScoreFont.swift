#if canImport(SwiftUI)
import CoreText
import Foundation
import SwiftUI

/// The SMuFL music font, Bravura (SIL OFL 1.1, see `Resources/OFL-Bravura.txt`).
///
/// Glyphs are drawn as outlines, not text, so placement follows SMuFL exactly. A SMuFL em is
/// 4 staff spaces, so outlines taken at size 4 are in staff spaces (origin at the SMuFL
/// origin, y down). Outlines are cached by code point.
public enum ScoreFont {
    /// Registers a Bravura.otf from elsewhere (for example the app's own copy), for builds
    /// where the package's resource bundle is not shipped. Call before the first draw.
    /// Returns true once the font is loadable from `url`.
    @discardableResult
    public static func register(url: URL) -> Bool {
        store.use(url: url)
    }

    /// True when a font is available (the bundled one, or one given to `register(url:)`).
    public static var isAvailable: Bool { store.isAvailable }

    /// The outline of a glyph in staff spaces for a 4 sp em, y down; nil when the font lacks it.
    public static func outline(_ codepoint: UInt32) -> Path? { store.outline(codepoint) }

    private static let store = FontStore()
}

private final class BundleToken {}

private final class FontStore: @unchecked Sendable {
    private let lock = NSLock()
    private var font: CTFont?
    private var loaded = false
    private var cache: [UInt32: Path?] = [:]

    var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return loadLocked() != nil
    }

    func use(url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let f = Self.makeFont(url: url) else { return false }
        font = f
        loaded = true
        cache = [:]
        return true
    }

    func outline(_ codepoint: UInt32) -> Path? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[codepoint] { return hit }
        guard let font = loadLocked() else { return nil }
        let path = Self.path(font, codepoint)
        cache[codepoint] = .some(path)
        return path
    }

    private func loadLocked() -> CTFont? {
        if loaded { return font }
        loaded = true
        font = Self.bundledURL().flatMap { Self.makeFont(url: $0) }
        return font
    }

    private static func bundledURL() -> URL? {
        // Not `Bundle.module`: its generated accessor traps when the resource bundle was not
        // shipped, and `register(url:)` is the fallback for that case.
        let name = "ScoreKit_ScoreKitUI.bundle"
        let roots = [Bundle.main.resourceURL, Bundle(for: BundleToken.self).resourceURL, Bundle.main.bundleURL]
        for root in roots.compactMap({ $0 }) {
            guard let b = Bundle(url: root.appendingPathComponent(name)) else { continue }
            if let u = b.url(forResource: "Bravura", withExtension: "otf", subdirectory: "Resources")
                ?? b.url(forResource: "Bravura", withExtension: "otf") { return u }
        }
        return nil
    }

    /// Built from the file itself, so a name clash cannot substitute another font. Also
    /// registered with the process so `Font.custom("Bravura")` works (already-registered is fine).
    private static func makeFont(url: URL) -> CTFont? {
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        _ = error?.takeRetainedValue()
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let desc = descs.first else { return nil }
        return CTFontCreateWithFontDescriptor(desc, 4, nil)
    }

    private static func path(_ font: CTFont, _ codepoint: UInt32) -> Path? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        // SMuFL code points are in the BMP's private use area, so one UTF-16 unit.
        var chars = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count), glyphs[0] != 0 else { return nil }
        var flip = CGAffineTransform(scaleX: 1, y: -1)
        guard let cg = CTFontCreatePathForGlyph(font, glyphs[0], &flip) else { return nil }
        return Path(cg)
    }
}
#endif
