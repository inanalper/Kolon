// Draws the DMG installer background: a Greek temple in the app icon's
// style with one column missing — the Applications alias sits in the gap,
// so installing Kolon literally completes the temple.
// The temple columns replicate the icon's column (chunky shaft, bronze
// capital with light diamonds, stepped base) at roughly icon size, so the
// dragged Kolon icon reads as the missing column.
// Usage: swift Scripts/dmg-background.swift <output.png> [scale]
// The Finder window is 720x440pt; render at scale 1 and 2 and combine with
// tiffutil -cathidpicheck for a retina-aware background.
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background@2x.png"

let W: CGFloat = 720, H: CGFloat = 440
let scale = CGFloat(CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 2)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.scaleBy(x: scale, y: scale)
// Flip so y grows downward — matches Finder's icon coordinates
cg.translateBy(x: 0, y: H)
cg.scaleBy(x: 1, y: -1)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// MARK: Palette (sampled from the app icon)
let tealTop = color(0x1E7D8C)
let tealBottom = color(0x0C3945)
let stoneLight = color(0xF4EEDF)
let stoneMid = color(0xE3D9C3)
let stoneDark = color(0xCBBD9F)
let bronze = color(0x8F8264)
let bronzeDark = color(0x6E6349)
let diamondLight = color(0xEDE5CE)

// MARK: Background gradient
let bgGradient = NSGradient(starting: tealTop, ending: tealBottom)!
bgGradient.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// Soft glow behind the temple
cg.saveGState()
let glowCenter = CGPoint(x: 424, y: 250)
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [color(0x2E93A3, 0.35).cgColor, color(0x2E93A3, 0).cgColor] as CFArray,
                      locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                      endCenter: glowCenter, endRadius: 300, options: [])
cg.restoreGState()

// MARK: Temple geometry — columns sized like the 100pt app icon's column
// Rightmost step edge must stay inside the 720pt canvas: templeRight + 48
let columnXs: [CGFloat] = [216, 320, 424, 528, 632]
let missingIndex = 3                      // gap where the Applications alias sits
let colTopY: CGFloat = 204
let colBottomY: CGFloat = 332             // top of the steps
let iconCenterY: CGFloat = 268            // vertical center of the column area

func stoneFill(_ rect: NSRect, radius: CGFloat = 0, angle: CGFloat = -90) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(starting: stoneLight, ending: stoneMid)!.draw(in: path, angle: angle)
}

// Drop shadow helper for stone parts
func withShadow(_ draw: () -> Void) {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -3), blur: 8,
                 color: NSColor.black.withAlphaComponent(0.35).cgColor)
    draw()
    cg.restoreGState()
}

// A row of the icon's faceted diamonds, alternating light/dark like the capital
func diamondRow(in rect: NSRect, count: Int, light: NSColor, dark: NSColor) {
    let step = rect.width / CGFloat(count)
    for i in 0..<count {
        let x = rect.minX + CGFloat(i) * step
        let d = NSBezierPath()
        d.move(to: NSPoint(x: x + step / 2, y: rect.minY + 1))
        d.line(to: NSPoint(x: x + step - 1, y: rect.midY))
        d.line(to: NSPoint(x: x + step / 2, y: rect.maxY - 1))
        d.line(to: NSPoint(x: x + 1, y: rect.midY))
        d.close()
        (i.isMultiple(of: 2) ? light : dark).setFill()
        d.fill()
    }
}

// MARK: Pediment (triangle) + entablature
let templeLeft: CGFloat = 180, templeRight: CGFloat = 668
withShadow {
    let pediment = NSBezierPath()
    pediment.move(to: NSPoint(x: 424, y: 122))
    pediment.line(to: NSPoint(x: templeRight, y: 168))
    pediment.line(to: NSPoint(x: templeLeft, y: 168))
    pediment.close()
    NSGradient(starting: stoneLight, ending: stoneMid)!.draw(in: pediment, angle: -90)
}
// Pediment inner triangle (tympanum), slightly darker
let tympanum = NSBezierPath()
tympanum.move(to: NSPoint(x: 424, y: 136))
tympanum.line(to: NSPoint(x: templeRight - 32, y: 162))
tympanum.line(to: NSPoint(x: templeLeft + 32, y: 162))
tympanum.close()
stoneDark.withAlphaComponent(0.5).setFill()
tympanum.fill()

// Architrave slab
withShadow { stoneFill(NSRect(x: templeLeft - 6, y: 168, width: (templeRight - templeLeft) + 12, height: 12)) }
// Frieze: bronze band with light diamonds, echoing the icon's capital
let frieze = NSRect(x: templeLeft, y: 180, width: templeRight - templeLeft, height: 14)
bronze.setFill()
NSBezierPath(rect: frieze).fill()
diamondRow(in: frieze.insetBy(dx: 6, dy: 1), count: 34, light: diamondLight, dark: diamondLight)
// Thin cornice between frieze and columns
stoneFill(NSRect(x: templeLeft - 4, y: 194, width: (templeRight - templeLeft) + 8, height: 10))

