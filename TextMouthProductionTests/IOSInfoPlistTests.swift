import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// The iOS app's Info.plist (TextMouth/Platform/iOS/Info.plist), read from the
/// source tree. It is written from the Mac's (TextMouth/Resources/Info.plist)
/// by Scripts/ios/sync-info-plist.py, and `make check-ios-plist` says when it
/// is stale. These tests check what the script is meant to give, which plist
/// each configuration of the project uses, and the keys the iPhone app runs
/// by. `make typecheck-ios` builds a plain executable with no Info.plist, so a
/// missing background mode or an undeclared type passes it: a lost audio
/// background mode would silence every book the moment the screen locks.
///
/// "Open in TextMouth" should offer every book the app can import on iOS, and
/// nothing it would refuse. iOS goes by the types a document type names
/// (`LSItemContentTypes`) and the declarations of those types
/// (`UTImportedTypeDeclarations`, with the extensions they tag), not by
/// `CFBundleTypeExtensions`, so most of these tests read those keys. The iOS
/// types are the Mac's less what needs a program iOS cannot start (the audio
/// the import converts with afconvert, and the braille files, which need the
/// braille helper). The Mac's own Kindle MOBI type names `.azw3` (since 0.4.2),
/// so iOS needs nothing added for it.
final class IOSInfoPlistTests: XCTestCase {

    // MARK: - Fixtures

    /// The repository's root: the folder above the app's source folder.
    private static let root = AppSourceFile.folder.deletingLastPathComponent()

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

    /// The identifiers `plist` declares, imported and exported.
    private func declaredIdentifiers(in plist: [String: Any]) throws -> Set<String> {
        var identifiers: Set<String> = []
        for key in ["UTImportedTypeDeclarations", "UTExportedTypeDeclarations"] {
            let declarations = try XCTUnwrap(plist[key] as? [[String: Any]], key)
            identifiers.formUnion(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
        }
        return identifiers
    }

    /// project.yml's text.
    private func projectYAML() throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
    }

