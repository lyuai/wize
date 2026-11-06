import AppKit
import Foundation

// 用法：
//   swift Design/render-wang-icon.swift <source.png> <out.png> [背景色 #RRGGBB] [文字色 #RRGGBB]
// 默认颜色为深色背景 + 米白字形；传入浅色背景即可生成明亮模式的图标。

func color(_ hex: String) -> NSColor {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
        fatalError("颜色格式应为 #RRGGBB：\(hex)")
    }
    return NSColor(
        calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
        green: CGFloat((rgb >> 8) & 0xFF) / 255,
        blue: CGFloat(rgb & 0xFF) / 255,
        alpha: 1
    )
}

let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let outputPath = CommandLine.arguments[2]
let backgroundColor = CommandLine.arguments.count > 3
    ? color(CommandLine.arguments[3])
    : NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.17, alpha: 1)
let inkColor = CommandLine.arguments.count > 4
    ? color(CommandLine.arguments[4])
    : NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.89, alpha: 1)

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
let bounds = CGRect(x: 0, y: 0, width: 1024, height: 1024)
backgroundColor.setFill()
bounds.fill()
// The source contains transparent margins; the graphic occupies the central area.
// Recolor only the source ink using its alpha, without redrawing the calligraphy.
let mask = NSImage(size: NSSize(width: 1024, height: 1024))
mask.lockFocus()
source.draw(in: CGRect(x: -8, y: 74, width: 1040, height: 876), from: .zero, operation: .sourceOver, fraction: 1)
inkColor.setFill()
bounds.fill(using: .sourceIn)
mask.unlockFocus()
mask.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outputPath))
