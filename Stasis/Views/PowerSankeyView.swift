import AppKit
import SwiftUI

struct PowerSankeyView: View {
    let powerSource: PowerSource
    let isCharging: Bool
    let batteryPower: Double
    let adapterPower: Double
    let systemPower: Double
    let powerBreakdown: [PowerBreakdownItem]

    init(
        powerSource: PowerSource,
        isCharging: Bool,
        batteryPower: Double,
        adapterPower: Double,
        systemPower: Double,
        powerBreakdown: [PowerBreakdownItem] = []
    ) {
        self.powerSource = powerSource
        self.isCharging = isCharging
        self.batteryPower = batteryPower
        self.adapterPower = adapterPower
        self.systemPower = systemPower
        self.powerBreakdown = powerBreakdown
    }

    private enum Layout {
        static let nodeWidth: CGFloat = 56
        static let branchWidth: CGFloat = 56
        static let gap: CGFloat = 5
        static let simpleViewHeight: CGFloat = 64
        static let splitViewHeight: CGFloat = 104
        static let detailedViewHeight: CGFloat = 112
        static let compactNodeHeight: CGFloat = 52
        static let largeNodeHeight: CGFloat = 80
        static let splitNodeGap: CGFloat = 6
        static let outerInset: CGFloat = 4
        static let flowOpacity: Double = 0.15
    }

    var body: some View {
        if hasDetailedBreakdown {
            detailedBody
        } else {
            standardBody
        }
    }

    private var hasDetailedBreakdown: Bool {
        systemPower > 0.1 && !powerBreakdown.isEmpty
    }

    private var hasSplitFlow: Bool {
        powerSource == .acAdapter && batteryPower > 0.1
    }

    private var standardViewHeight: CGFloat {
        hasSplitFlow || powerSource == .both
            ? Layout.splitViewHeight
            : Layout.simpleViewHeight
    }

