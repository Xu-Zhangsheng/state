import Foundation
import os.log

@MainActor
class SMCReaderConnection {
    private var connection: NSXPCConnection?
    // Reuse one remote proxy for the lifetime of a connection.  Creating a
    // fresh proxy for every battery/adapter sample adds avoidable XPC setup
    // work and also makes concurrent polls harder to reason about.
    private var helperProxy: HelperProtocol?
    private let serviceName: String
    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "SMCReaderConnection"
    )

    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private static let maxReconnectAttempts = 5
    private static let baseReconnectDelay: TimeInterval = 1.0

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    func getHelper(errorHandler: @escaping @Sendable (Error) -> Void) -> HelperProtocol? {
        guard let connection else { return nil }
        if let helperProxy { return helperProxy }

        let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? HelperProtocol
        helperProxy = proxy
        return proxy
    }

    func connect() {
        logger.info("Setting up XPC connection to \(self.serviceName)")
        connection = NSXPCConnection(serviceName: serviceName)
        connection?.remoteObjectInterface = NSXPCInterface(
            with: HelperProtocol.self
        )

        connection?.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.logger.error("XPC connection invalidated")
                self.connection = nil
                self.helperProxy = nil
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
            }
        }

        connection?.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.logger.warning("XPC connection interrupted")
                self.connection = nil
                self.helperProxy = nil
                self.scheduleReconnect()
            }
        }

        connection?.resume()
        helperProxy = nil
        reconnectAttempts = 0
        logger.info("XPC connection resumed")
    }

    private func scheduleReconnect() {
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            logger.error(
                "Exceeded max reconnect attempts (\(Self.maxReconnectAttempts)), giving up"
            )
            return
        }

        reconnectAttempts += 1
        let delay =
            Self.baseReconnectDelay * pow(2.0, Double(reconnectAttempts - 1))
        logger.info(
            "Scheduling reconnect attempt \(self.reconnectAttempts) in \(delay)s"
        )

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.connect()
        }
    }

    func disconnect() {
        logger.info("Disconnecting XPC connection")
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.invalidate()
        connection = nil
    }

}