// MARK: Columns — proportions copied from the app icon
func drawColumn(centerX x: CGFloat) {
    withShadow {
        let h = colBottomY - colTopY   // 128
        // Abacus: cream slab on top
        stoneFill(NSRect(x: x - 33, y: colTopY, width: 66, height: 9), radius: 2)
        // Capital: bronze block with a row of 4 faceted diamonds
        let block = NSRect(x: x - 28, y: colTopY + 9, width: 56, height: 18)
        bronze.setFill()
        NSBezierPath(rect: block).fill()
        // All-light diamonds, exactly like the app icon's capital
        diamondRow(in: block.insetBy(dx: 2, dy: 1.5), count: 4, light: diamondLight, dark: diamondLight)
        // Chunky shaft with flutes
        let shaft = NSRect(x: x - 19, y: colTopY + 27, width: 38, height: h - 27 - 16)
        NSGradient(starting: stoneLight, ending: stoneMid)!.draw(in: NSBezierPath(rect: shaft), angle: 0)
        stoneDark.withAlphaComponent(0.6).setFill()
        for i in 1..<3 {
            NSBezierPath(rect: NSRect(x: shaft.minX + CGFloat(i) * shaft.width / 3 - 1,
                                      y: shaft.minY, width: 2, height: shaft.height)).fill()
        }
        // Stepped base, widening downward like the icon's
        stoneFill(NSRect(x: x - 25, y: colBottomY - 16, width: 50, height: 8), radius: 2)
        stoneFill(NSRect(x: x - 32, y: colBottomY - 8, width: 64, height: 8), radius: 2)
    }
}

for (i, x) in columnXs.enumerated() where i != missingIndex {
    drawColumn(centerX: x)
}

// MARK: Ghost column at the gap (dashed silhouette = "drop here")
do {
    let x = columnXs[missingIndex]
    let ghost = NSBezierPath(roundedRect: NSRect(x: x - 36, y: colTopY - 4,
                                                 width: 72, height: (colBottomY - colTopY) + 8),
                             xRadius: 8, yRadius: 8)
    ghost.setLineDash([7, 5], count: 2, phase: 0)
    ghost.lineWidth = 2.5
    NSColor.white.withAlphaComponent(0.55).setStroke()
    ghost.stroke()
    NSColor.white.withAlphaComponent(0.07).setFill()
    ghost.fill()
}

// MARK: Steps (stylobate)
withShadow {
    stoneFill(NSRect(x: templeLeft - 12, y: colBottomY, width: (templeRight - templeLeft) + 24, height: 13), radius: 2)
    stoneFill(NSRect(x: templeLeft - 30, y: colBottomY + 13, width: (templeRight - templeLeft) + 60, height: 13), radius: 2)
    stoneFill(NSRect(x: templeLeft - 48, y: colBottomY + 26, width: (templeRight - templeLeft) + 96, height: 13), radius: 2)
}

// MARK: Ground line under the whole scene
NSColor.black.withAlphaComponent(0.18).setFill()
NSBezierPath(rect: NSRect(x: 0, y: colBottomY + 39, width: W, height: H - colBottomY - 39)).fill()

// MARK: Ground shadow under the spot where the Kolon icon sits
do {
    let shadow = NSBezierPath(ovalIn: NSRect(x: 90 - 46, y: iconCenterY + 56, width: 92, height: 16))
    NSColor.black.withAlphaComponent(0.22).setFill()
    shadow.fill()
}

// MARK: Arrow from the Kolon icon spot to the gap
do {
    let from = NSPoint(x: 158, y: iconCenterY - 6)
    let to = NSPoint(x: columnXs[missingIndex] - 48, y: iconCenterY - 6)
    let arrow = NSBezierPath()
    arrow.move(to: from)
    arrow.curve(to: to, controlPoint1: NSPoint(x: from.x + 110, y: 236),
                controlPoint2: NSPoint(x: to.x - 110, y: 236))
    arrow.lineWidth = 3
    arrow.setLineDash([1, 8], count: 2, phase: 0)
    arrow.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.65).setStroke()
    arrow.stroke()
    // Arrowhead
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to.x - 12, y: to.y - 11))
    head.line(to: NSPoint(x: to.x + 2, y: to.y - 1))
    head.line(to: NSPoint(x: to.x - 15, y: to.y + 3))
    NSColor.white.withAlphaComponent(0.65).setFill()
    head.close()
    head.fill()
}

// MARK: Caption
do {
    let text = "Drag the column into place"
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.75),
    ]
    let size = text.size(withAttributes: attrs)
    // Text draws through Core Text, which ignores our manual flip — undo it
    // locally so the glyphs aren't mirrored
    cg.saveGState()
    cg.translateBy(x: 0, y: H)
    cg.scaleBy(x: 1, y: -1)
    text.draw(at: NSPoint(x: (W - size.width) / 2, y: H - 408 - size.height), withAttributes: attrs)
    cg.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("wrote \(outputPath) (\(Int(W * scale))x\(Int(H * scale)))")