    private var standardBody: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    switch powerSource {
                    case .acAdapter where hasSplitFlow:
                        drawSplitSankeyFlow(
                            context: context,
                            size: canvasSize,
                            batteryPower: batteryPower,
                            systemPower: systemPower
                        )
                    case .both:
                        drawMergeSankeyFlow(
                            context: context,
                            size: canvasSize,
                            batteryPower: batteryPower,
                            adapterPower: adapterPower
                        )
                    case .battery:
                        drawSimpleFlow(
                            context: context,
                            size: canvasSize,
                            power: systemPower
                        )
                    case .acAdapter:
                        drawSimpleFlow(
                            context: context,
                            size: canvasSize,
                            power: max(adapterPower, systemPower)
                        )
                    }
                }

                standardNodes(in: size)
            }
        }
        .frame(height: standardViewHeight)
        .padding(.horizontal, StasisMenuMetrics.horizontalPadding)
        .padding(.vertical, StasisMenuMetrics.sectionSpacing)
    }

    /// A two-stage Sankey layout. Source and destination totals stay inside
    /// their nodes while third-level values sit on the individual branches.
    private var detailedBody: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let nodeWidth = Layout.nodeWidth
            let branchWidth = Layout.branchWidth
            let gap = Layout.gap
            let branchColumnX = max(nodeWidth * 2 + gap * 2, size.width - branchWidth)
            // Balance both transitions inside the native 300 pt menu. The
            // middle node needs enough separation from the source for the
            // five-point gaps to read as intentional rather than as a seam.
            let middleColumnX = max(
                nodeWidth + 12,
                min(nodeWidth + 44, branchColumnX - nodeWidth - 40)
            )
            let flowGeometry = makeDetailedFlowGeometry(
                size: size,
                nodeWidth: nodeWidth,
                middleColumnX: middleColumnX,
                branchColumnX: branchColumnX
            )

            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    if powerSource == .both {
                        drawDetailedMergeFlows(
                            context: context,
                            size: canvasSize,
                            geometry: flowGeometry
                        )
                    } else {
                        drawDetailedFlows(
                            context: context,
                            geometry: flowGeometry
                        )
                    }
                }

                if powerSource == .both {
                    detailedMergeSourceNodes(size: size, nodeWidth: nodeWidth)
                } else {
                    NodeView(
                        icon: detailedSourceIcon,
                        value: detailedSourcePower,
                        isLeftSide: true
                    )
                    .frame(width: nodeWidth, height: size.height - 8)
                    .position(x: nodeWidth / 2, y: size.height / 2)

                    if flowGeometry.hasBatteryFlow {
                        NodeView(
                            icon: isCharging ? "battery.100.bolt" : "battery.100",
                            value: batteryPower,
                            isLeftSide: false
                        )
                        .frame(
                            width: nodeWidth,
                            height: flowGeometry.batteryNodeHeight
                        )
                        .position(
                            x: middleColumnX + nodeWidth / 2,
                            y: flowGeometry.batteryCenter
                        )
                        .help(PowerFormatter.string(batteryPower))
                    }
                }

                NodeView(
                    icon: "laptopcomputer",
                    value: systemPower,
                    isLeftSide: false
                )
                .frame(
                    width: nodeWidth,
                    height: flowGeometry.laptopNodeHeight
                )
                .position(
                    x: middleColumnX + nodeWidth / 2,
                    y: flowGeometry.laptopCenter
                )
                .help(PowerFormatter.string(systemPower))

                ForEach(Array(powerBreakdown.enumerated()), id: \.element.id) { index, item in
                    if index < flowGeometry.branchCenters.count {
                        PowerBreakdownNode(item: item)
                            .frame(
                                width: branchWidth,
                                height: flowGeometry.branchNodeHeights[index]
                            )
                            .position(
                                x: branchColumnX + branchWidth / 2,
                                y: flowGeometry.branchCenters[index]
                            )
                    }
                }

                detailedFlowLabels(flowGeometry)
            }
        }
        .frame(height: Layout.detailedViewHeight)
        .padding(.horizontal, StasisMenuMetrics.horizontalPadding)
        .padding(.vertical, StasisMenuMetrics.sectionSpacing)
    }

    @ViewBuilder
    private func standardNodes(in size: CGSize) -> some View {
        let nodeWidth = Layout.nodeWidth
        let leftX = nodeWidth / 2
        let rightX = size.width - nodeWidth / 2
        let compactHeight = min(Layout.compactNodeHeight, size.height - 8)
        let metrics = standardSplitMetrics(size: size)

        switch powerSource {
        case .acAdapter where hasSplitFlow:
            NodeView(
                icon: isCharging ? "bolt.fill" : "powerplug.fill",
                value: adapterPower,
                isLeftSide: true,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: metrics.largeHeight)
            .position(x: leftX, y: size.height / 2)
            .help(PowerFormatter.string(adapterPower))

            NodeView(
                icon: isCharging ? "battery.100.bolt" : "battery.100",
                value: batteryPower,
                isLeftSide: false,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: metrics.smallHeight)
            .position(x: rightX, y: metrics.topCenter)
            .help(PowerFormatter.string(batteryPower))

            NodeView(
                icon: "laptopcomputer",
                value: systemPower,
                isLeftSide: false,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: metrics.smallHeight)
            .position(x: rightX, y: metrics.bottomCenter)
            .help(PowerFormatter.string(systemPower))

        case .both:
            NodeView(
                icon: "battery.100",
                value: abs(batteryPower),
                isLeftSide: true,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: metrics.smallHeight)
            .position(x: leftX, y: metrics.topCenter)
            .help(PowerFormatter.string(abs(batteryPower)))

            NodeView(
                icon: "powerplug.fill",
                value: adapterPower,
                isLeftSide: true,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: metrics.smallHeight)
            .position(x: leftX, y: metrics.bottomCenter)
            .help(PowerFormatter.string(adapterPower))

            NodeView(
                icon: "laptopcomputer",
                value: systemPower,
                isLeftSide: false,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: metrics.largeHeight)
            .position(x: rightX, y: size.height / 2)
            .help(PowerFormatter.string(systemPower))

        case .acAdapter:
            NodeView(
                icon: "powerplug.fill",
                value: max(adapterPower, systemPower),
                isLeftSide: true,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: compactHeight)
            .position(x: leftX, y: size.height / 2)

            NodeView(
                icon: "laptopcomputer",
                value: systemPower,
                isLeftSide: false,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: compactHeight)
            .position(x: rightX, y: size.height / 2)

        case .battery:
            NodeView(
                icon: "battery.100",
                value: max(abs(batteryPower), systemPower),
                isLeftSide: true,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: compactHeight)
            .position(x: leftX, y: size.height / 2)

            NodeView(
                icon: "laptopcomputer",
                value: systemPower,
                isLeftSide: false,
                width: nodeWidth
            )
            .frame(width: nodeWidth, height: compactHeight)
            .position(x: rightX, y: size.height / 2)
        }
    }

    private func standardSplitMetrics(size: CGSize) -> (
        smallHeight: CGFloat,
        largeHeight: CGFloat,
        topCenter: CGFloat,
        bottomCenter: CGFloat
    ) {
        let available = max(1, size.height - Layout.outerInset * 2)
        let smallHeight = max(1, (available - Layout.splitNodeGap) / 2)
        return (
            smallHeight,
            min(Layout.largeNodeHeight, available),
            Layout.outerInset + smallHeight / 2,
            Layout.outerInset + smallHeight + Layout.splitNodeGap + smallHeight / 2
        )
    }

    private func drawMergeSankeyFlow(
        context: GraphicsContext,
        size: CGSize,
        batteryPower: Double,
        adapterPower: Double
    ) {
        let edges = PowerFlowLayout.standardFlowEdges(
            width: size.width,
            nodeWidth: Layout.nodeWidth,
            gap: Layout.gap
        )
        let leftX = edges.left
        let rightX = edges.right
        let metrics = standardSplitMetrics(size: size)
        let bands = standardFlowBands(
            values: [abs(batteryPower), max(0, adapterPower)],
            size: size
        )
        let batteryBand = bands[0]
        let adapterBand = bands[1]
        let outputBand = batteryBand + adapterBand
        let outputTop = size.height / 2 - outputBand / 2
        let outputBottom = size.height / 2 + outputBand / 2

        drawTube(
            context: context,
            topLeft: CGPoint(x: leftX, y: metrics.topCenter - batteryBand / 2),
            bottomLeft: CGPoint(x: leftX, y: metrics.topCenter + batteryBand / 2),
            topRight: CGPoint(
                x: rightX,
                y: outputTop
            ),
            bottomRight: CGPoint(x: rightX, y: outputTop + batteryBand)
        )

        drawTube(
            context: context,
            topLeft: CGPoint(x: leftX, y: metrics.bottomCenter - adapterBand / 2),
            bottomLeft: CGPoint(x: leftX, y: metrics.bottomCenter + adapterBand / 2),
            topRight: CGPoint(x: rightX, y: outputTop + batteryBand),
            bottomRight: CGPoint(
                x: rightX,
                y: outputBottom
            )
        )
    }

    private func drawSplitSankeyFlow(
        context: GraphicsContext,
        size: CGSize,
        batteryPower: Double,
        systemPower: Double
    ) {
        let edges = PowerFlowLayout.standardFlowEdges(
            width: size.width,
            nodeWidth: Layout.nodeWidth,
            gap: Layout.gap
        )
        let leftX = edges.left
        let rightX = edges.right
        let metrics = standardSplitMetrics(size: size)
        let bands = standardFlowBands(
            values: [max(0, batteryPower), max(0, systemPower)],
            size: size
        )
        let batteryBand = bands[0]
        let systemBand = bands[1]
        let sourceTop = size.height / 2 - (batteryBand + systemBand) / 2
        let sourceBatteryBottom = sourceTop + batteryBand
        let sourceBottom = sourceBatteryBottom + systemBand

        drawTube(
            context: context,
            topLeft: CGPoint(
                x: leftX,
                y: sourceTop
            ),
            bottomLeft: CGPoint(x: leftX, y: sourceBatteryBottom),
            topRight: CGPoint(x: rightX, y: metrics.topCenter - batteryBand / 2),
            bottomRight: CGPoint(x: rightX, y: metrics.topCenter + batteryBand / 2)
        )

        drawTube(
            context: context,
            topLeft: CGPoint(x: leftX, y: sourceBatteryBottom),
            bottomLeft: CGPoint(
                x: leftX,
                y: sourceBottom
            ),
            topRight: CGPoint(x: rightX, y: metrics.bottomCenter - systemBand / 2),
            bottomRight: CGPoint(x: rightX, y: metrics.bottomCenter + systemBand / 2)
        )
    }

    private func drawSimpleFlow(
        context: GraphicsContext,
        size: CGSize,
        power: Double
    ) {
        let edges = PowerFlowLayout.standardFlowEdges(
            width: size.width,
            nodeWidth: Layout.nodeWidth,
            gap: Layout.gap
        )
        let leftX = edges.left
        let rightX = edges.right
        let maximumBand = PowerFlowLayout.singleBandThickness(
            nodeHeight: Layout.compactNodeHeight,
            availableHeight: size.height - 8
        )
        let band = PowerFlowLayout.bandThickness(power: power, maximum: maximumBand)
        let top = size.height / 2 - band / 2
        let bottom = size.height / 2 + band / 2

        drawTube(
            context: context,
            topLeft: CGPoint(x: leftX, y: top),
            bottomLeft: CGPoint(x: leftX, y: bottom),
            topRight: CGPoint(x: rightX, y: top),
            bottomRight: CGPoint(x: rightX, y: bottom)
        )
    }

    private func standardFlowBands(
        values: [Double],
        size: CGSize
    ) -> [CGFloat] {
        guard !values.isEmpty else { return [] }
        // The total reacts to absolute load; individual branches divide that
        // total proportionally. A substantial floor prevents low-watt flows
        // from collapsing into hairlines.
        let maximumBand = PowerFlowLayout.standardTotalBand(
            availableHeight: size.height
        )
        let totalPower = values.reduce(0) { $0 + max(0, $1) }
        let totalBand = PowerFlowLayout.bandThickness(power: totalPower, maximum: maximumBand)
        var bands = PowerFlowLayout.proportionalBands(
            values: values,
            total: totalBand,
            minimum: 2
        )
        let metrics = standardSplitMetrics(size: size)
        let capacity = max(1, metrics.smallHeight - 10)
        var scale: CGFloat = 1
        for band in bands where band > 0 {
            scale = min(scale, capacity / band)
        }
        if scale < 1 {
            bands = bands.map { $0 * scale }
        }
        return bands
    }

    private func makeDetailedFlowGeometry(
        size: CGSize,
        nodeWidth: CGFloat,
        middleColumnX: CGFloat,
        branchColumnX: CGFloat
    ) -> PowerFlowLayoutGeometry {
        PowerFlowLayout.detailed(
            size: size,
            nodeWidth: nodeWidth,
            middleColumnX: middleColumnX,
            branchColumnX: branchColumnX,
            batteryPower: powerSource == .acAdapter ? max(0, batteryPower) : 0,
            systemPower: systemPower,
            branchPowers: powerBreakdown.map(\.power)
        )
    }

    @ViewBuilder
    private func detailedMergeSourceNodes(
        size: CGSize,
        nodeWidth: CGFloat
    ) -> some View {
        let metrics = detailedMergeSourceMetrics(size: size)

        NodeView(
            icon: "battery.100",
            value: abs(batteryPower),
            isLeftSide: true,
            width: nodeWidth
        )
        .frame(width: nodeWidth, height: metrics.nodeHeight)
        .position(x: nodeWidth / 2, y: metrics.topCenter)

        NodeView(
            icon: "powerplug.fill",
            value: max(0, adapterPower),
            isLeftSide: true,
            width: nodeWidth
        )
        .frame(width: nodeWidth, height: metrics.nodeHeight)
        .position(x: nodeWidth / 2, y: metrics.bottomCenter)
    }

    private func detailedMergeSourceMetrics(size: CGSize) -> (
        nodeHeight: CGFloat,
        topCenter: CGFloat,
        bottomCenter: CGFloat
    ) {
        let available = max(1, size.height - Layout.outerInset * 2)
        let nodeHeight = max(1, (available - Layout.splitNodeGap) / 2)
        return (
            nodeHeight,
            Layout.outerInset + nodeHeight / 2,
            Layout.outerInset
                + nodeHeight
                + Layout.splitNodeGap
                + nodeHeight / 2
        )
    }

    private var detailedSourceIcon: String {
        switch powerSource {
        case .battery:
            "battery.100"
        case .acAdapter:
            isCharging ? "bolt.fill" : "powerplug.fill"
        case .both:
            "bolt.fill"
        }
    }

    private var detailedSourcePower: Double {
        switch powerSource {
        case .battery:
            max(abs(batteryPower), systemPower)
        case .acAdapter:
            abs(adapterPower)
        case .both:
            max(0, adapterPower) + abs(min(0, batteryPower))
        }
    }

    private func drawDetailedFlows(
        context: GraphicsContext,
        geometry: PowerFlowLayoutGeometry
    ) {
        let flowColor = Color.primary.opacity(Layout.flowOpacity)
        let inputTotalBand = geometry.batteryBand + geometry.systemBand

        if geometry.hasBatteryFlow, geometry.batteryBand > 0 {
            drawTube(
                context: context,
                topLeft: CGPoint(
                    x: geometry.sourceX,
                    y: geometry.sourceCenter - inputTotalBand / 2
                ),
                bottomLeft: CGPoint(
                    x: geometry.sourceX,
                    y: geometry.sourceCenter - inputTotalBand / 2 + geometry.batteryBand
                ),
                topRight: CGPoint(
                    x: geometry.middleColumnX,
                    y: geometry.batteryCenter - geometry.batteryBand / 2
                ),
                bottomRight: CGPoint(
                    x: geometry.middleColumnX,
                    y: geometry.batteryCenter + geometry.batteryBand / 2
                ),
                color: flowColor
            )
        }

        let systemTop = geometry.hasBatteryFlow
            ? geometry.sourceCenter - inputTotalBand / 2 + geometry.batteryBand
            : geometry.sourceCenter - geometry.systemBand / 2
        drawTube(
            context: context,
            topLeft: CGPoint(x: geometry.sourceX, y: systemTop),
            bottomLeft: CGPoint(x: geometry.sourceX, y: systemTop + geometry.systemBand),
            topRight: CGPoint(
                x: geometry.middleColumnX,
                y: geometry.laptopCenter - geometry.systemBand / 2
            ),
            bottomRight: CGPoint(
                x: geometry.middleColumnX,
                y: geometry.laptopCenter + geometry.systemBand / 2
            ),
            color: flowColor
        )

        drawDetailedBranchFlows(
            context: context,
            geometry: geometry,
            bands: geometry.branchBands,
            roots: geometry.branchRoots
        )
    }

    private func drawDetailedMergeFlows(
        context: GraphicsContext,
        size: CGSize,
        geometry: PowerFlowLayoutGeometry
    ) {
        let metrics = detailedMergeSourceMetrics(size: size)
        let capacity = max(1, metrics.nodeHeight - 8)
        let sourceBands = PowerFlowLayout.constrainedBands(
            values: [abs(batteryPower), max(0, adapterPower)],
            total: geometry.systemBand,
            minimum: 2,
            capacities: [capacity, capacity]
        )
        guard sourceBands.count == 2 else { return }

        let batteryBand = sourceBands[0]
        let adapterBand = sourceBands[1]
        let mergedBand = batteryBand + adapterBand
        let mergedTop = geometry.laptopCenter - mergedBand / 2

        drawTube(
            context: context,
            topLeft: CGPoint(
                x: geometry.sourceX,
                y: metrics.topCenter - batteryBand / 2
            ),
            bottomLeft: CGPoint(
                x: geometry.sourceX,
                y: metrics.topCenter + batteryBand / 2
            ),
            topRight: CGPoint(x: geometry.middleColumnX, y: mergedTop),
            bottomRight: CGPoint(
                x: geometry.middleColumnX,
                y: mergedTop + batteryBand
            )
        )

        drawTube(
            context: context,
            topLeft: CGPoint(
                x: geometry.sourceX,
                y: metrics.bottomCenter - adapterBand / 2
            ),
            bottomLeft: CGPoint(
                x: geometry.sourceX,
                y: metrics.bottomCenter + adapterBand / 2
            ),
            topRight: CGPoint(
                x: geometry.middleColumnX,
                y: mergedTop + batteryBand
            ),
            bottomRight: CGPoint(
                x: geometry.middleColumnX,
                y: mergedTop + mergedBand
            )
        )

        let branchGeometry = detailedMergeBranches(
            geometry: geometry,
            mergedBand: mergedBand
        )
        drawDetailedBranchFlows(
            context: context,
            geometry: geometry,
            bands: branchGeometry.bands,
            roots: branchGeometry.roots
        )
    }

    private func detailedMergeBranches(
        geometry: PowerFlowLayoutGeometry,
        mergedBand: CGFloat
    ) -> (bands: [CGFloat], roots: [CGFloat]) {
        let representedPower = powerBreakdown.reduce(0) { $0 + max(0, $1.power) }
        let representedFraction = systemPower > 0
            ? min(1, representedPower / systemPower)
            : 0
        let bands = PowerFlowLayout.constrainedBands(
            values: powerBreakdown.map(\.power),
            total: mergedBand * CGFloat(representedFraction),
            minimum: 1.5,
            capacities: geometry.branchNodeHeights.map { max(1, $0 - 6) }
        )

        let total = bands.reduce(0, +)
        var cursor = geometry.laptopCenter - total / 2
        var roots: [CGFloat] = []
        for band in bands {
            roots.append(cursor)
            cursor += band
        }
        return (bands, roots)
    }

    private func drawDetailedBranchFlows(
        context: GraphicsContext,
        geometry: PowerFlowLayoutGeometry,
        bands: [CGFloat],
        roots: [CGFloat]
    ) {
        let flowColor = Color.primary.opacity(Layout.flowOpacity)
        for index in bands.indices where index < geometry.branchCenters.count
            && index < roots.count {
            let root = roots[index]
            let band = bands[index]
            let center = geometry.branchCenters[index]
            drawTube(
                context: context,
                topLeft: CGPoint(x: geometry.middleRight, y: root),
                bottomLeft: CGPoint(x: geometry.middleRight, y: root + band),
                topRight: CGPoint(
                    x: geometry.branchColumnX,
                    y: center - band / 2
                ),
                bottomRight: CGPoint(
                    x: geometry.branchColumnX,
                    y: center + band / 2
                ),
                color: flowColor
            )
        }
    }

    @ViewBuilder
    private func detailedFlowLabels(_ geometry: PowerFlowLayoutGeometry) -> some View {
        // Adapter total is already visible in the source node. Repeating it on
        // the short first transition creates the overlap seen in narrow menus.
        ForEach(Array(powerBreakdown.enumerated()), id: \.element.id) { index, item in
            if index < geometry.branchCenters.count {
                Text(PowerFormatter.string(item.power))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(
                        x: geometry.middleRight
                            + (geometry.branchColumnX - geometry.middleRight) * 0.55,
                        y: geometry.branchCenters[index]
                    )
            }
        }
    }

    /// Draws a unified curved "tube" between four specific corners
    private func drawTube(
        context: GraphicsContext,
        topLeft: CGPoint,
        bottomLeft: CGPoint,
        topRight: CGPoint,
        bottomRight: CGPoint,
        color: Color = Color.primary.opacity(Layout.flowOpacity)
    ) {
        let controlX = topLeft.x + (topRight.x - topLeft.x) * 0.5

        let path = Path { p in
            p.move(to: topLeft)
            p.addCurve(
                to: topRight,
                control1: CGPoint(x: controlX, y: topLeft.y),
                control2: CGPoint(x: controlX, y: topRight.y)
            )
            p.addLine(to: bottomRight)
            p.addCurve(
                to: bottomLeft,
                control1: CGPoint(x: controlX, y: bottomRight.y),
                control2: CGPoint(x: controlX, y: bottomLeft.y)
            )
            p.closeSubpath()
        }

        context.fill(
            path,
            with: .color(color)
        )
    }
}

