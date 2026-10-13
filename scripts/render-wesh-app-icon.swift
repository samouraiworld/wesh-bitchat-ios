#!/usr/bin/env swift
import AppKit
import Foundation

// Independent native vector rendering of design/WeshAppIcon.svg.
// Run from the checkout with: swift -module-cache-path .validation/icon-module-cache scripts/render-wesh-app-icon.swift
let checkout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let points: [(CGFloat, CGFloat)] = [(220, 300), (356, 730), (512, 430), (668, 730), (804, 300)]
for setName in ["AppIcon", "AppIconDebug"] {
    let directory = checkout.appendingPathComponent("bitchat/Assets.xcassets/\(setName).appiconset")
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("Contents.json"))) as! [String: Any]
    for entry in manifest["images"] as! [[String: Any]] {
        guard let filename = entry["filename"] as? String, let size = entry["size"] as? String else { continue }
        let logicalSize = Double(size.split(separator: "x")[0])!
        let scale = Double((entry["scale"] as? String ?? "1x").dropLast())!
        let pixels = Int(logicalSize * scale)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setFillColor(CGColor(colorSpace: space, components: [30 / 255, 91 / 255, 184 / 255, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        context.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        context.setLineWidth(106); context.setLineCap(.round); context.setLineJoin(.round)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].0, y: 1024 - points[0].1))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: 1024 - point.1)) }
        context.addPath(path); context.strokePath()
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
print("Rendered independent Wesh vector app icons")
