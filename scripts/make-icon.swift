import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments[1]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// MARK: Squircle background (macOS icon grid: 824pt body on a 1024 canvas)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(color(0x0B2F6B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
ctx.drawLinearGradient(
    gradient([color(0x2FA6FF), color(0x1466D6), color(0x0A2F78)], [0, 0.55, 1]),
    start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
)
// Soft top-left highlight
ctx.drawRadialGradient(
    gradient([color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)]),
    startCenter: CGPoint(x: 300, y: 860), startRadius: 0,
    endCenter: CGPoint(x: 300, y: 860), endRadius: 560, options: []
)
// Subtle glow behind the device
ctx.drawRadialGradient(
    gradient([color(0x7FD0FF, 0.35), color(0x7FD0FF, 0)]),
    startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 470), endRadius: 380, options: []
)
ctx.restoreGState()

// Inner rim
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.18))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// MARK: Doorbell device
let device = CGRect(x: 367, y: 196, width: 290, height: 632)
let devicePath = CGPath(roundedRect: device, cornerWidth: 145, cornerHeight: 145, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 50, color: color(0x021335, 0.55))
ctx.addPath(devicePath)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(devicePath)
ctx.clip()
ctx.drawLinearGradient(
    gradient([color(0xFFFFFF), color(0xEEF3F9), color(0xCFDAE8)], [0, 0.5, 1]),
    start: CGPoint(x: 400, y: 828), end: CGPoint(x: 640, y: 196), options: []
)
// Edge shading on the right for depth
ctx.drawLinearGradient(
    gradient([color(0x000000, 0), color(0x0A2F78, 0.12)]),
    start: CGPoint(x: 560, y: 0), end: CGPoint(x: 657, y: 0), options: []
)
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: device.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 143, cornerHeight: 143, transform: nil))
ctx.setStrokeColor(color(0xFFFFFF, 0.9))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// MARK: Camera lens
let lensCenter = CGPoint(x: 512, y: 690)
func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

ctx.saveGState()
ctx.addEllipse(in: circle(lensCenter, 84))
ctx.setFillColor(color(0x1A2433))
ctx.fillPath()
ctx.addEllipse(in: circle(lensCenter, 84))
ctx.clip()
ctx.drawLinearGradient(
    gradient([color(0x2B3A50), color(0x0C121C)]),
    start: CGPoint(x: 0, y: lensCenter.y + 84), end: CGPoint(x: 0, y: lensCenter.y - 84), options: []
)
ctx.restoreGState()

ctx.saveGState()
ctx.addEllipse(in: circle(lensCenter, 54))
ctx.clip()
ctx.drawRadialGradient(
    gradient([color(0x2C6FD1), color(0x0B1B3A), color(0x05080F)], [0, 0.45, 1]),
    startCenter: CGPoint(x: lensCenter.x - 10, y: lensCenter.y + 10), startRadius: 0,
    endCenter: lensCenter, endRadius: 54, options: []
)
ctx.restoreGState()

ctx.setFillColor(color(0xFFFFFF, 0.85))
ctx.fillEllipse(in: circle(CGPoint(x: lensCenter.x - 20, y: lensCenter.y + 20), 12))
ctx.setFillColor(color(0xFFFFFF, 0.35))
ctx.fillEllipse(in: circle(CGPoint(x: lensCenter.x + 18, y: lensCenter.y - 16), 6))

// MARK: Motion sensor slit
ctx.setFillColor(color(0x0A2F78, 0.16))
ctx.addPath(CGPath(roundedRect: CGRect(x: 467, y: 555, width: 90, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil))
ctx.fillPath()

// MARK: Glowing ring button
let buttonCenter = CGPoint(x: 512, y: 372)

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: color(0x3DB4FF, 0.95))
ctx.addEllipse(in: circle(buttonCenter, 94))
ctx.setStrokeColor(color(0x3DB4FF))
ctx.setLineWidth(20)
ctx.strokePath()
ctx.restoreGState()

ctx.saveGState()
ctx.addEllipse(in: circle(buttonCenter, 94))
ctx.setStrokeColor(color(0xA9DEFF))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

ctx.saveGState()
ctx.addEllipse(in: circle(buttonCenter, 76))
ctx.clip()
ctx.drawLinearGradient(
    gradient([color(0xFFFFFF), color(0xDCE5F0)]),
    start: CGPoint(x: 0, y: buttonCenter.y + 76), end: CGPoint(x: 0, y: buttonCenter.y - 76), options: []
)
ctx.restoreGState()

ctx.saveGState()
ctx.addEllipse(in: circle(buttonCenter, 76))
ctx.setStrokeColor(color(0x0A2F78, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// MARK: Write PNG
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
