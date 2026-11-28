# rardecode as the source of TextMouth's RAR reader, November 26, 2026

Research for the RAR work planned for 0.7.0, not a build.
The user's question: does `github.com/nwaples/rardecode` (BSD) read RAR 3 to 5 encryption, and can its Go be rewritten in Swift?
Read: the repository at tag v2.4.6 (default branch `main`, head `f557bc9`, November 5, 2026), cloned as untrusted data and never built or run.
Labels: **(read)** is in the code, **(gh)** is from GitHub's or pkg.go.dev's public pages, **(recalled)** and **(estimate)** are not checked.
The earlier research is `research/PASSWORD-PROTECTED-BOOKS-2026-11-24.md`, its "7z and RAR" section and the follow-up.

## Answer in brief

- **Licence:** two-clause BSD for the whole repository, one `LICENSE` file, no vendored parts.
- **Provenance:** no sentence says it came from UnRAR, but the history cites unrar three times and its PPMd and filter design follow UnRAR's; treat it as written with UnRAR's source in view, not as a clean-room work.
- **Encryption:** RAR 3/4 (AES-128) and RAR 5 (AES-256), file data and headers, all read.
- **Gaps:** RAR 1.5 compression, RAR 5 BLAKE2sp checks, and a wrong-password signal for RAR 3/4.
- **Tests:** one test file in the whole history, and no archives.
- **Recommendation:** port it, choice B below (RAR 5 and RAR 3/4, the standard filters, no PPMd first), and prove it on a corpus from libarchive's and SharpCompress's public test archives.

## 1. Licence and provenance

- **`LICENSE`** is "Copyright (c) 2015, Nicholas Waples" and the BSD 2-clause text: keep the notice in source; reproduce it "in the documentation and/or other materials provided with the distribution" for binaries; the usual disclaimer **(read)**.
- GitHub reports `BSD-2-Clause` **(gh)**.
- No `.go` file has a licence header, there is no `vendor/` folder, and `go.mod` has no `require` line, so nothing else is bundled **(read)**.
- Authors in the history: Nicholas Waples 238 commits, and one each from Braxton Plaxco, ChrisJr404, and Hilko Bengen **(read, `git log`)**.
- Issue 2 (2015), "Please pick an applicable license", is closed **(gh)**.
- **Mentions of unrar, rarlab, or 7-Zip:**
  - `archive50.go:93`: `maxHeaderSize = 0x200000 // ...: https://www.rarlab.com/technote.htm`, so the public technote was used.
  - Commit `f091811`, January 22, 2016: "See unrar 5.3.2, unpack50.cpp:429" (an infinite loop in the ARM filter).
  - Commit `2534663`, January 6, 2017: volume-name logic "more in line with unrar".
  - Commit `e0e3c4a`, March 1, 2017: PPMd error cases "were mirroring unrar".
  - No mention of 7-Zip, and none in the README (3 lines).
- **What the code shows:** `ppm_model.go` has PPMd variant H's sub-allocator (`unitSize = 12`, `nIndexes` from `n0..n4`, `subAllocator`), and `filters.go:27-35` recognises RAR 3's six standard filter programs by the CRC of their code.
  The PPMd algorithm is Dmitry Shkarin's, which 7-Zip's `Ppmd7` also holds (recalled as public domain).
- **For a Swift port:** a port is a derived work of rardecode, so rardecode's notice must travel with it.
  That is a copy of `LICENSE` in the app's `Licenses/` folder and its text in the app's licence list, naming "rardecode, Nicholas Waples".
  The UnRAR licence forbids using UnRAR's source to re-create the RAR compression algorithm; rardecode carries no such licence and its author chose BSD, but if it was written by reading UnRAR's source I cannot prove the author's right to relicense that.
  I found no claim against it in 11 years, with 149 stars, 47 forks, and 104 importing modules **(gh)**; that is absence of evidence, not a ruling.
  This is a decision for the user: accept that residual risk, or have a lawyer read it.
- A port that reads the Go and writes Swift adds no new risk and removes none.

## 2. What it reads

