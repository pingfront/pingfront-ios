import Foundation
import Testing

@_spi(Fixtures) @testable import PingFrontCore

/// Secondary text reads 4.5:1 on the background and inside team bubbles (ChatTheme.muted), as on Android.
@Suite("Muted contrast")
struct MutedContrastTests {
    static func nudged(_ muted: RGBColor, bubble: RGBColor, background: RGBColor) -> RGBColor {
        Contrast.adjustText(Contrast.adjustText(muted, on: bubble, minimum: 4.5), on: background, minimum: 4.5)
    }

    @Test("The default muted, and the Android case (#6C6C78 on #ECEEF3, 4.46:1), reach 4.5:1 on bubble and background")
    func reachesMinimum() {
        let defaults = ResolvedLook.Defaults.self
        for mode in [ColorMode.light, .dark] {
            let background = defaults.background.value(in: mode)
            let bubble = defaults.teamBubble.value(in: mode)
            let muted = Self.nudged(defaults.muted.value(in: mode), bubble: bubble, background: background)
            #expect(RGBColor.contrast(muted, bubble) >= 4.5)
            #expect(RGBColor.contrast(muted, background) >= 4.5)
        }
        let android = Self.nudged(RGBColor(rgb: 0x6C6C78), bubble: RGBColor(rgb: 0xECEEF3), background: RGBColor(rgb: 0xFFFFFF))
        #expect(RGBColor.contrast(RGBColor(rgb: 0x6C6C78), RGBColor(rgb: 0xECEEF3)) < 4.5)
        #expect(RGBColor.contrast(android, RGBColor(rgb: 0xECEEF3)) >= 4.5)
    }
}
