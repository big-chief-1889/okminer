// Draws the 1024x1024 app icon.
// usage: swift app/make_icon.swift <out.png> [--linux]
// --linux draws a full-bleed square instead of the macOS rounded tile.
import AppKit

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let fullBleed = CommandLine.arguments.contains("--linux")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in top-left coordinates.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: 824pt rounded square centred on the 1024 canvas.
// Full-bleed blows that tile up to fill the whole canvas instead.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
if fullBleed {
    let scale = size / tile.width
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -tile.minX, y: -tile.minY)
}
let tilePath = CGPath(roundedRect: tile, cornerWidth: fullBleed ? 0 : 185,
                      cornerHeight: fullBleed ? 0 : 185, transform: nil)

if !fullBleed {
    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0xE9A56A))
    ctx.fillPath()
    ctx.restoreGState()
}

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

// Sky: dusty blue up high, wheat, then a hot orange at the horizon.
let sky = CGGradient(colorsSpace: cs,
                     colors: [rgb(0x6F97AE), rgb(0xC9B08F), rgb(0xF2C27E), rgb(0xEE8F55)] as CFArray,
                     locations: [0, 0.38, 0.62, 0.80])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

// Sun, sitting low and partly behind the far mesa.
let sunCenter = CGPoint(x: 640, y: 560)
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFE9C2, 0.75), rgb(0xFFE9C2, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: sunCenter, startRadius: 0, endCenter: sunCenter, endRadius: 260, options: [])
ctx.setFillColor(rgb(0xFFF1D6))
ctx.fillEllipse(in: CGRect(x: sunCenter.x - 105, y: sunCenter.y - 105, width: 210, height: 210))

func fill(_ points: [CGPoint], _ color: CGColor) {
    ctx.beginPath()
    ctx.addLines(between: points)
    ctx.closePath()
    ctx.setFillColor(color)
    ctx.fillPath()
}

// Far mesa: long flat top with talus slopes, in sun-lit clay.
let farTop = 598.0
let farMesa = [CGPoint(x: 60, y: 980), CGPoint(x: 60, y: 700), CGPoint(x: 330, y: 700), CGPoint(x: 372, y: farTop),
               CGPoint(x: 800, y: farTop), CGPoint(x: 838, y: 668), CGPoint(x: 900, y: 690), CGPoint(x: 980, y: 700),
               CGPoint(x: 980, y: 980)]
fill(farMesa, rgb(0xC9643A))
// Caprock and strata.
ctx.saveGState()
ctx.beginPath()
ctx.addLines(between: farMesa)
ctx.closePath()
ctx.clip()
ctx.setFillColor(rgb(0xE08A55))
ctx.fill(CGRect(x: 60, y: farTop, width: 920, height: 16))
ctx.setFillColor(rgb(0xB0512C))
for (y, h) in [(652.0, 10.0), (690.0, 8.0)] {
    ctx.fill(CGRect(x: 60, y: y, width: 920, height: h))
}
ctx.restoreGState()

// Near butte on the left, in deep red rock.
fill([CGPoint(x: 60, y: 980), CGPoint(x: 60, y: 690), CGPoint(x: 150, y: 690), CGPoint(x: 182, y: 640),
      CGPoint(x: 408, y: 640), CGPoint(x: 446, y: 724), CGPoint(x: 560, y: 760), CGPoint(x: 700, y: 772),
      CGPoint(x: 980, y: 780), CGPoint(x: 980, y: 980)], rgb(0x8E3524))
fill([CGPoint(x: 182, y: 640), CGPoint(x: 408, y: 640), CGPoint(x: 414, y: 654), CGPoint(x: 176, y: 654)],
     rgb(0xA8452C))

// Foreground plain in dark umber, with a gentle rise.
ctx.beginPath()
ctx.move(to: CGPoint(x: 60, y: 830))
ctx.addCurve(to: CGPoint(x: 980, y: 800), control1: CGPoint(x: 380, y: 790), control2: CGPoint(x: 700, y: 840))
ctx.addLine(to: CGPoint(x: 980, y: 980))
ctx.addLine(to: CGPoint(x: 60, y: 980))
ctx.closePath()
ctx.setFillColor(rgb(0x4A2A1C))
ctx.fillPath()

// Pumpjack. Mirrored (x' = 1330 - x) and scaled 1.45x around its base.
ctx.saveGState()
ctx.translateBy(x: 512, y: 868)
ctx.scaleBy(x: 1.45, y: 1.45)
ctx.translateBy(x: -663.5, y: -836)
ctx.translateBy(x: 1330, y: 0)
ctx.scaleBy(x: -1, y: 1)
let rig = rgb(0x2B1911)
ctx.setFillColor(rig)
ctx.setStrokeColor(rig)
ctx.setLineJoin(.round)

// Skid base.
ctx.fill(CGRect(x: 530, y: 816, width: 345, height: 20))

// Samson post (A-frame) up to the beam pivot.
let pivot = CGPoint(x: 690, y: 640)
ctx.setLineCap(.round)
ctx.setLineWidth(17)
ctx.strokeLineSegments(between: [CGPoint(x: 640, y: 818), pivot, CGPoint(x: 742, y: 818), pivot])
ctx.setLineWidth(9)
ctx.strokeLineSegments(between: [CGPoint(x: 658, y: 750), CGPoint(x: 724, y: 750)])

// Walking beam, tipped slightly (head end up).
ctx.setLineCap(.butt)
ctx.setLineWidth(26)
ctx.strokeLineSegments(between: [CGPoint(x: 505, y: 615), CGPoint(x: 845, y: 662)])

// Horsehead.
ctx.beginPath()
ctx.move(to: CGPoint(x: 540, y: 598))
ctx.addCurve(to: CGPoint(x: 462, y: 712), control1: CGPoint(x: 470, y: 600), control2: CGPoint(x: 445, y: 660))
ctx.addLine(to: CGPoint(x: 500, y: 716))
ctx.addCurve(to: CGPoint(x: 548, y: 632), control1: CGPoint(x: 492, y: 676), control2: CGPoint(x: 505, y: 640))
ctx.closePath()
ctx.fillPath()

// Bridle cable down to the wellhead.
ctx.setLineWidth(6)
ctx.strokeLineSegments(between: [CGPoint(x: 475, y: 712), CGPoint(x: 475, y: 804)])
ctx.fill(CGRect(x: 458, y: 798, width: 34, height: 38))

// Pitman arm, crank counterweight and gearbox at the tail end.
ctx.setLineWidth(13)
ctx.strokeLineSegments(between: [CGPoint(x: 838, y: 662), CGPoint(x: 800, y: 760)])
ctx.fillEllipse(in: CGRect(x: 758, y: 722, width: 84, height: 84))
ctx.fill(CGRect(x: 772, y: 770, width: 64, height: 48))
ctx.restoreGState()

// Top highlight.
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 420), options: [])
ctx.restoreGState()

// Hairline edge (macOS tile only).
if !fullBleed {
    ctx.addPath(tilePath)
    ctx.setStrokeColor(rgb(0x000000, 0.12))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