| Item | Result | Where, and what refuses it |
|---|---|---|
| RAR 1.5 compression (unpack version 15) | **not** | `decode_reader.go:102` makes `invalidDecoder(decode15Ver)`; `ErrUnsupportedDecoder`; issue 66 (open) |
| RAR 2.0 and 2.6 (unpack 20, 26) | yes | `decode20*.go`, 437 lines; `archive15.go:372` |
| RAR 3 and 4 (unpack 29) | yes | `decode29*.go` |
| RAR 5.0 and 7.0 (decoder 70) | yes, one known bug | `decode50.go`; issue 75 (open, November 5): solid archives from WinRAR 7 fail with "invalid filter" |
| LZ and Huffman, all versions | yes | `huffman.go`, `decode20_lz.go`, `decode29_lz.go`, `decode50.go` |
| PPMd (RAR 3/4) | yes | `ppm_model.go`, `decode29_ppm.go`; issue 49 (open): "corrupt ppm data" on one RAR 4 file |
| RAR 3 filters E8, E8E9, Itanium, delta, RGB, audio | yes, native code | `filters.go:27-35`, matched by the CRC of the program |
| Other RAR 3 filter programs | yes, by a VM | `vm.go`, 686 lines, 25,000,000-command cap |
| RAR 5 filters delta, E8, E8E9, ARM | yes | `decode50.go:182-188`; any other is `ErrUnknownFilter` |
| Stored files | yes | `decodeNone`, no decoder |
| Solid archives | yes | `archive.go:88`; random `Open` of a solid file is refused (`ErrSolidOpen`, `reader.go:43`) |
| Multi-volume | yes | `volume.go` (532 lines), old (`.r00`) and new (`.part1.rar`) naming; a missing volume gives `ErrMultiVolume` |
| CRC32 | yes | `reader.go:603-640`, and header CRCs |
| BLAKE2sp | **no** | `archive50.go:475-476`: `case file5ExtraHash: // TODO: hash`; a file that has only that hash is not checked |
| Symlink and unix owner records | yes | `archive50.go:482-485` |
| Self-extracting files | yes | `bufio.go:11` looks 1 MB in for the signature |

## 3. Encryption

### RAR 3 and 4
- **Key and IV** (`archive15.go:111-136`): the password is UTF-16LE, 128 characters at most (`volume.go:94-99`); the 8-byte salt is appended; SHA-1 runs over password, salt, and three counter bytes for `hashRounds = 0x40000` (262,144) rounds.
- The IV takes one byte (`s[4*4+3]`) of the running digest every 16,384 rounds, 16 bytes in all; the key is the first 16 bytes of the final digest with each 4-byte word reversed.
- **Cipher:** AES-128-CBC (`decrypt_reader.go:150`); a file's salt is in its header (flag `0x0400`).
- **Encrypted headers:** each block header is preceded by an 8-byte salt and decrypted (`archive15.go:410-418`), so file names are hidden too.
- **A cache** of keys by salt avoids the 262,144 rounds for each file (`archive15.go:253`).

### RAR 5
- **KDF** (`archive50.go:157-197`): PBKDF2-HMAC-SHA256, hand-written; the salt is cut to 64 bytes, a block counter `00 00 00 01` is added, and it runs `2^count` iterations (the stored count is at most 24, `maxKdfCount`).
- It then runs 16 more rounds, and 16 more again, giving three outputs: key 0 (AES key), key 1 (checksum MAC key), key 2 (password check).
- **Password check value:** key 2's 32 bytes fold to 8 by XOR (`pwcheck[i&7] ^= v`), and 4 bytes of their SHA-256 are appended: 12 bytes, compared with the 12 in the header.
- **Cipher:** AES-256-CBC with the 16-byte IV from the header.
- **Checksums under encryption:** with the flag `UseMac`, the stored CRC32 is the HMAC-SHA256 of the real one under key 1, folded to 4 bytes (`reader.go:617-625`).
- **Encrypted headers:** an archive-encryption block (`block5Encrypt`, `archive50.go:510-546`) gives the key, and each later header has its own 16-byte IV and is decrypted, so file names are hidden.
- **Wrong password, RAR 5:** `ErrBadPassword` when the header carries the check value (`archive50.go:229-231`); without it the failure shows later as a CRC error.
- **Wrong password, RAR 3 and 4:** there is no check value.
  Issue 65 (open, September 25): with encrypted headers a wrong password is `ErrBadHeaderCRC` or `io.ErrUnexpectedEOF`, not told from damage; issue 4's and issue 2's reports show wrong bytes or "corrupt ppm data" for file data.
