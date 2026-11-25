import AppKit
import XCTest
@testable import TextMouth

/// The licences of the code TextMouth bundles ship inside the app (L6 of the
/// braille review, FMT21 and FR04): liblouis's GNU Lesser General Public
/// License and README, LAME's GNU Library General Public License and
/// LICENSE note, foliate-js's MIT License (the MOBI reader follows its
/// mobi.js, FMT42), FFmpeg's (FMT50), and the rest; and the credits AppKit's
/// About panel shows (Credits.rtf) name each. project.yml copies the notices
/// from the vendored folders into `Contents/Resources/Licenses`; the app is
/// the hosted tests' main bundle, so this reads them where a user of the
/// built app would find them.
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
        // The tables' own licenses, which are not all the release's (FR40): the list names the license each is under.
        let tables = try licenseText("liblouis", "TABLES-LICENSES.md")
        XCTAssertTrue(tables.contains("GNU Lesser General Public License, version 2.1 or (at your option) any later version"), String(tables.prefix(200)))
        XCTAssertTrue(tables.contains("Left out"), "the list says what is left out")
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

    /// swift-markdown left the app on November 15, 2026 (Markdown is read from cmark's own tree), so its licence and
    /// its NOTICE are no longer in the app: a notice for code the app does not hold would mislead. An incremental
    /// build that copied them before leaves their folder behind, empty (Xcode removes a dropped copy's files but
    /// not its folder, as GitHub's cached build of November 15 showed), so the test asks for no file there.
    func testSwiftMarkdownNoticeIsGoneWithThePackage() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL, "the app has no Resources folder")
        let folder = resources.appendingPathComponent("Licenses/swift-markdown")
        let leftOver = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(leftOver, [], "Licenses/swift-markdown still holds \(leftOver)")
    }

    /// swift-cmark's COPYING, cmark's BSD licence, is in the app: cmark is the Markdown parser the app links.
    func testSwiftCmarkLicenseShipsWithTheApp() throws {
        let licence = try licenseText("swift-cmark", "COPYING")
        XCTAssertTrue(licence.contains("John MacFarlane"), String(licence.prefix(120)))
    }

    /// FFmpeg's notices are in the app (FMT50): the release's own LICENSE.md
    /// and COPYING.LGPLv2.1, the GNU Lesser General Public License 2.1, and
    /// the README of Scripts/vendor/ffmpeg/build.py, which names the release,
    /// its source and SHA-256, the five upstream patches it applies (each by
    /// its commit and CVE), and the configure line, as FFmpeg's legal
    /// checklist asks of a changed library.
    func testFFmpegLicenseShipsWithTheApp() throws {
        let licence = try licenseText("FFmpeg", "COPYING.LGPLv2.1")
        XCTAssertTrue(licence.contains("GNU LESSER GENERAL PUBLIC LICENSE"), String(licence.prefix(80)))
        XCTAssertTrue(licence.contains("Version 2.1, February 1999"), String(licence.prefix(160)))
        XCTAssertTrue(try licenseText("FFmpeg", "LICENSE.md").hasPrefix("# License"))
        let readme = try licenseText("FFmpeg", "README")
        for words in ["This software uses libraries from the FFmpeg project under the LGPLv2.1.",
                      "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz", "FFmpeg 9.0.2 with 5 upstream patches",
                      "CVE-2026-125104: 968e9e948ed8c9ba90dbc875e60b843c755cf4ba",
                      "CVE-2026-125171: 5d59b7c45d7142bddd13ddc8891e72c5c7dc991b",
                      "CVE-2026-125182: 7145d13201c9f9c5253f40295714faa4f4ada1a0",
                      "CVE-2026-125221: 972fe1ccd326538fe9a6b5d5094b7880b5443429",
                      "CVE-2026-125224: 90f5e61a1da2dcc0050169af8ca593530f26071b",
                      "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e", "--disable-everything"] {
            XCTAssertTrue(readme.contains(words), words)
        }
        // The configure lines, one for each platform, enable no part under the GPL; the prose
        // above them names those flags only to say they were not given.
        let lines = readme.split(separator: "\n").filter { $0.hasPrefix("configure ") }
        XCTAssertEqual(lines.count, 3, "one configure line for each platform")
        for line in lines {
            XCTAssertFalse(
                line.contains("--enable-gpl") || line.contains("--enable-nonfree") || line.contains("--enable-version3"),
                String(line.prefix(80))
            )
        }
    }

    // MARK: - The Credits

    /// What the app carries, as the credits name it: the folder of its notice
    /// in Licenses, the name the credits give it, and the helper program in
    /// Contents/MacOS that links it, for a library only a helper links. This
    /// is the table `Scripts/ios/check-licenses.py` keeps for the iPhone,
    /// for the Mac: a notice, a helper, or a credit without its entry fails.
    private let carried: [(folder: String, credit: String, helper: String?)] = [
        ("FFmpeg", "FFmpeg", "TextMouthFFmpeg"),
        ("LAME", "LAME", nil),
        ("liblouis", "liblouis", "TextMouthBraille"),
        ("SwiftSoup", "SwiftSoup", nil),
        ("ZIPFoundation", "ZIPFoundation", nil),
        ("swift-cmark", "swift-cmark", nil),
        ("foliate-js", "foliate-js", nil),
        ("TrueAudio", "TTA", nil),
        ("WavPack", "WavPack", nil),
        ("MonkeysAudio", "Monkey's Audio", nil),
    ]

    /// The text of the app's Credits.rtf, which AppKit's standard About
    /// panel shows with no code of the app's own.
    private func creditsText() throws -> String {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Credits", withExtension: "rtf"), "the app has no Credits.rtf")
        let credits = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        return credits.string
    }

    /// The credits name every library the app carries and every set of code
    /// its readers follow, with the sentence FFmpeg's legal checklist asks
    /// for word for word; and they are plain text, which VoiceOver and a
    /// braille display read as they are: no table, no tab, and no picture.
    func testTheCreditsNameEverythingTheAppCarries() throws {
        let credits = try creditsText()
        for entry in carried {
            XCTAssertTrue(credits.contains(entry.credit), "the credits do not name \(entry.credit)")
        }
        XCTAssertTrue(credits.contains("This software uses libraries from the FFmpeg project under the LGPLv2.1."))
        XCTAssertFalse(credits.contains("\t"))
        XCTAssertFalse(credits.contains("\u{FFFC}"), "the credits hold an attachment")
    }

    /// Every folder of notices in the app is an entry of the table, and has
    /// a notice in it; every entry's folder is in the app; and every helper
    /// program in Contents/MacOS is an entry's, so a helper that links a
    /// library cannot ship without that library's notice and credit.
    func testEveryNoticeAndHelperHasItsEntry() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL, "the app has no Resources folder")
        let licenses = resources.appendingPathComponent("Licenses")
        let folders = try FileManager.default.contentsOfDirectory(atPath: licenses.path).filter { name in
            // A folder an earlier build left empty (swift-markdown's) holds no notice.
            let files = (try? FileManager.default.contentsOfDirectory(atPath: licenses.appendingPathComponent(name).path)) ?? []
            return !files.isEmpty
        }
        XCTAssertEqual(Set(folders), Set(carried.map(\.folder)))
        for entry in carried {
            let files = try FileManager.default.contentsOfDirectory(atPath: licenses.appendingPathComponent(entry.folder).path)
            XCTAssertFalse(files.isEmpty, entry.folder)
        }
        let executables = try XCTUnwrap(Bundle.main.executableURL?.deletingLastPathComponent())
        // The helpers are the programs beside the app's own; a Debug build's
        // dylibs there (TextMouth.debug.dylib, __preview.dylib) are the app's.
        let helpers = try FileManager.default.contentsOfDirectory(atPath: executables.path)
            .filter { $0 != Bundle.main.executableURL?.lastPathComponent && !$0.contains(".") }
        XCTAssertEqual(Set(helpers), Set(carried.compactMap(\.helper)))
    }
}
