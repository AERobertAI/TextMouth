#if os(macOS)
import XCTest
import ZIPFoundation
@testable import TextMouth

/// A password-protected ZIP is made plain in memory (FR41, phase 1). The
/// fixtures come from the tools macOS ships, which are independent of
/// TextMouth's own reading: `zip -P` writes ZipCrypto, and `bsdtar` writes
/// WinZip AES in 128 and 256 bits. Each test makes its archives in its own
/// folder, and a missing tool skips the test.
final class ZipDecryptorTests: XCTestCase {

    /// The folder this test's files are made in.
    private var folder = FileManager.default.temporaryDirectory

    /// Text long enough that `zip` deflates it.
    private let longText = String(repeating: "lorem ipsum dolor sit amet ", count: 9000) + "END"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ZipDecryptorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src/d"), withIntermediateDirectories: true)
        try "short words".write(to: folder.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try longText.write(to: folder.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
        try "inner words".write(to: folder.appendingPathComponent("src/d/c.txt"), atomically: true, encoding: .utf8)
    }

    /// Runs `tool` with `arguments` in the sources folder; skips the test when it cannot run.
    private func run(_ tool: String, _ arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("\(tool) is not here") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder.appendingPathComponent("src")
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw XCTSkip("\(tool) could not make the fixture") }
    }

    /// A ZipCrypto archive of the sources, written by `zip`.
    private func zipCryptoArchive(password: String) throws -> URL {
        let url = folder.appendingPathComponent("crypto.zip")
        try run("/usr/bin/zip", ["-q", "-r", "-P", password, url.path, "a.txt", "b.txt", "d"])
        return url
    }

    /// A WinZip AES archive of the sources, written by `bsdtar`.
    private func aesArchive(password: String, strength: String) throws -> URL {
        let url = folder.appendingPathComponent("aes-\(strength).zip")
        try run("/usr/bin/bsdtar", ["-a", "-cf", url.path, "--options", "zip:encryption=\(strength)", "--passphrase", password, "a.txt", "b.txt", "d"])
        return url
    }

    /// The files of the plain archive `data`, by path, with their bytes.
    private func files(of data: Data) throws -> [String: String] {
        let archive = try Archive(data: data, accessMode: .read)
        var found: [String: String] = [:]
        for entry in archive where entry.type == .file {
            var bytes = Data()
            // Checked against the checksum the plain archive records.
            _ = try archive.extract(entry, skipCRC32: false) { bytes.append($0) }
            found[entry.path] = String(decoding: bytes, as: UTF8.self)
        }
        return found
    }

    /// The files every fixture holds.
    private var expectedFiles: [String: String] {
        ["a.txt": "short words", "b.txt": longText, "d/c.txt": "inner words"]
    }

    // MARK: - The Schemes

