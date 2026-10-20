import Foundation
import Testing
@testable import SweetCookieKit

#if os(macOS)
struct ChromiumLocalStorageStreamingTests {
    @Test(arguments: [false, true], [false, true])
    func `streaming agrees with whole store merging`(snappy: Bool, manifest: Bool) throws {
        let fixture = try SyntheticLevelDB()
        defer { fixture.remove() }
        let helper = ChromiumLocalStorageReaderTests()
        let tableHelper = ChromiumLevelDBTableTests()
        let origins = ["https://example.com", "http://example.com", "https://other.example", "example.com"]
        let keys = origins.flatMap { origin in
            (0..<12).map { helper.localStorageKey(storageKey: origin, key: "key\($0)") }
        }
        let records = (0..<250).map { index in
            let key = keys[(index * 17) % keys.count]
            return (
                tableHelper.levelDBInternalKey(
                    userKey: key, valueType: index % 7 == 0 ? 0 : 1, sequence: UInt64(index + 1)),
                helper.localStorageValue("table-\(index)"))
        }
        try tableHelper.writeTable(entries: records, to: fixture.directory, useSnappy: snappy)
        // Interleaved sequence numbers, equal-sequence ties, tombstones, and a fragmented batch.
        var batch = fixture.littleEndian(UInt64(200)) + fixture.littleEndian(UInt32(160))
        for index in 0..<160 {
            let deleted = index % 9 == 0
            batch.append(deleted ? 0 : 1)
            batch += fixture.slice(keys[(index * 19) % keys.count])
            if !deleted {
                batch += fixture.slice(helper.localStorageValue(String(repeating: "v", count: 600)))
            }
        }
        try fixture.write("000006.log", data: self.fragment(batch, fixture: fixture))
        if manifest {
            try fixture.write("CURRENT", data: Data("MANIFEST-000001\n".utf8))
            try fixture.write("MANIFEST-000001", data: fixture.version(log: 6, added: [5]))
            try fixture.write("000099.sst", data: fixture.table(sequence: 900, values: ["orphan"]))
        }
        for origin in origins + ["https://missing.example"] {
            let expected = ChromiumLocalStorageReader.withLevelDBEntries(in: fixture.directory) { entries, _ in
                ChromiumLocalStorageReader.decodeEntries(entries, for: origin).entries
            } ?? []
            let actual = ChromiumLocalStorageReader.readEntries(for: origin, in: fixture.directory)
            #expect(self.values(actual) == self.values(expected))
        }
    }

    @Test
    func `origin reads decode only matches and do not memoize`() throws {
        let fixture = try SyntheticLevelDB()
        defer { fixture.remove() }
        let helper = ChromiumLocalStorageReaderTests()
        let entries = (0..<300).map { index in
            (helper.localStorageKey(
                storageKey: index < 2 ? "https://example.com" : "https://other.example",
                key: "key\(index)"), helper.localStorageValue("synthetic-value"), false)
        }
        try helper.writeLog(entries: entries, to: fixture.directory)
        let counter = DecodeCounter()
        let cache = LevelDBReadCache(readData: { _ in
            Issue.record("Origin query must not load or cache a whole data file")
            return Data()
        }, onDerivation: { counter.record($0) })
        ChromiumLocalStorageReader.$levelDBCache.withValue(cache) {
            let first = ChromiumLocalStorageReader.readEntries(for: "https://example.com", in: fixture.directory)
            #expect(first.count == 2)
            #expect(counter.values == 2)
            let second = ChromiumLocalStorageReader.readEntries(for: "https://example.com", in: fixture.directory)
            #expect(self.values(first) == self.values(second))
            #expect(counter.values == 4)
        }
    }

