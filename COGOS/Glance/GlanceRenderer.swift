import CoreGraphics
import CoreText
import Foundation

/// Renders the glance dashboard as a 640×200 1-bit bitmap.
@MainActor
final class GlanceRenderer {
    static let width = 640
    static let height = 200
    static let leftColumnWidth: CGFloat = 160
    static let rightColumnX: CGFloat = 168 // 160 + 8px padding

    /// Render the glance dashboard to BMP data ready for BmpTransfer.
    func render(
        time: Date,
        weather: (temp: String, condition: String)?,
        contextualSource: GlanceSource?,
        contextualFallbackText: String?
    ) -> Data? {
        let w = Self.width
        let h = Self.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // White background (fully lit waveguide).
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Black foreground — text renders as dark cutouts.
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)

        drawLeftColumn(ctx: ctx, time: time, weather: weather)
        drawDivider(ctx: ctx)
        drawRightColumn(ctx: ctx, source: contextualSource, fallbackText: contextualFallbackText)

        guard let image = ctx.makeImage() else { return nil }
        return BmpEncoder.encode(image)
    }

    // MARK: - Left column

    private func drawLeftColumn(
        ctx: CGContext,
        time: Date,
        weather: (temp: String, condition: String)?
    ) {
        let margin: CGFloat = 12
        let colW = Self.leftColumnWidth - margin * 2

        // Time — large bold.
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "H:mm"
        let timeStr = timeFmt.string(from: time)
        let timeFont = CTFontCreateWithName("SFProDisplay-Bold" as CFString, 44, nil)
        var y = GlanceDrawing.drawText(
            timeStr, at: CGPoint(x: margin, y: CGFloat(Self.height) - 10),
            font: timeFont, in: ctx
        )

        // Date.
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "EEE MMM d"
        let dateStr = dateFmt.string(from: time)
        let smallFont = CTFontCreateWithName("SFProDisplay-Regular" as CFString, 20, nil)
        y = GlanceDrawing.drawText(
            dateStr, at: CGPoint(x: margin, y: y - 6),
            font: smallFont, in: ctx
        )

        // Weather.
        if let w = weather {
            y -= 12
            let weatherStr = "\(w.temp) \(w.condition)"
            let maxW = colW
            let truncated = GlanceDrawing.truncateToFit(weatherStr, font: smallFont, maxWidth: maxW)
            _ = GlanceDrawing.drawText(
                truncated, at: CGPoint(x: margin, y: y),
                font: smallFont, in: ctx
            )
        }
    }

    // MARK: - Divider

    private func drawDivider(ctx: CGContext) {
        let x = Self.leftColumnWidth
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: x, y: 10))
        ctx.addLine(to: CGPoint(x: x, y: CGFloat(Self.height) - 10))
        ctx.strokePath()
    }

    // MARK: - Right column

    private func drawRightColumn(
        ctx: CGContext,
        source: GlanceSource?,
        fallbackText: String?
    ) {
        let rect = CGRect(
            x: Self.rightColumnX, y: 0,
            width: CGFloat(Self.width) - Self.rightColumnX - 8,
            height: CGFloat(Self.height)
        )

        // Try source's custom drawing first.
        if let source = source, source.drawContent(in: rect, context: ctx) {
            return
        }

        // Fallback: render text.
        if let text = fallbackText, !text.isEmpty {
            let font = CTFontCreateWithName("SFProDisplay-Regular" as CFString, 20, nil)
            let lines = text.components(separatedBy: "\n")
            var y = CGFloat(Self.height) - 16
            for line in lines {
                let truncated = GlanceDrawing.truncateToFit(line, font: font, maxWidth: rect.width)
                y = GlanceDrawing.drawText(
                    truncated, at: CGPoint(x: rect.minX, y: y),
                    font: font, in: ctx
                )
                y -= 4
                if y < 10 { break }
            }
        }
    }
}

// MARK: - Drawing helpers

enum GlanceDrawing {
    /// Draw a line of text. Returns the Y position below the drawn text
    /// (accounting for descender), suitable as the baseline for the next line.
    @discardableResult
    static func drawText(
        _ text: String,
        at point: CGPoint,
        font: CTFont,
        in context: CGContext
    ) -> CGFloat {
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true
        ]
        let attrStr = CFAttributedStringCreate(
            nil, text as CFString, attrs as CFDictionary
        )!
        let line = CTLineCreateWithAttributedString(attrStr)

        // Core Text draws with y-up; CGContext for bitmaps also uses y-up origin,
        // so we can draw directly.
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let baseline = point.y - ascent
        context.textPosition = CGPoint(x: point.x, y: baseline)
        CTLineDraw(line, context)

        return baseline - descent
    }

    /// Draw a two-column aligned row (e.g., "11:00" | "Team Standup").
    /// Returns the Y position below the row.
    @discardableResult
    static func drawAlignedRow(
        left: String,
        right: String,
        at y: CGFloat,
        in rect: CGRect,
        leftWidth: CGFloat,
        font: CTFont,
        context: CGContext
    ) -> CGFloat {
        let rightX = rect.minX + leftWidth + 8
        let rightMaxW = rect.width - leftWidth - 8
        let truncRight = truncateToFit(right, font: font, maxWidth: rightMaxW)

        drawText(left, at: CGPoint(x: rect.minX, y: y), font: font, in: context)
        return drawText(truncRight, at: CGPoint(x: rightX, y: y), font: font, in: context)
    }

    /// Truncate text with "..." to fit within maxWidth.
    static func truncateToFit(_ text: String, font: CTFont, maxWidth: CGFloat) -> String {
        if textWidth(text, font: font) <= maxWidth { return text }
        var s = text
        while s.count > 1 {
            s = String(s.dropLast())
            if textWidth(s + "...", font: font) <= maxWidth {
                return s + "..."
            }
        }
        return text
    }

    /// Measure the width of a string with the given font.
    static func textWidth(_ text: String, font: CTFont) -> CGFloat {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        return bounds.width
    }
}