    /// ZipCrypto: every file comes out plain, stored and deflated alike.
    func testZipCryptoIsMadePlain() throws {
        let url = try zipCryptoArchive(password: "secret")
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: url).sorted(), ["a.txt", "b.txt", "d/c.txt"])
        let plain = try ZipDecryptor.decrypt(archiveAt: url, password: Secret("secret"))
        XCTAssertEqual(try files(of: plain), expectedFiles)
    }

    /// WinZip AES at 128 and 256 bits, whose checksums are made again.
    func testWinZipAESIsMadePlain() throws {
        for strength in ["aes128", "aes256"] {
            let url = try aesArchive(password: "secret", strength: strength)
            let plain = try ZipDecryptor.decrypt(archiveAt: url, password: Secret("secret"))
            XCTAssertEqual(try files(of: plain), expectedFiles, strength)
        }
    }

    /// The plain archive holds no encrypted entry, so every reader takes it as it is.
    func testThePlainArchiveHoldsNothingEncrypted() throws {
        let url = try aesArchive(password: "secret", strength: "aes256")
        let plain = try ZipDecryptor.decrypt(archiveAt: url, password: Secret("secret"))
        let copy = folder.appendingPathComponent("plain.zip")
        try plain.write(to: copy)
        XCTAssertEqual(EncryptedArchiveGuard.encryptedNames(inFileAt: copy), [])
        XCTAssertEqual(ZipCentralDirectory.records(ofFileAt: copy)?.map(\.name).sorted(), ["a.txt", "b.txt", "d/", "d/c.txt"])
    }

    // MARK: - The Wrong Password

    /// A wrong password is named as such, for each scheme.
    func testAWrongPasswordIsRefused() throws {
        let crypto = try zipCryptoArchive(password: "secret")
        let aes = try aesArchive(password: "secret", strength: "aes256")
        for url in [crypto, aes] {
            XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: url, password: Secret("Secret"))) {
                XCTAssertEqual($0 as? ZipDecryptor.Failure, .wrongPassword, url.lastPathComponent)
            }
            XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: url, password: Secret(""))) {
                XCTAssertEqual($0 as? ZipDecryptor.Failure, .wrongPassword, url.lastPathComponent)
            }
        }
    }

    /// An accent typed decomposed opens a file whose writer composed it, and the reverse.
    func testAnAccentedPasswordOpensInEitherForm() throws {
        let composed = "p\u{E4}ssw\u{F6}rd"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        for url in [try zipCryptoArchive(password: composed), try aesArchive(password: composed, strength: "aes256")] {
            let plain = try ZipDecryptor.decrypt(archiveAt: url, password: Secret(decomposed))
            XCTAssertEqual(try files(of: plain), expectedFiles, url.lastPathComponent)
        }
    }

    /// A ZipCrypto entry whose method cannot be inflated here (bzip2) has only the one-byte check, which a wrong
    /// password passes one time in 256: it is refused in words of its own, for any password.
    func testZipCryptoWithAMethodThatCannotBeCheckedIsRefused() throws {
        let url = folder.appendingPathComponent("bzip.zip")
        try run("/usr/bin/zip", ["-q", "-Z", "bzip2", "-P", "secret", url.path, "b.txt"])
        for typed in ["secret", "wrong"] {
            XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: url, password: Secret(typed)), typed) {
                XCTAssertEqual($0 as? ZipDecryptor.Failure, .unsupported, typed)
            }
        }
    }

    // MARK: - Damage

    /// A flipped byte of AES ciphertext fails its authentication after the password's own check passed:
    /// that is damage, never "wrong password". A flipped byte of the salt is a different key, so a wrong password.
    func testAFlippedByteInAESDataIsDamageNotAWrongPassword() throws {
        let url = try aesArchive(password: "secret", strength: "aes256")
        let original = [UInt8](try Data(contentsOf: url))
        // The first entry's data starts after its 30-byte header, name, and extra field:
        // a 16-byte salt, a 2-byte check, and then the ciphertext.
        let dataStart = 30 + Int(original.u16(26)) + Int(original.u16(28))
        var ciphertext = original
        ciphertext[dataStart + 16 + 2 + 1] ^= 0xFF
        let damaged = folder.appendingPathComponent("damaged.zip")
        try Data(ciphertext).write(to: damaged)
        XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: damaged, password: Secret("secret"))) {
            XCTAssertEqual($0 as? ZipDecryptor.Failure, .damaged)
        }
        var salt = original
        salt[dataStart + 3] ^= 0xFF
        let resalted = folder.appendingPathComponent("resalted.zip")
        try Data(salt).write(to: resalted)
        XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: resalted, password: Secret("secret"))) {
            XCTAssertEqual($0 as? ZipDecryptor.Failure, .wrongPassword)
        }
    }

    // MARK: - Hostile archives

    /// A record with the given name, offset, and sizes, for archives no tool would write.
    private func record(_ name: String, offset: UInt64 = 0, compressed: UInt64 = 10, uncompressed: UInt64 = 10) -> ZipDirectoryRecord {
        ZipDirectoryRecord(
            name: name, versionMadeBy: 20, modTime: 0, modDate: 0, externalAttributes: 0, flags: 1, method: 0, checksum: 0,
            compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: offset, extra: Data()
        )
    }

    /// Too many entries, too large an entry or total, a name too long to write, and overlapping
    /// entries are each refused with an error before anything is decrypted, never a trap or a hang.
    func testHostileArchivesAreRefusedBeforeAnythingIsDecrypted() {
        let secret = Secret("x")
        func refused(_ records: [ZipDirectoryRecord], _ expected: ZipDecryptor.Failure, _ label: String) {
            XCTAssertThrowsError(try ZipDecryptor.decrypt(archive: Data(), records: records, password: secret), label) {
                XCTAssertEqual($0 as? ZipDecryptor.Failure, expected, label)
            }
        }
        refused((0..<10_001).map { record("f\($0).txt", offset: UInt64($0) * 100) }, .unsupported, "too many entries")
        refused([record("big.txt", uncompressed: 65_000_000)], .unsupported, "an entry over the document limit")
        refused([record("a.txt", uncompressed: 60_000_000), record("b.txt", offset: 100, uncompressed: 60_000_000),
                 record("c.txt", offset: 200, uncompressed: 60_000_000), record("d.txt", offset: 300, uncompressed: 60_000_000),
                 record("e.txt", offset: 400, uncompressed: 60_000_000), record("f.txt", offset: 500, uncompressed: 60_000_000),
                 record("g.txt", offset: 600, uncompressed: 60_000_000), record("h.txt", offset: 700, uncompressed: 60_000_000),
                 record("i.txt", offset: 800, uncompressed: 60_000_000)], .unsupported, "a total over the budget")
        refused([record(String(repeating: "n", count: 65_536))], .unsupported, "a name past 65,535 bytes")
        refused([record("a.txt", offset: 0, compressed: 1_000), record("b.txt", offset: 500)], .damaged, "overlapping entries")
        refused([record("a.txt", offset: 0), record("b.txt", offset: 0)], .damaged, "two entries at one place")
    }

    /// A plain archive passes through unchanged in content.
    func testAnArchiveWithoutEncryptionIsCopiedAsItIs() throws {
        let made = try makeTemporaryZip(prefix: "plain", entries: ["a.txt": Data("short words".utf8)], compressionMethod: .deflate)
        defer { try? FileManager.default.removeItem(at: made) }
        let plain = try ZipDecryptor.decrypt(archiveAt: made, password: Secret("anything"))
        XCTAssertEqual(try files(of: plain), ["a.txt": "short words"])
    }

    /// A file that is no archive is damage.
    func testANonArchiveIsDamage() throws {
        let url = folder.appendingPathComponent("not.zip")
        try Data("plain words".utf8).write(to: url)
        XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: url, password: Secret("x"))) {
            XCTAssertEqual($0 as? ZipDecryptor.Failure, .damaged)
        }
    }

    /// Strong encryption (flag bit 6) is refused in its own words, not as a wrong password.
    func testStrongEncryptionIsUnsupported() throws {
        let url = try zipCryptoArchive(password: "secret")
        let strong = folder.appendingPathComponent("strong.zip")
        var bytes = [UInt8](try Data(contentsOf: url))
        // Set bit 6 in the first central header's flags.
        let central = try XCTUnwrap(ZipCentralDirectoryTestLookup.firstCentralHeader(in: bytes))
        bytes[central + 8] |= 0x40
        try Data(bytes).write(to: strong)
        XCTAssertThrowsError(try ZipDecryptor.decrypt(archiveAt: strong, password: Secret("secret"))) {
            XCTAssertEqual($0 as? ZipDecryptor.Failure, .unsupported)
        }
    }
}

/// Finds a central directory header in test bytes, without TextMouth's own reader.
enum ZipCentralDirectoryTestLookup {
    /// The offset of the first "PK\1\2" header in `bytes`, or nil.
    static func firstCentralHeader(in bytes: [UInt8]) -> Int? {
        (0..<max(0, bytes.count - 4)).first { bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x01 && bytes[$0 + 3] == 0x02 }
    }
}
#endif