    /// The lines of the target `name` in project.yml's text: from its name, two
    /// spaces in, to the next line at that indent or less, which begins the next
    /// target or its comment.
    private func block(ofTarget name: String, in project: String) -> String? {
        let lines = project.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "  \(name):") else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { !$0.isEmpty && !$0.hasPrefix("   ") } ?? rest.endIndex
        return lines[start..<end].joined(separator: "\n") + "\n"
    }

    /// The source of `FileImportService.supportedTypes`, from its first line
    /// through the end of its body, a line holding only a brace at its indent.
    private func supportedTypesSource() throws -> String {
        let file = AppSourceFile.folder.appendingPathComponent("Services/FileImportService.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static var supportedTypes: [UTType] {"), "supportedTypes moved")
        let end = try XCTUnwrap(
            source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex),
            "supportedTypes' end was not found"
        )
        return String(source[start.lowerBound..<end.upperBound])
    }

    /// The first group of each match of `pattern` in `text`.
    private func matches(of pattern: String, in text: String) throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return Set(expression.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// The document types the Mac declares and iOS leaves out, by name, and why:
    /// the audio the import converts with afconvert (`ImportAudioConverter`),
    /// among it the system's type for `.caf`, which ALAC's type names too, and the
    /// braille files, which need the braille helper.
    private static let refused: Set<String> = [
        "Ogg Audio", "Audio Converted at Import", "ALAC Audio",
        "BRF Braille File", "BRL Braille File", "PEF Braille File",
    ]

    /// The braille files' types, which the Mac declares and iOS does not: the
    /// import names them, and the iPhone refuses every braille book with a
    /// sentence of its own (`PhoneImportRefusal.braille`).
    private static let brailleTypes: Set<String> = ["com.textmouth.brf", "com.textmouth.brl", "org.daisy.pef"]

    /// The types only those document types name: what the Mac names and iOS does not.
    private static let refusedTypes: Set<String> = Set([
        "org.xiph.ogg-audio",
        "public.aifc-audio", "com.apple.coreaudio-format", "public.au-audio", "com.sony.wave64", "public.ac3-audio",
        "public.enhanced-ac3-audio", "public.mp2", "org.3gpp.adaptive-multi-rate-audio", "public.3gpp", "public.3gpp2",
    ]).union(brailleTypes)

    /// The keys only iOS has, which Scripts/ios/sync-info-plist.py adds.
    private static let iOSOnlyKeys: Set<String> = ["UIBackgroundModes", "UIApplicationSceneManifest"]

    // MARK: - Document types

    /// iOS declares each of the Mac's document types, as the Mac declares it,
    /// less the ones it refuses; the Kindle MOBI type is the Mac's too, which
    /// names `.azw3`.
    func testIOSDeclaresTheMacsDocumentTypesLessWhatItRefuses() throws {
        let mac = try documentTypes(of: macPlist())
        let ios = try documentTypes(of: iosPlist())
        XCTAssertEqual(Set(ios.keys), Set(mac.keys).subtracting(Self.refused))
        XCTAssertTrue(Self.refused.isSubset(of: Set(mac.keys)), "a refused type the Mac does not have")
        for (name, type) in ios {
            XCTAssertEqual(NSDictionary(dictionary: type), NSDictionary(dictionary: try XCTUnwrap(mac[name])), name)
        }
        // The Mac's own Kindle MOBI type names .azw3, so iOS offers those files with no addition of its own.
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
        XCTAssertEqual(ios, mac.subtracting(Self.refusedTypes))
        XCTAssertTrue(Self.refusedTypes.isSubset(of: mac), "a refused type the Mac does not name")
        // The refusals are exactly what each says: no type of a kept document type is among them.
        for type in try documentTypes(of: iosPlist()).values.flatMap({ $0["LSItemContentTypes"] as? [String] ?? [] }) {
            XCTAssertFalse(Self.refusedTypes.contains(type), type)
        }
    }

    /// Each kind of file another app may offer TextMouth is one the import
    /// takes: named in its list, or conforming either way to a type there. The
    /// ZIP entry conforms the other way: a .zip is public.zip-archive, which
    /// conforms to the older com.pkware.zip-archive the entry names.
    func testEveryDocumentTypeIsOneTheImportTakes() throws {
        let source = try supportedTypesSource()
        let supported = FileImportService.supportedTypes
        for (name, documentType) in try documentTypes(of: iosPlist()) {
            let identifiers = try XCTUnwrap(documentType["LSItemContentTypes"] as? [String], name)
            XCTAssertFalse(identifiers.isEmpty, name)
            for identifier in identifiers where !source.contains("\"\(identifier)\"") {
                let conforms = UTType(identifier).map { type in
                    supported.contains { type.conforms(to: $0) || $0.conforms(to: type) }
                }
                XCTAssertEqual(conforms, true, "\(name): the import takes no \(identifier)")
            }
        }
    }

    // MARK: - Type declarations

    /// The imported declarations iOS reads, which tag the extensions of the
    /// types, are the Mac's less the braille files' (the MOBI type's `.azw3`
    /// tag is the Mac's own); and the exported ones are the Mac's.
    func testTheDeclarationsAreTheMacsLessTheBrailleFiles() throws {
        let mac = try imported(in: macPlist())
        let ios = try imported(in: iosPlist())
        XCTAssertEqual(Set(ios.keys), Set(mac.keys).subtracting(Self.brailleTypes))
        for (identifier, declaration) in ios {
            XCTAssertEqual(NSDictionary(dictionary: declaration), NSDictionary(dictionary: try XCTUnwrap(mac[identifier])), identifier)
        }
        // The MOBI type tags .azw3 in the Mac's own plist, so iOS's copy of it does too.
        let mobi = try XCTUnwrap(ios["com.textmouth.mobi"])
        let tags = try XCTUnwrap(mobi["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["mobi", "prc", "azw", "azw3"])
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

    /// Every type the import declares for itself is declared for iOS too, but
    /// the braille files', which iOS refuses. The `UTType(identifier)` form
    /// answers nil for an undeclared type, and `UTType(importedAs:)` works only
    /// if the app declares it, so a missing one loses a format from the file
    /// picker with no error. The braille types drop out of the picker that way
    /// on purpose.
    func testEveryTypeTheImportNamesIsDeclaredButTheBrailleFiles() throws {
        let macDeclared = try declaredIdentifiers(in: macPlist())
        let iOSDeclared = try declaredIdentifiers(in: iosPlist())
        let source = try supportedTypesSource()

        let named = macDeclared.filter { source.contains("\"\($0)\"") }
        XCTAssertFalse(named.isEmpty, "Found none of the Mac's declared types in the import's source")
        XCTAssertEqual(named.subtracting(iOSDeclared), Self.brailleTypes, "Named by the import, and not declared for iOS")

        let importedAs = try matches(of: #"UTType\(importedAs: "([^"]+)""#, in: source)
        XCTAssertFalse(importedAs.isEmpty, "Found no UTType(importedAs:) in the import's source")
        XCTAssertEqual(
            importedAs.subtracting(iOSDeclared).subtracting(Self.brailleTypes), [],
            "UTType(importedAs:) with no declaration")

        // A UTType("com.textmouth...") is nil without its declaration, and drops
        // out of the file picker in silence (F33).
        let ownTypes = try matches(of: #"UTType\("(com\.textmouth\.[^"]+)"\)"#, in: source)
        XCTAssertFalse(ownTypes.isEmpty, "Found no UTType(\"com.textmouth...\") in the import's source")
        XCTAssertEqual(ownTypes.subtracting(iOSDeclared), [], "UTType(\"com.textmouth...\") with no declaration")

        // The import's list itself, as this process builds it.
        let used = Set(FileImportService.supportedTypes.map(\.identifier)).intersection(macDeclared)
        XCTAssertEqual(
            used.subtracting(iOSDeclared).subtracting(Self.brailleTypes), [],
            "In supportedTypes, and not declared for iOS")
    }

    /// What iOS cannot read is not offered: through no type it names, no
    /// extension its declarations tag, and no extension its document types
    /// list, are Ogg, the converted audio, `.caf`, ALAC, or the braille files.
    func testWhatNeedsAProgramIOSCannotStartIsNotOffered() throws {
        let ios = try iosPlist()
        let named = try namedTypes(of: ios)
        XCTAssertTrue(named.isDisjoint(with: Self.refusedTypes))
        let refusedExtensions = ImportAudioConverter.convertedExtensions.union(["caf", "alac", "brf", "brl", "pef"])
        let tagged = Set(try imported(in: ios).values.flatMap { declaration -> [String] in
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            return tags?["public.filename-extension"] as? [String] ?? []
        })
        XCTAssertTrue(tagged.isDisjoint(with: refusedExtensions), "tagged: \(tagged.intersection(refusedExtensions))")
        for (name, type) in try documentTypes(of: ios) {
            let listed = Set(type["CFBundleTypeExtensions"] as? [String] ?? [])
            XCTAssertTrue(listed.isDisjoint(with: refusedExtensions), "\(name): \(listed.intersection(refusedExtensions))")
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
    /// mean nothing on iOS, with the keys only iOS has: the network settings
    /// that feeds need stay.
    func testTheOtherKeysAreTheMacsLessTheMacOnlyOnesWithTheIOSOnes() throws {
        let mac = try macPlist()
        let ios = try iosPlist()
        let macOnly: Set<String> = ["LSMinimumSystemVersion", "NSAppleEventsUsageDescription"]
        let documentKeys: Set<String> = ["CFBundleDocumentTypes", "UTImportedTypeDeclarations"]
        XCTAssertEqual(Set(ios.keys), Set(mac.keys).subtracting(macOnly).union(Self.iOSOnlyKeys))
        XCTAssertTrue(Set(mac.keys).isDisjoint(with: Self.iOSOnlyKeys), "the Mac's plist holds a key only iOS should have")
        for key in ios.keys where !documentKeys.contains(key) && !Self.iOSOnlyKeys.contains(key) {
            XCTAssertEqual(NSDictionary(dictionary: [key: ios[key] as Any]), NSDictionary(dictionary: [key: mac[key] as Any]), key)
        }
        XCTAssertNotNil(ios["NSAppTransportSecurity"])
    }

    /// The book goes on with the screen locked, and the app asks for no other
    /// background mode: a short hold (`beginBackgroundTask`) needs none.
    func testTheBackgroundModesAreAudioAlone() throws {
        let modes = try XCTUnwrap(try iosPlist()["UIBackgroundModes"] as? [String])
        XCTAssertEqual(modes, ["audio"], "Without audio every book stops as the screen locks")
    }

    /// One scene at a time, also on an iPad, since one session cannot serve two
    /// windows; and nothing generates a manifest allowing several (F27).
    func testOneSceneAtATime() throws {
        let manifest = try XCTUnwrap(try iosPlist()["UIApplicationSceneManifest"] as? [String: Any])
        XCTAssertEqual(manifest["UIApplicationSupportsMultipleScenes"] as? Bool, false)
        let iOSTarget = try XCTUnwrap(block(ofTarget: "TextMouthiOS", in: try projectYAML()))
        XCTAssertFalse(
            iOSTarget.contains("INFOPLIST_KEY_UIApplicationSceneManifest_Generation: true"),
            "Xcode's generated manifest allows several scenes"
        )
    }

    /// The library stays hidden from the Files app (the spec's question 8).
    func testFileSharingIsNotTurnedOn() throws {
        XCTAssertNil(try iosPlist()["UIFileSharingEnabled"])
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
        let yml = try projectYAML()
        XCTAssertEqual(yml.components(separatedBy: "INFOPLIST_FILE: TextMouth/Platform/iOS/Info.plist").count - 1, 1)
        XCTAssertEqual(yml.components(separatedBy: "INFOPLIST_FILE: TextMouth/Resources/Info.plist").count - 1, 1)
    }

    /// The iOS target reads its plist, merged with the generated one, opens
    /// documents in place, and has a bundle identifier of its own; the Mac's
    /// target keeps its own of each.
    func testTheIOSTargetUsesItsPlistAndAnIdentifierOfItsOwn() throws {
        let project = try projectYAML()
        let iOSTarget = try XCTUnwrap(block(ofTarget: "TextMouthiOS", in: project), "No TextMouthiOS target")
        XCTAssertTrue(iOSTarget.contains("INFOPLIST_FILE: TextMouth/Platform/iOS/Info.plist\n"))
        XCTAssertTrue(iOSTarget.contains("GENERATE_INFOPLIST_FILE: true\n"))
        XCTAssertTrue(iOSTarget.contains("INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES\n"))
        XCTAssertTrue(iOSTarget.contains("PRODUCT_BUNDLE_IDENTIFIER: com.textmouth.TextMouth.iOS\n"))

        let macTarget = try XCTUnwrap(block(ofTarget: "TextMouth", in: project), "No TextMouth target")
        XCTAssertTrue(macTarget.contains("INFOPLIST_FILE: TextMouth/Resources/Info.plist\n"))
        XCTAssertTrue(macTarget.contains("PRODUCT_BUNDLE_IDENTIFIER: com.textmouth.TextMouth\n"))
    }

    /// No key is both in the iOS plist and generated by an `INFOPLIST_KEY_`
    /// setting of the iOS target, since Apple does not say which would win:
    /// `INFOPLIST_KEY_UILaunchScreen_Generation` makes `UILaunchScreen`, and
    /// `INFOPLIST_KEY_CFBundleDisplayName` would make `CFBundleDisplayName`,
    /// which the plist takes from the Mac's.
    func testNoKeyOfThePlistIsAlsoABuildSetting() throws {
        let iOSTarget = try XCTUnwrap(block(ofTarget: "TextMouthiOS", in: try projectYAML()))
        // A setting's own line, not a comment that names one.
        let settings = iOSTarget.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("INFOPLIST_KEY_") }
        XCTAssertFalse(settings.isEmpty, "Found no INFOPLIST_KEY_ setting in the iOS target")
        let generated = Set(settings.compactMap { line -> String? in
            guard let name = line.components(separatedBy: ":").first else { return nil }
            let key = String(name.dropFirst("INFOPLIST_KEY_".count))
            return key.hasSuffix("_Generation") ? String(key.dropLast("_Generation".count)) : key
        })
        XCTAssertTrue(generated.contains("LSSupportsOpeningDocumentsInPlace"), "\(generated)")
        let plist = try iosPlist()
        for key in generated {
            XCTAssertNil(plist[key], "\(key) is in the plist and has an INFOPLIST_KEY_ setting in project.yml")
        }
    }
}
