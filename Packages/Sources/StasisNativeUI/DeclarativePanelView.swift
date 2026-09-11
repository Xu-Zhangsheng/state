import StasisContracts
import SwiftUI

/// Host-owned renderer for the constrained module presentation contract.
/// Modules provide data and actions; they never inject a SwiftUI view into the
/// Stasis process.
public struct StasisDeclarativePanelView: View {
    public let components: [PresentationComponent]
    public let state: [String: JSONValue]
    public let resolvesPublishedState: Bool
    public let horizontalPadding: CGFloat
    public let verticalPadding: CGFloat
    public let action: (String, JSONValue?) -> Void

    public init(
        components: [PresentationComponent],
        state: [String: JSONValue] = [:],
        resolvesPublishedState: Bool = true,
        horizontalPadding: CGFloat = 12,
        verticalPadding: CGFloat = 6,
        action: @escaping (String, JSONValue?) -> Void
    ) {
        self.components = components
        self.state = state
        self.resolvesPublishedState = resolvesPublishedState
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(components) { component in
                componentView(component)
            }
        }
    }

    private func componentView(_ component: PresentationComponent) -> AnyView {
        switch component.kind {
        case .infoRow:
            return AnyView(HStack(spacing: 8) {
                if let icon = component.systemImage {
                    Image(systemName: icon).frame(width: 18)
                }
                Text(component.title ?? "")
                Spacer(minLength: 20)
                Text(resolvedValue(component))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }.moduleRowPadding(horizontal: horizontalPadding, vertical: verticalPadding))
        case .section:
            return AnyView(VStack(spacing: 0) {
                ForEach(component.children) { componentView($0) }
            })
        case .button:
            return AnyView(Button(component.title ?? "Action") {
                if let actionID = component.actionID { action(actionID, nil) }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .moduleRowPadding(horizontal: horizontalPadding, vertical: verticalPadding))
        case .toggle:
            return AnyView(HStack {
                Text(component.title ?? "")
                Spacer(minLength: 20)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { resolvedValue(component) == "true" },
                        set: { enabled in
                            if let actionID = component.actionID {
                                action(actionID, .bool(enabled))
                            }
                        }
                    )
                )
                .labelsHidden()
                .disabled(component.actionID == nil)
            }.moduleRowPadding(horizontal: horizontalPadding, vertical: verticalPadding))
        case .progress:
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                Text(component.title ?? "")
                ProgressView(value: Double(resolvedValue(component)) ?? 0)
            }.moduleRowPadding(horizontal: horizontalPadding, vertical: verticalPadding))
        case .divider:
            return AnyView(Divider().padding(.horizontal, horizontalPadding))
        }
    }

    private func resolvedValue(_ component: PresentationComponent) -> String {
        guard resolvesPublishedState,
              let binding = component.binding,
              let value = state[binding]
        else { return component.value ?? "—" }
        switch value {
        case .string(let string): return string
        case .number(let number): return number.formatted()
        case .bool(let bool): return bool ? "true" : "false"
        case .null, .object, .array: return "—"
        }
    }
}

private extension View {
    func moduleRowPadding(horizontal: CGFloat, vertical: CGFloat) -> some View {
        self
            .font(.callout)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
    }
}
