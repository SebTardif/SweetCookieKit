import Foundation

#if os(macOS)
import CryptoKit
import Darwin

/// A range reader owns one descriptor, never a mapping or a whole-file buffer.
final class LevelDBFile {
    let size: Int
    private let readRange: (Range<Int>) -> Data?
    private let finish: () -> Bool
    private let closeFile: () -> Void

    init(data: Data) {
        self.size = data.count
        self.readRange = { data.subdata(in: $0) }
        self.finish = { true }
        self.closeFile = {}
    }

    init(descriptor: Int32, size: Int, finish: @escaping () -> Bool = { true }) {
        self.size = size
        self.finish = finish
        self.closeFile = { _ = close(descriptor) }
        self.readRange = { range in
            var data = Data(count: range.count)
            let success = data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = pread(
                        descriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        buffer.count - offset,
                        off_t(range.lowerBound + offset))
                    if count < 0, errno == EINTR {
                        continue
                    }
                    guard count > 0 else { return false }
                    offset += count
                }
                return true
            }
            return success ? data : nil
        }
    }

    deinit { self.closeFile() }

    static func open(_ url: URL) -> LevelDBFile? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let size = Int(exactly: info.st_size), size >= 0
        else {
            _ = close(descriptor)
            return nil
        }
        return LevelDBFile(descriptor: descriptor, size: size)
    }

    func read(_ range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= self.size else { return nil }
        return self.readRange(range)
    }

    func unchanged() -> Bool {
        self.finish()
    }
}

extension ChromiumLocalStorageReader {
    /// Filters raw keys before copying values and retains only the current matching records.
    static func streamFiles(
        _ urls: [URL],
        cache: LevelDBReadCache,
        open: (URL) -> LevelDBFile? = LevelDBFile.open,
        complete: inout Bool,
        matches: (Data, UInt64) -> Bool,
        logger: (String) -> Void) -> [LevelDBEntry]
    {
        guard !cache.strictReads || urls.contains(where: { $0.lastPathComponent == "CURRENT" }) else {
            complete = false
            return []
        }
        let files = self.liveLevelDBFiles(urls, cache: cache, complete: &complete, logger: logger)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if cache.strictReads, !self.validateVersions(files, cache: cache, open: open, logger: logger) {
            complete = false
            return []
        }
        var current: [Data: LevelDBEntry] = [:]
        self
            .visitFiles(
                files,
                cache: cache,
                open: open,
                complete: &complete,
                matches: matches,
                logger: logger)
            { entry in
                if let previous = current[entry.key],
                   previous.sequence > entry.sequence ||
                   (previous.sequence == entry.sequence && !previous.isDeletion)
                {
                    return
                }
                current[entry.key] = entry
            }
        return current.values.sorted {
            if $0.sequence != $1.sequence {
                return $0.sequence > $1.sequence
            }
            if $0.isDeletion != $1.isDeletion {
                return !$0.isDeletion
            }
            return $0.key.lexicographicallyPrecedes($1.key)
        }
    }

    // Keep traversal controls explicit at the parser boundary.
    // swiftlint:disable:next function_parameter_count
    private static func visitFiles(
        _ urls: [URL],
        cache: LevelDBReadCache,
        open: (URL) -> LevelDBFile?,
        complete: inout Bool,
        matches: (Data, UInt64) -> Bool,
        logger: (String) -> Void,
        visit: (LevelDBEntry) -> Void)
    {
        for url in urls {
            guard let file = open(url) else { complete = false; continue }
            if url.pathExtension.lowercased() == "log" {
                self.visitLogEntries(
                    file: file,
                    strict: cache.strictReads,
                    complete: &complete,
                    matches: matches,
                    visit: visit)
            } else {
                self.visitTableEntries(
                    file: file,
                    cache: cache,
                    complete: &complete,
                    matches: matches,
                    logger: logger,
                    visit: visit)
            }
            if !file.unchanged() {
                complete = false
            }
        }
    }

    private struct VersionKey: Hashable {
        let key: Data
        let sequence: UInt64
    }

    private struct VersionFingerprint: Equatable {
        let isDeletion: Bool
        let digest: SHA256.Digest
    }

    private enum PartitionResult {
        case valid, split, invalid
    }

