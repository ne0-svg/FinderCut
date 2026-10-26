import AppKit

// 生成「剪切助手」应用图标：macOS 圆角矩形 + 靛蓝渐变 + 白色剪刀 SF Symbol
// 用法: make_icon <输出1024PNG路径>

func tint(_ image: NSImage, color: NSColor) -> NSImage {
    let tinted = NSImage(size: image.size)
    tinted.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("无法创建图形上下文") }

// 圆角矩形（macOS 图标比例）
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let path = CGPath(roundedRect: rect, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()

let colorSpace = CGColorSpaceCreateDeviceRGB()

// 背景渐变：靛蓝 → 蓝
let bg = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 0.37, green: 0.45, blue: 0.99, alpha: 1),
    CGColor(red: 0.15, green: 0.32, blue: 0.93, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// 顶部高光
let gloss = CGGradient(colorsSpace: colorSpace, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: size * 0.42), options: [])

// 剪刀符号（白色 + 柔和阴影）
if let base = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: 600, weight: .medium)
    let symbol = base.withSymbolConfiguration(cfg) ?? base
    let glyph = tint(symbol, color: .white)
    let glyphBox = size * 0.54
    let aspect = glyph.size.width / max(glyph.size.height, 1)
    var w = glyphBox
    var h = glyphBox / aspect
    if h > glyphBox {
        h = glyphBox
        w = glyphBox * aspect
    }
    let drawRect = NSRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.32))
    glyph.draw(in: drawRect)
    ctx.restoreGState()
} else {
    print("警告：SF Symbol scissors 不可用")
}

ctx.restoreGState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG 转换失败") }

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("已生成 \(outPath)")
