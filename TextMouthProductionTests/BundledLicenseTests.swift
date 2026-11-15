import XCTest
@testable import TextMouth

/// The licences of the code TextMouth bundles ship inside the app (L6 of the
/// braille review, FMT21 and FR04): liblouis's GNU Lesser General Public
/// License and README, LAME's GNU Library General Public License and
/// LICENSE note, and foliate-js's MIT License (the MOBI reader follows its
/// mobi.js, FMT42). project.yml copies them from the vendored folders into
/// `Contents/Resources/Licenses`; the app is the hosted tests' main bundle,
/// so this reads them where a user of the built app would find them.
final class BundledLicenseTests: XCTestCase {

    /// The text of the bundled licence file `name` in the Licenses folder
    /// `folder`.
    /// - Throws: when the file is not in the app or cannot be read as text.
    private func licenseText(_ folder: String, _ name: String) throws -> String {
        let resources = try XCTUnwrap(Bundle.main.resourceURL, "the app has no Resources folder")
        let url = resources.appendingPathComponent("Licenses/\(folder)/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(name) is not in the app at Licenses/\(folder)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// liblouis's licence and README are in the app, the licence being the
    /// GNU Lesser General Public License.
    func testLiblouisLicenseShipsWithTheApp() throws {
        let licence = try licenseText("liblouis", "COPYING.LESSER")
        XCTAssertTrue(
            licence.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("GNU LESSER GENERAL PUBLIC LICENSE"),
            String(licence.prefix(80)))
        XCTAssertFalse(try licenseText("liblouis", "README").isEmpty)
    }

    /// LAME's copying file and licence note are in the app, the copying file
    /// being the GNU Library General Public License.
    func testLAMELicenseShipsWithTheApp() throws {
        let copying = try licenseText("LAME", "COPYING")
        XCTAssertTrue(copying.contains("GNU LIBRARY GENERAL PUBLIC LICENSE"), String(copying.prefix(80)))
        XCTAssertFalse(try licenseText("LAME", "LICENSE").isEmpty)
    }

    /// foliate-js's licence is in the app: the MIT License, naming the
    /// copyright holder of mobi.js, which the MOBI reader follows.
    func testFoliateJSLicenseShipsWithTheApp() throws {
        let licence = try licenseText("foliate-js", "LICENSE")
        XCTAssertTrue(licence.hasPrefix("MIT License"), String(licence.prefix(80)))
        XCTAssertTrue(licence.contains("John Factotum"), String(licence.prefix(120)))
    }

    /// SwiftSoup's licence is in the app: the MIT License, naming jsoup's
    /// author (whose parser SwiftSoup ports) and the Swift port's. SwiftSoup
    /// is vendored in Vendor/SwiftSoup and compiled into the app.
    func testSwiftSoupLicenseShipsWithTheApp() throws {
        let licence = try licenseText("SwiftSoup", "LICENSE")
        XCTAssertTrue(licence.hasPrefix("The MIT License"), String(licence.prefix(80)))
        XCTAssertTrue(licence.contains("Jonathan Hedley"), String(licence.prefix(160)))
        XCTAssertTrue(licence.contains("Nabil Chatbi"), String(licence.prefix(160)))
    }

    /// ZIPFoundation's licence is in the app: the MIT License. The iPhone app ships the same file.
    func testZIPFoundationLicenseShipsWithTheApp() throws {
        let licence = try licenseText("ZIPFoundation", "LICENSE")
        XCTAssertTrue(licence.hasPrefix("MIT License"), String(licence.prefix(80)))
        XCTAssertTrue(licence.contains("Thomas Zoechling"), String(licence.prefix(160)))
    }

    /// swift-markdown's licence (Apache 2.0) and its NOTICE are in the app. When the package goes, this test and its
    /// project.yml entries go with it.
    func testSwiftMarkdownLicenseAndNoticeShipWithTheApp() throws {
        let licence = try licenseText("swift-markdown", "LICENSE")
        XCTAssertTrue(licence.contains("Apache License"), String(licence.prefix(120)))
        let notice = try licenseText("swift-markdown", "NOTICE")
        XCTAssertTrue(notice.contains("The Swift Markdown Project"), String(notice.prefix(120)))
    }

    /// swift-cmark's COPYING, cmark's BSD licence, is in the app.
    func testSwiftCmarkLicenseShipsWithTheApp() throws {
        let licence = try licenseText("swift-cmark", "COPYING")
        XCTAssertTrue(licence.contains("John MacFarlane"), String(licence.prefix(120)))
    }
}
