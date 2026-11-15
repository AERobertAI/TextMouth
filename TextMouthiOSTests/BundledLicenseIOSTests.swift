import XCTest
@testable import TextMouth

/// The licences of the libraries the iPhone app links ship inside the app, as the Mac app's do (BundledLicenseTests):
/// LAME's, SwiftSoup's, ZIPFoundation's, swift-markdown's with its NOTICE, swift-cmark's, and foliate-js's (the MOBI
/// reader follows its mobi.js). project.yml's TextMouthiOS target copies each from where the repository keeps it into
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

    /// swift-markdown's licence is the Apache License 2.0, and its NOTICE names the project.
    func testSwiftMarkdownLicenseAndNoticeShipWithTheApp() throws {
        let licence = try licenseText("swift-markdown", "LICENSE")
        XCTAssertTrue(licence.contains("Apache License"), String(licence.prefix(120)))
        XCTAssertTrue(licence.contains("Version 2.0"), String(licence.prefix(120)))
        let notice = try licenseText("swift-markdown", "NOTICE")
        XCTAssertTrue(notice.contains("The Swift Markdown Project"), String(notice.prefix(120)))
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