- **How a port would tell them apart:** RAR 5, by the check value; RAR 3/4, by the first decrypted header's CRC16 and the file's CRC32, with the message "wrong password or damaged archive" because the format cannot say which.

## 4. Quality

- **Tests:** one file in the whole history, `copybytes_offset_test.go` (28 lines, a crafted malformed RAR 5 stream); no `testdata/`, no archives, no encrypted test **(read, `git log --all`)**.
  The library is trusted through its users, not through a corpus of its own.
- **Issues:** GitHub counts 19 open **(gh)**.
  - Wrong output or refusal: 75, 66, 65, 49, 29 (open); 24 "Incorrect decompression" and 57 "failing checksum while 7Zip has no issue" (closed).
  - Crashes and hangs, fixed: 50 (CVE-2025-11579, out of memory), 51 and 53 (hang on non-RAR input), 36, 30, 27 (panics); open: 23 (crash in `decodeSymbol2`).
  - October 2026 fixes: file redirection and unix owner panics, a negative uvarint, an unknown decoder read as stored, a copy overflow in `copyBytes`.
- **Maintenance:** 241 commits from March 23, 2015 to November 5, 2026; latest tag v2.4.6 (November 5, 2026); one maintainer; tags v1.0.0 to v2.4.6; Go 1.21.
- **Users:** pkg.go.dev lists 104 importing modules and 38 packages for v2 **(gh)**, among them `mholt/archiver/v4` and `mholt/archives`, `jfrog/archiver/v3`, `hashicorp/go-extract`, `chezmoi`, `golift.io/xtractr`, `kitty`, `alist` and its forks, and `distribyted`.
  I did not see rclone in the list.

## 5. The port

Lines of Go at v2.4.6 **(read, `wc -l`)**:

| Part | Files | Go lines |
|---|---|---|
| Container, volumes, reader, I/O | `archive.go` 113, `bufio.go` 260, `reader.go` 790, `volume.go` 532, `fs.go` 406 | 2,101 (about 1,000 needed; `fs.go` and part of `volume.go` are conveniences) |
| RAR 3/4 headers | `archive15.go` | 523 |
| RAR 5 headers | `archive50.go` | 682 (about 150 are time, owner, redirect records) |
| Crypto | `decrypt_reader.go` 164, about 30 in `archive15.go`, about 45 in `archive50.go` | about 240 |
| Shared decode core | `decode_reader.go` 388, `huffman.go` 206, `bit_reader.go` 173 | 767 |
| RAR 5 decoder | `decode50.go` | 313 |
| RAR 3/4 LZ | `decode29.go` 272, `decode29_lz.go` 263 | 535 |
| RAR 2.x | `decode20*.go` | 437 |
| PPMd | `ppm_model.go` 1,053, `decode29_ppm.go` 140 | 1,193 |
| Filters | `filters.go` | 419 (about 300 for the six standard ones and ARM) |
| VM | `vm.go` | 686 |
| Checksums | CRC32 in `reader.go`; no BLAKE2sp | 0 |

- **Apple already gives:** CommonCrypto has AES-CBC (`CCCrypt`), SHA-1, SHA-256, HMAC, and `CCKeyDerivationPBKDF` (PBKDF2 with HMAC-SHA256); CryptoKit has no AES-CBC and no PBKDF2 (recalled, check before use).
  `zlib`'s `crc32` is in the SDK (recalled).
  Not given: BLAKE2sp (about 150 lines) and RAR 3's loop, which is one SHA-1 context fed 262,144 times (a loop of `CC_SHA1_Update`, no library call).
  RAR 5's extra 16 and 16 rounds continue the PBKDF2 chain, so they need the loop, not the library call.
- **Swift lines**, taking a Go line as about a Swift line (estimate):

| Choice | Lines | Size per app | Work |
|---|---|---|---|
| A. RAR 5 only | about 1,800 (container 600, headers 450, core 450, decoder 300) | 55 to 110 KB | 3 to 5 agent-days with tests |
| B. RAR 3/4 and 5, standard filters, no PPMd | about 3,100 (A + headers 400, LZ 535, RGB, audio, Itanium 170) | 95 to 185 KB | 6 to 9 agent-days |
| C. B with PPMd and the VM | about 5,000 (B + PPMd 1,200 + VM 690) | 150 to 300 KB | 10 to 15 agent-days |

