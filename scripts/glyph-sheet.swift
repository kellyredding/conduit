#!/usr/bin/env swift
//
//  glyph-sheet.swift
//
//  Design-exploration tool. Renders a single PNG "option sheet" of candidate
//  menu-bar glyphs so a human can pick a glyph family and a color treatment.
//
//  Run:   swift scripts/glyph-sheet.swift
//  Out:   scripts/glyph-sheet.png  (written next to this file)
//
//  This is not part of the app. Nothing here ships. Edit `families` and
//  `treatments` below and re-run to explore a different option set.
//

import AppKit
import Foundation

// AppKit needs an application instance before symbol images and font metrics
// behave. This never shows UI; the process exits as soon as the PNG is written.
_ = NSApplication.shared

// ---------------------------------------------------------------------------
// MARK: - What gets rendered (edit this section)
// ---------------------------------------------------------------------------

/// The five icon states, in the order they appear as grid columns.
let states = ["idle", "connecting", "connected", "sensitive", "error"]

/// A candidate glyph family: one SF Symbol per state, in `states` order.
struct Family {
    let name: String
    let symbols: [String]

    init(_ name: String, _ symbols: [String]) {
        precondition(symbols.count == states.count, "\(name): needs \(states.count) symbols")
        self.name = name
        self.symbols = symbols
    }
}

let families: [Family] = [
    Family("shield", [
        "shield",
        "shield.lefthalf.filled",
        "shield.fill",
        "lock.shield.fill",
        "exclamationmark.shield.fill",
    ]),
    Family("lock", [
        "lock.open",
        "lock.rotation",
        "lock.fill",
        "lock.shield.fill",
        "lock.trianglebadge.exclamationmark.fill",
    ]),
    Family("network", [
        "network.slash",
        "network.badge.shield.half.filled",
        "network",
        "lock.shield.fill",
        "exclamationmark.triangle.fill",
    ]),
    Family("globe", [
        "globe",
        "globe.badge.chevron.backward",
        "globe.americas.fill",
        "globe.central.south.asia.fill",
        "exclamationmark.triangle.fill",
    ]),
    Family("circle", [
        "circle.dotted",
        "circle.dashed",
        "circle.fill",
        "circle.circle.fill",
        "exclamationmark.circle.fill",
    ]),
    Family("powerplug", [
        "powerplug",
        "powerplug.portrait",
        "powerplug.fill",
        "powerplug.portrait.fill",
        "bolt.trianglebadge.exclamationmark.fill",
    ]),
    Family("antenna", [
        "antenna.radiowaves.left.and.right.slash",
        "dot.radiowaves.left.and.right",
        "antenna.radiowaves.left.and.right",
        "antenna.radiowaves.left.and.right.circle.fill",
        "exclamationmark.triangle.fill",
    ]),
    Family("points", [
        "point.3.connected.trianglepath.dotted",
        "point.3.filled.connected.trianglepath.dotted",
        "point.3.filled.connected.trianglepath.dotted",
        "point.3.connected.trianglepath.dotted",
        "exclamationmark.triangle.fill",
    ]),
    Family("cable", [
        "cable.connector.horizontal",
        "cable.connector",
        "cable.connector.horizontal",
        "cable.connector",
        "exclamationmark.triangle.fill",
    ]),
    Family("bolt", [
        "bolt.horizontal",
        "bolt.horizontal.circle",
        "bolt.horizontal.fill",
        "bolt.shield.fill",
        "bolt.trianglebadge.exclamationmark.fill",
    ]),
]

/// Color treatments. Each maps a state index to a flat fill color.
enum Treatment: String, CaseIterable {
    /// Template rendering: one flat color for every state, taken from the
    /// panel's foreground. The conventional macOS menu-bar treatment.
    case mono
    /// Saturated per-state tint.
    case color
    /// Subtler per-state tint.
    case muted

    func fill(stateIndex: Int, onDark: Bool) -> NSColor {
        switch self {
        case .mono:
            return onDark ? .white : .labelColor
        case .color:
            let palette: [NSColor] = [
                .tertiaryLabelColor, .systemOrange, .systemGreen, .systemRed, .systemYellow,
            ]
            return palette[stateIndex]
        case .muted:
            let palette: [NSColor] = [
                .tertiaryLabelColor, .systemYellow, .systemTeal, .systemPurple, .systemOrange,
            ]
            return palette[stateIndex]
        }
    }
}

