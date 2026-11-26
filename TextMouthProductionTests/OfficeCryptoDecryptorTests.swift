import CommonCrypto
import CryptoKit
import XCTest
import ZIPFoundation
@testable import TextMouth

/// A Word document saved with a password is decrypted in memory (FR41,
/// phase 2). No program here writes such a file, so a test-only encryptor
/// makes them, from the specification's steps run the other way ([MS-OFFCRYPTO]
/// 2.3.4): it shares no code with the decryptor. The compound file around
/// them is written by a small writer here, with regular sectors only (each
/// stream is padded past 4096 bytes, where the format stops using its
/// mini stream).
///
/// What this cannot prove is that Word's own files read: the encryptor and
/// the decryptor are written from the same understanding. A real file from
/// Word is the hand check.
final class OfficeCryptoDecryptorTests: XCTestCase {

    /// The plain package every test encrypts: a ZIP archive, so that the
    /// decrypted bytes can be read as one.
    private func plainPackage() throws -> Data {
        let url = try makeTemporaryZip(prefix: "office", entries: [
            "[Content_Types].xml": Data("<Types/>".utf8),
            "word/document.xml": Data(String(repeating: "<w:t>The sluice gate opens at dawn.</w:t>", count: 200).utf8)
        ], compressionMethod: .deflate)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    // MARK: - Agile

    /// Agile: right password, plain package back, for each hash.
    func testAgileEncryptionIsDecrypted() throws {
        let package = try plainPackage()
        for hash in ["SHA1", "SHA256", "SHA512"] {
            let made = TestOfficeEncryptor.agile(package: package, password: "secret", hash: hash, spinCount: 1000)
            let plain = try OfficeCryptoDecryptor.decrypt(info: made.info, package: made.package, password: Secret("secret"))
            XCTAssertEqual(plain, package, hash)
        }
    }

    /// Agile: a package that is not a whole number of segments, and one larger than a segment.
    func testAgileSegmentsOfAnySize() throws {
        for count in [1, 15, 16, 4095, 4096, 4097, 10_000] {
            let package = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let made = TestOfficeEncryptor.agile(package: package, password: "p", hash: "SHA512", spinCount: 100)
            let plain = try OfficeCryptoDecryptor.decrypt(info: made.info, package: made.package, password: Secret("p"))
            XCTAssertEqual(plain, package, "\(count) bytes")
        }
    }

    /// Agile: a wrong password, an empty one, and the wrong case are refused as such.
    func testAgileWrongPasswordIsRefused() throws {
        let made = TestOfficeEncryptor.agile(package: try plainPackage(), password: "secret", hash: "SHA512", spinCount: 100)
        for typed in ["Secret", "", "secre", "secret "] {
            XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: made.info, package: made.package, password: Secret(typed)), typed) {
                XCTAssertEqual($0 as? OfficeCryptoDecryptor.Failure, .wrongPassword, typed)
            }
        }
    }

    /// An accented password opens in either Unicode form.
    func testAnAccentedPasswordOpensInEitherForm() throws {
        let composed = "p\u{E4}ssw\u{F6}rd"
        let package = try plainPackage()
        let made = TestOfficeEncryptor.agile(package: package, password: composed, hash: "SHA512", spinCount: 100)
        let plain = try OfficeCryptoDecryptor.decrypt(info: made.info, package: made.package, password: Secret(composed.decomposedStringWithCanonicalMapping))
        XCTAssertEqual(plain, package)
    }

    /// A damaged or hostile descriptor is damage or unsupported, never a trap.
    func testAHostileDescriptorIsRefused() throws {
        let made = TestOfficeEncryptor.agile(package: Data("x".utf8), password: "p", hash: "SHA512", spinCount: 100)
        // Not XML.
        let garbage = Array(made.info.prefix(8)) + Array("not xml at all".utf8)
        XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: garbage, package: made.package, password: Secret("p"))) {
            XCTAssertEqual($0 as? OfficeCryptoDecryptor.Failure, .damaged)
        }
        // A spin count past the specification's limit.
        let xml = String(decoding: made.info.dropFirst(8), as: UTF8.self).replacingOccurrences(of: "spinCount=\"100\"", with: "spinCount=\"99999999999\"")
        XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: Array(made.info.prefix(8)) + Array(xml.utf8), package: made.package, password: Secret("p")))
        // Too short to hold a version, a version nobody knows, and an outside provider's.
        XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: [4, 0], package: made.package, password: Secret("p")))
        // Version 4.3: the version bytes replaced.
        let extensible = [4, 0, 3, 0] as [UInt8] + made.info.dropFirst(4)
        XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: extensible, package: made.package, password: Secret("p"))) {
            XCTAssertEqual($0 as? OfficeCryptoDecryptor.Failure, .unsupported)
        }
        // A stream cut short, and a size larger than the data.
        XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: made.info, package: [1, 2, 3], password: Secret("p")))
        // A size field that claims far more than the data holds.
        let lying = Array(made.package.prefix(7)) + [0x7F] + Array(made.package.dropFirst(8))
        XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: made.info, package: lying, password: Secret("p")))
    }

    /// The descriptor of `made` with its first `keyBits="256"` (the data's own key size) or both
    /// of them (the password key's too) given `bits` instead.
    private func descriptor(of made: TestOfficeEncryptor.Made, keyBits bits: String, both: Bool) throws -> [UInt8] {
        let xml = String(decoding: made.info.dropFirst(8), as: UTF8.self)
        let named = "keyBits=\"256\""
        let changed = both
            ? xml.replacingOccurrences(of: named, with: "keyBits=\"\(bits)\"")
            : xml.replacingCharacters(in: try XCTUnwrap(xml.range(of: named)), with: "keyBits=\"\(bits)\"")
        return Array(made.info.prefix(8)) + Array(changed.utf8)
    }

    /// A key size AES does not take is unsupported, in the data's key and the password's alike,
    /// refused before any key is made: a password key 256 bytes long was refused as damage, and
    /// the data's own size was never read, so a file that named a wrong one opened anyway.
    func testAKeySizeAESDoesNotTakeIsUnsupported() throws {
        let made = TestOfficeEncryptor.agile(package: Data("x".utf8), password: "p", hash: "SHA512", spinCount: 100)
        for both in [true, false] {
            let info = try descriptor(of: made, keyBits: "2048", both: both)
            XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: info, package: made.package, password: Secret("p")), "both: \(both)") {
                XCTAssertEqual($0 as? OfficeCryptoDecryptor.Failure, .unsupported, "both: \(both)")
            }
        }
    }

    /// A hostile key size, far past what memory holds, is refused before any key is made. The key
    /// was padded to the size named, so this asked for a buffer of about 12 GB; with the check
    /// broken it would take the host down, so it runs on GitHub's runner only.
    func testAHostileKeySizeIsRefusedBeforeAnyKeyIsMade() throws {
        try TestMachine.skipUnlessGitHubRunner("A key-size check broken by a later change would ask for about 12 GB")
        let made = TestOfficeEncryptor.agile(package: Data("x".utf8), password: "p", hash: "SHA512", spinCount: 100)
        let info = try descriptor(of: made, keyBits: "99999999999", both: true)
        XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: info, package: made.package, password: Secret("p"))) {
            XCTAssertEqual($0 as? OfficeCryptoDecryptor.Failure, .unsupported)
        }
    }

    // MARK: - Standard

    /// Standard (Office 2007): each key size.
    func testStandardEncryptionIsDecrypted() throws {
        let package = try plainPackage()
        for bits in [128, 192, 256] {
            let made = TestOfficeEncryptor.standard(package: package, password: "secret", keyBits: bits)
            let plain = try OfficeCryptoDecryptor.decrypt(info: made.info, package: made.package, password: Secret("secret"))
            XCTAssertEqual(plain, package, "\(bits) bits")
        }
    }

    /// Standard: a wrong password is refused as such.
    func testStandardWrongPasswordIsRefused() throws {
        let made = TestOfficeEncryptor.standard(package: try plainPackage(), password: "secret", keyBits: 128)
        XCTAssertThrowsError(try OfficeCryptoDecryptor.decrypt(info: made.info, package: made.package, password: Secret("Secret"))) {
            XCTAssertEqual($0 as? OfficeCryptoDecryptor.Failure, .wrongPassword)
        }
    }

    // MARK: - Through the compound file, and the book

    /// The compound file that holds the two streams is found and decrypted,
    /// and a plain compound file or a ZIP is not taken for one.
    func testTheCompoundFileIsRecognizedAndDecrypted() throws {
        let package = try plainPackage()
        let made = TestOfficeEncryptor.agile(package: package, password: "secret", hash: "SHA512", spinCount: 100, padInfoTo: 4200, padPackageTo: 4200)
        let file = TestCompoundFileWriter.file(streams: [("EncryptionInfo", Data(made.info)), ("EncryptedPackage", Data(made.package))])
        XCTAssertTrue(OfficeCryptoDecryptor.isEncryptedPackage(file))
        XCTAssertEqual(try OfficeCryptoDecryptor.decrypt(file, password: Secret("secret")), package)
        XCTAssertFalse(OfficeCryptoDecryptor.isEncryptedPackage(package))
        let plainCompound = TestCompoundFileWriter.file(streams: [("WordDocument", Data(repeating: 1, count: 5000))])
        XCTAssertFalse(OfficeCryptoDecryptor.isEncryptedPackage(plainCompound))
    }

    /// A protected Word document is found by the detector, unlocked from memory,
    /// read by the DOCX reader, refused again once released, and its password
    /// removed by rewriting the file, as a ZIP's is.
    func testAProtectedDocumentUnlocksAndReads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OfficeCrypto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let docx = try minimalDocx(text: "The sluice gate opens at dawn.")
        let made = TestOfficeEncryptor.agile(package: docx, password: "secret", hash: "SHA512", spinCount: 100, padInfoTo: 4200, padPackageTo: 4200)
        let url = folder.appendingPathComponent("Notes.docx")
        try TestCompoundFileWriter.file(streams: [("EncryptionInfo", Data(made.info)), ("EncryptedPackage", Data(made.package))]).write(to: url)

        XCTAssertEqual(ProtectionDetector.scheme(ofFileAt: url, format: .docx), .officeOpenXML)
        XCTAssertThrowsError(try DOCXParser.parse(url: url))
        XCTAssertThrowsError(try UnlockedSources.unlock(fileAt: url, format: .docx, password: Secret("wrong"))) {
            XCTAssertEqual($0 as? UnlockFailure, .wrongPassword)
        }
        try UnlockedSources.unlock(fileAt: url, format: .docx, password: Secret("secret"))
        let content = try DOCXParser.parse(url: url)
        XCTAssertTrue(content.chapters.map(\.text).joined().contains("sluice gate"))
        let listing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(listing, ["Notes.docx"], "nothing was written beside the book")

        try ProtectionRemoval.removePassword(fromFileAt: url, format: .docx)
        UnlockedSources.release(url)
        XCTAssertNil(ProtectionDetector.scheme(ofFileAt: url, format: .docx))
        XCTAssertTrue(try DOCXParser.parse(url: url).chapters.map(\.text).joined().contains("sluice gate"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Notes.docx"], "one file, no copy")
    }
}