private struct PowerBreakdownNode: View {
    let item: PowerBreakdownItem

    var body: some View {
        Group {
            if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: item.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .help(item.isEstimated ? "\(item.name)（估算）" : item.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(PowerFormatter.string(item.power))
    }
}

struct NodeView: View {
    let icon: String
    let value: Double?
    let isLeftSide: Bool
    var width: CGFloat = 56
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            )
            .frame(width: width)

            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                if let value {
                    Text(PowerFormatter.string(value))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    NodeView(icon: "battery.100.bolt", value: 36.5, isLeftSide: true).frame(
        height: 100
    )
}

#Preview {
    let items: [(PowerSource, Bool, Double, Double, Double)] = [
        (.both, false, -20.16, 36.0, 56.16),
        (.acAdapter, true, 20.0, 30.0, 10.0),
        (.battery, false, -18.63, 0.0, 18.63),
        (.acAdapter, false, 0.0, 25.0, 25.0),
        (.acAdapter, false, 23, 39, 16),
    ]
    LazyVGrid(
        columns: [
            GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
        ],
        spacing: 16
    ) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            PowerSankeyView(
                powerSource: item.0,
                isCharging: item.1,
                batteryPower: item.2,
                adapterPower: item.3,
                systemPower: item.4
            )
            .frame(height: 125)
        }
    }
    .padding(12)
    .frame(width: 900)
}
