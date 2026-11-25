import XCTest
@testable import TextMouth

/// The licences of the libraries the iPhone app links ship inside the app, as the Mac app's do (BundledLicenseTests):
/// FFmpeg's (since FMT54), liblouis's (since DR34), LAME's, SwiftSoup's, ZIPFoundation's, swift-cmark's, and
/// foliate-js's (the MOBI reader follows its mobi.js). project.yml's TextMouthiOS target copies each from where the repository keeps it into
/// `Licenses/<library>` of the app; the app is this bundle's host, so `Bundle.main` is the built iPhone app and the
/// files are read where a person who unpacked the app would find them. Scripts/ios/check-licenses.py checks the same
/// promise from project.yml without a build; this reads it from the product.
final class BundledLicenseIOSTests: XCTestCase {

    /// The text of the file `name` in the app's `Licenses/<folder>`.
    /// - Throws: when the file is not in the app or cannot be read as text.
    private func licenseText(_ folder: String, _ name: String) throws -> String {
        let resources = try XCTUnwrap(Bundle.main.resourceURL, "the app has no Resources folder")
        let url = resources.appendingPathComponent("Licenses/\(folder)/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) is not in the app at Licenses/\(folder)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// liblouis's licence and README are in the app, as in the Mac's, the licence being the GNU Lesser General Public
    /// License: the iPhone links liblouis since DR34, to translate braille in the app itself.
    func testLiblouisLicenseShipsWithTheApp() throws {
        let licence = try licenseText("liblouis", "COPYING.LESSER")
        XCTAssertTrue(
            licence.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("GNU LESSER GENERAL PUBLIC LICENSE"),
            String(licence.prefix(80)))
        XCTAssertFalse(try licenseText("liblouis", "README").isEmpty)
        // The tables' own licenses, which are not all the release's (FR40): the list names the license each is under.
        let tables = try licenseText("liblouis", "TABLES-LICENSES.md")
        XCTAssertTrue(tables.contains("GNU Lesser General Public License, version 2.1 or (at your option) any later version"), String(tables.prefix(200)))
        XCTAssertTrue(tables.contains("Left out"), "the list says what is left out")
    }

    /// FFmpeg's notices are in the app, as in the Mac's, since the iPhone links FFmpeg to convert in the app itself
    /// (FMT54): the release's own LICENSE.md and COPYING.LGPLv2.1, the GNU Lesser General Public License 2.1, and the
    /// README of Scripts/vendor/ffmpeg/build.py, which names the release, its SHA-256, the patches it applies, and the
    /// configure lines (the iPhone's and the simulator's among them), as FFmpeg's legal checklist asks of a changed
    /// library. No configure line enables a part under the GPL.
    func testFFmpegLicenseShipsWithTheApp() throws {
        let licence = try licenseText("FFmpeg", "COPYING.LGPLv2.1")
        XCTAssertTrue(licence.contains("GNU LESSER GENERAL PUBLIC LICENSE"), String(licence.prefix(80)))
        XCTAssertTrue(licence.contains("Version 2.1, February 1999"), String(licence.prefix(160)))
        XCTAssertTrue(try licenseText("FFmpeg", "LICENSE.md").hasPrefix("# License"))
        let readme = try licenseText("FFmpeg", "README")
        for words in ["This software uses libraries from the FFmpeg project under the LGPLv2.1.",
                      "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz", "FFmpeg 9.0.2 with 5 upstream patches",
                      "The iPhone (iOS 26.0, arm64)", "The iPhone simulator (iOS 26.0, arm64)"] {
            XCTAssertTrue(readme.contains(words), words)
        }
        let lines = readme.split(separator: "\n").filter { $0.hasPrefix("configure ") }
        XCTAssertEqual(lines.count, 3, "one configure line for each platform")
        for line in lines {
            XCTAssertFalse(
                line.contains("--enable-gpl") || line.contains("--enable-nonfree") || line.contains("--enable-version3"),
                String(line.prefix(80))
            )
        }
    }

    /// LAME's copying file is the GNU Library General Public License, and its licence note is there too.
    func testLAMELicenseShipsWithTheApp() throws {
        let copying = try licenseText("LAME", "COPYING")
        XCTAssertTrue(copying.contains("GNU LIBRARY GENERAL PUBLIC LICENSE"), String(copying.prefix(80)))
        XCTAssertFalse(try licenseText("LAME", "LICENSE").isEmpty)
    }

    /// SwiftSoup's licence is the MIT License, naming jsoup's author and the Swift port's.
    func testSwiftSoupLicenseShipsWithTheApp() throws {
        let licence = try licenseText("SwiftSoup", "LICENSE")
        XCTAssertTrue(licence.hasPrefix("The MIT License"), String(licence.prefix(80)))
        XCTAssertTrue(licence.contains("Jonathan Hedley"), String(licence.prefix(160)))
        XCTAssertTrue(licence.contains("Nabil Chatbi"), String(licence.prefix(160)))
    }

    /// ZIPFoundation's licence is the MIT License.
    func testZIPFoundationLicenseShipsWithTheApp() throws {
        let licence = try licenseText("ZIPFoundation", "LICENSE")
        XCTAssertTrue(licence.hasPrefix("MIT License"), String(licence.prefix(80)))
        XCTAssertTrue(licence.contains("Thomas Zoechling"), String(licence.prefix(160)))
    }

    /// swift-markdown left the iPhone app on November 15, 2026 (Markdown is read from cmark's own tree), so its licence and
    /// its NOTICE are no longer in the app: a notice for code the app does not hold would mislead. An incremental
    /// build that copied them before leaves their folder behind, empty (Xcode removes a dropped copy's files but
    /// not its folder, as GitHub's cached build of November 15 showed), so the test asks for no file there.
    func testSwiftMarkdownNoticeIsGoneWithThePackage() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL, "the app has no Resources folder")
        let folder = resources.appendingPathComponent("Licenses/swift-markdown")
        let leftOver = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(leftOver, [], "Licenses/swift-markdown still holds \(leftOver)")
    }

    /// swift-cmark's COPYING is cmark's BSD licence, naming its author.
    func testSwiftCmarkLicenseShipsWithTheApp() throws {
        let licence = try licenseText("swift-cmark", "COPYING")
        XCTAssertTrue(licence.contains("John MacFarlane"), String(licence.prefix(120)))
        XCTAssertTrue(licence.contains("Redistribution and use in source and binary forms"), String(licence.prefix(240)))
    }

    /// foliate-js's licence is the MIT License naming the holder of mobi.js, which the MOBI reader follows.
    func testFoliateJSLicenseShipsWithTheApp() throws {
        let licence = try licenseText("foliate-js", "LICENSE")
        XCTAssertTrue(licence.hasPrefix("MIT License"), String(licence.prefix(80)))
        XCTAssertTrue(licence.contains("John Factotum"), String(licence.prefix(120)))
    }
}