/// One stacked panel of the sheet: a treatment shown against one menu-bar tone.
struct Panel {
    let treatment: Treatment
    let onDark: Bool

    var title: String { "\(treatment.rawValue) — \(onDark ? "dark" : "light") menu bar" }
    var background: NSColor { onDark ? Ink.darkBar : Ink.lightBar }
    /// Color for labels and rules drawn on top of this panel's background.
    var chrome: NSColor { onDark ? Ink.chromeOnDark : Ink.chromeOnLight }
}

let panels: [Panel] = Treatment.allCases.flatMap { treatment in
    [Panel(treatment: treatment, onDark: false), Panel(treatment: treatment, onDark: true)]
}

/// Menu-bar glyph size. 18 pt at `.medium` weight is the real-world size.
let glyphPointSize: CGFloat = 18
let glyphWeight: NSFont.Weight = .medium

/// Device scale of the output PNG. The grid is drawn in points and multiplied
/// by this, so an 18 pt glyph lands at 54 px and reads clearly on screen.
let deviceScale: CGFloat = 3

// ---------------------------------------------------------------------------
// MARK: - Palette
// ---------------------------------------------------------------------------

enum Ink {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static let sheet = hex(0xFF_FFFF)
    static let lightBar = hex(0xF2_F2F2)
    static let darkBar = hex(0x1C_1C1E)
    static let chromeOnLight = hex(0x55_5558)
    static let chromeOnDark = hex(0xB4_B4B8)
    static let sheetText = hex(0x1A_1A1C)
    static let sheetMuted = hex(0x78_787D)
}

// ---------------------------------------------------------------------------
// MARK: - Layout metrics (points; multiply by `deviceScale` for pixels)
// ---------------------------------------------------------------------------

enum Metrics {
    static let margin: CGFloat = 24

    static let rowLabelWidth: CGFloat = 150
    static let cellWidth: CGFloat = 116
    static let rowHeight: CGFloat = 46
    static let columnHeaderHeight: CGFloat = 22

    static let sheetTitleHeight: CGFloat = 24
    static let sheetSubtitleHeight: CGFloat = 16
    static let gapAfterSheetHeader: CGFloat = 14

    static let stripTitleHeight: CGFloat = 16
    static let stripHeight: CGFloat = 60
    static let stripCaptionHeight: CGFloat = 14
    static let gapAfterStrip: CGFloat = 22

    static let panelTitleHeight: CGFloat = 18
    static let panelTitleGap: CGFloat = 6
    static let panelGap: CGFloat = 20

    static var contentWidth: CGFloat { rowLabelWidth + cellWidth * CGFloat(states.count) }
    static var panelBodyHeight: CGFloat { columnHeaderHeight + rowHeight * CGFloat(families.count) }
    static var panelHeight: CGFloat { panelTitleHeight + panelTitleGap + panelBodyHeight }

    static var sheetWidth: CGFloat { contentWidth + margin * 2 }
    static var sheetHeight: CGFloat {
        margin
            + sheetTitleHeight + sheetSubtitleHeight + gapAfterSheetHeader
            + stripTitleHeight + stripHeight + stripCaptionHeight + gapAfterStrip
            + panelHeight * CGFloat(panels.count)
            + panelGap * CGFloat(panels.count - 1)
            + margin
    }
}

enum Fonts {
    static let sheetTitle = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
    static let sheetSubtitle = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
    static let panelTitle = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
    static let columnHeader = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)
    static let rowLabel = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    static let stripLabel = NSFont.monospacedSystemFont(ofSize: 7.5, weight: .regular)
    static let caption = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
    static let placeholder = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
}

// ---------------------------------------------------------------------------
// MARK: - Symbol loading
// ---------------------------------------------------------------------------

let symbolConfiguration = NSImage.SymbolConfiguration(
    pointSize: glyphPointSize, weight: glyphWeight, scale: .medium
)

var symbolCache: [String: NSImage?] = [:]
var missingSymbols: Set<String> = []

/// Returns a configured symbol image, or nil if this machine does not have it.
func symbolImage(named name: String) -> NSImage? {
    if let cached = symbolCache[name] { return cached }

    let resolved: NSImage?
    if let base = NSImage(systemSymbolName: name, accessibilityDescription: name) {
        resolved = base.withSymbolConfiguration(symbolConfiguration) ?? base
    } else {
        resolved = nil
        missingSymbols.insert(name)
    }
    symbolCache[name] = resolved
    return resolved
}

