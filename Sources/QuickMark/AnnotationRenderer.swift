import AppKit

/// Draws annotations. Shared by the editor view and the exporter so what you
/// see is exactly what gets copied.
///
/// Expects: `ctx` in image-pixel coordinates with y pointing down, and
/// `NSGraphicsContext.current` set to a flipped context wrapping `ctx`
/// (needed for text drawing).
enum AnnotationRenderer {
    static func draw(_ annotations: [Annotation], in ctx: CGContext) {
        for annotation in annotations {
            ctx.saveGState()
            draw(annotation, in: ctx)
            ctx.restoreGState()
        }
    }

    private static func draw(_ a: Annotation, in ctx: CGContext) {
        let color = (a.color.usingColorSpace(.sRGB) ?? a.color).cgColor
        switch a.kind {
        case let .arrow(start, end):
            drawArrow(from: start, to: end, lineWidth: a.lineWidth, color: color, in: ctx)
        case let .rectangle(rect):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(a.lineWidth)
            ctx.setLineJoin(.round)
            ctx.stroke(rect)
        case let .text(string, origin):
            drawText(string, at: origin, font: a.font, color: a.color)
        }
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint,
                                  lineWidth: CGFloat, color: CGColor, in ctx: CGContext) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length

        let headLength = min(max(lineWidth * 4, 10), length)
        let headHalfWidth = headLength * 0.5
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)

        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        // Shaft stops at the head's base so the round cap doesn't poke out of the tip.
        ctx.move(to: start)
        ctx.addLine(to: base)
        ctx.strokePath()

        ctx.move(to: end)
        ctx.addLine(to: CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth))
        ctx.addLine(to: CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawText(_ string: String, at origin: CGPoint, font: NSFont, color: NSColor) {
        // Outline pass first (white, or black for white text) for readability on any background.
        let isWhite = (color.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.9
            && (color.usingColorSpace(.sRGB)?.saturationComponent ?? 1) < 0.1
        let outlineColor: NSColor = isWhite ? .black : .white

        let outline = NSAttributedString(string: string, attributes: [
            .font: font,
            .strokeColor: outlineColor,
            .strokeWidth: 16, // positive = stroke only, % of font size
        ])
        outline.draw(at: origin)

        let fill = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        fill.draw(at: origin)
    }
}

/// Composites annotations onto the original-resolution image and puts it on the pasteboard.
enum ImageExporter {
    static func render(image: CGImage, annotations: [Annotation]) -> CGImage? {
        let width = image.width, height = image.height
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: bitmapInfo)
        else { return nil }

        // 1. Original pixels, 1:1 (no resampling).
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 2. Annotations, in a y-down coordinate system matching the editor.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        AnnotationRenderer.draw(annotations, in: ctx)
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }

    @discardableResult
    static func copyToPasteboard(_ image: CGImage, scale: CGFloat) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        // Keep the point size (e.g. 144 dpi for Retina) so pasted images aren't shown at 2x.
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        return true
    }
}
