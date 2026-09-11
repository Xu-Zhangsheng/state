import Foundation
import Observation

@MainActor
@Observable
final class ModuleTaskStore {
    enum State: String, Sendable {
        case running
        case succeeded
        case failed
        case cancelled
    }

    struct Record: Identifiable, Sendable {
        let taskID: String
        let moduleID: String
        var id: String { "\(moduleID):\(taskID)" }
        var title: String
        var detail: String?
        var progress: Double?
        var state: State
        var updatedAt: Date
    }

    private(set) var records: [Record] = []

    func report(
        moduleID: String,
        taskID: String,
        title: String,
        detail: String?,
        progress: Double?
    ) {
        let normalizedProgress = progress.map { min(1, max(0, $0)) }
        if let index = records.firstIndex(where: { $0.taskID == taskID && $0.moduleID == moduleID }) {
            records[index].title = title
            records[index].detail = detail
            records[index].progress = normalizedProgress
            records[index].state = .running
            records[index].updatedAt = .now
        } else {
            records.append(
                Record(
                    taskID: taskID,
                    moduleID: moduleID,
                    title: title,
                    detail: detail,
                    progress: normalizedProgress,
                    state: .running,
                    updatedAt: .now
                )
            )
        }
        trimHistory()
    }

    func finish(
        moduleID: String,
        taskID: String,
        state: State,
        detail: String?
    ) {
        guard let index = records.firstIndex(where: { $0.taskID == taskID && $0.moduleID == moduleID }) else {
            records.append(
                Record(
                    taskID: taskID,
                    moduleID: moduleID,
                    title: taskID,
                    detail: detail,
                    progress: state == .succeeded ? 1 : nil,
                    state: state,
                    updatedAt: .now
                )
            )
            trimHistory()
            return
        }
        records[index].detail = detail ?? records[index].detail
        records[index].progress = state == .succeeded ? 1 : records[index].progress
        records[index].state = state
        records[index].updatedAt = .now
    }

    func moduleDisconnected(_ moduleID: String) {
        for index in records.indices where
            records[index].moduleID == moduleID && records[index].state == .running {
            records[index].state = .failed
            records[index].detail = String(localized: "The module stopped before the task finished.")
            records[index].updatedAt = .now
        }
    }

    func records(for moduleID: String) -> [Record] {
        records
            .filter { $0.moduleID == moduleID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func trimHistory() {
        guard records.count > 100 else { return }
        records = records.sorted { $0.updatedAt > $1.updatedAt }.prefix(100).map { $0 }
    }
}
