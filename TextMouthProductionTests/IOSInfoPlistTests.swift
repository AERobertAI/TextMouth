import XCTest
@testable import TextMouth

/// The document types the iOS app declares, so that "Open in TextMouth" offers
/// every book the app can import there. They are the Mac's
/// (TextMouth/Resources/Info.plist), less the audio the import converts with a
/// program iOS cannot start, and with `.azw3` added to the Kindle MOBI type.
/// The iOS file (TextMouth/Platform/iOS/Info.plist) is written from the Mac's
/// by Scripts/ios/sync-info-plist.py, and these tests read both files from the
/// repository and check what the script is meant to give.
final class IOSInfoPlistTests: XCTestCase {

    // MARK: - Fixtures

    /// The repository's root, found from this file's place in it.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The property list at `path` under the repository's root.
    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any], path)
    }

    private func macPlist() throws -> [String: Any] { try plist("TextMouth/Resources/Info.plist") }
    private func iosPlist() throws -> [String: Any] { try plist("TextMouth/Platform/iOS/Info.plist") }

    /// The document types of `plist`, by name.
    private func documentTypes(of plist: [String: Any]) throws -> [String: [String: Any]] {
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: try types.map { (try XCTUnwrap($0["CFBundleTypeName"] as? String), $0) })
    }

    /// The extensions that `plist`'s document types declare.
    private func extensions(of plist: [String: Any]) throws -> Set<String> {
        Set(try documentTypes(of: plist).values.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] })
    }

    /// The document types the Mac declares and iOS refuses: Ogg and the other
    /// audio the import converts with afconvert (`ImportAudioConverter`).
    private let refused: Set<String> = ["Ogg Audio", "Audio Converted at Import"]

    // MARK: - Tests

    /// iOS declares each of the Mac's document types, as the Mac declares it,
    /// less the two it refuses, and the Kindle MOBI type with `.azw3` too.
    func testIOSDeclaresTheMacsDocumentTypesLessWhatItRefuses() throws {
        let mac = try documentTypes(of: macPlist())
        let ios = try documentTypes(of: iosPlist())
        XCTAssertEqual(Set(ios.keys), Set(mac.keys).subtracting(refused))
        for (name, type) in ios where name != "Kindle Book (MOBI)" {
            XCTAssertEqual(NSDictionary(dictionary: type), NSDictionary(dictionary: try XCTUnwrap(mac[name])), name)
        }
        let mobi = try XCTUnwrap(ios["Kindle Book (MOBI)"])
        XCTAssertEqual(mobi["CFBundleTypeExtensions"] as? [String], ["mobi", "prc", "azw", "azw3"])
        XCTAssertEqual(mobi["LSItemContentTypes"] as? [String], ["com.textmouth.mobi"])
    }

    /// MOBI and KFX books are offered, by every extension their readers take.
    func testKindleBooksAreOffered() throws {
        let declared = try extensions(of: iosPlist())
        for format in [BookFormat.mobi, .kfx] {
            XCTAssertTrue(Set(format.fileExtensions).isSubset(of: declared), "\(format) \(format.fileExtensions)")
        }
        XCTAssertTrue(declared.contains("azw3"))
    }

    /// Every extension of a book format the app imports is offered on iOS,
    /// but those whose audio is converted with a program iOS cannot start.
    /// (Movie files, `.mp4`, `.m4v`, and `.mov`, are not offered on the Mac
    /// either, and so are not checked here.)
    func testEveryImportableExtensionIsOffered() throws {
        let declared = try extensions(of: iosPlist())
        let converted = ImportAudioConverter.convertedExtensions
        let movies: Set<String> = ["mp4", "m4v", "mov"]
        for format in BookFormat.allCases {
            for ext in format.fileExtensions where !converted.contains(ext) && !movies.contains(ext) {
                XCTAssertTrue(declared.contains(ext), "\(ext) of \(format) is not declared on iOS")
            }
        }
        for ext in converted {
            XCTAssertFalse(declared.contains(ext), "\(ext) is converted by a program iOS cannot start")
        }
        // The extensions that no BookFormat lists but the import reads.
        for ext in ["tmb", "zip", "m3u", "m3u8", "xml"] {
            XCTAssertTrue(declared.contains(ext), ext)
        }
    }

    /// Every type a document type names that the system does not know is
    /// declared in the iOS plist, imported or exported, and none twice.
    func testEveryTypeADocumentTypeNamesIsDeclared() throws {
        let ios = try iosPlist()
        let named = Set(try documentTypes(of: ios).values.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        let declarations = ((ios["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? [])
            + ((ios["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? [])
        let declared = declarations.compactMap { $0["UTTypeIdentifier"] as? String }
        XCTAssertEqual(declared.count, Set(declared).count, "a type is declared twice")
        for type in named where type.hasPrefix("com.textmouth.") {
            XCTAssertTrue(declared.contains(type), "\(type) is named but not declared")
        }
        // A declaration is of a type some document type names.
        for type in declared {
            XCTAssertTrue(named.contains(type), "\(type) is declared but no document type names it")
        }
        // The MOBI type's declaration names `.azw3` as the document type does.
        let mobi = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == "com.textmouth.mobi" })
        let tags = try XCTUnwrap(mobi["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["mobi", "prc", "azw", "azw3"])
    }

    /// What is not about documents is the Mac's, but for the two keys that
    /// mean nothing on iOS: the network settings that feeds need stay.
    func testTheOtherKeysAreTheMacsLessTheMacOnlyOnes() throws {
        let mac = try macPlist()
        let ios = try iosPlist()
        let macOnly: Set<String> = ["LSMinimumSystemVersion", "NSAppleEventsUsageDescription"]
        let documentKeys: Set<String> = ["CFBundleDocumentTypes", "UTImportedTypeDeclarations"]
        XCTAssertEqual(Set(ios.keys), Set(mac.keys).subtracting(macOnly))
        for key in ios.keys where !documentKeys.contains(key) {
            XCTAssertEqual(NSDictionary(dictionary: [key: ios[key] as Any]), NSDictionary(dictionary: [key: mac[key] as Any]), key)
        }
        XCTAssertNotNil(ios["NSAppTransportSecurity"])
    }

    /// The iOS target names the file, so the project does not fall back on the
    /// Mac's plist (XcodeGen picks the first Info.plist it finds, even among
    /// files a target excludes), and the Mac target does not use iOS's.
    func testTheProjectGivesEachAppItsOwnPlist() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("INFOPLIST_FILE: TextMouth/Platform/iOS/Info.plist"))
        XCTAssertTrue(project.contains("INFOPLIST_FILE: TextMouth/Resources/Info.plist"))
        let generated = try String(
            contentsOf: Self.root.appendingPathComponent("TextMouth.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(generated.contains("INFOPLIST_FILE = TextMouth/Platform/iOS/Info.plist;"))
    }
}
