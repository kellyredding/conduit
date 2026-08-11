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

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "placeholder-icon.png"

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

let indigo = NSColor(srgbRed: 0.227, green: 0.184, blue: 0.749, alpha: 1)
let violet = NSColor(srgbRed: 0.482, green: 0.247, blue: 0.894, alpha: 1)

// Top-left to bottom-right, matching the brief.
NSGradient(starting: indigo, ending: violet)?
    .draw(in: CGRect(x: 0, y: 0, width: size, height: size), angle: -45)

// The same symbol the menu bar draws for a live tunnel, so the Dock and the
// bar read as one tool rather than two.
if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
    let configured = bolt.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .medium)
    ) ?? bolt

    let drawn = configured.size
    let rect = CGRect(
        x: (size - drawn.width) / 2,
        y: (size - drawn.height) / 2,
        width: drawn.width,
        height: drawn.height
    )

    // Template fill: the symbol supplies the mask, white supplies the pixels.
    NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    configured.draw(in: rect)
    NSColor.white.setFill()
    rect.fill(using: .sourceAtop)
    NSGraphicsContext.current?.cgContext.endTransparencyLayer()
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode the image")
}
try data.write(to: URL(fileURLWithPath: output))
print("placeholder-icon: wrote \(output) (\(side)x\(side))")
