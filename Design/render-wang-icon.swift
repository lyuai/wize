import AppKit
import Foundation
let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.17, alpha: 1).setFill()
bounds.fill()
// The source contains transparent margins; the graphic occupies the central area.
// Recolor only the source ink using its alpha, without redrawing the calligraphy.
let mask = NSImage(size: NSSize(width: 1024, height: 1024))
mask.lockFocus()
source.draw(in: CGRect(x: -8, y: 74, width: 1040, height: 876), from: .zero, operation: .sourceOver, fraction: 1)
NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.89, alpha: 1).setFill()
bounds.fill(using: .sourceIn)
mask.unlockFocus()
mask.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
