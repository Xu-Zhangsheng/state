import AppKit
import SwiftUI

@main
struct PowerFlowSnapshotTool {
    @MainActor
    static func main() throws {
        let outputDirectory = CommandLine.arguments.dropFirst().first
            ?? FileManager.default.currentDirectoryPath
        try FileManager.default.createDirectory(
            atPath: outputDirectory,
            withIntermediateDirectories: true
        )

        let lowItems = makeItems([4.5, 2.0, 2.4, 1.1])
        let highItems = makeItems([27, 12, 14.4, 6.6])

        try render(
            name: "power-flow-light-low",
            outputDirectory: outputDirectory,
            colorScheme: .light,
            adapterPower: 10,
            systemPower: 10,
            items: lowItems
        )
        try render(
            name: "power-flow-light-high",
            outputDirectory: outputDirectory,
            colorScheme: .light,
            adapterPower: 60,
            systemPower: 60,
            items: highItems
        )
        try render(
            name: "power-flow-dark-low",
            outputDirectory: outputDirectory,
            colorScheme: .dark,
            adapterPower: 10,
            systemPower: 10,
            items: lowItems
        )
        try render(
            name: "power-flow-dark-charging",
            outputDirectory: outputDirectory,
            colorScheme: .dark,
            adapterPower: 84.9,
            batteryPower: 61.2,
            systemPower: 23.7,
            isCharging: true,
            items: makeItems([10.7, 3.8, 9.2])
        )
        try render(
            name: "power-flow-light-battery",
            outputDirectory: outputDirectory,
            colorScheme: .light,
            powerSource: .battery,
            adapterPower: 0,
            batteryPower: -10.3,
            systemPower: 10.3,
            items: []
        )
        try render(
            name: "power-flow-dark-battery",
            outputDirectory: outputDirectory,
            colorScheme: .dark,
            powerSource: .battery,
            adapterPower: 0,
            batteryPower: -10.3,
            systemPower: 10.3,
            items: []
        )
        try render(
            name: "power-flow-dark-battery-6w",
            outputDirectory: outputDirectory,
            colorScheme: .dark,
            powerSource: .battery,
            adapterPower: 0,
            batteryPower: -6.3,
            systemPower: 6.3,
            items: []
        )
        try render(
            name: "power-flow-dark-battery-detailed",
            outputDirectory: outputDirectory,
            colorScheme: .dark,
            powerSource: .battery,
            adapterPower: 0,
            batteryPower: -6.3,
            systemPower: 6.3,
            items: makeItems([2.5, 1.4, 1.6, 0.8])
        )
        try render(
            name: "power-flow-light-adapter",
            outputDirectory: outputDirectory,
            colorScheme: .light,
            adapterPower: 10.3,
            systemPower: 10.3,
            items: []
        )
        try render(
            name: "power-flow-dark-split",
            outputDirectory: outputDirectory,
            colorScheme: .dark,
            adapterPower: 84.9,
            batteryPower: 61.2,
            systemPower: 23.7,
            isCharging: true,
            items: []
        )
        try render(
            name: "power-flow-light-merge",
            outputDirectory: outputDirectory,
            colorScheme: .light,
            powerSource: .both,
            adapterPower: 36,
            batteryPower: -20.2,
            systemPower: 56.2,
            items: []
        )
        try render(
            name: "power-flow-dark-merge-detailed",
            outputDirectory: outputDirectory,
            colorScheme: .dark,
            powerSource: .both,
            adapterPower: 36,
            batteryPower: -20.2,
            systemPower: 56.2,
            items: makeItems([14.2, 8.4, 21.0, 12.6])
        )
        try renderBatteryPanel(
            name: "battery-panel-light",
            outputDirectory: outputDirectory,
            colorScheme: .light
        )
        try renderBatteryPanel(
            name: "battery-panel-dark",
            outputDirectory: outputDirectory,
            colorScheme: .dark
        )
    }

