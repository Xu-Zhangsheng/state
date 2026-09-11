import AppKit
import Darwin
import Foundation
import Observation

/// Estimates recent app energy use from libproc counters while the menu is open.
/// Every sampling session starts from a fresh baseline, and helper processes are
/// aggregated into their owning foreground application.
@MainActor
@Observable
final class HighEnergyAppsService {
    private struct Reading {
        let energyNanojoules: UInt64
        let timestamp: ContinuousClock.Instant
        let processStartAbstime: UInt64
    }

    private struct AppIdentity {
        let id: String
        let name: String
        let bundleIdentifier: String?
        let bundleURLPath: String
        let icon: NSImage?
    }

    private(set) var apps: [HighEnergyApp] = []
    private(set) var hasCompletedSample = false

    private var previousReadings: [pid_t: Reading] = [:]
    private var smoothedWattsByApp: [String: Double] = [:]
    private var samplingTask: Task<Void, Never>?
    private let clock = ContinuousClock()

    private static let sampleInterval: Duration = .seconds(1)
    private static let minimumEstimatedWatts = 0.5

    func startSampling() {
        guard samplingTask == nil else { return }

        resetMeasurementState()
        samplingTask = Task { [weak self] in
            guard let self else { return }
            self.sample(isBaseline: true)

            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                guard !Task.isCancelled else { return }
                self.sample(isBaseline: false)
            }
        }
    }

    func stopSampling() {
        samplingTask?.cancel()
        samplingTask = nil
        resetMeasurementState()
    }

    /// Starts each menu session from a fresh counter baseline while retaining
    /// the last completed result so reopening the menu has no empty-state flash.
    private func resetMeasurementState() {
        previousReadings.removeAll(keepingCapacity: true)
        smoothedWattsByApp.removeAll(keepingCapacity: true)
    }

    private func sample(isBaseline: Bool) {
        let now = clock.now
        let visibleApps = foregroundApplicationsByBundlePath()
        var nextReadings: [pid_t: Reading] = [:]
        var rawWattsByApp: [String: Double] = [:]

        for pid in allProcessIdentifiers() {
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  let executablePath = executablePath(for: pid),
                  let appPath = containingApplicationPath(for: executablePath),
                  let identity = visibleApps[appPath],
                  let usage = readUsage(for: pid)
            else { continue }

            nextReadings[pid] = Reading(
                energyNanojoules: usage.energyNanojoules,
                timestamp: now,
                processStartAbstime: usage.processStartAbstime
            )

            guard !isBaseline,
                  let previous = previousReadings[pid],
                  previous.processStartAbstime == usage.processStartAbstime,
                  usage.energyNanojoules >= previous.energyNanojoules
            else { continue }

            let elapsed = max(0.1, previous.timestamp.duration(to: now).timeInterval)
            let joules = Double(usage.energyNanojoules - previous.energyNanojoules)
                / 1_000_000_000
            rawWattsByApp[identity.id, default: 0] += joules / elapsed
        }

        previousReadings = nextReadings
        guard !isBaseline else { return }

        var nextSmoothedWatts: [String: Double] = [:]
        var nextApps: [HighEnergyApp] = []
        for (id, rawWatts) in rawWattsByApp {
            guard let identity = visibleApps.values.first(where: { $0.id == id }) else {
                continue
            }

            let watts = if let previousWatts = smoothedWattsByApp[id] {
                previousWatts * 0.55 + rawWatts * 0.45
            } else {
                rawWatts
            }
            nextSmoothedWatts[id] = watts

            guard watts >= Self.minimumEstimatedWatts else { continue }
            nextApps.append(
                HighEnergyApp(
                    id: identity.id,
                    name: identity.name,
                    bundleIdentifier: identity.bundleIdentifier,
                    bundleURLPath: identity.bundleURLPath,
                    icon: identity.icon,
                    powerWatts: watts
                )
            )
        }

        smoothedWattsByApp = nextSmoothedWatts
        apps = nextApps.sorted { $0.powerWatts > $1.powerWatts }
        hasCompletedSample = true
    }

    private func foregroundApplicationsByBundlePath() -> [String: AppIdentity] {
        var result: [String: AppIdentity] = [:]
        for application in NSWorkspace.shared.runningApplications where
            application.activationPolicy == .regular &&
            !application.isTerminated &&
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            guard let bundleURL = application.bundleURL,
                  let name = application.localizedName
            else { continue }

            let path = bundleURL.standardizedFileURL.path
            let id = application.bundleIdentifier ?? path
            result[path] = AppIdentity(
                id: id,
                name: name,
                bundleIdentifier: application.bundleIdentifier,
                bundleURLPath: path,
                icon: application.icon
            )
        }
        return result
    }

    private func allProcessIdentifiers() -> [pid_t] {
        let estimatedCount = max(0, proc_listallpids(nil, 0))
        guard estimatedCount > 0 else { return [] }

        var identifiers = [pid_t](repeating: 0, count: Int(estimatedCount) + 32)
        let count = identifiers.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard count > 0 else { return [] }
        return Array(identifiers.prefix(Int(count))).filter { $0 > 0 }
    }

    private func executablePath(for pid: pid_t) -> String? {
        // libproc defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN (4096),
        // but the C macro is not imported into Swift.
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(min(Int(length), buffer.count))
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func containingApplicationPath(for executablePath: String) -> String? {
        let components = URL(fileURLWithPath: executablePath).standardizedFileURL.pathComponents
        guard let appIndex = components.firstIndex(where: {
            $0.lowercased().hasSuffix(".app")
        }) else { return nil }

        return NSString.path(withComponents: Array(components.prefix(through: appIndex)))
    }

    private func readUsage(for pid: pid_t) -> (
        energyNanojoules: UInt64,
        processStartAbstime: UInt64
    )? {
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buffer in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, buffer)
            }
        }

        guard result == 0 else { return nil }
        return (usage.ri_energy_nj, usage.ri_proc_start_abstime)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) +
            TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