// MARK: - A Small Word Document

/// The parts of a small, valid .docx holding `text`, in the order Word writes
/// them: for a test that zips them itself, as with the `zip` tool's password.
func minimalDocxEntries(text: String) -> [TestZIPEntry] {
    let types = """
    <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
    """
    let rels = """
    <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    """
    let body = """
    <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body></w:document>
    """
    return [
        TestZIPEntry("[Content_Types].xml", Data(types.utf8)),
        TestZIPEntry("_rels/.rels", Data(rels.utf8)),
        TestZIPEntry("word/document.xml", Data(body.utf8))
    ]
}

/// A small, valid .docx holding `text`, its parts deflated.
func minimalDocx(text: String) throws -> Data {
    let url = try makeTemporaryZip(prefix: "docx", orderedEntries: minimalDocxEntries(text: text), compressionMethod: .deflate)
    defer { try? FileManager.default.removeItem(at: url) }
    return try Data(contentsOf: url)
}

// MARK: - The Test-Only Encryptor

/// Encrypts a package as Word does, from the specification's steps run the
/// other way. Test code only.
enum TestOfficeEncryptor {
    /// An `EncryptionInfo` stream and an `EncryptedPackage` stream.
    struct Made {
        var info: [UInt8]
        var package: [UInt8]
    }

