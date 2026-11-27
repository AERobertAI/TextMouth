import CommonCrypto
import CryptoKit
import Foundation

// MARK: - Opening a Password-Protected Office Open XML File

/// Decrypts the Office Open XML files (DOCX and its kinds) that Word saved
/// with a password (FR41, phase 2). Such a file is not a ZIP archive but a
/// compound file whose root holds two streams, `EncryptionInfo` and
/// `EncryptedPackage` ([MS-OFFCRYPTO]); decrypting the second gives the
/// ordinary .docx, which every reader of Office files then reads as it is.
///
/// Both schemes Word writes are read:
/// - **Standard encryption** (versions 2, 3, and 4 with minor version 2:
///   Office 2007): AES in ECB mode, a key made by 50,000 rounds of SHA-1.
/// - **Agile encryption** (version 4.4: Office 2010 on): an XML descriptor,
///   AES in CBC mode, a key made by `spinCount` rounds of the descriptor's
///   hash, the data in 4096-byte segments each with its own IV.
///
/// The steps follow the public specification, [MS-OFFCRYPTO] sections 2.3.4
/// (the two `EncryptionInfo` forms), 2.3.4.7 (Standard's key), 2.3.4.11
/// (Agile's data), and 2.3.4.13 (Agile's key). An outside provider's
/// "Extensible" encryption (version 3.3 or 4.3) is refused, and so is any
/// cipher but AES.
enum OfficeCryptoDecryptor {

    /// Why a file could not be decrypted.
    enum Failure: Error, Equatable {
        /// No encoding of the password opens it.
        case wrongPassword
        /// A scheme this reader does not open.
        case unsupported
        /// The file's bytes do not hold together.
        case damaged
    }

    /// The names of the two streams of an encrypted package.
    static let infoStream = "EncryptionInfo"
    static let packageStream = "EncryptedPackage"

    // MARK: Entry Points

    /// Whether `data` is a compound file that holds an encrypted package.
    static func isEncryptedPackage(_ data: Data) -> Bool {
        guard CompoundFile.hasSignature(data), let file = try? CompoundFile(data) else { return false }
        return ((try? file.stream(named: infoStream)) ?? nil) != nil
            && ((try? file.stream(named: packageStream)) ?? nil) != nil
    }

    /// The plain package (the .docx) held by the compound file `data`.
    /// - Throws: `Failure`.
    static func decrypt(_ data: Data, password: Secret) throws -> Data {
        guard let file = try? CompoundFile(data),
              let info = (try? file.stream(named: infoStream)) ?? nil,
              let package = (try? file.stream(named: packageStream)) ?? nil else { throw Failure.damaged }
        return try decrypt(info: [UInt8](info), package: [UInt8](package), password: password)
    }

    /// The plain package held by `package` (the `EncryptedPackage` stream),
    /// described by `info` (the `EncryptionInfo` stream).
    static func decrypt(info: [UInt8], package: [UInt8], password: Secret) throws -> Data {
        guard info.count >= 8, package.count >= 8 else { throw Failure.damaged }
        let major = info.u16(0)
        let minor = info.u16(2)
        let size = Int(clamping: package.u64(0))
        let encrypted = Array(package[8...])
        let candidates = PasswordEncoding.candidates(for: password, scheme: .utf16LittleEndian)
        switch (major, minor) {
        case (4, 4):
            return try decryptAgile(info: info, encrypted: encrypted, size: size, passwords: candidates)
        case (2, 2), (3, 2), (4, 2):
            return try decryptStandard(info: info, encrypted: encrypted, size: size, passwords: candidates)
        default:
            // Extensible encryption (3.3, 4.3), or a version not known.
            throw Failure.unsupported
        }
    }

    // MARK: Hashes and Ciphers

    /// A hash the schemes name.
    private enum HashKind: String {
        case sha1 = "SHA1", sha256 = "SHA256", sha384 = "SHA384", sha512 = "SHA512"

