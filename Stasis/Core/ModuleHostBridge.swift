import Defaults
import Foundation
import UserNotifications

@MainActor
final class ModuleHostBridge {
    private struct ActiveSubscription {
        let brokerID: UUID
        let demandID: UUID
    }

    private let registry: ModuleRegistry
    private let settings: ModuleSettingsStore
    private let services: ServiceBroker
    private let permissions: PermissionBroker
    private let leases: ControlLeaseManager
    private let presentation: ModulePresentationStateStore
    private let tasks: ModuleTaskStore
    private let supervisor: RuntimeSupervisor
    private weak var batteryService: BatteryService?
    private var subscriptions: [String: [String: ActiveSubscription]] = [:]

    init(
        registry: ModuleRegistry,
        settings: ModuleSettingsStore,
        services: ServiceBroker,
        permissions: PermissionBroker,
        leases: ControlLeaseManager,
        presentation: ModulePresentationStateStore,
        tasks: ModuleTaskStore,
        supervisor: RuntimeSupervisor,
        batteryService: BatteryService
    ) {
        self.registry = registry
        self.settings = settings
        self.services = services
        self.permissions = permissions
        self.leases = leases
        self.presentation = presentation
        self.tasks = tasks
        self.supervisor = supervisor
        self.batteryService = batteryService
    }

    func handle(moduleID: String, method: String, params: JSONValue?) async throws -> JSONValue? {
        guard let module = registry.module(id: moduleID), module.isEnabled else {
            throw ModuleHostBridgeError.moduleUnavailable
        }
        switch method {
        case "services.subscribe":
            return try await subscribe(moduleID: moduleID, params: params)
        case "services.unsubscribe":
            try await unsubscribe(moduleID: moduleID, params: params)
            return .null
        case "services.publish":
            guard module.descriptor.roles.contains(.data) else {
                throw ModuleHostBridgeError.missingRole("data")
            }
            try await publish(moduleID: moduleID, params: params)
            return .null
        case "settings.read":
            return try encode(settings.snapshot(moduleID: moduleID, schemaVersion: module.descriptor.settingsVersion))
        case "settings.proposePatch":
            return try proposeSettingsPatch(module: module, params: params)
        case "presentation.publishState":
            guard module.descriptor.roles.contains(.presentation) else {
                throw ModuleHostBridgeError.missingRole("presentation")
            }
            let object = try requiredObject(params)
            let state = try requiredObject(object["state"])
            presentation.publish(state, moduleID: moduleID)
            return .null
        case "control.acquire":
            guard module.descriptor.roles.contains(.control),
                  module.descriptor.permissions.contains("hardware.control")
            else { throw ModuleHostBridgeError.undeclaredPermission("hardware.control") }
            try await permissions.authorize(moduleID: moduleID, permission: "hardware.control")
            let object = try requiredObject(params)
            let resourceID = try requiredString(object["resourceID"])
            try validateControlResource(resourceID)
            let sessionID = try requiredUUID(object["sessionID"])
            let lease = try await leases.acquire(resourceID: resourceID, moduleID: moduleID, sessionID: sessionID)
            return .object([
                "leaseID": .string(lease.id.uuidString),
                "resourceID": .string(resourceID),
                "sessionID": .string(sessionID.uuidString),
                "renewAfterSeconds": .number(5),
            ])
        case "control.renew":
            let object = try requiredObject(params)
            let lease = try await leases.renew(
                try requiredUUID(object["leaseID"]),
                resourceID: try requiredString(object["resourceID"]),
                moduleID: moduleID,
                sessionID: try requiredUUID(object["sessionID"])
            )
            return .object(["leaseID": .string(lease.id.uuidString)])
        case "control.apply":
            guard module.descriptor.roles.contains(.control),
                  module.descriptor.permissions.contains("hardware.control")
            else { throw ModuleHostBridgeError.undeclaredPermission("hardware.control") }
            try await permissions.authorize(moduleID: moduleID, permission: "hardware.control")
            try await applyControl(moduleID: moduleID, params: params)
            return .null
        case "control.release":
            let object = try requiredObject(params)
            try await leases.validate(
                leaseID: try requiredUUID(object["leaseID"]),
                resourceID: try requiredString(object["resourceID"]),
                moduleID: moduleID,
                sessionID: try requiredUUID(object["sessionID"])
            )
            await leases.release(
                try requiredUUID(object["leaseID"]),
                resourceID: try requiredString(object["resourceID"])
            )
            return .null
        case "notifications.post":
            guard module.descriptor.permissions.contains("notifications") else {
                throw ModuleHostBridgeError.undeclaredPermission("notifications")
            }
            try await permissions.authorize(moduleID: moduleID, permission: "notifications")
            try await postNotification(module: module, params: params)
            return .null
        case "tasks.reportProgress":
            let object = try requiredObject(params)
            let taskID = try requiredTaskID(object["taskID"])
            tasks.report(
                moduleID: moduleID,
                taskID: taskID,
                title: optionalString(object["title"]) ?? taskID,
                detail: optionalString(object["detail"]),
                progress: optionalNumber(object["progress"])
            )
            return .null
        case "tasks.finish":
            let object = try requiredObject(params)
            let taskID = try requiredTaskID(object["taskID"])
            let state: ModuleTaskStore.State
            switch optionalString(object["state"]) ?? "succeeded" {
            case "succeeded": state = .succeeded
            case "failed": state = .failed
            case "cancelled": state = .cancelled
            default: throw ModuleHostBridgeError.invalidParameters
            }
            tasks.finish(
                moduleID: moduleID,
                taskID: taskID,
                state: state,
                detail: optionalString(object["detail"])
            )
            return .null
        default:
            throw ModuleHostBridgeError.unsupportedMethod(method)
        }
    }

