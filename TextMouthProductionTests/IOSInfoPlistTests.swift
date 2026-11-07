import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// `iOSApp/Info.plist`, read from the source tree. `make typecheck-ios` builds
/// a plain executable with no Info.plist, so a missing background mode or an
/// undeclared type passes it, and nothing can run on iOS tonight: these tests
/// are the only thing that reads the file. A lost audio background mode would
/// silence every book the moment the screen locks.
final class IOSInfoPlistTests: XCTestCase {
    /// The repository: the folder above the app's source folder.
    private static let repository = AppSourceFile.folder.deletingLastPathComponent()

    /// The document types the iPhone leaves out of the Mac's, so that no app
    /// offers TextMouth a file it would refuse: what the import converts, and
    /// braille, whose translator is a helper program.
    private static let typesLeftOut: Set<String> = [
        "Ogg Audio",
        "Audio Converted at Import",
        "ALAC Audio",
        "BRF Braille File",
        "BRL Braille File",
        "PEF Braille File",
    ]

    // MARK: - The Keys

    /// The book goes on with the screen locked.
    func testTheBackgroundModesHoldAudio() throws {
        let modes = try XCTUnwrap(Self.iOSPlist()["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("audio"), "Without it every book stops as the screen locks")
    }

    /// The library stays hidden from the Files app (the spec's question 8).
    func testFileSharingIsNotTurnedOn() throws {
        XCTAssertNil(try Self.iOSPlist()["UIFileSharingEnabled"])
    }

    /// No key is on both sides of the merge: Apple does not say which wins.
    /// These have INFOPLIST_KEY_ settings, in project.yml.
    func testNoKeyAlsoHasABuildSetting() throws {
        let plist = try Self.iOSPlist()
        for key in [
            "CFBundleDisplayName", "LSSupportsOpeningDocumentsInPlace", "UILaunchScreen", "UIApplicationSceneManifest",
        ] {
            XCTAssertNil(plist[key], "\(key) has an INFOPLIST_KEY_ setting in project.yml")
        }
    }

    /// The iOS target reads this file, opens documents in place, and has a
    /// bundle identifier of its own; the Mac's target keeps its own of each.
    func testTheProjectUsesThisFile() throws {
        let project = try String(
            contentsOf: Self.repository.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let iOSTarget = try XCTUnwrap(Self.block(ofTarget: "TextMouthiOS", in: project), "No TextMouthiOS target")
        XCTAssertTrue(iOSTarget.contains("INFOPLIST_FILE: iOSApp/Info.plist"))
        XCTAssertTrue(iOSTarget.contains("GENERATE_INFOPLIST_FILE: true"))
        XCTAssertTrue(iOSTarget.contains("INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES"))
        XCTAssertTrue(iOSTarget.contains("PRODUCT_BUNDLE_IDENTIFIER: com.textmouth.TextMouth.iOS\n"))

        let macTarget = try XCTUnwrap(Self.block(ofTarget: "TextMouth", in: project), "No TextMouth target")
        XCTAssertTrue(macTarget.contains("INFOPLIST_FILE: TextMouth/Resources/Info.plist"))
        XCTAssertTrue(macTarget.contains("PRODUCT_BUNDLE_IDENTIFIER: com.textmouth.TextMouth\n"))
    }

    // MARK: - The Types the Import Names

    /// Every type the import declares for itself is declared here too. The
    /// `UTType(identifier)` form answers nil for an undeclared type, and
    /// `UTType(importedAs:)` works only if the app declares it, so a missing
    /// one loses a format from the file picker with no error.
    func testEveryTypeTheImportDeclaresForItselfIsDeclared() throws {
        let macDeclared = try Self.declaredIdentifiers(in: Self.macPlist())
        let iOSDeclared = try Self.declaredIdentifiers(in: Self.iOSPlist())
        let source = try Self.supportedTypesSource()

        let named = macDeclared.filter { source.contains("\"\($0)\"") }
        XCTAssertFalse(named.isEmpty, "Found none of the Mac's declared types in the import's source")
        XCTAssertEqual(named.subtracting(iOSDeclared), [], "Named by the import, and not declared for iOS")

        let importedAs = try Self.matches(of: #"UTType\(importedAs: "([^"]+)""#, in: source)
        XCTAssertFalse(importedAs.isEmpty, "Found no UTType(importedAs:) in the import's source")
        XCTAssertEqual(importedAs.subtracting(iOSDeclared), [], "UTType(importedAs:) with no declaration")

        // The import's list itself, as this process builds it.
        let used = Set(FileImportService.supportedTypes.map(\.identifier)).intersection(macDeclared)
        XCTAssertEqual(used.subtracting(iOSDeclared), [], "In supportedTypes, and not declared for iOS")
    }

    /// Each kind of file another app may offer TextMouth is one the import
    /// takes: named in its list, or conforming either way to a type there. The
    /// ZIP entry conforms the other way: a .zip is public.zip-archive, which
    /// conforms to the older com.pkware.zip-archive the entry names.
    func testEveryDocumentTypeIsOneTheImportTakes() throws {
        let source = try Self.supportedTypesSource()
        let supported = FileImportService.supportedTypes
        for documentType in try Self.documentTypes(in: Self.iOSPlist()) {
            let name = documentType["CFBundleTypeName"] as? String ?? "unnamed"
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

    // MARK: - Agreeing with the Mac

    /// Each document type is the Mac's own, word for word, and every one of the
    /// Mac's is here or named as left out, so a type the Mac gains is decided
    /// for the iPhone too. A left-out name that no longer exists fails as well.
    func testTheDocumentTypesAreTheMacsLessThoseLeftOut() throws {
        let macTypes = try Self.documentTypes(in: Self.macPlist())
        let iOSTypes = try Self.documentTypes(in: Self.iOSPlist())
        let macByName = Dictionary(
            macTypes.map { ($0["CFBundleTypeName"] as? String ?? "", $0 as NSDictionary) },
            uniquingKeysWith: { first, _ in first }
        )

        for type in iOSTypes {
            let name = try XCTUnwrap(type["CFBundleTypeName"] as? String)
            XCTAssertEqual(macByName[name], type as NSDictionary, "\(name) differs from the Mac's")
        }
        let iOSNames = Set(iOSTypes.compactMap { $0["CFBundleTypeName"] as? String })
        XCTAssertEqual(iOSNames.intersection(Self.typesLeftOut), [], "A type left out is offered")
        XCTAssertEqual(iOSNames.union(Self.typesLeftOut), Set(macByName.keys), "Decide each Mac type for the iPhone")
    }

    /// What the iPhone cannot read is not offered, by any route: no extension
    /// the import converts, no braille extension, and no content type of either.
    func testNothingTheIPhoneRefusesIsOffered() throws {
        let refusedTypes: Set<String> = [
            "org.xiph.ogg-audio", "com.apple.coreaudio-format", "public.aifc-audio", "public.au-audio",
            "com.textmouth.brf", "com.textmouth.brl", "org.daisy.pef",
        ]
        let refusedExtensions = ImportAudioConverter.convertedExtensions.union(["brf", "brl", "pef", "alac"])
        for type in try Self.documentTypes(in: Self.iOSPlist()) {
            let name = type["CFBundleTypeName"] as? String ?? "unnamed"
            let identifiers = Set(type["LSItemContentTypes"] as? [String] ?? [])
            XCTAssertEqual(identifiers.intersection(refusedTypes), [], name)
            let extensions = Set(type["CFBundleTypeExtensions"] as? [String] ?? [])
            XCTAssertEqual(extensions.intersection(refusedExtensions), [], name)
        }
    }

    /// The type declarations are the Mac's, so the two apps name a file alike.
    func testTheTypeDeclarationsAreTheMacs() throws {
        let macPlist = try Self.macPlist()
        let iOSPlist = try Self.iOSPlist()
        for key in ["UTImportedTypeDeclarations", "UTExportedTypeDeclarations"] {
            let macList = try XCTUnwrap(macPlist[key] as? NSArray, key)
            XCTAssertEqual(iOSPlist[key] as? NSArray, macList, "\(key) differs from the Mac's")
        }
    }

    // MARK: - Reading the Files

    /// The iOS app's Info.plist.
    private static func iOSPlist() throws -> [String: Any] {
        try plist(at: "iOSApp/Info.plist")
    }

    /// The Mac app's Info.plist.
    private static func macPlist() throws -> [String: Any] {
        try plist(at: "TextMouth/Resources/Info.plist")
    }

    /// The property list at `path` in the repository.
    private static func plist(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repository.appendingPathComponent(path))
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: Any], "\(path) is not a dictionary")
    }

    /// The document types of `plist`.
    private static func documentTypes(in plist: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]], "No document types")
    }

    /// The identifiers `plist` declares, imported and exported.
    private static func declaredIdentifiers(in plist: [String: Any]) throws -> Set<String> {
        var identifiers: Set<String> = []
        for key in ["UTImportedTypeDeclarations", "UTExportedTypeDeclarations"] {
            let declarations = try XCTUnwrap(plist[key] as? [[String: Any]], key)
            identifiers.formUnion(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
        }
        return identifiers
    }

    /// The source of `FileImportService.supportedTypes`, from its first line
    /// through the end of its body, a line holding only a brace at its indent.
    private static func supportedTypesSource() throws -> String {
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
    private static func matches(of pattern: String, in text: String) throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return Set(expression.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// The lines of the target `name` in project.yml's text: from its name, two
    /// spaces in, to the next line at that indent or less, which begins the next
    /// target or its comment.
    private static func block(ofTarget name: String, in project: String) -> String? {
        let lines = project.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "  \(name):") else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { !$0.isEmpty && !$0.hasPrefix("   ") } ?? rest.endIndex
        return lines[start..<end].joined(separator: "\n") + "\n"
    }
}