- **Size basis:** 31 to 60 bytes per line, the ratio of the earlier research's table (450 lines for 14 to 27 KB); not measured on a build.
- **B's gap:** a RAR 3 archive using a filter program outside the six, or compressed with PPMd (WinRAR's "best" method and `-mc` options), is refused with a clear message.
  How common that is in real comic and book archives is unknown; the corpus and the user's own archives answer it.
- RAR 1.5 and 2.x: skip, as the earlier research did (+437 lines for 2.x, and a new decoder for 1.5).
- The apps are 18.2 and 14.0 MB (memory of November 23) against a 30 MB limit (40 strict), so any choice fits.

## 6. Against the other choices

| | Port of rardecode | libarchive's RAR readers | No RAR |
|---|---|---|---|
| Licence | BSD-2; the provenance question in section 1 | BSD-2 (Kientzle, Mejia, Antoniak; earlier research) | none |
| Size per app | 55 to 300 KB | 165 to 280 KB (earlier research) | 0 |
| Encrypted RAR 3/4 and 5 | **yes**, headers and files | **no**: "Encryption is not supported" (earlier research, read) | no |
| Risk of wrong output | its own: one test file, 19 open issues; mitigated by CRC32 and the corpus | better tested; but it cannot decrypt | none |
| Work | 3 to 15 agent-days | wire a C library into two targets, and still write decryption | 0 |

- **Recommendation: the port, B first, then C** if the corpus or the user's archives show PPMd or an unknown filter program.
  It is the only choice that opens an encrypted .cbr or RAR book, it is smaller than libarchive, and it adds no C to the apps.
- "libarchive plus our own decryption" is a rewrite of libarchive's reader, since it parses the archive structure itself.
- If the user will not accept the provenance risk, the fallback is no RAR; I know of no third licence-clean route.

## What I would prove first

- **A corpus, without the RAR tool** (`rar` is proprietary and `unrar` is under the UnRAR licence, so neither makes fixtures here):
  - libarchive's test files (BSD) `test_read_format_rar4_encrypted.rar.uu`, `..._rar4_encrypted_filenames.rar.uu`, `..._rar4_solid_encrypted*.rar.uu`, `..._rar5_encrypted.rar.uu`, `..._rar5_encrypted_filenames.rar.uu`, `..._rar5_blake2.rar.uu`, and the RAR 5 ARM, solid, and window-size ones **(gh, file names read)**; the passwords are in their `.c` tests (to read).
  - SharpCompress's `tests/TestArchives/Archives` (MIT **(gh)**): `Rar.Encrypted.rar`, `Rar.encrypted_filesAndHeader.rar`, `Rar.encrypted_filesOnly.rar`, `Rar.EncryptedParts.part01..06.rar`, `Rar2.rar`, `Rar4.rar`, `Rar.solid.rar`, `Rar.multi.*` **(gh, file names read)**.
  - The user's own RAR archives, in a read-only run that counts and times and writes nothing.
- **First experiments, in order:**
  1. The Swift RAR 5 key derivation against the check value in `..._rar5_encrypted.rar`: the right password passes, a wrong one fails.
  2. The RAR 3 key loop on `Rar.encrypted_filesOnly.rar`: decrypt, then match the file's CRC32.
  3. Every decoder's output against the CRC32 and sizes in each corpus archive, solid and multi-volume included.
  4. The Go rardecode as an oracle on the same corpus, in GitHub Actions only: the same bytes, and the same errors on wrong passwords.
  5. Truncation and bit-flip tests: a flipped byte is a clean error, never a crash, hang, or memory growth, with a memory cap, since several of rardecode's own fixes were of this kind.
- **A book's risk:** a wrong decode that still passes CRC32 is about 2^-32; the check must be on, and a file that fails it must refuse, never show partial text.

## Questions for the user

- Does the user accept rardecode's provenance (BSD-licensed by its author, written with UnRAR's source in view) for a port shipped under TextMouth's licences?
- Choice A, B, or C for 0.7.0, and does RAR 3/4 (most .cbr comics) matter more than RAR 5?
- Is "wrong password or damaged archive" acceptable for RAR 3/4, since the format has no check value?
