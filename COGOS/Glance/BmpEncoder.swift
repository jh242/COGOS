import CoreGraphics
import Foundation

/// Converts a CGImage to a 1-bit Windows BMP suitable for the G1 display.
enum BmpEncoder {
    /// Encode a CGImage as a 1-bit monochrome BMP.
    /// The image is rendered to grayscale and thresholded at 128.
    static func encode(_ image: CGImage) -> Data? {
        let w = image.width
        let h = image.height

        // Render into 8-bit grayscale buffer for thresholding.
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        // 1-bit row: each row padded to 4-byte boundary.
        let rowBytes = ((w + 31) / 32) * 4
        let pixelDataSize = rowBytes * h

        // BMP file header (14) + DIB header (40) + color table (8) + pixels.
        let headerSize = 14 + 40 + 8
        let fileSize = headerSize + pixelDataSize

        var data = Data(capacity: fileSize)

        // -- File header (14 bytes) --
        data.append(contentsOf: [0x42, 0x4D])          // "BM"
        data.append(littleEndian32: UInt32(fileSize))
        data.append(contentsOf: [0, 0, 0, 0])          // reserved
        data.append(littleEndian32: UInt32(headerSize)) // pixel data offset

        // -- DIB header (BITMAPINFOHEADER, 40 bytes) --
        data.append(littleEndian32: 40)                 // header size
        data.append(littleEndian32: UInt32(w))          // width
        data.append(littleEndian32: UInt32(h))          // height (positive = bottom-up)
        data.append(littleEndian16: 1)                  // planes
        data.append(littleEndian16: 1)                  // bits per pixel
        data.append(littleEndian32: 0)                  // compression (BI_RGB)
        data.append(littleEndian32: UInt32(pixelDataSize))
        data.append(littleEndian32: 2835)               // h-res (72 dpi)
        data.append(littleEndian32: 2835)               // v-res
        data.append(littleEndian32: 2)                  // colors used
        data.append(littleEndian32: 0)                  // important colors

        // -- Color table (2 entries × 4 bytes) --
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // index 0 = black
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0x00]) // index 1 = white

        // -- Pixel data (bottom-up, 1-bit packed) --
        for y in stride(from: h - 1, through: 0, by: -1) {
            var row = Data(count: rowBytes)
            for x in 0..<w {
                let gray = pixels[y * w + x]
                if gray >= 128 {
                    let byteIdx = x / 8
                    let bitIdx = 7 - (x % 8)
                    row[byteIdx] |= UInt8(1 << bitIdx)
                }
            }
            data.append(row)
        }

        return data
    }
}

// MARK: - Data helpers for little-endian encoding

private extension Data {
    mutating func append(littleEndian32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
