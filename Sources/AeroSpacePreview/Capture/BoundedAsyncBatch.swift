/// Runs asynchronous operations with a fixed concurrency bound and publishes
/// each result as soon as it completes. Cancellation prevents queued elements
/// from starting; already-running operations retain normal structured-task
/// cancellation semantics.
struct BoundedAsyncBatch<Element: Sendable, Result: Sendable>: Sendable {
    let elements: [Element]
    let maximumConcurrentTasks: Int
    let operation: @Sendable (Element) async -> Result

    func run(_ receive: @Sendable (Result) -> Void) async {
        guard !elements.isEmpty, !Task.isCancelled else { return }
        let limit = max(1, maximumConcurrentTasks)

        await withTaskGroup(of: Result.self) { group in
            var iterator = elements.makeIterator()
            for _ in 0..<min(limit, elements.count) {
                guard let element = iterator.next() else { break }
                _ = group.addTaskUnlessCancelled { await operation(element) }
            }

            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                receive(result)
                if let element = iterator.next() {
                    _ = group.addTaskUnlessCancelled { await operation(element) }
                }
            }
        }
    }
}
