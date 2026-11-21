import XCTest
@testable import TextMouth

/// The localization settings of the Mac app (FR34, TL10): English is the language the code and the String Catalog
/// are written in, so it is the development region the bundle names, and the fallback of every string and every
/// person whose languages TextMouth lacks.
final class LocalizationSettingsTests: XCTestCase {
    /// The app's development localization is English: `CFBundleDevelopmentRegion` is `$(DEVELOPMENT_LANGUAGE)`, which
    /// project.yml's `developmentLanguage` sets, and the bundle reads it back as `en`.
    func testTheAppsDevelopmentLocalizationIsEnglish() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
    }

    /// The Info.plist's value was expanded from the build setting: a value still reading `$(DEVELOPMENT_LANGUAGE)`
    /// would mean the build setting is missing, and the bundle would then name no development language.
    func testTheInfoPlistNamesTheDevelopmentRegionAsEnglishWithTheSettingExpanded() {
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundleDevelopmentRegion"] as? String, "en")
    }
}