// ---------------------------------------------------------------------------
// MARK: - Drawing helpers
//
// Everything below lays out top-down (y grows downward, origin top-left) and
// converts to AppKit's bottom-up coordinates at the last moment.
// ---------------------------------------------------------------------------

let sheetWidth = Metrics.sheetWidth
let sheetHeight = Metrics.sheetHeight

/// Top-down rect -> AppKit rect.
func rect(_ x: CGFloat, _ yFromTop: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: sheetHeight - yFromTop - height, width: width, height: height)
}

enum HAlign { case left, center, right }

func fill(_ r: NSRect, _ color: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    color.setFill()
    r.fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// Draws `text` vertically centered in `box`, aligned horizontally.
func drawText(
    _ text: String,
    in box: NSRect,
    font: NSFont,
    color: NSColor,
    align: HAlign = .left,
    inset: CGFloat = 0
) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (text as NSString).size(withAttributes: attributes)
    let x: CGFloat
    switch align {
    case .left: x = box.minX + inset
    case .center: x = box.midX - size.width / 2
    case .right: x = box.maxX - inset - size.width
    }
    let y = box.midY - size.height / 2
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
}

/// One device pixel, expressed in points.
let hairline: CGFloat = 1 / deviceScale

func drawHairline(x: CGFloat, yFromTop: CGFloat, width: CGFloat, color: NSColor, alpha: CGFloat) {
    fill(rect(x, yFromTop, width, hairline), color.withAlphaComponent(alpha))
}

func drawVerticalHairline(x: CGFloat, yFromTop: CGFloat, height: CGFloat, color: NSColor, alpha: CGFloat) {
    fill(rect(x, yFromTop, hairline, height), color.withAlphaComponent(alpha))
}

/// Flat-fills `image`'s shape with `color` inside `box`.
///
/// This is exactly what template rendering does: the symbol supplies the mask,
/// the color supplies every pixel. The image is drawn into a transparency layer
/// so a `.sourceAtop` fill can recolor it; the color's own alpha is applied to
/// the layer as a whole rather than blended over the symbol's default black.
func drawGlyph(_ image: NSImage, in box: NSRect, color: NSColor) {
    guard let context = NSGraphicsContext.current else { return }
    let resolved = color.usingColorSpace(.sRGB) ?? color
    let layerAlpha = resolved.alphaComponent
    let opaque = resolved.withAlphaComponent(1)
    // Pad so antialiased edges are not clipped by the transparency layer.
    let layerBox = box.insetBy(dx: -2, dy: -2)

    NSGraphicsContext.saveGraphicsState()
    let cg = context.cgContext
    cg.saveGState()
    cg.setAlpha(layerAlpha)
    cg.beginTransparencyLayer(in: layerBox, auxiliaryInfo: nil)
    image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
    opaque.setFill()
    layerBox.fill(using: .sourceAtop)
    cg.endTransparencyLayer()
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
}

/// Visible stand-in for a symbol this machine does not have.
func drawMissingPlaceholder(in box: NSRect, color: NSColor, font: NSFont = Fonts.placeholder) {
    drawText("—", in: box, font: font, color: color.withAlphaComponent(0.55), align: .center)
}

/// Runs `body` with `appearance` current, so dynamic colors such as
/// `labelColor` and `tertiaryLabelColor` resolve for the panel being drawn.
func withAppearance(dark: Bool, _ body: () -> Void) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    appearance.performAsCurrentDrawingAppearance(body)
}

/// Centers a rect of `size` inside `box`.
func centered(_ size: NSSize, in box: NSRect) -> NSRect {
    NSRect(
        x: (box.midX - size.width / 2).rounded(),
        y: (box.midY - size.height / 2).rounded(),
        width: size.width,
        height: size.height
    )
}

// ---------------------------------------------------------------------------
// MARK: - Sheet sections
// ---------------------------------------------------------------------------

