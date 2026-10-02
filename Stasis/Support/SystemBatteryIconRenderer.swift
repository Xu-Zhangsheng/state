import AppKit
import ObjectiveC.runtime

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

    private typealias SharedImageCacheFunction = @convention(c) (
        AnyClass,
        Selector
    ) -> Unmanaged<AnyObject>?
    private typealias ModernBatteryImageFunction = @convention(c) (
        AnyObject,
        Selector,
        Double,
        Bool,
        Bool,
        Bool,
        Bool,
        Bool,
        Bool,
        Bool
    ) -> Unmanaged<AnyObject>?
    private struct SystemModernRenderer {
        let cache: AnyObject
        let selector: Selector
        let render: ModernBatteryImageFunction
    }

    private static let systemModernRenderer: SystemModernRenderer? = {
        let frameworkPath = "/System/Library/PrivateFrameworks/BatteryUIKit.framework"
        guard Bundle(path: frameworkPath)?.load() == true,
              let imageClass = NSClassFromString("BUIImage")
        else { return nil }

        let sharedSelector = NSSelectorFromString("sharedBUIImageCache")
        let imageSelector = NSSelectorFromString(
            "_modernBatteryImageForLevel:charging:pluggedIn:noBattery:needsReplacement:lowPowerMode:showPercentage:useRed:"
        )
        guard let sharedMethod = class_getClassMethod(imageClass, sharedSelector),
              let imageMethod = class_getInstanceMethod(imageClass, imageSelector),
              let typeEncoding = method_getTypeEncoding(imageMethod),
              String(cString: typeEncoding) == "@52@0:8d16B24B28B32B36B40B44B48"
        else { return nil }

        let sharedImageCache = unsafeBitCast(
            method_getImplementation(sharedMethod),
            to: SharedImageCacheFunction.self
        )
        guard let cache = sharedImageCache(imageClass, sharedSelector)?.takeUnretainedValue()
        else { return nil }

        return SystemModernRenderer(
            cache: cache,
            selector: imageSelector,
            render: unsafeBitCast(
                method_getImplementation(imageMethod),
                to: ModernBatteryImageFunction.self
            )
        )
    }()

    /// The classic Control Center artwork occupies its full 23pt width. Its
    /// separate 2pt terminal is attached immediately outside the body.
    private static let canvasSize = NSSize(width: 25, height: 14)
    private static let bodyFrame = NSRect(x: 0, y: 1, width: 23, height: 12)
    private static let capFrame = NSRect(x: 23, y: 1, width: 2, height: 12)
    private static let glyphFrame = NSRect(x: 6, y: 0, width: 11, height: 14)
    private static let fullFillFrame = NSRect(x: 2, y: 3, width: 19, height: 8)


    /// macOS 27's compact status item: the percentage sits inside the battery
    /// body and the unused capacity is the muted trailing portion. This is a
    /// single AppKit image so the status item cannot insert title spacing or a
    /// percent sign beside it.
    static func macOS27Image(
        level: Int,
        state: SystemBatteryIconState,
        isLowPowerModeEnabled: Bool,
        showState: Bool,
        showPercentage: Bool,
        isHighlighted: Bool,
        foregroundColor: NSColor
    ) -> NSImage {
        let clampedLevel = max(0, min(100, level))
        let tone = statusStateColor(
            state: state,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            showState: showState,
            level: clampedLevel
        ) ?? foregroundColor

        guard let frame = systemModernImage(
            level: clampedLevel,
            state: state,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            showState: showState,
            showPercentage: showPercentage
        ) else {
            if let classic = classicImage(
                level: clampedLevel,
                state: state,
                isLowPowerModeEnabled: isLowPowerModeEnabled,
                showState: showState,
                isHighlighted: isHighlighted,
                foregroundColor: foregroundColor
            ) {
                return classic
            }
            return fallbackImage(level: clampedLevel, state: state, showState: showState)
                ?? NSImage(size: canvasSize)
        }

        // Rasterise Apple's frame once. Its alpha carries the silhouette, the
        // digit shapes and the bolt; the RGB values it produces are discarded,
        // so the current appearance cannot tint the result.
        let scale = 2
        let pixelWidth = Int((frame.size.width * CGFloat(scale)).rounded())
        let pixelHeight = Int((frame.size.height * CGFloat(scale)).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ), context.data != nil
        else {
            return frame
        }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        frame.draw(in: NSRect(origin: .zero, size: frame.size))
        NSGraphicsContext.restoreGraphicsState()

        guard let raw = context.data else { return frame }
        let rowStride = context.bytesPerRow
        let samples = raw.bindMemory(to: UInt8.self, capacity: rowStride * pixelHeight)
        let pixelCount = pixelWidth * pixelHeight

        // Every pixel is painted with the frame's own alpha, scaled so the
        // charged capacity lands on Apple's brightness and what is left on
        // Apple's dimmer one. The digits and the bolt keep their intermediate
        // alpha, which is exactly how the system renders them - punching them
        // out or emboldening them made the glyph weight wrong.
        var coverage = [Double](repeating: 0, count: pixelCount)
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                coverage[y * pixelWidth + x] = Double(samples[y * rowStride + x * 4 + 3]) / 255.0
            }
        }

        // Flood fill the low-alpha space from the border: whatever cannot be
        // reached is inside the battery, i.e. the glyph area.
        var barrier = [Bool](repeating: false, count: pixelCount)
        for index in 0..<pixelCount { barrier[index] = coverage[index] >= 0.45 }
        var outside = [Bool](repeating: false, count: pixelCount)
        var queue: [Int] = []
        func enqueue(_ x: Int, _ y: Int) {
            let index = y * pixelWidth + x
            if !barrier[index], !outside[index] {
                outside[index] = true
                queue.append(index)
            }
        }
        for x in 0..<pixelWidth { enqueue(x, 0); enqueue(x, pixelHeight - 1) }
        for y in 0..<pixelHeight { enqueue(0, y); enqueue(pixelWidth - 1, y) }
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % pixelWidth
            let y = index / pixelWidth
            if x > 0 { enqueue(x - 1, y) }
            if x + 1 < pixelWidth { enqueue(x + 1, y) }
            if y > 0 { enqueue(x, y - 1) }
            if y + 1 < pixelHeight { enqueue(x, y + 1) }
        }

        // Fill the digits in solid; the bolt keeps the frame's own shape.
        let digitLimit = Int(Double(pixelWidth) * 0.46)
        for y in 0..<pixelHeight {
            for x in 0..<digitLimit {
                let index = y * pixelWidth + x
                if !outside[index] { coverage[index] = 0.84 }
            }
        }


        // Nudge the bolt to the right by translating only its own bounding box.
        // Transforming a whole column strip moved the charge boundary with it
        // and distorted the icon.
        var boltMinX = pixelWidth
        var boltMaxX = 0
        var boltMinY = pixelHeight
        var boltMaxY = 0
        for y in 0..<pixelHeight {
            for x in digitLimit..<pixelWidth {
                let index = y * pixelWidth + x
                if !outside[index], coverage[index] < 0.45 {
                    boltMinX = min(boltMinX, x)
                    boltMaxX = max(boltMaxX, x)
                    boltMinY = min(boltMinY, y)
                    boltMaxY = max(boltMaxY, y)
                }
            }
        }
        let boltShift = 2
        if boltMaxX > boltMinX, boltMaxY > boltMinY {
            let boxWidth = boltMaxX - boltMinX + 1
            let boxHeight = boltMaxY - boltMinY + 1
            var saved = [Double](repeating: 0, count: boxWidth * boxHeight)
            for y in boltMinY...boltMaxY {
                for x in boltMinX...boltMaxX {
                    saved[(y - boltMinY) * boxWidth + (x - boltMinX)] = coverage[y * pixelWidth + x]
                    coverage[y * pixelWidth + x] = 0.84
                }
            }
            for y in boltMinY...boltMaxY {
                for x in boltMinX...boltMaxX {
                    let nx = x + boltShift
                    guard nx < pixelWidth else { continue }
                    coverage[y * pixelWidth + nx] = saved[(y - boltMinY) * boxWidth + (x - boltMinX)]
                }
            }
        }

        // Reading redComponent from a colour outside an RGB space raises an
        // exception - NSColor.white is Generic Gray - so convert first.
        func rgb(_ color: NSColor) -> NSColor {
            color.usingColorSpace(.deviceRGB)
                ?? NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        }
        let chargedColor = rgb(tone)
        let remainingColor = rgb(foregroundColor)
        let chargedAlpha = 0.95
        let remainingAlpha = 0.45
        // The frame is 26pt wide; the battery body is the first 23pt.
        let boundary = Double(pixelWidth) * (23.0 / 26.0) * Double(clampedLevel) / 100.0
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let index = y * pixelWidth + x
                let byteIndex = y * rowStride + x * 4
                let isCharged = Double(x) < boundary
                let source = coverage[index]
                guard source > 0 else {
                    samples[byteIndex] = 0
                    samples[byteIndex + 1] = 0
                    samples[byteIndex + 2] = 0
                    samples[byteIndex + 3] = 0
                    continue
                }
                let normalised = isCharged ? min(1, source / 0.84) : min(1, source / 0.49)
                let level = (isCharged ? chargedAlpha : remainingAlpha) * normalised
                let color = isCharged ? chargedColor : remainingColor
                samples[byteIndex] = UInt8((color.redComponent * level * 255).rounded())
                samples[byteIndex + 1] = UInt8((color.greenComponent * level * 255).rounded())
                samples[byteIndex + 2] = UInt8((color.blueComponent * level * 255).rounded())
                samples[byteIndex + 3] = UInt8((level * 255).rounded())
            }
        }
        // Measure the digits in the frame itself and match that box, so the
        // size and position cannot drift from Apple's.
        var digitMinX = pixelWidth, digitMaxX = 0, digitMinY = pixelHeight, digitMaxY = 0
        for y in 0..<pixelHeight {
            for x in 0..<digitLimit {
                let index = y * pixelWidth + x
                if !outside[index], coverage[index] < 0.84 {
                    digitMinX = min(digitMinX, x)
                    digitMaxX = max(digitMaxX, x)
                    digitMinY = min(digitMinY, y)
                    digitMaxY = max(digitMaxY, y)
                }
            }
        }
        if digitMaxX <= digitMinX || digitMaxY <= digitMinY {
            digitMinX = 4
            digitMaxX = pixelWidth / 2
            digitMinY = 6
            digitMaxY = pixelHeight - 7
        }
        let digitBox = NSRect(
            x: CGFloat(digitMinX) / CGFloat(scale),
            y: (CGFloat(pixelHeight) - CGFloat(digitMaxY) - 1) / CGFloat(scale),
            width: CGFloat(digitMaxX - digitMinX + 1) / CGFloat(scale),
            height: CGFloat(digitMaxY - digitMinY + 1) / CGFloat(scale)
        )
        // SF Pro digit height is about 0.72 of the point size.
        let fontSize = max(6, digitBox.height / 0.80)
        let text = NSAttributedString(
            string: String(clampedLevel),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: NSColor.white,
            ]
        )
        let textSize = text.size()
        let centeredX = digitBox.midX - textSize.width / 2 + 2.0
        // The digits have to stay inside the charged region. Once the boundary
        // cuts through a glyph the part beyond it is punched out of the other
        // tone and the digit reads as clipped.
        let boundaryInPoints = CGFloat(boundary) / CGFloat(scale)
        let textOrigin = NSPoint(
            x: min(centeredX, boundaryInPoints - textSize.width - 1),
            y: digitBox.midY - textSize.height / 2 + 0.4
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        text.draw(at: textOrigin)
        NSGraphicsContext.restoreGraphicsState()

        guard let baked = context.makeImage() else { return frame }
        let representation = NSBitmapImageRep(cgImage: baked)
        representation.size = frame.size
        let image = NSImage(size: frame.size)
        image.addRepresentation(representation)
        image.isTemplate = false
        image.accessibilityDescription = String(localized: "Battery")
        return image
    }

    /// Returns the same dynamically composed image used by the macOS 27
    /// battery menu extra. No system artwork is copied into the app bundle;
    /// the framework is discovered at runtime and its ABI is checked before
    /// the private renderer is called.
    private static func systemModernImage(
        level: Int,
        state: SystemBatteryIconState,
        isLowPowerModeEnabled: Bool,
        showState: Bool,
        showPercentage: Bool
    ) -> NSImage? {
        guard let renderer = systemModernRenderer else { return nil }
        let shouldShowState = showState
        // charging and pluggedIn are separate inputs: the framework draws the
        // bolt for the first and the plug for the second. Passing charging for
        // both states meant a plugged-in battery that is not charging still
        // showed a bolt.
        let result = renderer.render(
            renderer.cache,
            renderer.selector,
            Double(level) / 100,
            shouldShowState && state == .charging,
            shouldShowState && state == .pluggedIn,
            false,
            false,
            shouldShowState && isLowPowerModeEnabled,
            showPercentage,
            shouldShowState && state == .discharging && level <= 20
        )?.takeUnretainedValue()
        return result as? NSImage
    }

    static func classicImage(
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

    /// The color macOS uses for the menu-bar battery glyph in each state.
    /// Returning nil keeps the frame a template so the status bar tints it.
    static func statusStateColor(
        state: SystemBatteryIconState,
        isLowPowerModeEnabled: Bool,
        showState: Bool,
        level: Int
    ) -> NSColor? {
        guard showState else { return nil }
        if isLowPowerModeEnabled { return .systemYellow }
        switch state {
        case .discharging where level <= 20: return .systemRed
        default: return nil
        }
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

    private static func contrastingTextColor(for background: NSColor) -> NSColor {
        guard let rgb = background.usingColorSpace(.deviceRGB) else { return .black }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.52 ? .black.withAlphaComponent(0.82) : .white
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
