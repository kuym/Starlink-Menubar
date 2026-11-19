import AppKit

/// Renders the menu bar image. Signal strength (and no signal) is the app's own symbol: a Starlink dish on
/// its kickstand with the bars on its face, drawn from `Design/signal-icon.svg` (via `SignalIconShapes`) as a
/// vector template image, so it's sharp at any scale and follows the menu bar's appearance. Error states swap
/// in a coloured system symbol.
enum StatusIcon {
    static func image(for state: IconState) -> NSImage {
        switch state {
        case .bars(let n):
            return signal(bars: n, label: "Starlink: \(n) of 4 bars")
        case .searching:                         // the dish is there, but no service or connection yet
            return signal(bars: 0, label: "Starlink: no service")
        case .obstructed:
            return symbol("tree.fill", color: .systemOrange, label: "Starlink obstructed")
        case .misaligned:
            return symbol("scope", weight: .bold, color: .systemYellow, label: "Starlink misaligned")
        case .disabled:
            return symbol("person.crop.circle.badge.exclamationmark", color: .systemRed, label: "Starlink service disabled")
        case .hardwareFault(let key):
            return key.hasPrefix("thermal")
                ? symbol("thermometer.high", color: .systemRed, label: "Starlink thermal shutdown")
                : symbol("exclamationmark.triangle.fill", color: .systemRed, label: "Starlink hardware fault")
        case .notOnStarlink:                     // no dish found
            return signal(bars: nil, label: "No Starlink dish found")
        }
    }

    /// The dish symbol with `bars` of 4 bars lit (0: dish there, no service), or (nil) struck through: no dish.
    static func signal(bars: Int?, label: String) -> NSImage {
        let L = SignalIconShapes.layers
        let img = NSImage(size: SignalIconShapes.size, flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            func fill(_ id: String) {
                guard let layer = L[id] else { return }
                // A partly transparent layer is drawn whole, then faded, so its overlapping shapes don't darken.
                let faded = layer.opacity < 1
                if faded { cg.setAlpha(layer.opacity); cg.beginTransparencyLayer(auxiliaryInfo: nil) }
                for shape in layer.shapes {
                    let p = CGMutablePath()
                    for ring in shape.outlines { p.addLines(between: ring); p.closeSubpath() }
                    cg.addPath(p)
                    cg.fillPath(using: shape.evenOdd ? .evenOdd : .winding)
                }
                if faded { cg.endTransparencyLayer(); cg.setAlpha(1) }
            }
            cg.setFillColor(.black)
            fill("frame")
            fill("stand")
            if let bars {
                for i in 0..<max(0, min(4, bars)) { fill("bar-\(i + 1)") }
            } else {
                fill("none-edge")
                cg.setBlendMode(.clear)          // the gap round the slash
                fill("none-cut")
                cg.setBlendMode(.normal)
                fill("none-slash")
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = label
        return img
    }

    private static func symbol(_ name: String, variable: Double? = nil, pointSize: CGFloat = 14,
                               weight: NSFont.Weight = .regular, template: Bool = false,
                               color: NSColor? = nil, label: String? = nil) -> NSImage {
        let base = (variable.map { NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: label) }
                    ?? NSImage(systemSymbolName: name, accessibilityDescription: label))
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: label)!
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let color, !template { config = config.applying(.init(paletteColors: [color])) }
        let img = base.withSymbolConfiguration(config) ?? base
        img.isTemplate = template
        return img
    }
}
