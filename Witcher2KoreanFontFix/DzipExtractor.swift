import Foundation

enum DzipExtractor {
    enum ExtractionError: LocalizedError {
        case invalidArchive
        var errorDescription: String? {
            "krbr.dzip에서 한국어 글꼴을 읽을 수 없습니다."
        }
    }

    static func decodeLZF<Input: RandomAccessCollection>(_ input: Input, limit: Int) throws -> [UInt8]
    where Input.Element == UInt8, Input.Index == Int {
        var output: [UInt8] = []
        var cursor = input.startIndex
        while cursor < input.endIndex {
            let control = Int(input[cursor])
            cursor += 1
            if control < 32 {
                let length = control + 1
                guard length <= input.endIndex - cursor, length <= limit - output.count else {
                    throw ExtractionError.invalidArchive
                }
                output.append(contentsOf: input[cursor..<cursor + length])
                cursor += length
            } else {
                var length = control >> 5
                var distance = (control & 31) << 8
                if length == 7 {
                    guard cursor < input.endIndex else { throw ExtractionError.invalidArchive }
                    length += Int(input[cursor])
                    cursor += 1
                }
                guard cursor < input.endIndex else { throw ExtractionError.invalidArchive }
                distance |= Int(input[cursor])
                cursor += 1
                length += 2
                let reference = output.count - distance - 1
                guard reference >= 0, length <= limit - output.count else { throw ExtractionError.invalidArchive }
                // LZF references may overlap the bytes currently being produced.
                for index in 0..<length { output.append(output[reference + index]) }
            }
        }
        return output
    }

    static func extract(from archive: URL) throws -> Data {
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        func range(_ offset: Int, _ length: Int) throws {
            guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
                throw ExtractionError.invalidArchive
            }
        }
        func integer(_ offset: Int, _ length: Int) throws -> Int {
            try range(offset, length)
            var value: UInt64 = 0
            for i in 0..<length { value |= UInt64(bytes[offset + i]) << (8 * i) }
            guard let result = Int(exactly: value) else { throw ExtractionError.invalidArchive }
            return result
        }
        try range(0, 32)
        guard bytes.prefix(4) == Data("DZIP".utf8), try integer(4, 4) >= 2 else {
            throw ExtractionError.invalidArchive
        }
        let count = try integer(8, 4)
        let table = try integer(16, 8)
        guard table >= 32, table <= bytes.count else { throw ExtractionError.invalidArchive }
        var cursor = table
        let target = Data("globals\\gui\\fonts_kr.swf\0".utf8)
        for _ in 0..<count {
            let nameLength = try integer(cursor, 2)
            cursor += 2
            try range(cursor, nameLength)
            guard nameLength > 0, bytes[cursor + nameLength - 1] == 0 else { throw ExtractionError.invalidArchive }
            let matches = bytes[cursor..<cursor + nameLength] == target
            cursor += nameLength
            try range(cursor, 32)
            if matches {
                let size = try integer(cursor + 8, 8)
                let offset = try integer(cursor + 16, 8)
                let compressed = try integer(cursor + 24, 8)
                guard offset >= 32, offset <= table, compressed <= table - offset,
                      size >= 8, size / 264 <= compressed else { throw ExtractionError.invalidArchive }
                let blocks = (size - 1) / 65_536 + 1
                guard blocks <= compressed / 4 else { throw ExtractionError.invalidArchive }
                var boundaries: [Int] = []
                for index in 0..<blocks {
                    let relative = try integer(offset + index * 4, 4)
                    guard relative >= blocks * 4, relative <= compressed else { throw ExtractionError.invalidArchive }
                    boundaries.append(offset + relative)
                }
                boundaries.append(offset + compressed)
                var output = Data()
                for index in 0..<blocks {
                    let start = boundaries[index], end = boundaries[index + 1]
                    guard start <= end else { throw ExtractionError.invalidArchive }
                    let decoded = try decodeLZF(bytes[start..<end], limit: min(65_536, size - output.count))
                    output.append(contentsOf: decoded)
                }
                guard output.count == size,
                      output.prefix(3) == Data("FWS".utf8) || output.prefix(3) == Data("CWS".utf8) else {
                    throw ExtractionError.invalidArchive
                }
                let declared = (0..<4).reduce(UInt32(0)) { $0 | UInt32(output[4 + $1]) << (8 * $1) }
                guard declared >= 1_048_576 else { throw ExtractionError.invalidArchive }
                return output
            }
            cursor += 32
        }
        throw ExtractionError.invalidArchive
    }
}
