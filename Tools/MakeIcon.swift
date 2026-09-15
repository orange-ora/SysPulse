import AppKit
import Foundation

// 生成 AppIcon.icns：用 Core Graphics 画一枚「脉搏波形」图标，再交给 iconutil 打包。
// 用法: swift Tools/MakeIcon.swift

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")

try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let inset = dimension * 0.06
    let rect = CGRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let radius = rect.width * 0.235

    // 圆角底 + 渐变
    let background = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(background)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.11, green: 0.13, blue: 0.20, alpha: 1),
            CGColor(red: 0.05, green: 0.06, blue: 0.10, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
    context.restoreGState()

    // 顶部高光
    context.saveGState()
    context.addPath(background)
    context.clip()
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 0.35),
            CGColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 0.0)
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: rect.midX, y: rect.maxY * 0.98),
        startRadius: 0,
        endCenter: CGPoint(x: rect.midX, y: rect.maxY * 0.98),
        endRadius: rect.width * 0.85,
        options: []
    )
    context.restoreGState()

    // 脉搏折线
    let points: [CGPoint] = [
        CGPoint(x: 0.16, y: 0.50),
        CGPoint(x: 0.32, y: 0.50),
        CGPoint(x: 0.40, y: 0.66),
        CGPoint(x: 0.50, y: 0.24),
        CGPoint(x: 0.60, y: 0.60),
        CGPoint(x: 0.68, y: 0.50),
        CGPoint(x: 0.84, y: 0.50)
    ]

    let path = CGMutablePath()
    for (index, point) in points.enumerated() {
        let scaled = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        if index == 0 { path.move(to: scaled) } else { path.addLine(to: scaled) }
    }

    context.saveGState()
    context.addPath(background)
    context.clip()
    context.setShadow(offset: .zero, blur: dimension * 0.06, color: CGColor(red: 0.30, green: 0.68, blue: 1, alpha: 0.9))
    context.setStrokeColor(CGColor(red: 0.42, green: 0.78, blue: 1, alpha: 1))
    context.setLineWidth(max(1, dimension * 0.055))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(path)
    context.strokePath()

    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    context.setLineWidth(max(1, dimension * 0.030))
    context.addPath(path)
    context.strokePath()
    context.restoreGState()

    guard let image = context.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = draw(size: size) else { continue }
    let name = size == 1024 ? "icon_512x512@2x.png" : "icon_\(size)x\(size).png"
    try data.write(to: iconset.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
try? fileManager.removeItem(at: iconset)
print("AppIcon.icns 生成完毕 (exit \(process.terminationStatus))")
