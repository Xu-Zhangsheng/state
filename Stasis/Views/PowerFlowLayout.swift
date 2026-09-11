import CoreGraphics

/// Deterministic geometry for the optional two-stage power-flow view.
///
/// Absolute watts control the total visible band thickness. Relative watts
/// only split that band between destinations. Keeping this calculation out of
/// SwiftUI makes the layout testable without opening the menu.
struct PowerFlowLayoutGeometry {
    let sourceX: CGFloat
    let sourceCenter: CGFloat
    let middleColumnX: CGFloat
    let middleRight: CGFloat
    let branchColumnX: CGFloat
    let batteryCenter: CGFloat
    let laptopCenter: CGFloat
    let batteryBand: CGFloat
    let systemBand: CGFloat
    let batteryNodeHeight: CGFloat
    let laptopNodeHeight: CGFloat
    let hasBatteryFlow: Bool
    let branchGap: CGFloat
    let branchCenters: [CGFloat]
    let branchNodeHeights: [CGFloat]
    let branchRoots: [CGFloat]
    let branchBands: [CGFloat]
}

enum PowerFlowLayout {
    static let referencePower = 100.0
    // Detailed flows were added after 0.2.2. Give them a substantial baseline
    // so low-watt readings remain legible while still growing with load.
    static let minimumBand: CGFloat = 18

    static func singleBandThickness(
        nodeHeight: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        min(max(0, nodeHeight), max(0, availableHeight))
    }

    static func standardTotalBand(availableHeight: CGFloat) -> CGFloat {
        min(56, max(1, availableHeight - 24))
    }

    static func standardFlowEdges(
        width: CGFloat,
        nodeWidth: CGFloat,
        gap: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        let safeGap = max(0, gap)
        return (
            min(width / 2, nodeWidth + safeGap),
            max(width / 2, width - nodeWidth - safeGap)
        )
    }

    static func detailed(
        size: CGSize,
        nodeWidth: CGFloat,
        middleColumnX: CGFloat,
        branchColumnX: CGFloat,
        batteryPower: Double,
        systemPower: Double,
        branchPowers: [Double]
    ) -> PowerFlowLayoutGeometry {
        let outerInset: CGFloat = 4
        let flowGap: CGFloat = 5
        let usableHeight = max(1, size.height - outerInset * 2)
        let hasBatteryFlow = batteryPower > 0.1
        let middleGap: CGFloat = hasBatteryFlow ? 5 : 0
        let positiveBatteryPower = hasBatteryFlow ? max(0, batteryPower) : 0
        let positiveSystemPower = max(0, systemPower)

        let middleHeights: [CGFloat]
        if hasBatteryFlow {
            middleHeights = nodeHeights(
                values: [positiveBatteryPower, positiveSystemPower],
                available: max(1, usableHeight - middleGap),
                minimum: 28
            )
        } else {
            middleHeights = [usableHeight]
        }

        let batteryNodeHeight = hasBatteryFlow ? middleHeights[0] : 0
        let laptopNodeHeight = hasBatteryFlow ? middleHeights[1] : middleHeights[0]
        let batteryCenter = hasBatteryFlow
            ? outerInset + batteryNodeHeight / 2
            : size.height / 2
        let laptopCenter = hasBatteryFlow
            ? outerInset + batteryNodeHeight + middleGap + laptopNodeHeight / 2
            : size.height / 2

        let maximumInputBand = max(minimumBand, usableHeight - 16)
        // Keep the 0.2.2 visual weight at low load, while allowing the total
        // tube thickness to communicate a real change in absolute watts.
        let inputPower = positiveBatteryPower + positiveSystemPower
        let rawInputBand = bandThickness(power: inputPower, maximum: maximumInputBand)

        var batteryBand: CGFloat = 0
        var systemBand: CGFloat
        if hasBatteryFlow, inputPower > 0 {
            batteryBand = rawInputBand * CGFloat(positiveBatteryPower / inputPower)
            systemBand = rawInputBand - batteryBand

            let batteryCapacity = max(1, batteryNodeHeight - 8)
            let systemCapacity = max(1, laptopNodeHeight - 8)
            let scale = min(
                1,
                batteryBand > 0 ? batteryCapacity / batteryBand : 1,
                systemBand > 0 ? systemCapacity / systemBand : 1
            )
            batteryBand *= scale
            systemBand *= scale
        } else {
            systemBand = min(rawInputBand, max(1, laptopNodeHeight - 8))
        }

        let branchCount = branchPowers.count
        let branchGap: CGFloat = branchCount >= 4 ? 3 : 4
        let branchNodeAvailable = max(
            1,
            usableHeight - CGFloat(max(0, branchCount - 1)) * branchGap
        )
        let branchNodeHeights = nodeHeights(
            values: branchPowers,
            available: branchNodeAvailable,
            minimum: 22
        )

        var branchCenters: [CGFloat] = []
        var nodeCursor = outerInset
        for height in branchNodeHeights {
            branchCenters.append(nodeCursor + height / 2)
            nodeCursor += height + branchGap
        }

        let branchTotalPower = branchPowers.reduce(0) { $0 + max(0, $1) }
        let representedFraction = positiveSystemPower > 0
            ? min(1, branchTotalPower / positiveSystemPower)
            : 0
        let desiredBranchBand = systemBand * CGFloat(representedFraction)
        let branchBands = constrainedBands(
            values: branchPowers,
            total: desiredBranchBand,
            minimum: 1.5,
            capacities: branchNodeHeights.map { max(1, $0 - 6) }
        )

        let branchBandTotal = branchBands.reduce(0, +)
        var branchRoots: [CGFloat] = []
        var bandCursor = laptopCenter - branchBandTotal / 2
        for band in branchBands {
            branchRoots.append(bandCursor)
            bandCursor += band
        }

        return PowerFlowLayoutGeometry(
            sourceX: nodeWidth + flowGap,
            sourceCenter: size.height / 2,
            middleColumnX: middleColumnX - flowGap,
            middleRight: middleColumnX + nodeWidth + flowGap,
            branchColumnX: branchColumnX - flowGap,
            batteryCenter: batteryCenter,
            laptopCenter: laptopCenter,
            batteryBand: batteryBand,
            systemBand: systemBand,
            batteryNodeHeight: batteryNodeHeight,
            laptopNodeHeight: laptopNodeHeight,
            hasBatteryFlow: hasBatteryFlow,
            branchGap: branchGap,
            branchCenters: branchCenters,
            branchNodeHeights: branchNodeHeights,
            branchRoots: branchRoots,
            branchBands: branchBands
        )
    }

