import Foundation
import Testing
@testable import SweetCookieKit

struct ChromiumLocalStorageReaderTests {
    @Test
    func `reads host only storage key without prefix`() throws {
        let levelDBURL = try self.makeLevelDBDirectory()
        let key = self.localStorageKey(
            storageKey: "minimax.io",
            key: "access_token",
            includePrefix: false)
        let value = self.localStorageValue("token-abc")
        try self.writeLog(entries: [(key, value, false)], to: levelDBURL)

        let entries = ChromiumLocalStorageReader.readEntries(
            for: "https://minimax.io",
            in: levelDBURL)

        #expect(entries.count == 1)
        #expect(entries.first?.key == "access_token")
        #expect(entries.first?.value == "token-abc")
    }

    @Test
    func `reads prefixed storage key`() throws {
        let levelDBURL = try self.makeLevelDBDirectory()
        let key = self.localStorageKey(storageKey: "https://example.com", key: "pref")
        let value = self.localStorageValue("value-0")
        try self.writeLog(entries: [(key, value, false)], to: levelDBURL)

        let entries = ChromiumLocalStorageReader.readEntries(
            for: "https://example.com",
            in: levelDBURL)

        #expect(entries.count == 1)
        #expect(entries.first?.key == "pref")
        #expect(entries.first?.value == "value-0")
    }

    @Test
    func `reads partitioned storage key`() throws {
        let levelDBURL = try self.makeLevelDBDirectory()
        let key = self.localStorageKey(
            storageKey: "https://example.com/^0https://top.example",
            key: "pref")
        let value = self.localStorageValue("value-1")
        try self.writeLog(entries: [(key, value, false)], to: levelDBURL)

        let entries = ChromiumLocalStorageReader.readEntries(
            for: "https://example.com",
            in: levelDBURL)

        #expect(entries.count == 1)
        #expect(entries.first?.key == "pref")
        #expect(entries.first?.value == "value-1")
    }

    @Test
    func `ignores non origin keys without prefix`() throws {
        let levelDBURL = try self.makeLevelDBDirectory()
        let key = self.localStorageKey(storageKey: "not-an-origin", key: "pref", includePrefix: false)
        let value = self.localStorageValue("value-ignored")
        try self.writeLog(entries: [(key, value, false)], to: levelDBURL)

        let entries = ChromiumLocalStorageReader.readEntries(
            for: "https://example.com",
            in: levelDBURL)

        #expect(entries.isEmpty)
    }

    @Test
    func `prefers deletion tombstone from log`() throws {
        let levelDBURL = try self.makeLevelDBDirectory()
        let key = self.localStorageKey(storageKey: "https://example.com", key: "pref")
        let value = self.localStorageValue("value-2")
        try self.writeLog(entries: [(key, value, false), (key, Data(), true)], to: levelDBURL)

        let entries = ChromiumLocalStorageReader.readEntries(
            for: "https://example.com",
            in: levelDBURL)

        #expect(entries.isEmpty)
    }

    @Test
    func `reads token candidates from level DB`() throws {
        let levelDBURL = try self.makeLevelDBDirectory()
        let token = String(repeating: "a", count: 25) + "." + String(repeating: "b", count: 25) + ".ccc"
        let key = self.localStorageKey(storageKey: "https://example.com", key: "pref")
        let value = Data(token.utf8)
        try self.writeLog(entries: [(key, value, false)], to: levelDBURL)

        let tokens = ChromiumLevelDBReader.readTokenCandidates(
            in: levelDBURL,
            minimumLength: 40)

        #expect(tokens.contains(token))
    }

    @Test
    func `ignores empty level DB keys`() throws {
        let levelDBURL = try self.makeLevelDBDirectory()
        try self.writeLog(entries: [(Data(), self.localStorageValue("ignored"), false)], to: levelDBURL)

        let entries = ChromiumLocalStorageReader.readEntries(
            for: "https://example.com",
            in: levelDBURL)

        #expect(entries.isEmpty)
    }

    @Test(arguments: ["http://example.com", "https://example.com", "HTTPS://example.com",
                      "https://example.com:8443"])
    func `public reader separates schemes and ports while preserving host only keys`(requested: String) throws {
        let levelDBURL = try self.makeLevelDBDirectory()
        defer { try? FileManager.default.removeItem(at: levelDBURL) }
        let fixtures = [
            ("http://example.com", "http"),
            ("https://example.com", "https"),
            ("https://example.com:8443", "port"),
            ("example.com", "host-only"),
            ("https://other.example", "other-host"),
        ]
        let rows = fixtures.map { origin, value in
            (self.localStorageKey(storageKey: origin, key: value), self.localStorageValue(value), false)
        }
        try self.writeLog(entries: rows, to: levelDBURL)

        let entries = ChromiumLocalStorageReader.readEntries(for: requested, in: levelDBURL)
        let expected: Set<String>
        switch requested.lowercased() {
        case "http://example.com": expected = ["http", "host-only"]
        case "https://example.com": expected = ["https", "host-only"]
        default: expected = ["port"]
        }
        #expect(Set(entries.map(\.value)) == expected)
        #expect(entries.count == expected.count)
    }

}

extension ChromiumLocalStorageReaderTests {
    func makeLevelDBDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
        let url = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func localStorageKey(storageKey: String, key: String, includePrefix: Bool = true) -> Data {
        var data = Data()
        if includePrefix {
            data.append(0x5F)
        }
        data.append(contentsOf: storageKey.utf8)
        data.append(0x00)
        data.append(contentsOf: key.utf8)
        return data
    }

    func localStorageValue(_ value: String) -> Data {
        var data = Data([0x01])
        data.append(contentsOf: value.utf8)
        return data
    }

    func writeLog(entries: [(key: Data, value: Data, isDeletion: Bool)], to url: URL) throws {
        var batch = Data()
        batch.append(contentsOf: Array(repeating: 0, count: 8))
        let count = UInt32(entries.count)
        batch.append(contentsOf: self.littleEndianBytes(count))
        for entry in entries {
            batch.append(entry.isDeletion ? 0 : 1)
            batch.append(self.varint32(entry.key.count))
            batch.append(entry.key)
            if !entry.isDeletion {
                batch.append(self.varint32(entry.value.count))
                batch.append(entry.value)
            }
        }

        var record = Data()
        record.append(contentsOf: Array(repeating: 0, count: 4))
        let length = UInt16(batch.count)
        record.append(contentsOf: self.littleEndianBytes(length))
        record.append(1)
        record.append(batch)

        try record.write(to: url.appendingPathComponent("000003.log"))
    }

    private func varint32(_ value: Int) -> Data {
        var result = Data()
        var remaining = UInt32(value)
        while true {
            if remaining & ~0x7F == 0 {
                result.append(UInt8(remaining))
                break
            }
            result.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        return result
    }

    private func littleEndianBytes(_ value: some FixedWidthInteger) -> [UInt8] {
        let littleEndian = value.littleEndian
        return withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