        /// `data` hashed.
        func digest(_ data: [UInt8]) -> [UInt8] {
            switch self {
            case .sha1: return Array(Insecure.SHA1.hash(data: data))
            case .sha256: return Array(SHA256.hash(data: data))
            case .sha384: return Array(SHA384.hash(data: data))
            case .sha512: return Array(SHA512.hash(data: data))
            }
        }
    }

    /// `bytes` of AES-`mode` decrypted with `key`, with `iv` for CBC. No padding: the
    /// input is a whole number of blocks.
    private static func aesDecrypt(_ bytes: [UInt8], key: [UInt8], iv: [UInt8]?, ecb: Bool) throws -> [UInt8] {
        guard [16, 24, 32].contains(key.count), bytes.count % 16 == 0 else { throw Failure.damaged }
        var output = [UInt8](repeating: 0, count: bytes.count + kCCBlockSizeAES128)
        var produced = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(ecb ? kCCOptionECBMode : 0),
            key, key.count, ecb ? nil : iv, bytes, bytes.count, &output, output.count, &produced
        )
        guard status == kCCSuccess else { throw Failure.damaged }
        return Array(output[0..<produced])
    }

    /// `bytes` made `length` long: cut, or padded with `fill`.
    private static func fitted(_ bytes: [UInt8], to length: Int, fill: UInt8 = 0x36) -> [UInt8] {
        bytes.count >= length ? Array(bytes[0..<length]) : bytes + [UInt8](repeating: fill, count: length - bytes.count)
    }

    /// `value` as four little-endian bytes.
    private static func le32(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    // MARK: Agile

    /// The key sizes AES takes, in bits.
    private static let aesKeyBits: Set<Int> = [128, 192, 256]

    /// What the Agile descriptor says, from its XML attributes.
    private struct AgileDescriptor {
        /// The data's own parameters (the `keyData` element), the data key's size among them.
        var dataSalt: [UInt8]
        var dataBlockSize: Int
        var dataHash: HashKind
        var dataKeyBits: Int
        /// The password key encryptor's parameters (the `encryptedKey` element).
        var salt: [UInt8]
        var spinCount: Int
        var keyBits: Int
        var blockSize: Int
        var hash: HashKind
        var verifierInput: [UInt8]
        var verifierValue: [UInt8]
        var encryptedKey: [UInt8]
    }

    /// Reads the descriptor out of the stream's XML.
    private static func parseAgile(_ info: [UInt8]) throws -> AgileDescriptor {
        guard info.count > 8 else { throw Failure.damaged }
        let collector = AttributeCollector()
        let parser = XMLParser(data: Data(info[8...]))
        parser.delegate = collector
        // No external entities: the descriptor is untrusted.
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw Failure.damaged }
        guard let data = collector.elements["keyData"], let key = collector.elements["encryptedKey"] else { throw Failure.damaged }
        func bytes(_ element: [String: String], _ name: String) throws -> [UInt8] {
            guard let text = element[name], let decoded = Data(base64Encoded: text) else { throw Failure.damaged }
            return [UInt8](decoded)
        }
        func number(_ element: [String: String], _ name: String) throws -> Int {
            guard let text = element[name], let value = Int(text), value >= 0 else { throw Failure.damaged }
            return value
        }
        for element in [data, key] {
            // Only AES in CBC mode is read.
            guard element["cipherAlgorithm"] == "AES", element["cipherChaining"] == "ChainingModeCBC" else { throw Failure.unsupported }
        }
        guard let dataHash = HashKind(rawValue: data["hashAlgorithm"] ?? ""), let hash = HashKind(rawValue: key["hashAlgorithm"] ?? "") else {
            throw Failure.unsupported
        }
        let spin = try number(key, "spinCount")
        // The specification allows up to 10,000,000 rounds; more is a hostile file.
        guard spin <= 10_000_000, try number(key, "blockSize") == 16, try number(data, "blockSize") == 16 else { throw Failure.unsupported }
        // AES keys are 128, 192, or 256 bits. Any other size is refused here,
        // before a key is made: the key is cut or padded to the size named
        // (`fitted`), so a hostile size would ask for a buffer that large.
        let keyBits = try number(key, "keyBits")
        let dataKeyBits = try number(data, "keyBits")
        guard Self.aesKeyBits.contains(keyBits), Self.aesKeyBits.contains(dataKeyBits) else { throw Failure.unsupported }
        return AgileDescriptor(
            dataSalt: try bytes(data, "saltValue"), dataBlockSize: 16, dataHash: dataHash, dataKeyBits: dataKeyBits,
            salt: try bytes(key, "saltValue"), spinCount: spin, keyBits: keyBits, blockSize: 16, hash: hash,
            verifierInput: try bytes(key, "encryptedVerifierHashInput"),
            verifierValue: try bytes(key, "encryptedVerifierHashValue"),
            encryptedKey: try bytes(key, "encryptedKeyValue")
        )
    }

    /// The hash chain Agile makes from `password`: the salt and password
    /// hashed, then `spinCount` rounds. It is the costly part (up to
    /// 10,000,000 rounds) and is the same for every purpose, so it is made
    /// once per password and each block key finishes it.
    private static func agileBase(_ password: [UInt8], _ d: AgileDescriptor) -> [UInt8] {
        var hash = d.hash.digest(d.salt + password)
        for round in 0..<d.spinCount { hash = d.hash.digest(le32(round) + hash) }
        return hash
    }

    /// The key Agile makes from the chain `base` for the purpose `blockKey` names.
    private static func agileKey(_ base: [UInt8], _ d: AgileDescriptor, blockKey: [UInt8]) -> [UInt8] {
        fitted(d.hash.digest(base + blockKey), to: d.keyBits / 8)
    }

    /// The three block keys that make the verifier's and the data key's keys.
    private static let verifierInputBlockKey: [UInt8] = [0xfe, 0xa7, 0xd2, 0x76, 0x3b, 0x4b, 0x9e, 0x79]
    private static let verifierValueBlockKey: [UInt8] = [0xd7, 0xaa, 0x0f, 0x6d, 0x30, 0x61, 0x34, 0x4e]
    private static let keyValueBlockKey: [UInt8] = [0x14, 0x6e, 0x0b, 0xe7, 0xab, 0xac, 0xd0, 0xd6]

    /// Agile decryption: the password is checked through the verifier, the
    /// data key is unwrapped, and each 4096-byte segment is decrypted.
    private static func decryptAgile(info: [UInt8], encrypted: [UInt8], size: Int, passwords: [[UInt8]]) throws -> Data {
        let d = try parseAgile(info)
        let iv = fitted(d.salt, to: 16)
        for password in passwords {
            let base = agileBase(password, d)
            let input = try aesDecrypt(d.verifierInput, key: agileKey(base, d, blockKey: verifierInputBlockKey), iv: iv, ecb: false)
            let value = try aesDecrypt(d.verifierValue, key: agileKey(base, d, blockKey: verifierValueBlockKey), iv: iv, ecb: false)
            let expected = d.hash.digest(Array(input.prefix(d.salt.count)))
            guard value.count >= expected.count, Array(value.prefix(expected.count)) == expected else { continue }
            // The data key is as long as the data's own key size says.
            let dataKey = Array(try aesDecrypt(d.encryptedKey, key: agileKey(base, d, blockKey: keyValueBlockKey), iv: iv, ecb: false).prefix(d.dataKeyBits / 8))
            return try decryptSegments(encrypted, size: size, key: dataKey, descriptor: d)
        }
        throw Failure.wrongPassword
    }

    /// The package's bytes, 4096 at a time, each with the IV its number makes.
    private static func decryptSegments(_ encrypted: [UInt8], size: Int, key: [UInt8], descriptor d: AgileDescriptor) throws -> Data {
        guard size <= encrypted.count else { throw Failure.damaged }
        var output = [UInt8]()
        output.reserveCapacity(encrypted.count)
        var index = 0
        var offset = 0
        while offset < encrypted.count {
            // A last segment may end short of a block: its bytes are padded to one.
            let end = min(offset + 4096, encrypted.count)
            var segment = Array(encrypted[offset..<end])
            if segment.count % 16 != 0 { segment += [UInt8](repeating: 0, count: 16 - segment.count % 16) }
            let segmentIV = fitted(d.dataHash.digest(d.dataSalt + le32(index)), to: 16)
            output += try aesDecrypt(segment, key: key, iv: segmentIV, ecb: false)
            offset = end
            index += 1
        }
        return Data(output.prefix(size))
    }

    // MARK: Standard

    /// Standard decryption: the key is the verifier-checked SHA-1 derivation, the data AES-ECB.
    private static func decryptStandard(info: [UInt8], encrypted: [UInt8], size: Int, passwords: [[UInt8]]) throws -> Data {
        // flags (4), header size (4), then the header and the verifier.
        guard info.count >= 12 else { throw Failure.damaged }
        let flags = info.u32(4)
        // Bit 0x20 says AES; a file without it uses another cipher.
        guard flags & 0x20 != 0 else { throw Failure.unsupported }
        let headerSize = Int(info.u32(8))
        guard headerSize >= 32, 12 + headerSize + 4 + 16 + 16 + 4 + 32 <= info.count else { throw Failure.damaged }
        let algorithm = info.u32(12 + 8)
        let keyBits = Int(info.u32(12 + 16))
        guard [0x660E, 0x660F, 0x6610].contains(Int(algorithm)), [128, 192, 256].contains(keyBits) else { throw Failure.unsupported }
        let verifier = 12 + headerSize
        let saltSize = Int(info.u32(verifier))
        guard saltSize == 16 else { throw Failure.damaged }
        let salt = Array(info[(verifier + 4)..<(verifier + 20)])
        let encryptedVerifier = Array(info[(verifier + 20)..<(verifier + 36)])
        let hashSize = Int(info.u32(verifier + 36))
        guard hashSize == 20 else { throw Failure.damaged }
        let encryptedHash = Array(info[(verifier + 40)..<(verifier + 72)])
        for password in passwords {
            let key = standardKey(password, salt: salt, keyBits: keyBits)
            let plainVerifier = try aesDecrypt(encryptedVerifier, key: key, iv: nil, ecb: true)
            let plainHash = try aesDecrypt(encryptedHash, key: key, iv: nil, ecb: true)
            guard Array(plainHash.prefix(20)) == HashKind.sha1.digest(plainVerifier) else { continue }
            guard size <= encrypted.count else { throw Failure.damaged }
            let whole = encrypted.count - encrypted.count % 16
            return Data(try aesDecrypt(Array(encrypted[0..<whole]), key: key, iv: nil, ecb: true).prefix(size))
        }
        throw Failure.wrongPassword
    }

    /// Standard's key: 50,000 rounds of SHA-1, then the two-half expansion of 2.3.4.7.
    private static func standardKey(_ password: [UInt8], salt: [UInt8], keyBits: Int) -> [UInt8] {
        var hash = HashKind.sha1.digest(salt + password)
        for round in 0..<50_000 { hash = HashKind.sha1.digest(le32(round) + hash) }
        let final = HashKind.sha1.digest(hash + le32(0))
        let padded = fitted(final, to: 64, fill: 0)
        let first = HashKind.sha1.digest(zip([UInt8](repeating: 0x36, count: 64), padded).map { $0 ^ $1 })
        let second = HashKind.sha1.digest(zip([UInt8](repeating: 0x5c, count: 64), padded).map { $0 ^ $1 })
        return Array((first + second).prefix(keyBits / 8))
    }
}

// MARK: - Reading the Descriptor's XML

/// Collects the attributes of each element of an XML document by its local
/// name (a namespace prefix such as "p:" is dropped), for the descriptor's
/// two elements that matter.
private final class AttributeCollector: NSObject, XMLParserDelegate {
    /// The attributes of the last element met for each local name.
    var elements: [String: [String: String]] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        elements[local] = attributeDict
    }
}
