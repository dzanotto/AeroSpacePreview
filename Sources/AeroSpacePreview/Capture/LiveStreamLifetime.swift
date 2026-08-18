/// Idempotent cleanup for a group of streams. If cancellation wins the race
/// with asynchronous startup, later-installed streams are stopped immediately.
actor LiveStreamLifetime {
    typealias StopOperation = @Sendable () async -> Void

    private var stopOperations: [StopOperation] = []
    private var isStopped = false

    func install(_ operations: [StopOperation]) async {
        guard !isStopped else {
            await Self.run(operations)
            return
        }
        stopOperations.append(contentsOf: operations)
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        let operations = stopOperations
        stopOperations.removeAll()
        await Self.run(operations)
    }

    private static func run(_ operations: [StopOperation]) async {
        await withTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask { await operation() }
            }
        }
    }
}
