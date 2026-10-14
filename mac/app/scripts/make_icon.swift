// Draws the PEAK (Modded) app icon (1024×1024 PNG) with CoreGraphics. Run on macOS:
//   swift scripts/make_icon.swift out/icon_1024.png
// Original artwork (no game assets): the macOS icon grid's rounded square, a navy night-sky gradient,
// a two-tone mountain with a snow cap, and a small orange pack crate, matching the Windows PeakPack icon.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])! }

// macOS icon grid: 824 pt body centred in 1024, corner radius ~185, soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(20, 32, 64)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
// Sky gradient (deep navy at top to dusk blue at the horizon).
let sky = CGGradient(colorsSpace: cs, colors: [rgb(14, 24, 52), rgb(33, 58, 112), rgb(72, 104, 160)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 300), options: [.drawsAfterEndLocation])
// A few stars.
for (x, y, r) in [(250.0, 800.0, 5.0), (330, 860, 3.5), (700, 830, 4.5), (790, 760, 3), (560, 880, 3), (420, 760, 2.5)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.setFillColor(rgb(255, 255, 255, 0.85)); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
// Back ridge.
ctx.beginPath()
ctx.move(to: CGPoint(x: 100, y: 330)); ctx.addLine(to: CGPoint(x: 300, y: 520)); ctx.addLine(to: CGPoint(x: 400, y: 450))
ctx.addLine(to: CGPoint(x: 560, y: 600)); ctx.addLine(to: CGPoint(x: 924, y: 380)); ctx.addLine(to: CGPoint(x: 924, y: 100)); ctx.addLine(to: CGPoint(x: 100, y: 100))
ctx.closePath(); ctx.setFillColor(rgb(46, 70, 118)); ctx.fillPath()
// Main peak: light face and shadow face.
let summit = CGPoint(x: 512, y: 760)
ctx.beginPath(); ctx.move(to: summit); ctx.addLine(to: CGPoint(x: 180, y: 220)); ctx.addLine(to: CGPoint(x: 512, y: 220)); ctx.closePath()
ctx.setFillColor(rgb(98, 124, 168)); ctx.fillPath()
ctx.beginPath(); ctx.move(to: summit); ctx.addLine(to: CGPoint(x: 512, y: 220)); ctx.addLine(to: CGPoint(x: 850, y: 220)); ctx.closePath()
ctx.setFillColor(rgb(62, 86, 132)); ctx.fillPath()
// Snow cap with a jagged lower edge.
ctx.beginPath(); ctx.move(to: summit)
ctx.addLine(to: CGPoint(x: 405, y: 588)); ctx.addLine(to: CGPoint(x: 452, y: 612)); ctx.addLine(to: CGPoint(x: 486, y: 575))
ctx.addLine(to: CGPoint(x: 512, y: 600)); ctx.closePath()
ctx.setFillColor(rgb(246, 249, 255)); ctx.fillPath()
ctx.beginPath(); ctx.move(to: summit)
ctx.addLine(to: CGPoint(x: 512, y: 600)); ctx.addLine(to: CGPoint(x: 548, y: 570)); ctx.addLine(to: CGPoint(x: 580, y: 605)); ctx.addLine(to: CGPoint(x: 622, y: 584))
ctx.closePath(); ctx.setFillColor(rgb(206, 218, 238)); ctx.fillPath()
// Foreground ground band.
ctx.setFillColor(rgb(24, 38, 72)); ctx.fill(CGRect(x: 100, y: 100, width: 824, height: 130))
ctx.restoreGState()

// The pack crate (PEAK-orange), bottom right, slightly overlapping the body edge like a badge.
let crate = CGRect(x: 600, y: 150, width: 250, height: 210)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0, 0, 0.35))
ctx.addPath(CGPath(roundedRect: crate, cornerWidth: 34, cornerHeight: 34, transform: nil))
ctx.setFillColor(rgb(242, 128, 36)); ctx.fillPath()
ctx.restoreGState()
// Lid band and straps.
ctx.setFillColor(rgb(255, 160, 72)); ctx.fill(CGRect(x: crate.minX + 10, y: crate.maxY - 62, width: crate.width - 20, height: 40))
ctx.setFillColor(rgb(196, 92, 18))
ctx.fill(CGRect(x: crate.minX + 62, y: crate.minY + 12, width: 26, height: crate.height - 24))
ctx.fill(CGRect(x: crate.maxX - 88, y: crate.minY + 12, width: 26, height: crate.height - 24))
// Buckle.
ctx.setFillColor(rgb(255, 236, 210)); ctx.fill(CGRect(x: crate.midX - 22, y: crate.maxY - 72, width: 44, height: 30))

guard let img = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: img)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
