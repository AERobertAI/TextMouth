import Foundation

func runMD5Tests() {
print("\n--- MD5 Hash Tests ---")

test("MD5 hash produces consistent 32-char hex string") {
    let url = try requireFile("alice.epub")
    let hash = try md5Hash(of: url)
    try assertEqual(hash.count, 32, "MD5 should be 32 hex chars")
    try assertTrue(hash.allSatisfy { $0.isHexDigit }, "Should be hex only")
    print("    alice.epub MD5: \(hash)")
}

test("MD5 hash is deterministic") {
    let url = try requireFile("alice.epub")
    let hash1 = try md5Hash(of: url)
    let hash2 = try md5Hash(of: url)
    try assertEqual(hash1, hash2, "Hashes should match")
}

test("Different files produce different hashes") {
    let url1 = try requireFile("alice.epub")
    let url2 = try requireFile("pride.txt")
    let hash1 = try md5Hash(of: url1)
    let hash2 = try md5Hash(of: url2)
    try assertTrue(hash1 != hash2, "Different files should have different hashes")
    print("    alice.epub: \(hash1)")
    print("    pride.txt:  \(hash2)")
}

// MD5 Hash Edge Cases
print("\n--- MD5 Hash Edge Cases ---")

test("MD5 hash of small file") {
    let url = try requireFile("sample.md")
    let hash = try md5Hash(of: url)
    try assertEqual(hash.count, 32, "Should be 32 hex chars")
    try assertTrue(hash.allSatisfy { $0.isHexDigit })
    print("    sample.md MD5: \(hash)")
}

test("MD5 hash of text file matches across reads") {
    let url = try requireFile("pride.txt")
    let h1 = try md5Hash(of: url)
    let h2 = try md5Hash(of: url)
    try assertEqual(h1, h2, "Same file should produce same hash every time")
}

} // end runMD5Tests