/// Header: title plus a line describing how to read the sheet.
func drawSheetHeader(yFromTop: inout CGFloat) {
    let x = Metrics.margin
    let width = Metrics.contentWidth

    drawText(
        "menu-bar glyph option sheet",
        in: rect(x, yFromTop, width, Metrics.sheetTitleHeight),
        font: Fonts.sheetTitle,
        color: Ink.sheetText
    )
    yFromTop += Metrics.sheetTitleHeight

    let subtitle = "rows = glyph family · columns = state · glyphs drawn at "
        + "\(Int(glyphPointSize)) pt/.medium and rendered at \(Int(deviceScale))x "
        + "(\(Int(glyphPointSize * deviceScale)) px) · missing symbols show —"
    drawText(
        subtitle,
        in: rect(x, yFromTop, width, Metrics.sheetSubtitleHeight),
        font: Fonts.sheetSubtitle,
        color: Ink.sheetMuted
    )
    yFromTop += Metrics.sheetSubtitleHeight + Metrics.gapAfterSheetHeader
}

/// Reference strip: the `connected` glyph of every family at true 18 pt / 1x,
/// so the reviewer can judge real-world legibility, not just the blown-up grid.
func drawActualSizeStrip(yFromTop: inout CGFloat) {
    let x = Metrics.margin
    let width = Metrics.contentWidth
    let connectedIndex = states.firstIndex(of: "connected") ?? 0

    drawText(
        "actual size — state `connected`, every family, true \(Int(glyphPointSize)) pt / 1x",
        in: rect(x, yFromTop, width, Metrics.stripTitleHeight),
        font: Fonts.panelTitle,
        color: Ink.sheetText
    )
    yFromTop += Metrics.stripTitleHeight

    let box = rect(x, yFromTop, width, Metrics.stripHeight)
    fill(box, Ink.lightBar)

    let itemWidth = width / CGFloat(families.count)
    let glyphBandTop = yFromTop + 14
    let glyphBandHeight: CGFloat = 22
    let labelTop = glyphBandTop + glyphBandHeight + 4

    withAppearance(dark: false) {
        for (index, family) in families.enumerated() {
            let itemX = x + CGFloat(index) * itemWidth
            let glyphBox = rect(itemX, glyphBandTop, itemWidth, glyphBandHeight)

            if let image = symbolImage(named: family.symbols[connectedIndex]) {
                // Divide by the device scale so the glyph occupies its natural
                // point size in *pixels* — i.e. what a 1x menu bar shows.
                let actual = NSSize(
                    width: image.size.width / deviceScale,
                    height: image.size.height / deviceScale
                )
                drawGlyph(image, in: centered(actual, in: glyphBox), color: .labelColor)
            } else {
                drawMissingPlaceholder(
                    in: glyphBox,
                    color: Ink.chromeOnLight,
                    font: Fonts.stripLabel
                )
            }

            drawText(
                family.name,
                in: rect(itemX, labelTop, itemWidth, 12),
                font: Fonts.stripLabel,
                color: Ink.chromeOnLight,
                align: .center
            )
        }
    }

    yFromTop += Metrics.stripHeight

    drawText(
        "note: this strip is 1 image pixel per 1x point. On a Retina display at 100% zoom it "
            + "reads about half real size; view at 200% for true scale.",
        in: rect(x, yFromTop, width, Metrics.stripCaptionHeight),
        font: Fonts.caption,
        color: Ink.sheetMuted
    )
    yFromTop += Metrics.stripCaptionHeight + Metrics.gapAfterStrip
}