    /// Hashes values one at a time. Overflowing groups split by key/sequence hash, releasing the parent first.
    /// Repeated versions use one dictionary slot, so long histories never trigger a scan per candidate.
    private static func validateVersions(
        _ urls: [URL],
        cache: LevelDBReadCache,
        open: (URL) -> LevelDBFile?,
        logger: (String) -> Void) -> Bool
    {
        var pending: [(prefix: UInt64, bits: Int)] = [(0, 0)]
        while let partition = pending.popLast() {
            switch self.validatePartition(urls, cache: cache, open: open, partition: partition, logger: logger) {
            case .valid: continue
            case .invalid: return false
            case .split:
                guard partition.bits < 64 else { return false }
                pending.append((partition.prefix, partition.bits + 1))
                pending.append((partition.prefix | (UInt64(1) << partition.bits), partition.bits + 1))
            }
        }
        return true
    }

    private static func validatePartition(
        _ urls: [URL],
        cache: LevelDBReadCache,
        open: (URL) -> LevelDBFile?,
        partition: (prefix: UInt64, bits: Int),
        logger: (String) -> Void) -> PartitionResult
    {
        var versions: [VersionKey: VersionFingerprint] = [:]
        var retainedBytes = 0
        var overflow = false
        var conflict = false
        var complete = true
        let mask: UInt64 = partition.bits == 64 ? .max : (UInt64(1) << partition.bits) - 1
        self.visitFiles(
            urls,
            cache: cache,
            open: open,
            complete: &complete,
            matches: { key, sequence in
                let version = VersionKey(key: key, sequence: sequence)
                return !overflow && UInt64(UInt(bitPattern: version.hashValue)) & mask == partition.prefix
            },
            logger: logger,
            visit: { entry in
                let key = VersionKey(key: entry.key, sequence: entry.sequence)
                let fingerprint = VersionFingerprint(
                    isDeletion: entry.isDeletion,
                    digest: SHA256.hash(data: entry.value))
                if let previous = versions[key] {
                    if previous != fingerprint {
                        conflict = true
                    }
                } else {
                    // Charge for key bytes plus dictionary/fingerprint overhead. Allow one unusually large key.
                    retainedBytes += entry.key.count + 128
                    if retainedBytes > 4 * 1024 * 1024, !versions.isEmpty {
                        overflow = true
                    } else {
                        versions[key] = fingerprint
                    }
                }
            })
        if !complete || conflict {
            return .invalid
        }
        return overflow ? .split : .valid
    }

