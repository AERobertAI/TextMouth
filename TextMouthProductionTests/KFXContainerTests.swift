import XCTest
@testable import TextMouth

/// The KFX container and its symbols (FMT52, layer 2): containers built by
/// hand, the real one Amazon's conversion made (`kfx/alice.kfx`), and then
/// hostile ones, each with an offset, length, or count pointed wrong.
final class KFXContainerTests: XCTestCase {

    // MARK: - Helpers

    /// A small container: two local symbols, a section, a content fragment,
    /// and a raw resource.
    private func sampleBuilder() -> KFXContainerBuilder {
        var builder = KFXContainerBuilder()
        builder.localSymbols = ["c0", "content_1", "resource/e0"]
        builder.add(type: 260, name: "c0", .structure([(174, .symbol(builder.id(of: "c0")))]))
        builder.add(type: 145, name: "content_1", .structure([
            (4, .symbol(builder.id(of: "content_1"))), (146, .list([.string("One"), .string("Two")])),
        ]))
        builder.add(type: 538, .structure([(8, .int(1004))]))
        builder.addResource(name: "resource/e0", [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        return builder
    }

    /// The real container, as bytes.
    private func realBytes() throws -> [UInt8] {
        [UInt8](try Data(contentsOf: copyOfFormatSample("kfx/alice.kfx")))
    }

    /// A little-endian field of the container header at `offset`, overwritten.
    private func patched(_ bytes: [UInt8], at offset: Int, width: Int, to value: UInt64) -> [UInt8] {
        var copy = bytes
        for index in 0..<width { copy[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(index))) }
        return copy
    }

    // MARK: - A container built by hand

    func testAContainerOpensWithItsEntitiesAndSymbols() throws {
        let container = try KFXContainer(bytes: sampleBuilder().build())
        XCTAssertEqual(container.version, 2)
        XCTAssertEqual(container.entities.map(\.type), [260, 145, 538, 417])
        XCTAssertEqual(container.symbols.sharedMaximum, 859)
        XCTAssertEqual(container.symbols.local, ["c0", "content_1", "resource/e0"])
        var budget = 1_000
        let fragments = try container.fragments(budget: &budget)
        // The resource is raw bytes, not Ion, and is not decoded.
        XCTAssertEqual(fragments.map(\.type), [260, 145, 538])
        XCTAssertEqual(fragments.map(\.name), ["c0", "content_1", "$348"])
        XCTAssertEqual(fragments[1].value.structValue?[146]?.listValue?.compactMap(\.stringValue), ["One", "Two"])
        // The fragment's own name is a local symbol, so it is a string in the value; $4 is a system field.
        XCTAssertEqual(fragments[1].value.structValue?[4], .string("content_1"))
        XCTAssertTrue(fragments[1].localFieldNames.isEmpty)
    }

    func testARawResourceIsItsBytesAfterTheEntityHeader() throws {
        let container = try KFXContainer(bytes: sampleBuilder().build())
        let resource = try XCTUnwrap(container.entities.last)
        let raw = try container.rawBytes(of: resource)
        XCTAssertEqual(Array(raw.bytes[raw.range]), [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    }

    func testAFragmentAnnotatedWithItsOwnTypeIsUnwrapped() throws {
        var builder = KFXContainerBuilder()
        builder.localSymbols = ["story"]
        builder.add(type: 259, name: "story", .annotated([259], .structure([(176, .int(1))])))
        var budget = 100
        let fragment = try XCTUnwrap(try KFXContainer(bytes: builder.build()).fragments(budget: &budget).first)
        XCTAssertEqual(fragment.value.structValue?[176], .int(1))
    }

    func testVersionOneOpensToo() throws {
        var builder = sampleBuilder()
        builder.version = 1
        XCTAssertEqual(try KFXContainer(bytes: builder.build()).version, 1)
    }

    func testAContainerWithNoSymbolTableHasOnlyTheSharedSymbols() throws {
        // The builder writes a symbol table with no local symbols.
        var builder = KFXContainerBuilder()
        builder.add(type: 538, .structure([]))
        let symbols = try KFXContainer(bytes: builder.build()).symbols
        XCTAssertEqual(symbols.local, [])
    }

    // MARK: - Symbols

    func testTheFirstLocalSymbolFollowsTheImportsMaxID() {
        let symbols = KFXSymbols(sharedMaximum: 859, local: ["a13X", "c0"])
        XCTAssertEqual(symbols.name(of: 859), "$859", "the last shared symbol")
        XCTAssertEqual(symbols.name(of: 860), "a13X", "the first local symbol")
        XCTAssertEqual(symbols.name(of: 861), "c0")
        XCTAssertEqual(symbols.name(of: 862), "$862", "past the table: handled, not a trap")
        XCTAssertEqual(symbols.name(of: 0), "$0")
        XCTAssertEqual(symbols.name(of: 260), "$260")
        XCTAssertEqual(symbols.name(of: -5), "$-5")
        XCTAssertEqual(symbols.name(of: Int.max), "$\(Int.max)")
        XCTAssertEqual(symbols.name(of: Int.min), "$\(Int.min)")
    }

    func testANameComesFromASymbolOrAString() {
        let symbols = KFXSymbols(sharedMaximum: 859, local: ["c0"])
        XCTAssertEqual(symbols.name(of: .symbol(860)), "c0")
        XCTAssertEqual(symbols.name(of: .string("c0")), "c0")
        XCTAssertEqual(symbols.name(of: .annotated([1], .symbol(860))), "c0")
        XCTAssertNil(symbols.name(of: .int(860)))
        XCTAssertNil(symbols.name(of: nil))
    }

    func testATableWithNoImportsStartsAfterIonsSystemSymbols() throws {
        let table = IonWriter.document(.annotated([3], .structure([(7, .list([.string("x")]))])))
        var budget = 100
        let value = try XCTUnwrap(try IonReader.firstValue(in: KFXView(table), budget: &budget))
        XCTAssertEqual(try KFXSymbols(table: value).name(of: 10), "x")
    }

    func testASymbolTableWithAnImpossibleMaxIDIsRefused() throws {
        for count: Int64 in [-1, 1_000_000_000_000] {
            let table = IonWriter.document(.annotated([3], .structure([
                (6, .list([.structure([(4, .string("YJ_symbols")), (8, .int(count))])])),
            ])))
            var budget = 100
            let value = try XCTUnwrap(try IonReader.firstValue(in: KFXView(table), budget: &budget))
            XCTAssertThrowsError(try KFXSymbols(table: value), "\(count)")
        }
        XCTAssertThrowsError(try KFXSymbols(table: .int(5)))
    }

    // MARK: - The real container

    func testTheRealContainerOpens() throws {
        let container = try KFXContainer(bytes: try realBytes())
        XCTAssertEqual(container.version, 2)
        XCTAssertEqual(container.entities.count, 152)
        // The shared table ends at 859, so the first local symbol, 860, is the book's own.
        XCTAssertEqual(container.symbols.sharedMaximum, 859)
        XCTAssertEqual(container.symbols.name(of: 860), "a13X")
        XCTAssertTrue(container.symbols.local.contains("c0"))
        XCTAssertTrue(container.symbols.local.contains("content_1"))
    }

    func testTheRealContainersFragmentsAllDecode() throws {
        let container = try KFXContainer(bytes: try realBytes())
        var budget = KFXContainer.maximumValues
        let fragments = try container.fragments(budget: &budget)
        // The one raw resource (the cover) is not decoded; the rest are.
        XCTAssertEqual(fragments.count, 151)
        let byType = Dictionary(grouping: fragments, by: \.type).mapValues(\.count)
        XCTAssertEqual(byType[260], 19, "sections")
        XCTAssertEqual(byType[259], 19, "storylines")
        XCTAssertEqual(byType[145], 21, "content fragments")
        XCTAssertEqual(byType[389], 1, "navigation")
        XCTAssertEqual(byType[538], 1, "document data")
        XCTAssertGreaterThan(KFXContainer.maximumValues - budget, 1_000, "the values were counted")
    }

    func testTheRealContainersSectionsNameTheirStorylines() throws {
        let container = try KFXContainer(bytes: try realBytes())
        var budget = KFXContainer.maximumValues
        let fragments = try container.fragments(budget: &budget)
        let storyline = try XCTUnwrap(fragments.first { $0.type == 260 && $0.name == "c108" })
        let template = try XCTUnwrap(storyline.value.structValue?[141]?.listValue?.first?.structValue)
        // Local symbols come back as the strings of their names.
        XCTAssertEqual(template[176], .string("l10C"))
        XCTAssertTrue(fragments.contains { $0.type == 259 && $0.name == "l10C" })
    }

    // MARK: - Hostile containers

    func testNothingButAContainerOpens() {
        assertRefusedQuickly("empty") { try KFXContainer(bytes: []) }
        assertRefusedQuickly("short") { try KFXContainer(bytes: Array("CONT".utf8) + [2, 0]) }
        assertRefusedQuickly("text") { try KFXContainer(bytes: Array("This is not a Kindle book at all.".utf8)) }
        XCTAssertEqual(
            assertRefusedQuickly("signature") { try KFXContainer(bytes: Array("CONX".utf8) + [UInt8](repeating: 0, count: 40)) } as? MOBIError,
            .notAKindleBook)
    }

    func testAnUnknownVersionIsRefused() {
        let bytes = patched(sampleBuilder().build(), at: 4, width: 2, to: 3)
        assertRefusedQuickly("version 3") { try KFXContainer(bytes: bytes) }
    }

    func testEveryHeaderFieldPointedPastTheEndIsRefused() {
        let good = sampleBuilder().build()
        // The header's length, the container info's offset and length.
        for (offset, width) in [(6, 4), (10, 4), (14, 4)] {
            for value: UInt64 in [UInt64(good.count) + 1, 0xFFFF_FFFF] {
                let bytes = patched(good, at: offset, width: width, to: value)
                assertRefusedQuickly("field \(offset) = \(value)") { try KFXContainer(bytes: bytes) }
            }
        }
        // A header shorter than its own fixed part.
        assertRefusedQuickly("header length 17") { try KFXContainer(bytes: patched(good, at: 6, width: 4, to: 17)) }
    }

    func testEveryEntityTableFieldPointedWrongIsRefused() throws {
        let good = sampleBuilder().build()
        let tableOffset = 18
        for row in 0..<4 {
            let at = tableOffset + row * 24
            // Offset and length, each past the end, at the 32-bit and 64-bit extremes.
            for field in [8, 16] {
                for value: UInt64 in [UInt64(good.count), 0x7FFF_FFFF, 0xFFFF_FFFF, UInt64.max, UInt64(Int.max), UInt64(Int.max) - 10] {
                    let bytes = patched(good, at: at + field, width: 8, to: value)
                    assertRefusedQuickly("row \(row) field \(field) = \(value)") { try KFXContainer(bytes: bytes) }
                }
            }
            // A length too short to hold an entity header.
            assertRefusedQuickly("row \(row) length 3") { try KFXContainer(bytes: patched(good, at: at + 16, width: 8, to: 3)) }
        }
    }

    func testAnEntityTableThatIsNotWholeRowsIsRefused() {
        // $414 is the table's length; find it in the info and make it 25.
        var builder = sampleBuilder()
        builder.entities.append(KFXContainerBuilder.Entity(id: 348, type: 538, value: .null))
        var bytes = builder.build()
        // Append a stray byte to the table by lengthening the declared length: patch via the info Ion.
        let info = IonWriter.document(.structure([(413, .int(18)), (414, .int(25))]))
        let infoOffset = Int(bytes[10]) | Int(bytes[11]) << 8
        bytes.replaceSubrange(infoOffset..<(infoOffset + info.count), with: info)
        // The replaced info is no longer the one the container wrote, but it is a struct the reader reads.
        assertRefusedQuickly("25 bytes") { try KFXContainer(bytes: bytes) }
    }

    func testTheDeclaredCompressionAndProtectionAreRefusedNeverRead() {
        var protected = sampleBuilder()
        protected.drm = 1
        XCTAssertEqual(
            assertRefusedQuickly("container DRM") { try KFXContainer(bytes: protected.build()) } as? MOBIError, .copyProtected)
        var compressed = sampleBuilder()
        compressed.compression = 2
        XCTAssertEqual(
            assertRefusedQuickly("container compression") { try KFXContainer(bytes: compressed.build()) } as? MOBIError,
            .unsupportedCompression)
        var entityDRM = sampleBuilder()
        entityDRM.entities[0].headerDRM = 3
        let container = try? KFXContainer(bytes: entityDRM.build())
        var budget = 1_000
        XCTAssertEqual(
            assertRefusedQuickly("entity DRM") { try XCTUnwrap(container).fragments(budget: &budget) } as? MOBIError, .copyProtected)
        var entityCompressed = sampleBuilder()
        entityCompressed.entities[1].headerCompression = 1
        let second = try? KFXContainer(bytes: entityCompressed.build())
        XCTAssertEqual(
            assertRefusedQuickly("entity compression") { try XCTUnwrap(second).fragments(budget: &budget) } as? MOBIError,
            .unsupportedCompression)
    }

    func testAnEntityWithoutItsSignatureOrWithAWrongHeaderLengthIsRefused() throws {
        let good = sampleBuilder().build()
        let container = try KFXContainer(bytes: good)
        let start = container.entities[0].range.lowerBound
        var budget = 1_000

        var noSignature = good
        noSignature[start] = 0x58
        let first = try KFXContainer(bytes: noSignature)
        assertRefusedQuickly("signature") { try first.fragments(budget: &budget) }

        for length: UInt64 in [0, 9, 0xFFFF_FFFF, UInt64(container.entities[0].range.count) + 1] {
            let bytes = patched(good, at: start + 6, width: 4, to: length)
            let opened = try KFXContainer(bytes: bytes)
            assertRefusedQuickly("header length \(length)") { try opened.fragments(budget: &budget) }
        }
    }

    func testTooManyEntitiesAreRefusedBeforeAnyIsListed() {
        // A table of 200,001 rows needs 4.8 MB: the file is padded to hold it,
        // so the table lies inside the file and only the count refuses it.
        var bytes = sampleBuilder().build()
        let rows = KFXContainer.maximumEntities + 1
        bytes += [UInt8](repeating: 0, count: rows * 24)
        let info = IonWriter.document(.structure([(413, .int(18)), (414, .int(Int64(rows * 24)))]))
        let infoOffset = Int(bytes[10]) | Int(bytes[11]) << 8
        bytes.replaceSubrange(infoOffset..<(infoOffset + info.count), with: info)
        assertRefusedQuickly("200,001 rows") { try KFXContainer(bytes: bytes) }
    }

    func testEveryTruncationOfARealContainerIsRefused() throws {
        let real = try realBytes()
        // At many lengths, from the first bytes to one short of the end.
        var lengths = Array(stride(from: 0, to: real.count, by: 997))
        lengths += [1, 4, 17, 18, 19, real.count - 1, real.count - 2]
        for length in lengths {
            assertRefusedQuickly("cut at \(length)") {
                let container = try KFXContainer(bytes: Array(real.prefix(length)))
                var budget = KFXContainer.maximumValues
                _ = try container.fragments(budget: &budget)
            }
        }
    }

    func testEveryTruncationOfASmallContainerIsRefused() {
        let small = sampleBuilder().build()
        for length in 0..<small.count {
            assertRefusedQuickly("cut at \(length)") {
                let container = try KFXContainer(bytes: Array(small.prefix(length)))
                var budget = 10_000
                _ = try container.fragments(budget: &budget)
            }
        }
    }

    func testAFixedSeedByteFlipRunOverTheRealContainerNeverTraps() throws {
        let real = try realBytes()
        var generator = KFXSeededGenerator(seed: 52)
        // Flips in the header and tables, where an offset can be made wrong,
        // and flips anywhere; each ends quickly, in a read or an error.
        for round in 0..<120 {
            assertQuick("round \(round)") {
                var damaged = real
                let flips = 1 + Int(generator.next() % 4)
                for _ in 0..<flips {
                    let limit = round % 2 == 0 ? 5_000 : damaged.count
                    damaged[Int(generator.next() % UInt64(limit))] = UInt8(truncatingIfNeeded: generator.next())
                }
                do {
                    let container = try KFXContainer(bytes: damaged)
                    var budget = KFXContainer.maximumValues
                    _ = try container.fragments(budget: &budget)
                } catch {
                    XCTAssertTrue(error is MOBIError, "round \(round): \(error)")
                }
            }
        }
    }
}
