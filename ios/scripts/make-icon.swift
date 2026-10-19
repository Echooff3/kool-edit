// Makes the iOS app icon from the macOS one (src/bin/make-icon.rs renders
// a tiny Cool Edit window): cropped to the window so it fills the square,
// on the window's grey, with no transparency (iOS rounds the corners).
//
//   cargo run --release --bin make-icon -- /tmp/kool.iconset
//   swift ios/scripts/make-icon.swift /tmp/kool.iconset/icon_512x512@2x.png \
//       ios/KoolEdit/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    print("usage: make-icon.swift macos-icon-1024.png AppIcon.png")
    exit(1)
}
let size = 1024
// The window's outline in the 1024-px macOS icon.
let window = CGRect(x: 100, y: 100, width: 824, height: 824)
let scale = CGFloat(size) / window.width
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(srgbRed: 0xD4 / 255, green: 0xD0 / 255, blue: 0xC8 / 255, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: -window.minX * scale, y: -(1024 - window.maxY) * scale, width: 1024 * scale, height: 1024 * scale))
let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(out, context.makeImage()!, nil)
guard CGImageDestinationFinalize(out) else { exit(1) }
