import SwiftUI

struct BatteryAdditionalInfo: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer(minLength: 20)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .font(.callout)
        .stasisMenuRowPadding()
    }
}

#Preview("Menu Items") {
    VStack(spacing: 0) {
        BatteryAdditionalInfo(label: "Battery Percentage", value: "85%")
        BatteryAdditionalInfo(label: "Time Remaining", value: "02:45")
        BatteryAdditionalInfo(label: "Battery Mode", value: "Discharging")
    }
    .frame(width: 300)
    .background(Color(NSColor.controlBackgroundColor))
}
