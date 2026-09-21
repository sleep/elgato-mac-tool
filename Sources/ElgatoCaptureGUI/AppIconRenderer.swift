import AppKit

/// Draws the app icon with Core Graphics: a blue→violet gradient tile with a white
/// viewfinder and a record dot. Used for the Dock icon at runtime, the .icns in the
/// packaged app (scripts/export-icon.swift) and the mobile remote's PWA icon.
enum AppIconRenderer {

    /// - Parameter fullBleed: `false` follows the macOS icon grid — an 824pt rounded
    ///   tile centred in a 1024pt canvas, with a drop shadow in the margin. `true`
    ///   fills the whole square with no rounding or shadow, for platforms that apply
    ///   their own mask (iOS / Android home-screen icons).
    static func makeIcon(fullBleed: Bool = false) -> NSImage {
        let pt: CGFloat = 512
        let px = 1024

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4 * px, bitsPerPixel: 32
        ) else {
            return NSImage(size: NSSize(width: pt, height: pt))
        }
        rep.size = NSSize(width: pt, height: pt)

        guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: NSSize(width: pt, height: pt))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx

        // NSBitmapImageRep already maps 512pt → 1024px; no manual scale needed.
        drawIcon(ctx: gctx.cgContext, size: pt, fullBleed: fullBleed)

        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: pt, height: pt))
        img.addRepresentation(rep)
        return img
    }

    // MARK: - Drawing (CG native coords: origin = bottom-left, Y up)

    private static func drawIcon(ctx: CGContext, size: CGFloat, fullBleed: Bool) {
        // All measurements below are in units of Apple's 1024pt icon grid.
        let u = size / 1024
        let tile = fullBleed
            ? CGRect(x: 0, y: 0, width: size, height: size)
            : CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
        let tilePath = fullBleed ? CGPath(rect: tile, transform: nil) : squircle(in: tile)
        let centre = CGPoint(x: tile.midX, y: tile.midY)
        let side = tile.width

        // Drop shadow, cast by a flat fill that the gradient then covers.
        if !fullBleed {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 28 * u,
                          color: rgba(0, 0, 0, 0.35))
            ctx.addPath(tilePath)
            ctx.setFillColor(rgb(0.30, 0.22, 0.80))
            ctx.fillPath()
            ctx.restoreGState()
        }

        // --- Tile ---
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()

        // Base gradient: lighter at the top, like the system icons.
        if let g = makeGrad([rgb(0.38, 0.66, 1.00), rgb(0.36, 0.36, 0.96), rgb(0.42, 0.16, 0.78)]) {
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: tile.midX, y: tile.maxY),
                                   end: CGPoint(x: tile.midX, y: tile.minY), options: [])
        }

        // Soft light from the top-left corner.
        if let g = makeGrad([rgba(1, 1, 1, 0.30), rgba(1, 1, 1, 0)]) {
            let origin = CGPoint(x: tile.minX + side * 0.2, y: tile.maxY)
            ctx.drawRadialGradient(g, startCenter: origin, startRadius: 0,
                                   endCenter: origin, endRadius: side * 0.85, options: [])
        }

        // Glyph: viewfinder corners + record dot, lifted off the tile by a soft shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.035,
                      color: rgba(0.10, 0.04, 0.35, 0.45))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        let half = side * 0.27      // centre → outer edge of the viewfinder
        let arm = side * 0.15       // length of each bracket arm
        let radius = side * 0.075   // bracket corner rounding
        ctx.setStrokeColor(rgb(1, 1, 1))
        ctx.setLineWidth(side * 0.05)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (sx, sy) in [(-1.0, 1.0), (1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] as [(CGFloat, CGFloat)] {
            let corner = CGPoint(x: centre.x + sx * half, y: centre.y + sy * half)
            let armEndX = CGPoint(x: corner.x - sx * arm, y: corner.y)
            let armEndY = CGPoint(x: corner.x, y: corner.y - sy * arm)
            ctx.move(to: armEndX)
            ctx.addArc(tangent1End: corner, tangent2End: armEndY, radius: radius)
            ctx.addLine(to: armEndY)
        }
        ctx.strokePath()

        // Record dot, ringed in white so the red never touches the blue.
        let dotR = side * 0.115
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.fillEllipse(in: CGRect(x: centre.x - dotR, y: centre.y - dotR,
                                   width: dotR * 2, height: dotR * 2).insetBy(dx: -side * 0.03, dy: -side * 0.03))
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        if let g = makeGrad([rgb(1.00, 0.45, 0.40), rgb(0.93, 0.16, 0.27)]) {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: centre.x - dotR, y: centre.y - dotR,
                                      width: dotR * 2, height: dotR * 2))
            ctx.clip()
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: centre.x, y: centre.y + dotR),
                                   end: CGPoint(x: centre.x, y: centre.y - dotR), options: [])
            ctx.restoreGState()
        }

        // Rim light along the top edge (the outer half of the stroke is clipped away).
        if !fullBleed, let g = makeGrad([rgba(1, 1, 1, 0.45), rgba(1, 1, 1, 0)]) {
            ctx.setLineWidth(6 * u)
            ctx.addPath(tilePath)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: tile.midX, y: tile.maxY),
                                   end: CGPoint(x: tile.midX, y: tile.midY), options: [])
        }

        ctx.restoreGState() // end tile clip
    }

    // MARK: - Helpers

    /// Superellipse (|x|⁵ + |y|⁵ = 1) — a close match for the continuous-corner
    /// shape of macOS icons, which a plain rounded rect isn't.
    private static func squircle(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let n: CGFloat = 5
        let steps = 360
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
            let y = rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.closeSubpath()
        return path
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    private static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func makeGrad(_ colors: [CGColor]) -> CGGradient? {
        let n = colors.count
        let locs = (0..<n).map { CGFloat($0) / CGFloat(n - 1) }
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: locs)
    }
}
