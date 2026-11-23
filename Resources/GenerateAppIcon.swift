import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let iconSet = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((rgb >> 16) & 255) / 255,
        CGFloat((rgb >> 8) & 255) / 255,
        CGFloat(rgb & 255) / 255,
        alpha
    ])!
}

func circle(_ x: CGFloat, _ y: CGFloat, radius: CGFloat) -> CGRect {
    CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
}

func drawIcon(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)

    let plate = CGPath(
        roundedRect: CGRect(x: 88, y: 94, width: 848, height: 848),
        cornerWidth: 191, cornerHeight: 191, transform: nil
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -22), blur: 32, color: color(0x071324, alpha: 0.46))
    context.setFillColor(color(0x0D2032))
    context.addPath(plate)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(plate)
    context.clip()
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0x244B66), color(0x142D46), color(0x0B192B)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        background, start: CGPoint(x: 195, y: 930), end: CGPoint(x: 833, y: 80),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    let light = CGGradient(
        colorsSpace: colorSpace, colors: [color(0x6DDCCF, alpha: 0.12), color(0x6DDCCF, alpha: 0)] as CFArray,
        locations: nil
    )!
    context.drawRadialGradient(light, startCenter: CGPoint(x: 681, y: 718), startRadius: 10,
                               endCenter: CGPoint(x: 681, y: 718), endRadius: 491, options: [])
    context.setStrokeColor(color(0xD9EDFA, alpha: 0.20))
    context.setLineWidth(11)
    context.addPath(plate)
    context.strokePath()
    context.restoreGState()

    let muted = color(0x7796AA)
    let active = color(0x6AF4D9)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(muted)
    context.setLineWidth(50)
    context.move(to: CGPoint(x: 405, y: 515))
    context.addCurve(to: CGPoint(x: 668, y: 358),
                     control1: CGPoint(x: 531, y: 515), control2: CGPoint(x: 575, y: 358))
    context.addLine(to: CGPoint(x: 733, y: 358))
    context.strokePath()
    context.setFillColor(muted)
    context.fillEllipse(in: circle(733, 358, radius: 48))
    context.setFillColor(color(0x1C3951))
    context.fillEllipse(in: circle(733, 358, radius: 21))

    context.saveGState()
    context.setShadow(offset: .zero, blur: 19, color: color(0x42D6C3, alpha: 0.35))
    context.setStrokeColor(active)
    context.setLineWidth(54)
    context.move(to: CGPoint(x: 286, y: 515))
    context.addLine(to: CGPoint(x: 405, y: 515))
    context.addCurve(to: CGPoint(x: 668, y: 674),
                     control1: CGPoint(x: 531, y: 515), control2: CGPoint(x: 575, y: 674))
    context.addLine(to: CGPoint(x: 733, y: 674))
    context.strokePath()
    context.setFillColor(active)
    context.fillEllipse(in: circle(733, 674, radius: 55))
    context.fillEllipse(in: circle(286, 515, radius: 55))
    context.restoreGState()
    context.setFillColor(color(0xE3FFF6))
    context.fillEllipse(in: circle(733, 674, radius: 22))
    context.setFillColor(color(0x173950))
    context.fillEllipse(in: circle(286, 515, radius: 21))

    return context.makeImage()!
}

for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 2 ? "@2x" : ""
        let file = iconSet.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
        let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, drawIcon(size: base * factor), nil)
        precondition(CGImageDestinationFinalize(output))
    }
}