    static func bandThickness(power: Double, maximum: CGFloat) -> CGFloat {
        guard maximum > 0 else { return 0 }
        let boundedMinimum = min(minimumBand, maximum)
        let ratio = min(1, max(0, power) / referencePower)
        return boundedMinimum + (maximum - boundedMinimum) * CGFloat(ratio)
    }

    private static func nodeHeights(
        values: [Double],
        available: CGFloat,
        minimum: CGFloat
    ) -> [CGFloat] {
        guard !values.isEmpty else { return [] }

        let count = CGFloat(values.count)
        let base = min(minimum, available / count)
        let remainder = max(0, available - base * count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else {
            return values.map { _ in available / count }
        }
        return values.map { value in
            base + remainder * CGFloat(max(0, value) / total)
        }
    }

    static func proportionalBands(
        values: [Double],
        total: CGFloat,
        minimum: CGFloat
    ) -> [CGFloat] {
        guard !values.isEmpty, total > 0 else {
            return values.map { _ in 0 }
        }

        let positiveCount = values.filter { $0 > 0 }.count
        guard positiveCount > 0 else { return values.map { _ in 0 } }

        let base = min(minimum, total / CGFloat(positiveCount))
        let remainder = max(0, total - base * CGFloat(positiveCount))
        let valueTotal = values.reduce(0) { $0 + max(0, $1) }
        return values.map { value in
            guard value > 0 else { return 0 }
            return base + remainder * CGFloat(value / valueTotal)
        }
    }

    static func constrainedBands(
        values: [Double],
        total: CGFloat,
        minimum: CGFloat,
        capacities: [CGFloat]
    ) -> [CGFloat] {
        var bands = proportionalBands(
            values: values,
            total: total,
            minimum: minimum
        )
        guard bands.count == capacities.count else { return bands }

        var scale: CGFloat = 1
        for index in bands.indices where bands[index] > 0 {
            scale = min(scale, max(0, capacities[index]) / bands[index])
        }
        if scale < 1 {
            bands = bands.map { $0 * scale }
        }
        return bands
    }
}