    private static func visitLogEntries(
        file: LevelDBFile,
        strict: Bool,
        complete: inout Bool,
        matches: (Data, UInt64) -> Bool,
        visit: (LevelDBEntry) -> Void)
    {
        // First locate logical records without assembling their payloads. A write batch may span the entire file.
        var firstHeader: Int?
        var lastHeader = 0
        var recordLength = 0
        for blockStart in stride(from: 0, to: file.size, by: self.blockSize) {
            let blockEnd = min(blockStart + self.blockSize, file.size)
            guard let block = file.read(blockStart..<blockEnd) else { complete = false; return }
            var offset = 0
            while offset + 7 <= block.count {
                let header = blockStart + offset
                let length = Int(self.readUInt16LE(block, at: offset + 4))
                let type = block[offset + 6]
                offset += 7
                guard offset + length <= block.count else { complete = false; break }
                if strict, !self.validLogChecksum(block, payloadOffset: offset, length: length, blockEnd: block.count) {
                    complete = false
                    return
                }
                if length == 0 {
                    if type == 2 {
                        if firstHeader != nil {
                            complete = false
                        }
                        firstHeader = header
                        recordLength = 0
                        lastHeader = header
                    } else if type != 0 {
                        complete = false
                    }
                    continue
                }
                offset += length
                switch type {
                case 1:
                    if firstHeader != nil {
                        complete = false
                    }
                    firstHeader = nil
                    self.visitBatch(
                        file: file,
                        first: header,
                        last: header,
                        length: length,
                        complete: &complete,
                        matches: matches,
                        visit: visit)
                case 2:
                    if firstHeader != nil {
                        complete = false
                    }
                    firstHeader = header
                    lastHeader = header
                    recordLength = length
                case 3, 4:
                    guard let first = firstHeader else { complete = false; continue }
                    recordLength += length
                    lastHeader = header
                    if type == 4 {
                        self.visitBatch(
                            file: file,
                            first: first,
                            last: header,
                            length: recordLength,
                            complete: &complete,
                            matches: matches,
                            visit: visit)
                        firstHeader = nil
                        recordLength = 0
                    }
                default: complete = false
                }
            }
            if offset < block.count, block[offset...].contains(where: { $0 != 0 }) {
                complete = false
            }
        }
        if let first = firstHeader {
            complete = false
            // Match the best-effort reader's treatment of an unterminated but decodable batch.
            self.visitBatch(
                file: file,
                first: first,
                last: lastHeader,
                length: recordLength,
                complete: &complete,
                matches: matches,
                visit: visit)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func visitBatch(
        file: LevelDBFile,
        first: Int,
        last: Int,
        length: Int,
        complete: inout Bool,
        matches: (Data, UInt64) -> Bool,
        visit: (LevelDBEntry) -> Void)
    {
        // Validate the entire batch first: a malformed tail must not publish an earlier operation.
        // A second pass emits one value at a time, including strict-validation candidates from other origins.
        for validating in [true, false] {
            var cursor = LogCursor(file: file, header: first, last: last, remaining: length)
            guard let header = cursor.read(12) else { complete = false; return }
            let sequence = self.readUInt64LE(header, at: 0)
            let count = Int(self.readUInt32LE(header, at: 8))
            let maximum = UInt64.max >> 8
            guard sequence <= maximum, UInt64(max(count - 1, 0)) <= maximum - sequence,
                  count <= cursor.remaining / 2 else { complete = false; return }
            for index in 0..<count {
                guard let tag = cursor.read(1)?.first, tag <= 1,
                      let keyLength = cursor.varint(), let key = cursor.read(keyLength, retain: !validating)
                else { complete = false; return }
                let entrySequence = sequence + UInt64(index)
                let selectedKey = !validating && matches(key, entrySequence)
                var value = Data()
                if tag == 1 {
                    guard let valueLength = cursor.varint(),
                          let bytes = cursor.read(valueLength, retain: selectedKey) else { complete = false; return }
                    value = bytes
                }
                if selectedKey {
                    visit(LevelDBEntry(key: key, value: value, isDeletion: tag == 0, sequence: entrySequence))
                }
            }
            guard cursor.remaining == 0 else { complete = false; return }
        }
    }

    /// Reads a logical record across physical fragments; unmatched values are skipped without allocation.
    private struct LogCursor {
        let file: LevelDBFile
        var header: Int
        let last: Int
        var remaining: Int
        private var payload = Data()
        private var offset = 0
        private var nextHeader: Int?

        init(file: LevelDBFile, header: Int, last: Int, remaining: Int) {
            self.file = file
            self.header = header
            self.last = last
            self.remaining = remaining
        }

        mutating func read(_ count: Int, retain: Bool = true) -> Data? {
            guard count >= 0, count <= self.remaining else { return nil }
            var result = Data()
            var needed = count
            while needed > 0 {
                if self.offset == self.payload.count {
                    if let next = self.nextHeader {
                        self.header = next
                    }
                    let blockEnd = (self.header / ChromiumLocalStorageReader.blockSize + 1) *
                        ChromiumLocalStorageReader.blockSize
                    if blockEnd - self.header < 7 {
                        self.header = blockEnd
                    }
                    guard self.header <= self.last, let bytes = self.file.read(self.header..<(self.header + 7))
                    else { return nil }
                    let length = Int(ChromiumLocalStorageReader.readUInt16LE(bytes, at: 4))
                    let start = self.header + 7
                    guard let payload = self.file.read(start..<(start + length)) else { return nil }
                    self.offset = 0
                    self.nextHeader = start + length
                    // The best-effort framing scan ignores unknown physical record types.
                    let type = bytes[6]
                    self.payload = (1...4).contains(type) ? payload : Data()
                    if self.payload.isEmpty {
                        continue
                    }
                }
                let take = min(needed, self.payload.count - self.offset)
                if retain {
                    result.append(self.payload[self.offset..<(self.offset + take)])
                }
                self.offset += take
                needed -= take
            }
            self.remaining -= count
            return result
        }

        mutating func varint() -> Int? {
            var value: UInt32 = 0
            for shift in stride(from: 0, to: 32, by: 7) {
                guard let byte = self.read(1)?.first, shift < 28 || byte <= 15 else { return nil }
                value |= UInt32(byte & 127) << shift
                if byte & 128 == 0 {
                    return Int(value)
                }
            }
            return nil
        }
    }
}
#endif
