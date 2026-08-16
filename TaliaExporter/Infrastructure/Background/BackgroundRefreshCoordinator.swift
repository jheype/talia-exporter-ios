import BackgroundTasks
import Foundation

final class BackgroundRefreshCoordinator: @unchecked Sendable {
    static let shared = BackgroundRefreshCoordinator()
    static let taskIdentifier = "com.talia.exporter.refresh"

    private let lock = NSLock()
    private var refreshHandler: (@Sendable () async -> Bool)?
    private var isRegistered = false

    private init() {}

    func register() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRegistered else { return }

        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handle(refreshTask)
        }
    }

    func setHandler(_ handler: @escaping @Sendable () async -> Bool) {
        lock.withLock {
            refreshHandler = handler
        }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Scheduling is best-effort. The next foreground refresh retries it.
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        schedule()
        let operation = Task { [weak self] in
            guard let handler = self?.handlerSnapshot() else {
                task.setTaskCompleted(success: false)
                return
            }
            task.setTaskCompleted(success: await handler())
        }
        task.expirationHandler = {
            operation.cancel()
        }
    }

    private func handlerSnapshot() -> (@Sendable () async -> Bool)? {
        lock.withLock { refreshHandler }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}