    private static func makeItems(_ powers: [Double]) -> [PowerBreakdownItem] {
        let metadata = [
            ("external", "External Devices", "arrow.up.forward"),
            ("display", "Display", "display"),
            ("chip", "M2 Chip", "cpu"),
            ("other", "Other", "ellipsis"),
        ]
        return powers.enumerated().map { index, power in
            let item = metadata[index]
            return PowerBreakdownItem(
                id: item.0,
                name: item.1,
                power: power,
                systemImage: item.2,
                icon: nil,
                isEstimated: item.0 != "chip"
            )
        }
    }

    @MainActor
    private static func render(
        name: String,
        outputDirectory: String,
        colorScheme: ColorScheme,
        powerSource: PowerSource = .acAdapter,
        adapterPower: Double,
        batteryPower: Double = 0,
        systemPower: Double,
        isCharging: Bool = false,
        items: [PowerBreakdownItem]
    ) throws {
        let background = colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(nsColor: .windowBackgroundColor)
        let content = PowerSankeyView(
            powerSource: powerSource,
            isCharging: isCharging,
            batteryPower: batteryPower,
            adapterPower: adapterPower,
            systemPower: systemPower,
            powerBreakdown: items
        )
        .frame(width: 300)
        .background(background)
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        let expectedHeight: CGFloat
        if !items.isEmpty && systemPower > 0.1 {
            expectedHeight = 124
        } else if powerSource == .both
                    || (powerSource == .acAdapter && isCharging && batteryPower > 0.1) {
            expectedHeight = 116
        } else {
            expectedHeight = 76
        }
        guard abs(image.size.height - expectedHeight) < 0.5 else {
            throw CocoaError(.formatting)
        }

        let url = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("\(name).png")
        try png.write(to: url, options: .atomic)
        print(url.path)
    }

    @MainActor
    private static func renderBatteryPanel(
        name: String,
        outputDirectory: String,
        colorScheme: ColorScheme
    ) throws {
        let content = VStack(spacing: 0) {
            BatteryAdditionalInfo(label: "电池模式", value: "放电中")
            BatteryAdditionalInfo(label: "电池温度", value: "34.4°C")

            Divider()
                .padding(.horizontal, StasisMenuMetrics.horizontalPadding)
                .padding(.vertical, StasisMenuMetrics.sectionSpacing)

            BatteryAdditionalInfo(label: "电池功率", value: "11.40V @ -0.90A")

            PowerSankeyView(
                powerSource: .battery,
                isCharging: false,
                batteryPower: -10.3,
                adapterPower: 0,
                systemPower: 10.3,
                powerBreakdown: []
            )

            Divider()
                .padding(.horizontal, StasisMenuMetrics.horizontalPadding)
                .padding(.vertical, StasisMenuMetrics.sectionSpacing)

            BatteryAdditionalInfo(label: "充放电次数", value: "98")

            Text("没有明显耗能的 App")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .stasisMenuRowPadding(vertical: StasisMenuMetrics.regularRowPadding)

            Divider()
                .padding(.horizontal, StasisMenuMetrics.horizontalPadding)
                .padding(.vertical, StasisMenuMetrics.sectionSpacing)

            HStack(spacing: 10) {
                Text("充电上限")
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 4)
                        Capsule()
                            .fill(.tint)
                            .frame(width: proxy.size.width * 0.4, height: 4)
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                Circle().stroke(
                                    Color(nsColor: .separatorColor),
                                    lineWidth: 0.5
                                )
                            )
                            .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
                            .frame(width: 14, height: 14)
                            .offset(x: max(0, proxy.size.width * 0.4 - 7))
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 16)
                Text("70%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            .stasisMenuRowPadding(vertical: StasisMenuMetrics.regularRowPadding)

            Divider()
                .padding(.horizontal, StasisMenuMetrics.horizontalPadding)

            HStack {
                Text("设置")
                Spacer()
                Text("⌘,")
                    .foregroundStyle(.tertiary)
            }
            .font(.body)
            .stasisMenuRowPadding(vertical: StasisMenuMetrics.regularRowPadding)
        }
        .frame(width: StasisMenuMetrics.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, colorScheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        guard image.size.width == StasisMenuMetrics.width,
              image.size.height < 420
        else {
            throw CocoaError(.formatting)
        }

        let url = URL(fileURLWithPath: outputDirectory)
            .appendingPathComponent("\(name).png")
        try png.write(to: url, options: .atomic)
        print(url.path)
    }
}
