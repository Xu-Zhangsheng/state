import Foundation
import Observation

@MainActor
@Observable
final class ModulePresentationStateStore {
    private(set) var states: [String: [String: JSONValue]] = [:]

    func publish(_ state: [String: JSONValue], moduleID: String) {
        states[moduleID] = state
    }

    func value(moduleID: String, binding: String) -> JSONValue? {
        states[moduleID]?[binding]
    }

    func remove(moduleID: String) {
        states[moduleID] = nil
    }
}