/// One treatment/tone panel: column headers across the top, one row per family.
func drawPanel(_ panel: Panel, yFromTop: inout CGFloat) {
    let x = Metrics.margin
    let width = Metrics.contentWidth

    drawText(
        panel.title,
        in: rect(x, yFromTop, width, Metrics.panelTitleHeight),
        font: Fonts.panelTitle,
        color: Ink.sheetText
    )
    yFromTop += Metrics.panelTitleHeight + Metrics.panelTitleGap

    let bodyTop = yFromTop
    fill(rect(x, bodyTop, width, Metrics.panelBodyHeight), panel.background)

    let chrome = panel.chrome
    let gridLeft = x + Metrics.rowLabelWidth

    withAppearance(dark: panel.onDark) {
        // Column headers.
        for (index, state) in states.enumerated() {
            let cellX = gridLeft + CGFloat(index) * Metrics.cellWidth
            drawText(
                state,
                in: rect(cellX, bodyTop, Metrics.cellWidth, Metrics.columnHeaderHeight),
                font: Fonts.columnHeader,
                color: chrome,
                align: .center
            )
        }
        drawText(
            "family",
            in: rect(x, bodyTop, Metrics.rowLabelWidth, Metrics.columnHeaderHeight),
            font: Fonts.columnHeader,
            color: chrome.withAlphaComponent(0.7),
            align: .right,
            inset: 12
        )
        drawHairline(
            x: x, yFromTop: bodyTop + Metrics.columnHeaderHeight,
            width: width, color: chrome, alpha: 0.28
        )
        drawVerticalHairline(
            x: gridLeft, yFromTop: bodyTop,
            height: Metrics.panelBodyHeight, color: chrome, alpha: 0.16
        )

        // Rows.
        for (rowIndex, family) in families.enumerated() {
            let rowTop = bodyTop + Metrics.columnHeaderHeight + CGFloat(rowIndex) * Metrics.rowHeight

            if rowIndex > 0 {
                drawHairline(x: x, yFromTop: rowTop, width: width, color: chrome, alpha: 0.10)
            }

            drawText(
                family.name,
                in: rect(x, rowTop, Metrics.rowLabelWidth, Metrics.rowHeight),
                font: Fonts.rowLabel,
                color: chrome,
                align: .right,
                inset: 12
            )

            for (stateIndex, symbolName) in family.symbols.enumerated() {
                let cell = rect(
                    gridLeft + CGFloat(stateIndex) * Metrics.cellWidth, rowTop,
                    Metrics.cellWidth, Metrics.rowHeight
                )
                guard let image = symbolImage(named: symbolName) else {
                    drawMissingPlaceholder(in: cell, color: chrome)
                    continue
                }
                let tint = panel.treatment.fill(stateIndex: stateIndex, onDark: panel.onDark)
                drawGlyph(image, in: centered(image.size, in: cell), color: tint)
            }
        }
    }

    yFromTop += Metrics.panelBodyHeight
}

// ---------------------------------------------------------------------------
// MARK: - Render
// ---------------------------------------------------------------------------

let pixelWidth = Int((sheetWidth * deviceScale).rounded())
let pixelHeight = Int((sheetHeight * deviceScale).rounded())

guard
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
else {
    FileHandle.standardError.write(Data("error: could not allocate bitmap\n".utf8))
    exit(1)
}

// Keep the rep 1:1 with its pixels so the context starts unscaled, then apply
// the device scale explicitly. All drawing above is therefore in points.
bitmap.size = NSSize(width: pixelWidth, height: pixelHeight)

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("error: could not create graphics context\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true
context.imageInterpolation = .high
context.cgContext.scaleBy(x: deviceScale, y: deviceScale)

fill(NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight), Ink.sheet)

var cursor = Metrics.margin
drawSheetHeader(yFromTop: &cursor)
drawActualSizeStrip(yFromTop: &cursor)
for (index, panel) in panels.enumerated() {
    drawPanel(panel, yFromTop: &cursor)
    if index < panels.count - 1 { cursor += Metrics.panelGap }
}

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

// ---------------------------------------------------------------------------
// MARK: - Write
// ---------------------------------------------------------------------------

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let outputURL = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("glyph-sheet.png")

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: PNG encoding failed\n".utf8))
    exit(1)
}

do {
    try png.write(to: outputURL)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

// ---------------------------------------------------------------------------
// MARK: - Run report
// ---------------------------------------------------------------------------

let uniqueSymbols = Set(families.flatMap(\.symbols))
print("wrote  \(outputURL.path)")
print("size   \(pixelWidth) x \(pixelHeight) px (\(Int(sheetWidth)) x \(Int(sheetHeight)) pt @ \(Int(deviceScale))x)")
print("bytes  \(png.count)")
print("grid   \(families.count) families x \(states.count) states x \(panels.count) panels")
print("symbols \(uniqueSymbols.count - missingSymbols.count)/\(uniqueSymbols.count) available")

if missingSymbols.isEmpty {
    print("missing none — every candidate symbol resolved on this machine")
} else {
    print("missing \(missingSymbols.count) symbol(s), rendered as —:")
    for name in missingSymbols.sorted() {
        let users = families.filter { $0.symbols.contains(name) }.map(\.name).joined(separator: ", ")
        print("  \(name)  (used by: \(users))")
    }
}
