import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class ThemeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ThemeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultAppearanceStateUsesSafeMVPValues() {
        let store = ThemeStore(defaults: defaults)

        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.mode.subtitle, "跟随当前设备外观")
        XCTAssertEqual(store.preset, .codex)
        XCTAssertEqual(store.uiFontPreset, .system)
        XCTAssertEqual(store.codeFontPreset, .systemMono)
        XCTAssertEqual(store.fontScale, ThemeStore.defaultFontScale)
        XCTAssertNil(store.preferredColorScheme)

        let tokens = store.tokens(for: .light)
        XCTAssertEqual(tokens.preset, .codex)
        XCTAssertEqual(tokens.resolvedScheme, .light)
    }

    func testPersistsAppearancePreferences() {
        let store = ThemeStore(defaults: defaults)

        store.mode = .dark
        store.preset = .gruvbox
        store.uiFontPreset = .rounded
        store.codeFontPreset = .menlo
        store.setFontScale(1.20)

        let restored = ThemeStore(defaults: defaults)
        XCTAssertEqual(restored.mode, .dark)
        XCTAssertEqual(restored.preset, .gruvbox)
        XCTAssertEqual(restored.uiFontPreset, .rounded)
        XCTAssertEqual(restored.codeFontPreset, .menlo)
        XCTAssertEqual(restored.fontScale, 1.20, accuracy: 0.001)
        XCTAssertEqual(restored.preferredColorScheme, .dark)
    }

    func testInvalidStoredValuesFallBackToDefaults() {
        defaults.set("broken", forKey: "appearance.theme.mode")
        defaults.set("unknown", forKey: "appearance.theme.preset")
        defaults.set("comic-sans", forKey: "appearance.theme.uiFont")
        defaults.set("terminal", forKey: "appearance.theme.codeFont")
        defaults.set(99.0, forKey: "appearance.theme.fontScale")

        let store = ThemeStore(defaults: defaults)

        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.preset, .codex)
        XCTAssertEqual(store.uiFontPreset, .system)
        XCTAssertEqual(store.codeFontPreset, .systemMono)
        XCTAssertEqual(store.fontScale, ThemeStore.maximumFontScale)
    }

    func testFontScaleClampsToSupportedRange() {
        let store = ThemeStore(defaults: defaults)

        store.setFontScale(0.1)
        XCTAssertEqual(store.fontScale, ThemeStore.minimumFontScale)

        store.setFontScale(9.0)
        XCTAssertEqual(store.fontScale, ThemeStore.maximumFontScale)
    }

    func testResetPersistsDefaults() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .dark
        store.preset = .xcode
        store.uiFontPreset = .serif
        store.codeFontPreset = .menlo
        store.setFontScale(1.25)

        store.reset()

        let restored = ThemeStore(defaults: defaults)
        XCTAssertEqual(restored.mode, .system)
        XCTAssertEqual(restored.preset, .codex)
        XCTAssertEqual(restored.uiFontPreset, .system)
        XCTAssertEqual(restored.codeFontPreset, .systemMono)
        XCTAssertEqual(restored.fontScale, ThemeStore.defaultFontScale)
    }

    func testResetResolvesToCurrentSystemColorScheme() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .light

        store.reset()

        XCTAssertNil(store.preferredColorScheme)
        XCTAssertEqual(store.resolvedColorScheme(for: .dark), .dark)
        XCTAssertEqual(store.tokens(for: .dark).resolvedScheme, .dark)
    }

    func testTokenSelectionUsesPresetAndResolvedScheme() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .system
        store.preset = .xcode

        XCTAssertEqual(store.tokens(for: .light).preset, .xcode)
        XCTAssertEqual(store.tokens(for: .light).resolvedScheme, .light)
        XCTAssertEqual(store.tokens(for: .dark).resolvedScheme, .dark)

        store.mode = .light
        XCTAssertEqual(store.tokens(for: .dark).resolvedScheme, .light)

        store.mode = .dark
        XCTAssertEqual(store.tokens(for: .light).resolvedScheme, .dark)
    }

    func testDefaultCodexPresetUsesWarmWorkbenchPalette() {
        let store = ThemeStore(defaults: defaults)

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)
        let lightBackground = rgba(lightTokens.background)
        let lightSurface = rgba(lightTokens.surface)
        let lightElevatedSurface = rgba(lightTokens.elevatedSurface)
        let lightAccent = rgba(lightTokens.accent)
        let lightSuccess = rgba(lightTokens.success)
        let lightUserBubble = rgba(lightTokens.userBubble)
        let lightSidebarBackground = rgba(lightTokens.sidebarBackground)
        let lightSidebarHoverFill = rgba(lightTokens.sidebarHoverFill)
        let lightInputBackground = rgba(lightTokens.inputBackground)
        let lightPlanCardBackground = rgba(lightTokens.planCardBackground)
        let lightPlanCardBorder = rgba(lightTokens.planCardBorder)
        let lightBorder = rgba(lightTokens.border)
        let lightSelectionFill = rgba(lightTokens.selectionFill)
        let lightSecondaryText = rgba(lightTokens.secondaryText)
        let codexSwatchForeground = rgba(ThemePreset.codex.swatchForeground)
        let codexSwatchBackground = rgba(ThemePreset.codex.swatchBackground)
        let darkBackground = rgba(darkTokens.background)
        let darkSurface = rgba(darkTokens.surface)
        let darkElevatedSurface = rgba(darkTokens.elevatedSurface)
        let darkAccent = rgba(darkTokens.accent)
        let darkSuccess = rgba(darkTokens.success)
        let darkUserBubble = rgba(darkTokens.userBubble)

        XCTAssertEqual(ThemePreset.codex.subtitle, "暖白工作界面配紫色消息，适合长时间对话")

        assertRGB(lightBackground, red: 252, green: 251, blue: 248)
        assertRGB(lightSidebarBackground, red: 247, green: 246, blue: 242)
        assertRGB(lightSelectionFill, red: 236, green: 234, blue: 228)
        assertRGB(lightSidebarHoverFill, red: 243, green: 242, blue: 238)
        assertRGB(lightInputBackground, red: 245, green: 244, blue: 241)
        assertRGB(lightPlanCardBackground, red: 255, green: 248, blue: 234)
        assertRGB(lightPlanCardBorder, red: 233, green: 221, blue: 199)
        assertRGB(lightBorder, red: 231, green: 228, blue: 221)
        assertRGB(lightSecondaryText, red: 110, green: 106, blue: 99)
        XCTAssertGreaterThan(lightSurface.red, 0.99)
        XCTAssertGreaterThan(lightSurface.green, 0.99)
        XCTAssertGreaterThan(lightSurface.blue, 0.99)
        XCTAssertEqual(lightTokens.assistantBubble, .white)
        XCTAssertLessThan(abs(lightElevatedSurface.red - lightElevatedSurface.blue), 0.03)

        XCTAssertEqual(lightAccent.red, lightUserBubble.red, accuracy: 0.001)
        XCTAssertEqual(lightAccent.green, lightUserBubble.green, accuracy: 0.001)
        XCTAssertEqual(lightAccent.blue, lightUserBubble.blue, accuracy: 0.001)
        XCTAssertEqual(codexSwatchBackground.red, lightBackground.red, accuracy: 0.001)
        XCTAssertEqual(codexSwatchBackground.green, lightBackground.green, accuracy: 0.001)
        XCTAssertEqual(codexSwatchBackground.blue, lightBackground.blue, accuracy: 0.001)
        XCTAssertGreaterThan(lightSuccess.green, lightSuccess.red)
        XCTAssertGreaterThan(lightSuccess.green, lightSuccess.blue)

        // 用户发送气泡使用 Slack Aubergine (#4A154B)；其它操作只做少量同色点缀，不再引入蓝色体系。
        XCTAssertEqual(lightUserBubble.red, 0.29, accuracy: 0.01)
        XCTAssertEqual(lightUserBubble.green, 0.08, accuracy: 0.01)
        XCTAssertEqual(lightUserBubble.blue, 0.29, accuracy: 0.01)
        XCTAssertGreaterThan(lightUserBubble.alpha, 0.99)
        XCTAssertEqual(codexSwatchForeground.red, lightUserBubble.red, accuracy: 0.001)
        XCTAssertEqual(codexSwatchForeground.green, lightUserBubble.green, accuracy: 0.001)
        XCTAssertEqual(codexSwatchForeground.blue, lightUserBubble.blue, accuracy: 0.001)

        XCTAssertLessThan(darkBackground.red, 0.12)
        XCTAssertLessThan(darkBackground.green, 0.12)
        XCTAssertLessThan(darkBackground.blue, 0.12)
        XCTAssertLessThan(abs(darkBackground.red - darkBackground.blue), 0.03)
        XCTAssertLessThan(abs(darkSurface.red - darkSurface.blue), 0.04)
        XCTAssertLessThan(abs(darkElevatedSurface.red - darkElevatedSurface.blue), 0.04)
        XCTAssertGreaterThan(darkAccent.red, 0.75)
        XCTAssertGreaterThan(darkAccent.green, 0.65)
        XCTAssertGreaterThan(darkAccent.blue, 0.85)
        XCTAssertGreaterThan(darkAccent.blue, darkAccent.green)
        XCTAssertGreaterThan(darkSuccess.green, darkSuccess.red)
        XCTAssertGreaterThan(darkSuccess.green, darkSuccess.blue)

        XCTAssertEqual(darkUserBubble.red, 0.29, accuracy: 0.01)
        XCTAssertEqual(darkUserBubble.green, 0.08, accuracy: 0.01)
        XCTAssertEqual(darkUserBubble.blue, 0.29, accuracy: 0.01)
        XCTAssertGreaterThan(darkUserBubble.alpha, 0.99)
    }

    func testXcodePresetKeepsEditorInspiredContrastAndAccents() {
        let store = ThemeStore(defaults: defaults)
        store.preset = .xcode

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)
        let lightCodeBlock = rgba(lightTokens.codeBlock)
        let lightCodeText = rgba(lightTokens.codeText)
        let darkBackground = rgba(darkTokens.background)
        let darkCodeBlock = rgba(darkTokens.codeBlock)
        let accent = rgba(lightTokens.accent)
        let warning = rgba(lightTokens.warning)
        let success = rgba(darkTokens.success)

        XCTAssertGreaterThan(lightCodeBlock.red, 0.95)
        XCTAssertGreaterThan(lightCodeBlock.green, 0.96)
        XCTAssertGreaterThan(lightCodeBlock.blue, 0.98)
        XCTAssertLessThan(lightCodeText.red, 0.15)
        XCTAssertLessThan(lightCodeText.green, 0.15)
        XCTAssertLessThan(lightCodeText.blue, 0.18)

        XCTAssertLessThan(abs(darkBackground.red - darkBackground.blue), 0.04)
        XCTAssertLessThan(abs(darkCodeBlock.red - darkCodeBlock.blue), 0.03)

        XCTAssertGreaterThan(accent.blue, 0.95)
        XCTAssertGreaterThan(accent.green, 0.45)
        XCTAssertGreaterThan(warning.red, 0.95)
        XCTAssertLessThan(warning.blue, 0.10)
        XCTAssertGreaterThan(success.green, success.red)
        XCTAssertGreaterThan(success.green, success.blue)
    }

    func testGitHubPresetProvidesLightAndDarkTokens() {
        let store = ThemeStore(defaults: defaults)
        store.preset = .github

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)

        XCTAssertTrue(ThemePreset.allCases.contains(.github))
        XCTAssertEqual(ThemePreset.github.title, "GitHub")
        XCTAssertEqual(lightTokens.preset, .github)
        XCTAssertEqual(lightTokens.resolvedScheme, .light)
        XCTAssertEqual(darkTokens.preset, .github)
        XCTAssertEqual(darkTokens.resolvedScheme, .dark)
    }

    func testPrimaryColorPresetsKeepVoiceRecordingAlignedWithAccent() {
        let store = ThemeStore(defaults: defaults)

        for preset in [ThemePreset.codex, .github, .xcode] {
            store.preset = preset

            for scheme in [ColorScheme.light, .dark] {
                let tokens = store.tokens(for: scheme)
                let voice = rgba(tokens.voiceRecording)
                let accent = rgba(tokens.accent)
                let warning = rgba(tokens.warning)

                // 语音录音态要保留“正在听”的差异感，但默认/代码主题里应贴近主色，而不是跳成警告色。
                XCTAssertLessThan(
                    colorDistance(voice, accent),
                    colorDistance(voice, warning),
                    "\(preset.title) \(scheme) voice color should stay closer to accent than warning"
                )
            }
        }
    }

    func testThemeVersionIncrementsWhenVisualStateChanges() {
        let store = ThemeStore(defaults: defaults)
        let originalVersion = store.themeVersion

        store.preset = .gruvbox

        XCTAssertGreaterThan(store.themeVersion, originalVersion)
    }

    private func rgba(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return (red, green, blue, alpha)
    }

    private func assertRGB(
        _ color: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        accuracy: CGFloat = 0.003
    ) {
        XCTAssertEqual(color.red, red / 255.0, accuracy: accuracy)
        XCTAssertEqual(color.green, green / 255.0, accuracy: accuracy)
        XCTAssertEqual(color.blue, blue / 255.0, accuracy: accuracy)
        XCTAssertGreaterThan(color.alpha, 0.99)
    }

    private func colorDistance(
        _ lhs: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        _ rhs: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    ) -> CGFloat {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }
}

