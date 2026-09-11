import AppKit

enum SystemBatteryIconState: Hashable {
    case discharging
    case charging
    case pluggedIn
}

/// Composes the same assets used by macOS Control Center's Battery menu extra.
/// The outline, terminal, bolt, plug, and clearing masks are loaded from the
/// running system instead of being approximated with SF Symbols or custom paths.
@MainActor
enum SystemBatteryIconRenderer {
    private static let systemBundle = Bundle(
        path: "/System/Library/CoreServices/ControlCenter.app"
    )

    // Use Control Center's regular battery artwork. The small variant makes
    // the icon visibly undersized beside macOS status-bar items.
    private static let outline = systemImage(named: "battery-outline")
    private static let cap = systemImage(named: "battery-cap")
    private static let bolt = systemImage(named: "battery-bolt")
    private static let boltMask = systemImage(named: "battery-bolt-mask")
    private static let plug = systemImage(named: "battery-plug")
    private static let plugMask = systemImage(named: "battery-plug-mask")

    /// Control Center's outline occupies its full 23pt width. Its separate
    /// 2pt terminal is attached immediately outside the body at x=23.
    private static let canvasSize = NSSize(width: 25, height: 14)
    private static let bodyFrame = NSRect(x: 0, y: 1, width: 23, height: 12)
    private static let capFrame = NSRect(x: 23, y: 1, width: 2, height: 12)
    private static let glyphFrame = NSRect(x: 6, y: 0, width: 11, height: 14)
    private static let fullFillFrame = NSRect(x: 2, y: 3, width: 19, height: 8)

    static func image(
        level: Int,
        state: SystemBatteryIconState,
        isLowPowerModeEnabled: Bool,
        showState: Bool,
        isHighlighted: Bool,
        foregroundColor: NSColor
    ) -> NSImage? {
        guard let outline, let cap else {
            return fallbackImage(level: level, state: state, showState: showState)
        }

        let clampedLevel = max(0, min(100, level))
        let glyph: NSImage?
        let glyphMask: NSImage?
        if showState {
            switch state {
            case .charging:
                glyph = bolt
                glyphMask = boltMask
            case .pluggedIn:
                glyph = plug
                glyphMask = plugMask
            case .discharging:
                glyph = nil
                glyphMask = nil
            }
        } else {
            glyph = nil
            glyphMask = nil
        }

        let stateColor: NSColor? = if !showState {
            nil
        } else if isLowPowerModeEnabled {
            .systemYellow
        } else if state == .charging {
            .systemGreen
        } else if state == .discharging && clampedLevel <= 20 {
            .systemRed
        } else {
            nil
        }

        let outlineColor = isHighlighted ? NSColor.white : foregroundColor
        let fillColor = stateColor ?? outlineColor
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            if clampedLevel > 0 {
                let fillWidth = max(
                    1.5,
                    fullFillFrame.width * CGFloat(clampedLevel) / 100
                )
                fillColor.setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: fullFillFrame.minX,
                        y: fullFillFrame.minY,
                        width: fillWidth,
                        height: fullFillFrame.height
                    ),
                    xRadius: 2,
                    yRadius: 2
                ).fill()
            }

            tinted(outline, color: outlineColor).draw(in: bodyFrame)
            tinted(cap, color: outlineColor).draw(in: capFrame)

            if let glyphMask, let glyph {
                glyphMask.draw(
                    in: glyphFrame,
                    from: .zero,
                    operation: .destinationOut,
                    fraction: 1
                )
                tinted(glyph, color: outlineColor).draw(in: glyphFrame)
            }
            return true
        }

        // A monochrome result remains a template so NSStatusBarButton performs
        // the same wallpaper/highlight tinting as Apple's own menu extra.
        image.isTemplate = stateColor == nil
        image.accessibilityDescription = String(localized: "Battery")
        return image
    }

    private static func systemImage(named name: String) -> NSImage? {
        systemBundle?.image(forResource: NSImage.Name(name))
    }

    private static func tinted(_ source: NSImage, color: NSColor) -> NSImage {
        let image = NSImage(size: source.size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            source.draw(
                in: rect,
                from: .zero,
                operation: .destinationIn,
                fraction: 1
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func fallbackImage(
        level: Int,
        state: SystemBatteryIconState,
        showState: Bool
    ) -> NSImage? {
        let name = showState && state == .charging
            ? "battery.100percent.bolt"
            : "battery.100percent"
        let image = NSImage(
            systemSymbolName: name,
            variableValue: Double(max(0, min(100, level))) / 100,
            accessibilityDescription: String(localized: "Battery")
        )
        image?.isTemplate = true
        return image
    }
}
