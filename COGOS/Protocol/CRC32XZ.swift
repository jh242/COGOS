import Foundation

/// CRC32 (IEEE 802.3 / zlib polynomial), a.k.a. Dart `Crc32Xz`.
/// Polynomial 0xEDB88320 (reflected form of 0x04C11DB7),
/// init 0xFFFFFFFF, reflected in/out, xor-out 0xFFFFFFFF.
enum CRC32XZ {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c: UInt32 = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data {
            let idx = Int((crc ^ UInt32(b)) & 0xff)
            crc = (crc >> 8) ^ table[idx]
        }
        return crc ^ 0xFFFFFFFF
    }
}
