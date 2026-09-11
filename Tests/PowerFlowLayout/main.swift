import CoreGraphics
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw TestFailure.failed(message) }
}

private let size = CGSize(width: 272, height: 125)
private let nodeWidth: CGFloat = 60
private let middleX: CGFloat = 88
private let branchX: CGFloat = 212

do {
    let standardEdges = PowerFlowLayout.standardFlowEdges(
        width: 272,
        nodeWidth: 56,
        gap: 5
    )
    try require(
        standardEdges.left == 61 && standardEdges.right == 211,
        "standard flow must keep a 5 pt breathing gap from both nodes"
    )

    let singleBand = PowerFlowLayout.singleBandThickness(
        nodeHeight: 52,
        availableHeight: 56
    )
    try require(
        singleBand == 52,
        "single flow must retain the full 0.2.2 node-edge thickness"
    )
    try require(
        PowerFlowLayout.standardTotalBand(availableHeight: 104) == 56,
        "split flow must retain a substantial 0.2.2-style source band"
    )

    let low = PowerFlowLayout.bandThickness(power: 5, maximum: 100)
    let medium = PowerFlowLayout.bandThickness(power: 35, maximum: 100)
    let high = PowerFlowLayout.bandThickness(power: 80, maximum: 100)
    try require(low < medium && medium < high, "absolute watts must increase band thickness")

    let standardBands = PowerFlowLayout.proportionalBands(
        values: [61.2, 23.7],
        total: 48,
        minimum: 2
    )
    try require(standardBands.count == 2, "split flow must keep both destinations")
    try require(
        abs(standardBands.reduce(0, +) - 48) < 0.001,
        "split bands must preserve the requested absolute thickness"
    )
    try require(
        standardBands[0] > standardBands[1],
        "higher power destination must receive the thicker band"
    )

    let mergeBands = PowerFlowLayout.constrainedBands(
        values: [20.2, 36.0],
        total: 88,
        minimum: 2,
        capacities: [41, 41]
    )
    try require(
        mergeBands.count == 2
            && mergeBands[0] > 0
            && mergeBands[1] > mergeBands[0],
        "combined supply must preserve both source contributions and their ratio"
    )
    try require(
        mergeBands.allSatisfy { $0 <= 41.001 },
        "combined source bands must stay inside their nodes"
    )

    let noBattery = PowerFlowLayout.detailed(
        size: size,
        nodeWidth: nodeWidth,
        middleColumnX: middleX,
        branchColumnX: branchX,
        batteryPower: 0,
        systemPower: 10,
        branchPowers: [4.5, 2, 2.4, 1.1]
    )
    try require(
        noBattery.sourceX == nodeWidth + 5
            && noBattery.middleColumnX == middleX - 5
            && noBattery.middleRight == middleX + nodeWidth + 5
            && noBattery.branchColumnX == branchX - 5,
        "every detailed flow segment must keep a 5 pt gap from its nodes"
    )
    try require(!noBattery.hasBatteryFlow, "battery node must be hidden at zero battery power")
    try require(noBattery.batteryNodeHeight == 0, "hidden battery node must consume no height")
    try require(noBattery.branchBands.count == 4, "all enabled branches must be laid out")

    for index in noBattery.branchNodeHeights.indices {
        let top = noBattery.branchCenters[index] - noBattery.branchNodeHeights[index] / 2
        let bottom = noBattery.branchCenters[index] + noBattery.branchNodeHeights[index] / 2
        try require(top >= 3.99 && bottom <= 121.01, "branch node escaped the 125 pt view")
        if index > 0 {
            let previousBottom = noBattery.branchCenters[index - 1]
                + noBattery.branchNodeHeights[index - 1] / 2
            try require(top > previousBottom, "branch nodes overlap")
        }
    }

    for index in noBattery.branchBands.indices where index > 0 {
        let previousBottom = noBattery.branchRoots[index - 1]
            + noBattery.branchBands[index - 1]
        try require(
            abs(noBattery.branchRoots[index] - previousBottom) < 0.001,
            "branch bands must partition one continuous output without overlap"
        )
    }

    let charging = PowerFlowLayout.detailed(
        size: size,
        nodeWidth: nodeWidth,
        middleColumnX: middleX,
        branchColumnX: branchX,
        batteryPower: 61.2,
        systemPower: 23.7,
        branchPowers: [10.7, 3.83, 9.17]
    )
    try require(charging.hasBatteryFlow, "positive charging power must show the battery node")
    try require(
        charging.batteryNodeHeight + charging.laptopNodeHeight + 5 <= 117.01,
        "middle nodes exceed their available height"
    )
    try require(
        charging.batteryBand <= charging.batteryNodeHeight - 8.0 + 0.001,
        "battery flow escapes its node"
    )
    try require(
        charging.systemBand <= charging.laptopNodeHeight - 8.0 + 0.001,
        "system flow escapes its node"
    )

    let highLoad = PowerFlowLayout.detailed(
        size: size,
        nodeWidth: nodeWidth,
        middleColumnX: middleX,
        branchColumnX: branchX,
        batteryPower: 0,
        systemPower: 60,
        branchPowers: [27, 12, 14.4, 6.6]
    )
    try require(
        highLoad.systemBand > noBattery.systemBand,
        "higher absolute power must produce a thicker source band"
    )
    try require(
        highLoad.branchBands.reduce(0, +) > noBattery.branchBands.reduce(0, +),
        "higher absolute power must produce thicker detailed branches"
    )

    print("PowerFlowLayout tests passed")
} catch {
    fputs("PowerFlowLayout test failure: \(error)\n", stderr)
    exit(1)
}