@MainActor
final class ResponsiveLayoutTests: XCTestCase {
    func testWorkbenchLayoutUsesCompactNavigationOnPhoneWidth() {
        let layout = WorkbenchLayout(containerWidth: 390, horizontalSizeClass: .compact)

        XCTAssertTrue(layout.usesCompactNavigation)
        XCTAssertTrue(layout.prefersDetailOnly)
        XCTAssertFalse(layout.usesAttachedInspector)
        XCTAssertLessThanOrEqual(layout.titleMaxWidth, 150)
        XCTAssertGreaterThanOrEqual(layout.titleMaxWidth, 86)
    }

    func testWorkbenchLayoutKeepsSplitNavigationOnWidePadWidth() {
        let layout = WorkbenchLayout(containerWidth: 1180, horizontalSizeClass: .regular)

        XCTAssertFalse(layout.usesCompactNavigation)
        XCTAssertFalse(layout.prefersDetailOnly)
        XCTAssertTrue(layout.usesAttachedInspector)
        XCTAssertEqual(layout.projectColumn.ideal, 330)
        XCTAssertEqual(layout.titleMaxWidth, 340)
    }

    func testConversationLayoutFitsPhonePortraitWidth() {
        let layout = ConversationLayout(containerWidth: 390, horizontalSizeClass: .compact)

        XCTAssertEqual(layout.horizontalInset, 12)
        XCTAssertEqual(layout.composerAvailableWidth, 366)
        XCTAssertEqual(layout.composerMaxWidth, .infinity)
        XCTAssertLessThanOrEqual(layout.userBubbleMaxWidth, 354)
        XCTAssertLessThanOrEqual(layout.assistantBubbleMaxWidth, 354)
        XCTAssertLessThanOrEqual(layout.runtimeCardMaxWidth, 366)
    }
}
