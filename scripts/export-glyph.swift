#!/usr/bin/env swift
//
// export-glyph.swift — export one system symbol as reference artwork.
//
//   swift scripts/export-glyph.swift bolt.fill /tmp/glyph
//
// Writes a vector PDF plus PNGs on light and dark. The PDF is the accurate
// artefact; the PNGs exist because most tools that accept a "reference image"
// want pixels, and a shape described in words comes back wrong — a bolt is a
// family of shapes, and the one in the menu bar is a specific member of it.

import AppKit

let arguments = CommandLine.arguments
let symbolName = arguments.count > 1 ? arguments[1] : "bolt.fill"
let outputDirectory = arguments.count > 2 ? arguments[2] : "."

guard
    let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
else {
    FileHandle.standardError.write(Data("no such symbol: \(symbolName)\n".utf8))
    exit(1)
}

let configured = symbol.withSymbolConfiguration(
    NSImage.SymbolConfiguration(pointSize: 512, weight: .medium)
) ?? symbol

let drawn = configured.size
let side = max(drawn.width, drawn.height) * 1.25  // a little air around it
let box = CGRect(x: 0, y: 0, width: side, height: side)
let placement = CGRect(
    x: (side - drawn.width) / 2,
    y: (side - drawn.height) / 2,
    width: drawn.width,
    height: drawn.height
)

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

let base = symbolName.replacingOccurrences(of: ".", with: "-")

func draw(fill: NSColor) {
    NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    configured.draw(in: placement)
    fill.setFill()
    placement.fill(using: .sourceAtop)
    NSGraphicsContext.current?.cgContext.endTransparencyLayer()
}

// MARK: - PDF
//
// Drawn into a PDF context so the outline is preserved as curves rather than
// resampled into pixels, which is what makes it usable as a tracing reference
// at any size.

let pdfPath = "\(outputDirectory)/\(base).pdf"
var mediaBox = box
if let consumer = CGDataConsumer(url: URL(fileURLWithPath: pdfPath) as CFURL),
    let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
{
    pdf.beginPDFPage(nil)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
    draw(fill: .black)
    NSGraphicsContext.current = previous
    pdf.endPDFPage()
    pdf.closePDF()
    print("wrote \(pdfPath)")
}

// MARK: - PNGs

func png(named suffix: String, background: NSColor?, ink: NSColor, scale: CGFloat = 2) {
    let pixels = Int(side * scale)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
    else { return }

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = context
    context?.cgContext.scaleBy(x: scale, y: scale)

    if let background {
        background.setFill()
        box.fill()
    }
    draw(fill: ink)
    NSGraphicsContext.restoreGraphicsState()

    let path = "\(outputDirectory)/\(base)-\(suffix).png"
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(pixels)x\(pixels))")
    }
}

png(named: "black-on-white", background: .white, ink: .black)
png(named: "white-on-dark", background: NSColor(white: 0.11, alpha: 1), ink: .white)
png(named: "transparent", background: nil, ink: .black)
