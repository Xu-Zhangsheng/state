import Defaults
import AppKit
import SwiftUI

/// UI-facing snapshot produced by the energy metrics service.
/// The service can replace the preview values without changing this view.
struct HighEnergyApp: Identifiable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let bundleURLPath: String?
    let icon: NSImage?
    let iconName: String
    let powerWatts: Double

    init(
        id: String,
        name: String,
        bundleIdentifier: String? = nil,
        bundleURLPath: String? = nil,
        icon: NSImage? = nil,
        iconName: String = "app.dashed",
        powerWatts: Double
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURLPath = bundleURLPath
        self.icon = icon
        self.iconName = iconName
        self.powerWatts = powerWatts
    }
}

/// Boundary between the menu UI and whichever process-energy collector is available.
/// A future provider can publish an observable snapshot while the menu is open.
@MainActor
protocol HighEnergyAppsProviding: AnyObject {
    var highEnergyApps: [HighEnergyApp] { get }
    var isHighEnergySampleReady: Bool { get }
}

extension MenuViewModel: HighEnergyAppsProviding {
}

struct HighEnergyAppsView<Provider: HighEnergyAppsProviding>: View {
    let provider: Provider
    @Default(.highEnergyAppLimit) private var limit

    private var apps: [HighEnergyApp] {
        Array(provider.highEnergyApps.sorted { $0.powerWatts > $1.powerWatts }.prefix(max(0, limit)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !provider.isHighEnergySampleReady {
                Text("Calculating…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .stasisMenuRowPadding(vertical: StasisMenuMetrics.regularRowPadding)
            } else if apps.isEmpty {
                Text("No apps with significant energy impact")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .stasisMenuRowPadding(vertical: StasisMenuMetrics.regularRowPadding)
            } else {
                ForEach(apps) { app in
                    HighEnergyAppRow(app: app)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
}

private struct HighEnergyAppRow: View {
    let app: HighEnergyApp

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: app)

            Text(app.name)
                .lineLimit(1)

            Spacer(minLength: 12)
        }
        .font(.callout)
        .padding(.horizontal, StasisMenuMetrics.horizontalPadding)
        .padding(.vertical, 4)
    }
}

private struct AppIcon: View {
    let app: HighEnergyApp

    var body: some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else if let path = app.bundleURLPath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: app.iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

#Preview {
    HighEnergyAppsView(provider: PreviewHighEnergyAppsProvider())
        .frame(width: 300)
}

private final class PreviewHighEnergyAppsProvider: HighEnergyAppsProviding {
    let isHighEnergySampleReady = true
    let highEnergyApps: [HighEnergyApp] = [
        HighEnergyApp(id: "chatgpt", name: "ChatGPT", iconName: "bubble.left.fill", powerWatts: 6.4),
        HighEnergyApp(id: "safari", name: "Safari", iconName: "safari.fill", powerWatts: 4.8),
    ]
}
