import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let variants: [(String, Int)] = [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)]
for (name, size) in variants {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    NSAffineTransform(scaleBy: scale).concat()
    let body = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 200, yRadius: 200)
    NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.14, alpha: 1).setFill(); body.fill()
    let colors = [NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.57, alpha: 1), NSColor(calibratedRed: 1, green: 0.40, blue: 0.42, alpha: 1)]
    for (index, center) in [CGPoint(x: 403,y: 549), CGPoint(x: 622,y: 458)].enumerated() {
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 185, y: center.y - 185, width: 370, height: 370))
        ring.lineWidth = 70; colors[index].setStroke(); ring.stroke()
    }
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 407, y: 370, width: 110, height: 85)).fill()
    NSBezierPath(roundedRect: NSRect(x: 487, y: 408, width: 30, height: 245), xRadius: 12, yRadius: 12).fill()
    let flag = NSBezierPath()
    flag.move(to: CGPoint(x: 502, y: 653)); flag.line(to: CGPoint(x: 627, y: 600))
    flag.line(to: CGPoint(x: 627, y: 540)); flag.line(to: CGPoint(x: 502, y: 593)); flag.close(); flag.fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(name).png"))
}

// ICNS supports PNG payloads for these modern icon types. Writing the container
// directly avoids invoking ImageIO's external converter during a sandboxed build.
let types = ["16x16":"icp4", "16x16@2x":"ic11", "32x32":"icp5", "32x32@2x":"ic12", "128x128":"ic07", "128x128@2x":"ic13", "256x256":"ic08", "256x256@2x":"ic14", "512x512":"ic09", "512x512@2x":"ic10"]
func integer(_ value: Int) -> Data {
    var encoded = UInt32(value).bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}
var chunks = Data()
for (name, _) in variants {
    let png = try Data(contentsOf: destination.appendingPathComponent("icon_\(name).png"))
    chunks.append(Data(types[name]!.utf8)); chunks.append(integer(png.count + 8)); chunks.append(png)
}
var icon = Data("icns".utf8); icon.append(integer(chunks.count + 8)); icon.append(chunks)
if CommandLine.arguments.count > 2 { try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }

extension NSAffineTransform {
    convenience init(scaleBy value: CGFloat) { self.init(); scale(by: value) }
}
