import XCTest
@testable import TextMouth

/// The document types the iOS app declares, so that "Open in TextMouth" offers
/// every book the app can import there. iOS goes by the types a document type
/// names (`LSItemContentTypes`) and the declarations of those types
/// (`UTImportedTypeDeclarations`, with the extensions they tag), so these tests
/// read those keys, not `CFBundleTypeExtensions`. They are the Mac's
/// (TextMouth/Resources/Info.plist), less what needs a program iOS cannot
/// start (the audio the import converts with afconvert, and the braille
/// files), with `.azw3` added to the Kindle MOBI type. The iOS file
/// (TextMouth/Platform/iOS/Info.plist) is written from the Mac's by
/// Scripts/ios/sync-info-plist.py (`make check-ios-plist` says when it is
/// stale); the tests read both files from the repository and check what the
/// script is meant to give, and which plist each configuration of the project uses.
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

    /// The types that `plist`'s document types name.
    private func namedTypes(of plist: [String: Any]) throws -> Set<String> {
        Set(try documentTypes(of: plist).values.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
    }

    /// The imported type declarations of `plist`, by identifier.
    private func imported(in plist: [String: Any]) throws -> [String: [String: Any]] {
        let declarations = (plist["UTImportedTypeDeclarations"] as? [[String: Any]]) ?? []
        return Dictionary(uniqueKeysWithValues: try declarations.map { (try XCTUnwrap($0["UTTypeIdentifier"] as? String), $0) })
    }

    /// The document types the Mac declares and iOS leaves out, by name, and why:
    /// the audio the import converts with afconvert (`ImportAudioConverter`),
    /// among it the system's type for `.caf`, which ALAC's type names too, and the
    /// braille files, which need the braille helper.
    private let refused: Set<String> = [
        "Ogg Audio", "Audio Converted at Import", "ALAC Audio",
        "BRF Braille File", "BRL Braille File", "PEF Braille File",
    ]

    /// The types only those document types name: what the Mac names and iOS does not.
    private let refusedTypes: Set<String> = [
        "org.xiph.ogg-audio",
        "public.aifc-audio", "com.apple.coreaudio-format", "public.au-audio", "com.sony.wave64", "public.ac3-audio",
        "public.enhanced-ac3-audio", "public.mp2", "org.3gpp.adaptive-multi-rate-audio", "public.3gpp", "public.3gpp2",
        "com.textmouth.brf", "com.textmouth.brl", "org.daisy.pef",
    ]

    // MARK: - Document types

    /// iOS declares each of the Mac's document types, as the Mac declares it,
    /// less the ones it refuses, and the Kindle MOBI type with `.azw3` too.
    func testIOSDeclaresTheMacsDocumentTypesLessWhatItRefuses() throws {
        let mac = try documentTypes(of: macPlist())
        let ios = try documentTypes(of: iosPlist())
        XCTAssertEqual(Set(ios.keys), Set(mac.keys).subtracting(refused))
        XCTAssertTrue(refused.isSubset(of: Set(mac.keys)), "a refused type the Mac does not have")
        for (name, type) in ios where name != "Kindle Book (MOBI)" {
            XCTAssertEqual(NSDictionary(dictionary: type), NSDictionary(dictionary: try XCTUnwrap(mac[name])), name)
        }
        let mobi = try XCTUnwrap(ios["Kindle Book (MOBI)"])
        XCTAssertEqual(mobi["CFBundleTypeExtensions"] as? [String], ["mobi", "prc", "azw", "azw3"])
        XCTAssertEqual(mobi["LSItemContentTypes"] as? [String], ["com.textmouth.mobi"])
    }

    /// The types iOS goes by (`LSItemContentTypes`): the Mac's less those only a
    /// refused document type names, and none of them is named for a document
    /// type that is not there.
    func testTheTypesIOSNamesAreTheMacsLessTheNamedOnes() throws {
        let mac = try namedTypes(of: macPlist())
        let ios = try namedTypes(of: iosPlist())
        XCTAssertEqual(ios, mac.subtracting(refusedTypes))
        XCTAssertTrue(refusedTypes.isSubset(of: mac), "a refused type the Mac does not name")
        // The refusals are exactly what each says: no type of a kept document type is among them.
        for type in try documentTypes(of: iosPlist()).values.flatMap({ $0["LSItemContentTypes"] as? [String] ?? [] }) {
            XCTAssertFalse(refusedTypes.contains(type), type)
        }
    }

    // MARK: - Type declarations

    /// The imported declarations iOS reads, which tag the extensions of the
    /// types, are the Mac's less the braille files', with `.azw3` tagged on the
    /// MOBI type; and the exported ones are the Mac's.
    func testTheDeclarationsAreTheMacsLessTheBrailleFiles() throws {
        let mac = try imported(in: macPlist())
        let ios = try imported(in: iosPlist())
        XCTAssertEqual(Set(ios.keys), Set(mac.keys).subtracting(["com.textmouth.brf", "com.textmouth.brl", "org.daisy.pef"]))
        for (identifier, declaration) in ios where identifier != "com.textmouth.mobi" {
            XCTAssertEqual(NSDictionary(dictionary: declaration), NSDictionary(dictionary: try XCTUnwrap(mac[identifier])), identifier)
        }
        // MOBI: the same but for the extension.
        var mobi = try XCTUnwrap(ios["com.textmouth.mobi"])
        var tags = try XCTUnwrap(mobi["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["mobi", "prc", "azw", "azw3"])
        var macMobi = try XCTUnwrap(mac["com.textmouth.mobi"])
        var macTags = try XCTUnwrap(macMobi["UTTypeTagSpecification"] as? [String: Any])
        tags["public.filename-extension"] = nil
        macTags["public.filename-extension"] = nil
        mobi["UTTypeTagSpecification"] = tags
        macMobi["UTTypeTagSpecification"] = macTags
        XCTAssertEqual(NSDictionary(dictionary: mobi), NSDictionary(dictionary: macMobi))
        // The exported type (a TextMouth book's package) is the Mac's.
        let exported = (try iosPlist())["UTExportedTypeDeclarations"] as? [[String: Any]]
        let macExported = (try macPlist())["UTExportedTypeDeclarations"] as? [[String: Any]]
        XCTAssertEqual(NSArray(array: exported ?? []), NSArray(array: macExported ?? []))
    }

    /// MOBI and KFX books are offered through the types and extensions iOS
    /// reads: their types are named and declared, with every extension their
    /// readers take and their MIME types.
    func testKindleBooksAreOfferedThroughTheirDeclarations() throws {
        let ios = try iosPlist()
        let named = try namedTypes(of: ios)
        let declarations = try imported(in: ios)
        for (format, type) in [(BookFormat.mobi, "com.textmouth.mobi"), (.kfx, "com.textmouth.kfx")] {
            XCTAssertTrue(named.contains(type), type)
            let tags = try XCTUnwrap(try XCTUnwrap(declarations[type])["UTTypeTagSpecification"] as? [String: Any], type)
            let tagged = Set(tags["public.filename-extension"] as? [String] ?? [])
            XCTAssertTrue(Set(format.fileExtensions).isSubset(of: tagged), "\(format) \(format.fileExtensions) \(tagged)")
        }
        let mobiTags = try XCTUnwrap(try XCTUnwrap(declarations["com.textmouth.mobi"])["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertTrue((mobiTags["public.filename-extension"] as? [String] ?? []).contains("azw3"))
        XCTAssertEqual(mobiTags["public.mime-type"] as? [String], ["application/x-mobipocket-ebook", "application/vnd.amazon.ebook"])
    }

    /// What iOS cannot read is not offered: through no type it names, and no
    /// extension its declarations tag, are Ogg, the converted audio, `.caf`,
    /// or the braille files.
    func testWhatNeedsAProgramIOSCannotStartIsNotOffered() throws {
        let ios = try iosPlist()
        let named = try namedTypes(of: ios)
        XCTAssertTrue(named.isDisjoint(with: refusedTypes))
        let tagged = Set(try imported(in: ios).values.flatMap { declaration -> [String] in
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            return tags?["public.filename-extension"] as? [String] ?? []
        })
        for ext in ImportAudioConverter.convertedExtensions.union(["caf", "brf", "brl", "pef"]) {
            XCTAssertFalse(tagged.contains(ext), ext)
        }
        // And the custom types left are declared, once each, and each declaration is named.
        let declarations = try imported(in: ios)
        for type in named where type.hasPrefix("com.textmouth.") && type != "com.textmouth.book-package" {
            XCTAssertNotNil(declarations[type], "\(type) is named but not declared")
        }
        for type in declarations.keys {
            XCTAssertTrue(named.contains(type), "\(type) is declared but no document type names it")
        }
    }

    // MARK: - Other keys

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

    // MARK: - The project

    /// Every build configuration of the project names the plist of its own app:
    /// the iOS app's two (Debug and Release; the SDK is iphoneos) the iOS file,
    /// the Mac app's two the Mac's, and the test bundle's two its own. XcodeGen
    /// once picked the Mac's plist for iOS by itself.
    func testEachConfigurationOfTheProjectUsesItsOwnAppsPlist() throws {
        let project = try String(
            contentsOf: Self.root.appendingPathComponent("TextMouth.xcodeproj/project.pbxproj"), encoding: .utf8)
        var found: [String: Int] = [:]
        for block in project.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst() {
            // The settings of this configuration, up to the end of its block.
            let settings = block.components(separatedBy: "\n\t\t};").first ?? ""
            // (GENERATE_INFOPLIST_FILE is another setting, whose name ends the same.)
            guard let line = settings.components(separatedBy: "\n")
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("INFOPLIST_FILE = ") }) else { continue }
            let plist = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "INFOPLIST_FILE = ", with: "")
                .replacingOccurrences(of: ";", with: "")
            let isIOS = settings.contains("SDKROOT = iphoneos;")
            switch plist {
            case "TextMouth/Platform/iOS/Info.plist": XCTAssertTrue(isIOS, "the iOS plist outside an iOS configuration")
            case "TextMouth/Resources/Info.plist": XCTAssertFalse(isIOS, "the Mac's plist in an iOS configuration")
            default: break
            }
            found[plist, default: 0] += 1
        }
        XCTAssertEqual(found["TextMouth/Platform/iOS/Info.plist"], 2)
        XCTAssertEqual(found["TextMouth/Resources/Info.plist"], 2)
        XCTAssertEqual(found["TextMouthProductionTests/Info.plist"], 2)
        let yml = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertEqual(yml.components(separatedBy: "INFOPLIST_FILE: TextMouth/Platform/iOS/Info.plist").count - 1, 1)
        XCTAssertEqual(yml.components(separatedBy: "INFOPLIST_FILE: TextMouth/Resources/Info.plist").count - 1, 1)
    }
}