    func disconnect(moduleID: String) async {
        for subscription in subscriptions.removeValue(forKey: moduleID)?.values ?? [:].values {
            await services.unsubscribe(subscription.brokerID, demandID: subscription.demandID)
        }
        presentation.remove(moduleID: moduleID)
        tasks.moduleDisconnected(moduleID)
        await leases.releaseAll(moduleID: moduleID)
    }

    private func subscribe(moduleID: String, params: JSONValue?) async throws -> JSONValue {
        let object = try requiredObject(params)
        let serviceID = try requiredString(object["serviceID"])
        guard let module = registry.module(id: moduleID),
              module.descriptor.requires.contains(where: { $0.serviceID == serviceID }),
              let providerID = registry.selectedProviderID(for: serviceID),
              let service = registry.module(id: providerID)?.descriptor.provides.first(where: {
                  $0.id == serviceID
              })
        else { throw ModuleHostBridgeError.undeclaredService(serviceID) }
        let subscriptionID = optionalString(object["subscriptionID"]) ?? UUID().uuidString
        let fields = Set(optionalStringArray(object["fields"]))
        if let supportedFields = service.fields, !fields.isSubset(of: supportedFields) {
            throw ModuleHostBridgeError.unsupportedServiceFields(
                fields.subtracting(supportedFields).sorted()
            )
        }
        var interval = max(0.1, optionalNumber(object["interval"]) ?? 1)
        if let minimum = service.minimumInterval { interval = max(interval, minimum) }
        if let maximum = service.maximumInterval { interval = min(interval, maximum) }
        let purpose = DemandPurpose(rawValue: optionalString(object["purpose"]) ?? "visiblePanel") ?? .visiblePanel
        let demand = ModuleDemand(
            id: UUID(),
            consumerID: moduleID,
            serviceID: serviceID,
            fields: fields,
            interval: interval,
            purpose: purpose
        )
        let brokerID = try await services.subscribe(demand: demand) { [weak supervisor] snapshot in
            guard let supervisor else { return }
            await MainActor.run {
                let encoded = try? Self.encodeStatic(snapshot)
                guard let encoded else { return }
                try? supervisor.notify(
                    moduleID: moduleID,
                    method: "services.snapshot",
                    params: .object(["serviceID": .string(serviceID), "snapshot": encoded])
                )
            }
        }
        subscriptions[moduleID, default: [:]][subscriptionID] = .init(
            brokerID: brokerID,
            demandID: demand.id
        )
        return .object(["subscriptionID": .string(subscriptionID)])
    }

    private func unsubscribe(moduleID: String, params: JSONValue?) async throws {
        let object = try requiredObject(params)
        let subscriptionID = try requiredString(object["subscriptionID"])
        guard let subscription = subscriptions[moduleID]?.removeValue(forKey: subscriptionID) else { return }
        await services.unsubscribe(subscription.brokerID, demandID: subscription.demandID)
    }

    private func publish(moduleID: String, params: JSONValue?) async throws {
        let object = try requiredObject(params)
        let serviceID = try requiredString(object["serviceID"])
        guard let service = registry.module(id: moduleID)?.descriptor.provides.first(where: {
            $0.id == serviceID
        }) else {
            throw ModuleHostBridgeError.undeclaredService(serviceID)
        }
        let snapshot: TelemetrySnapshot = try decode(object["snapshot"])
        try validate(snapshot: snapshot, for: service)
        try await services.publish(snapshot, serviceID: serviceID, providerID: moduleID)
    }

    private func validate(
        snapshot: TelemetrySnapshot,
        for service: ModuleServiceDeclaration
    ) throws {
        guard snapshot.windowStartedAt <= snapshot.sampledAt,
              Set(snapshot.metrics.map(\.id)).count == snapshot.metrics.count
        else { throw ModuleHostBridgeError.invalidSnapshot }
        if let fields = service.fields,
           !Set(snapshot.metrics.map(\.id)).isSubset(of: fields) {
            throw ModuleHostBridgeError.unsupportedServiceFields(
                Set(snapshot.metrics.map(\.id)).subtracting(fields).sorted()
            )
        }
        for metric in snapshot.metrics {
            guard !metric.id.isEmpty, !metric.unit.isEmpty, !metric.source.isEmpty,
                  metric.sampledAt <= snapshot.sampledAt,
                  metric.value?.isFinite != false,
                  metric.quality != .unavailable || metric.value == nil
            else { throw ModuleHostBridgeError.invalidSnapshot }
        }
    }

