import AppKit

/// Renders the menu bar image. Normal signal uses the system "cellularbars" symbol with a
/// variable value (so it looks exactly like the phone-style indicator and follows the menu bar's
/// light/dark appearance as a template). Error states swap in a coloured symbol.
enum StatusIcon {
    static func image(for state: IconState) -> NSImage {
        switch state {
        case .bars(let n):
            return symbol("cellularbars", variable: Double(n) / 4.0, template: true, label: "\(n) of 4 bars")
        case .searching:
            return composite(base: symbol("cellularbars", variable: 0, template: false, color: .secondaryLabelColor),
                             badge: symbol("xmark", pointSize: 7, weight: .black, color: .systemRed),
                             label: "Starlink offline")
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
        case .notOnStarlink:
            return symbol("antenna.radiowaves.left.and.right.slash", template: true, label: "Not on Starlink")
        }
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

    private static func composite(base: NSImage, badge: NSImage, label: String) -> NSImage {
        let size = base.size
        let img = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let b = badge.size
            badge.draw(in: NSRect(x: 0, y: 0, width: b.width, height: b.height))
            return true
        }
        img.accessibilityDescription = label
        return img
    }
}