    private static func random(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255) } }

    private static func hash(_ name: String, _ data: [UInt8]) -> [UInt8] {
        switch name {
        case "SHA1": return Array(Insecure.SHA1.hash(data: data))
        case "SHA256": return Array(SHA256.hash(data: data))
        default: return Array(SHA512.hash(data: data))
        }
    }

    private static func aes(_ encrypt: Bool, _ data: [UInt8], key: [UInt8], iv: [UInt8]?) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(iv == nil ? kCCOptionECBMode : 0),
            key, key.count, iv, data, data.count, &out, out.count, &moved
        )
        return status == kCCSuccess ? Array(out[0..<moved]) : []
    }

    private static func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    private static func le64(_ value: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    private static func utf16(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }
    private static func padded(_ bytes: [UInt8], to multiple: Int) -> [UInt8] {
        bytes.count % multiple == 0 ? bytes : bytes + [UInt8](repeating: 0, count: multiple - bytes.count % multiple)
    }

    /// Agile encryption (version 4.4), 256-bit AES. `padInfoTo` and
    /// `padPackageTo` make the streams at least that long (trailing spaces in
    /// the XML, and zero blocks in the package, which its size field ignores).
    static func agile(package: Data, password: String, hash name: String, spinCount: Int, padInfoTo: Int = 0, padPackageTo: Int = 0) -> Made {
        let keySalt = random(16), dataSalt = random(16), dataKey = random(32)
        let pw = utf16(password)
        func derive(_ blockKey: [UInt8]) -> [UInt8] {
            var h = hash(name, keySalt + pw)
            for i in 0..<spinCount { h = hash(name, le32(i) + h) }
            h = hash(name, h + blockKey)
            return Array((h + [UInt8](repeating: 0x36, count: 32)).prefix(32))
        }
        let verifier = random(16)
        let encryptedInput = aes(true, verifier, key: derive([0xfe, 0xa7, 0xd2, 0x76, 0x3b, 0x4b, 0x9e, 0x79]), iv: keySalt)
        let encryptedValue = aes(true, padded(hash(name, verifier), to: 16), key: derive([0xd7, 0xaa, 0x0f, 0x6d, 0x30, 0x61, 0x34, 0x4e]), iv: keySalt)
        let encryptedKey = aes(true, dataKey, key: derive([0x14, 0x6e, 0x0b, 0xe7, 0xab, 0xac, 0xd0, 0xd6]), iv: keySalt)
        let hashSize = hash(name, []).count
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <encryption xmlns="http://schemas.microsoft.com/office/2006/encryption" xmlns:p="http://schemas.microsoft.com/office/2006/keyEncryptor/password"><keyData saltSize="16" blockSize="16" keyBits="256" hashSize="\(hashSize)" cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" hashAlgorithm="\(name)" saltValue="\(Data(dataSalt).base64EncodedString())"/><keyEncryptors><keyEncryptor uri="http://schemas.microsoft.com/office/2006/keyEncryptor/password"><p:encryptedKey spinCount="\(spinCount)" saltSize="16" blockSize="16" keyBits="256" hashSize="\(hashSize)" cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" hashAlgorithm="\(name)" saltValue="\(Data(keySalt).base64EncodedString())" encryptedVerifierHashInput="\(Data(encryptedInput).base64EncodedString())" encryptedVerifierHashValue="\(Data(encryptedValue).base64EncodedString())" encryptedKeyValue="\(Data(encryptedKey).base64EncodedString())"/></keyEncryptor></keyEncryptors></encryption>
        """
        if xml.utf8.count + 8 < padInfoTo { xml += String(repeating: " ", count: padInfoTo - xml.utf8.count - 8) }
        let info = [4, 0, 4, 0, 0x40, 0, 0, 0] as [UInt8] + Array(xml.utf8)

        var body = [UInt8]()
        let plain = [UInt8](package)
        var offset = 0, index = 0
        while offset < plain.count {
            let end = min(offset + 4096, plain.count)
            let iv = Array((hash(name, dataSalt + le32(index)) + [UInt8](repeating: 0x36, count: 16)).prefix(16))
            body += aes(true, padded(Array(plain[offset..<end]), to: 16), key: dataKey, iv: iv)
            offset = end
            index += 1
        }
        if body.count + 8 < padPackageTo { body += [UInt8](repeating: 0, count: padPackageTo - body.count - 8) }
        return Made(info: info, package: le64(plain.count) + body)
    }

    /// Standard encryption (version 3.2), AES with `keyBits`, written as Office 2007 does.
    static func standard(package: Data, password: String, keyBits: Int) -> Made {
        let salt = random(16)
        var h = hash("SHA1", salt + utf16(password))
        for i in 0..<50_000 { h = hash("SHA1", le32(i) + h) }
        let final = hash("SHA1", h + le32(0))
        let block = final + [UInt8](repeating: 0, count: 44)
        let x1 = hash("SHA1", block.map { $0 ^ 0x36 })
        let x2 = hash("SHA1", block.map { $0 ^ 0x5c })
        let key = Array((x1 + x2).prefix(keyBits / 8))
        let verifier = random(16)
        let encryptedVerifier = aes(true, verifier, key: key, iv: nil)
        let encryptedHash = aes(true, padded(hash("SHA1", verifier), to: 16), key: key, iv: nil)
        let algorithm = [0x660E, 0x660F, 0x6610][[128, 192, 256].firstIndex(of: keyBits) ?? 0]
        let cspName = utf16("Microsoft Enhanced RSA and AES Cryptographic Provider") + [0, 0]
        // The header: flags, size extra, algorithm, hash algorithm, key size,
        // provider type, two reserved numbers, and the provider's name.
        let fields: [[UInt8]] = [le32(0x24), le32(0), le32(algorithm), le32(0x8004), le32(keyBits), le32(0x18), le32(0), le32(0)]
        let header: [UInt8] = fields.flatMap { $0 } + cspName
        var info: [UInt8] = [3, 0, 2, 0]
        info += le32(0x24)
        info += le32(header.count)
        info += header
        info += le32(16)
        info += salt
        info += encryptedVerifier
        info += le32(20)
        info += encryptedHash
        let plain = [UInt8](package)
        let body = aes(true, padded(plain, to: 16), key: key, iv: nil)
        return Made(info: info, package: le64(plain.count) + body)
    }
}

// MARK: - The Test-Only Compound File

/// Writes a compound file of root streams, each at least 4096 bytes so it
/// lives in regular sectors, with one FAT sector (so at most about 64 KB).
/// Test code only.
enum TestCompoundFileWriter {
    static func file(streams: [(String, Data)]) -> Data {
        let sector = 512
        let end: UInt32 = 0xFFFF_FFFE, free: UInt32 = 0xFFFF_FFFF
        // Sector 0: the FAT; 1: the directory; then each stream's sectors.
        var fat = [UInt32](repeating: free, count: 128)
        fat.replaceSubrange(0..<2, with: [0xFFFF_FFFD, end])
        var next = 2
        var starts: [Int] = []
        var body = Data()
        for (_, data) in streams {
            let count = (data.count + sector - 1) / sector
            starts.append(next)
            for i in 0..<count { fat[next + i] = i == count - 1 ? end : UInt32(next + i + 1) }
            body.append(data)
            body.append(Data(repeating: 0, count: count * sector - data.count))
            next += count
        }

        func le(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }) }
        func le16(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }

        var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        header += Data(count: 16)
        // Version 3 (minor 0x3E), little-endian, 512-byte and 64-byte sectors.
        for field in [le16(0x3E), le16(3), le16(0xFFFE), le16(9), le16(6), Data(count: 6)] { header += field }
        // Directory sectors, FAT sectors, first directory sector, transaction
        // number, mini stream cutoff, mini FAT (none), DIFAT (none).
        for number in [0, 1, 1, 0, 4096, end, 0, end, 0, 0] as [UInt32] { header += le(number) }
        for _ in 1..<109 { header += le(free) }

        func entry(name: String, type: UInt8, left: UInt32, right: UInt32, child: UInt32, start: UInt32, size: Int) -> Data {
            var e = Data()
            let units = Array(name.utf16)
            for unit in units { e += le16(unit) }
            e += Data(count: 64 - units.count * 2)
            e += le16(UInt16((units.count + 1) * 2))
            e += Data([type, 1])
            e += le(left) + le(right) + le(child)
            e += Data(count: 16 + 4 + 16)
            e += le(start) + le(UInt32(size)) + le(0)
            return e
        }
        var directory = entry(name: "Root Entry", type: 5, left: free, right: free, child: streams.isEmpty ? free : 1, start: end, size: 0)
        for (i, (name, data)) in streams.enumerated() {
            directory += entry(name: name, type: 2, left: free, right: i + 1 < streams.count ? UInt32(i + 2) : free, child: free, start: UInt32(starts[i]), size: data.count)
        }
        while directory.count < sector {
            directory += entry(name: "", type: 0, left: free, right: free, child: free, start: 0, size: 0)
        }

        var file = header
        file += fat.reduce(into: Data()) { $0 += le($1) }
        file += directory
        file += body
        return file
    }
}
