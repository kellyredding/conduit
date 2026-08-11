#!/usr/bin/env swift
//
// placeholder-icon.swift — a stand-in icon source, drawn from the same symbol
// the menu bar uses.
//
//   swift scripts/placeholder-icon.swift out.png
//
// Exists so the application is never shipping a blank icon while a designed
// one is being made, and so the icon pipeline can be proven end to end before
// there is anything to run through it. Deliberately the same composition as
// the brief given to the illustrator — a white bolt on an indigo-to-violet
// diagonal — so replacing this with the real artwork changes the quality and
// not the identity.
//
// Full-bleed with square corners, exactly as make-appicon.sh expects: the
// rounded shape, the inset, and the shadow all belong to that script.

import AppKit

// out.png [topHex] [bottomHex] [inkHex] [symbolName]
let arguments = CommandLine.arguments
let output = arguments.count > 1 ? arguments[1] : "placeholder-icon.png"

func color(_ hex: String) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

let side = 1024
let size = CGFloat(side)

guard
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )
else { fatalError("could not allocate the bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let top = color(arguments.count > 2 ? arguments[2] : "#3A3A3C")
let bottom = color(arguments.count > 3 ? arguments[3] : "#1C1C1E")
let ink = color(arguments.count > 4 ? arguments[4] : "#FFFFFF")

// Top-left to bottom-right, matching the brief.
NSGradient(starting: top, ending: bottom)?
    .draw(in: CGRect(x: 0, y: 0, width: size, height: size), angle: -45)

// The same symbol the menu bar draws for a live tunnel, so the Dock and the
// bar read as one tool rather than two. Defaults to the connected glyph;
// pass another name to preview an alternative.
let symbolName = arguments.count > 5 ? arguments[5] : "bolt.horizontal.fill"

if let bolt = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
    let configured = bolt.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 512, weight: .medium)
    ) ?? bolt

    // Fitted by its larger dimension rather than by point size. A horizontal
    // glyph is wider than it is tall, so sizing by height alone would leave it
    // small and lost in the frame while a vertical one filled it.
    let drawn = configured.size
    let target = size * 0.58
    let scale = target / max(drawn.width, drawn.height)
    let fitted = CGSize(width: drawn.width * scale, height: drawn.height * scale)
    let rect = CGRect(
        x: (size - fitted.width) / 2,
        y: (size - fitted.height) / 2,
        width: fitted.width,
        height: fitted.height
    )

    // Template fill: the symbol supplies the mask, white supplies the pixels.
    NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    configured.draw(in: rect)
    ink.setFill()
    rect.fill(using: .sourceAtop)
    NSGraphicsContext.current?.cgContext.endTransparencyLayer()
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode the image")
}
try data.write(to: URL(fileURLWithPath: output))
print("placeholder-icon: wrote \(output) (\(side)x\(side))")