    private func proposeSettingsPatch(module: InstalledModule, params: JSONValue?) throws -> JSONValue {
        let object = try requiredObject(params)
        let revision = UInt64(try requiredNumber(object["expectedRevision"]))
        let schemaVersion = Int(optionalNumber(object["schemaVersion"]) ?? Double(module.descriptor.settingsVersion))
        let patch = try requiredObject(object["patch"])
        let updated = try settings.apply(
            moduleID: module.id,
            expectedRevision: revision,
            schemaVersion: schemaVersion,
            patch: patch
        )
        return .object(["revision": .number(Double(updated))])
    }

    private func applyControl(moduleID: String, params: JSONValue?) async throws {
        let object = try requiredObject(params)
        let resourceID = try requiredString(object["resourceID"])
        try validateControlResource(resourceID)
        try await leases.validate(
            leaseID: try requiredUUID(object["leaseID"]),
            resourceID: resourceID,
            moduleID: moduleID,
            sessionID: try requiredUUID(object["sessionID"])
        )
        guard let enabled = optionalBool(object["enabled"]), let batteryService else {
            throw ModuleHostBridgeError.invalidParameters
        }
        switch resourceID {
        case "battery.charging": try await batteryService.manageBatteryCharging(enabled: enabled)
        case "battery.external-power": try await batteryService.manageExternalPower(enabled: enabled)
        default: throw ModuleHostBridgeError.invalidControlResource
        }
        batteryService.scheduleSinglePoll()
    }

    private func postNotification(module: InstalledModule, params: JSONValue?) async throws {
        guard !Defaults[.disableNotifications], module.notificationsEnabled else { return }
        let object = try requiredObject(params)
        let content = UNMutableNotificationContent()
        content.title = optionalString(object["title"]) ?? module.displayName
        content.body = optionalString(object["body"]) ?? ""
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }

    private func validateControlResource(_ value: String) throws {
        guard value == "battery.charging" || value == "battery.external-power" else {
            throw ModuleHostBridgeError.invalidControlResource
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try Self.encodeStatic(value)
    }

    private static func encodeStatic<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private func decode<T: Decodable>(_ value: JSONValue?) throws -> T {
        guard let value else { throw ModuleHostBridgeError.invalidParameters }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func requiredObject(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { throw ModuleHostBridgeError.invalidParameters }
        return object
    }

    private func requiredString(_ value: JSONValue?) throws -> String {
        guard case .string(let string) = value else { throw ModuleHostBridgeError.invalidParameters }
        return string
    }

    private func requiredNumber(_ value: JSONValue?) throws -> Double {
        guard case .number(let number) = value, number.isFinite else {
            throw ModuleHostBridgeError.invalidParameters
        }
        return number
    }

    private func requiredUUID(_ value: JSONValue?) throws -> UUID {
        guard let uuid = UUID(uuidString: try requiredString(value)) else {
            throw ModuleHostBridgeError.invalidParameters
        }
        return uuid
    }

    private func requiredTaskID(_ value: JSONValue?) throws -> String {
        let taskID = try requiredString(value)
        guard !taskID.isEmpty, taskID.utf8.count <= 128 else {
            throw ModuleHostBridgeError.invalidParameters
        }
        return taskID
    }

    private func optionalString(_ value: JSONValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    private func optionalNumber(_ value: JSONValue?) -> Double? {
        guard case .number(let number) = value, number.isFinite else { return nil }
        return number
    }

    private func optionalBool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let bool) = value else { return nil }
        return bool
    }

    private func optionalStringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap(optionalString)
    }
}

enum ModuleHostBridgeError: LocalizedError {
    case moduleUnavailable
    case invalidParameters
    case invalidControlResource
    case undeclaredService(String)
    case unsupportedServiceFields([String])
    case invalidSnapshot
    case undeclaredPermission(String)
    case missingRole(String)
    case unsupportedMethod(String)

    var errorDescription: String? {
        switch self {
        case .moduleUnavailable: "The module is disabled or no longer installed."
        case .invalidParameters: "The module request contains invalid parameters."
        case .invalidControlResource: "The requested hardware control resource is not available."
        case .undeclaredService(let service): "The module did not declare access to \(service)."
        case .unsupportedServiceFields(let fields):
            "The service does not provide these requested fields: \(fields.joined(separator: ", "))."
        case .invalidSnapshot: "The module published an invalid telemetry snapshot."
        case .undeclaredPermission(let permission): "The module did not declare the \(permission) permission."
        case .missingRole(let role): "The module did not declare the \(role) role."
        case .unsupportedMethod(let method): "Unsupported module host method: \(method)."
        }
    }
}
