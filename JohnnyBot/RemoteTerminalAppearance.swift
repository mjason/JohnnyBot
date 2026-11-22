import SwiftUI
import SwiftTerm
import CoreText
import Synchronization
#if os(macOS)
import AppKit
private typealias TerminalColor = NSColor
private typealias TerminalFont = NSFont
#else
import UIKit
private typealias TerminalColor = UIColor
private typealias TerminalFont = UIFont
#endif

enum RemoteTerminalTheme: String, CaseIterable, Identifiable {
    case dark, light, system

    var id: Self { self }

    var label: String {
        switch self {
        case .dark: "深色"
        case .light: "浅色"
        case .system: "跟随系统"
        }
    }
}

struct RemoteTerminalAppearance: Equatable {
    let theme: RemoteTerminalTheme
    let colorScheme: ColorScheme
    let fontFamily: String
    let fontSize: Double
    let useNerdSymbols: Bool

    static let fontSizes = 10...28

    private var isDark: Bool { theme == .dark || (theme == .system && colorScheme == .dark) }
    private var nativeBackground: TerminalColor { Self.color(isDark ? 0x101216 : 0xFBFBFC) }
    var background: SwiftUI.Color {
#if os(macOS)
        SwiftUI.Color(nsColor: nativeBackground)
#else
        SwiftUI.Color(uiColor: nativeBackground)
#endif
    }

    private var font: TerminalFont {
        let size = CGFloat(min(Double(Self.fontSizes.upperBound), max(Double(Self.fontSizes.lowerBound), fontSize)))
        return Self.familyFont(fontFamily, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static let fontFamilies: [String] = {
#if os(macOS)
        let names = NSFontManager.shared.availableFontFamilies
#else
        let names = UIFont.familyNames
#endif
        return names.filter { name in
            guard let font = familyFont(name, size: 13) else { return false }
#if os(macOS)
            let monospaced = font.isFixedPitch
#else
            let monospaced = font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
#endif
            return monospaced || name.localizedCaseInsensitiveContains("Nerd Font")
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    func apply(to view: TerminalView) {
        let font = self.font
        if view.font != font { view.font = font }
        view.glyphFallbackProvider = useNerdSymbols ? NerdSymbolFallback.shared : nil
        let foreground: UInt32 = isDark ? 0xE6E8EC : 0x20242B
        view.nativeBackgroundColor = nativeBackground
        view.nativeForegroundColor = Self.color(foreground)
        view.caretColor = Self.color(foreground)
        let palette: [UInt32] = isDark ? [
            0x191C21, 0xE86872, 0x70C98C, 0xE2BA68, 0x79AFFF, 0xBC9CFF, 0x68CACC, 0xDDE2EB,
            0x626C7C, 0xFF8B94, 0x91E4A6, 0xFFCD81, 0x9BC4FF, 0xD1B5FF, 0x93E0E0, 0xF7F8FA
        ] : [
            0x262B32, 0xAD2E3E, 0x287444, 0x855F16, 0x275FAD, 0x7046A3, 0x076D79, 0x546170,
            0x626C78, 0xBB3145, 0x316E46, 0x875D11, 0x2458AA, 0x7445A7, 0x056A76, 0xF3F4F6
        ]
        view.installColors(palette.map {
            SwiftTerm.Color(red8: UInt16(($0 >> 16) & 255), green8: UInt16(($0 >> 8) & 255), blue8: UInt16($0 & 255))
        })
    }

    private static func familyFont(_ family: String, size: CGFloat) -> TerminalFont? {
        guard !family.isEmpty else { return nil }
#if os(macOS)
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
#else
        let descriptor = UIFontDescriptor(fontAttributes: [.family: family, .face: "Regular"])
        return UIFont.familyNames.contains(family) ? UIFont(descriptor: descriptor, size: size) : nil
#endif
    }

    private static func color(_ hex: UInt32) -> TerminalColor {
        TerminalColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                      blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

nonisolated private final class NerdSymbolFallback: TerminalGlyphFallbackProvider, @unchecked Sendable {
    static let shared: NerdSymbolFallback? = {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf"),
              let data = CGDataProvider(url: url as CFURL), let face = CGFont(data) else { return nil }
        return NerdSymbolFallback(face: face)
    }()

    let generation: UInt64 = 0
    private let face: CGFont
    private let coverage: CharacterSet
    private let fonts = Mutex<[CGFloat: CTFont]>([:])

    private init(face: CGFont) {
        self.face = face
        let font = CTFontCreateWithGraphicsFont(face, 13, nil, nil)
        coverage = CTFontCopyCharacterSet(font) as CharacterSet
    }

    func placementPolicy(for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy? {
        guard scalar.properties.generalCategory == .privateUse, coverage.contains(scalar) else { return nil }
        if (0xE0B0...0xE0B3).contains(scalar.value) {
            return TerminalGlyphPlacementPolicy(placement: .stretch, maximumCellWidth: 1)
        }
        return TerminalGlyphPlacementPolicy(placement: .icon, maximumCellWidth: 1)
    }

    func fallbackFont(forPointSize size: CGFloat) -> CTFont? {
        fonts.withLock { cache in
            if let font = cache[size] { return font }
            let font = CTFontCreateWithGraphicsFont(face, size, nil, nil)
            cache[size] = font
            return font
        }
    }
}