    @Test
    func `streams multiple table blocks with shared key prefixes`() throws {
        let fixture = try SyntheticLevelDB()
        defer { fixture.remove() }
        let helper = ChromiumLocalStorageReaderTests()
        let rawKeys = ["https://example.com", "https://other.example"].map {
            helper.localStorageKey(storageKey: $0, key: "session")
        }
        var table = Data()
        var handles: [(Data, Data)] = []
        for (index, key) in rawKeys.enumerated() {
            let first = key + fixture.littleEndian(UInt64(20 << 8 | 1))
            let second = key + fixture.littleEndian(UInt64(10 << 8 | 1))
            let value = helper.localStorageValue("current")
            var block = Data([0]) + fixture.varint(UInt64(first.count)) + fixture.varint(UInt64(value.count))
            block += first + value
            // Reconstruct the user key from a shared prefix, including a prior unrelated record.
            block += fixture.varint(UInt64(key.count)) + Data([8, 4])
            block += second.suffix(8) + helper.localStorageValue("old")
            block += fixture.littleEndian(UInt32(0)) + fixture.littleEndian(UInt32(1))
            let handle = fixture.varint(UInt64(table.count)) + fixture.varint(UInt64(block.count))
            handles.append((Data([UInt8(index)]), handle))
            table += block + Data([0]) + fixture.checksum(block + Data([0]))
        }
        let meta = self.block([], fixture: fixture)
        let metaHandle = fixture.varint(UInt64(table.count)) + fixture.varint(UInt64(meta.count))
        table += meta + Data([0]) + fixture.checksum(meta + Data([0]))
        let index = self.block(handles, fixture: fixture)
        var footer = metaHandle + fixture.varint(UInt64(table.count)) + fixture.varint(UInt64(index.count))
        table += index + Data([0]) + fixture.checksum(index + Data([0]))
        footer += Data(repeating: 0, count: 40 - footer.count) + fixture.littleEndian(UInt64(0xDB47_7524_8B80_FB57))
        try fixture.write("000003.ldb", data: table + footer)
        try fixture.write("CURRENT", data: Data("MANIFEST-000001\n".utf8))
        try fixture.write("MANIFEST-000001", data: fixture.version(log: 0, added: [3]))
        #expect(ChromiumLocalStorageReader.readEntries(for: "https://example.com", in: fixture.directory)
            .map(\.value) == ["current"])
        #expect(ChromiumLocalStorageReader.readCurrentValue(forRawKey: rawKeys[0], in: fixture.directory)
            == helper.localStorageValue("current"))
    }

    private func block(_ entries: [(Data, Data)], fixture: SyntheticLevelDB) -> Data {
        var data = Data()
        for (key, value) in entries {
            data += Data([0]) + fixture.varint(UInt64(key.count)) + fixture.varint(UInt64(value.count)) + key + value
        }
        return data + fixture.littleEndian(UInt32(0)) + fixture.littleEndian(UInt32(1))
    }

    @Test
    func `strict conflicts on unrelated keys still reject the snapshot`() throws {
        let fixture = try SyntheticLevelDB()
        defer { fixture.remove() }
        try fixture.write("CURRENT", data: Data("MANIFEST-000001\n".utf8))
        try fixture.write("MANIFEST-000001", data: fixture.version(log: 4))
        try fixture.write("000004.log", data: fixture.batch(sequence: 1, values: ["wanted"]))
        let otherKey = Data("unrelated".utf8)
        let header = fixture.littleEndian(UInt64(7)) + fixture.littleEndian(UInt32(1))
        let first = header + Data([1]) + fixture.slice(otherKey) + fixture.slice(Data("first".utf8))
        let second = header + Data([0]) + fixture.slice(otherKey)
        try fixture.write("000005.log", data: fixture.record(first) + fixture.record(second))
        #expect(ChromiumLocalStorageReader.readCurrentValue(forRawKey: fixture.key, in: fixture.directory) == nil)
    }

    @Test
    func `strict duplicate identical versions remain valid`() throws {
        let fixture = try SyntheticLevelDB()
        defer { fixture.remove() }
        try fixture.write("CURRENT", data: Data("MANIFEST-000001\n".utf8))
        try fixture.write("MANIFEST-000001", data: fixture.version(log: 4, added: [3]))
        try fixture.write("000003.ldb", data: fixture.table(sequence: 1, values: ["wanted"]))
        try fixture.write("000004.log", data: fixture.batch(sequence: 1, values: ["wanted"]))
        #expect(ChromiumLocalStorageReader.readCurrentValue(forRawKey: fixture.key, in: fixture.directory)
            == Data([1]) + Data("wanted".utf8))
    }

    @Test(arguments: [false, true])
    func `strict validation groups histories and partitions large metadata`(partitioned: Bool) throws {
        let fixture = try SyntheticLevelDB()
        defer { fixture.remove() }
        let count = partitioned ? 35000 : 2000
        var batch = fixture.littleEndian(UInt64(1)) + fixture.littleEndian(UInt32(count))
        for index in 0..<count {
            let key = partitioned && index > 0 ? Data("unrelated-key-\(index)".utf8) : fixture.key
            batch += Data([1]) + fixture.slice(key) + fixture.slice(Data("value-\(index)".utf8))
        }
        try fixture.write("CURRENT", data: Data("MANIFEST-000001\n".utf8))
        try fixture.write("MANIFEST-000001", data: fixture.version(log: 4))
        try fixture.write("000004.log", data: self.fragment(batch, fixture: fixture))
        let opens = DecodeCounter()
        ChromiumLocalStorageReader.$strictReadObserver.withValue({ event in
            if case .didOpen("000004.log") = event {
                opens.record(.localStorageValue)
            }
        }, operation: {
            let result = ChromiumLocalStorageReader.readCurrentValue(forRawKey: fixture.key, in: fixture.directory)
            #expect(result == Data("value-\(partitioned ? 0 : count - 1)".utf8))
        })
        #expect(opens.values < 12)
        #expect(partitioned ? opens.values > 2 : opens.values == 2)
    }

    private func values(_ entries: [ChromiumLocalStorageEntry]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, "\($0.rawValueLength):\($0.value)") })
    }

    private func fragment(_ data: Data, fixture: SyntheticLevelDB) -> Data {
        var result = Data()
        var offset = 0
        while offset < data.count {
            let count = min(ChromiumLocalStorageReader.blockSize - 7, data.count - offset)
            let type: UInt8 = offset == 0 ? 2 : offset + count == data.count ? 4 : 3
            result += fixture.record(data.subdata(in: offset..<(offset + count)), type: type)
            offset += count
        }
        return result
    }
}

private final class DecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var values: Int {
        self.lock.withLock { self.count }
    }

    func record(_ derivation: LevelDBReadCache.Derivation) {
        if derivation == .localStorageValue {
            self.lock.withLock { self.count += 1 }
        }
    }
}
#endif
