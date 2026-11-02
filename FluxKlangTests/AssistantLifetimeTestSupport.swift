actor AssistantLifetimeGate {
    private let entries: AsyncStream<Int>
    private let entry: AsyncStream<Int>.Continuation
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0

    init() {
        (entries, entry) = AsyncStream<Int>.makeStream()
    }

    func enter() async {
        guard !released else { return }
        entered += 1
        entry.yield(entered)
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func releaseAll() {
        released = true
        let pending = waiters
        waiters.removeAll()
        entry.finish()
        for waiter in pending { waiter.resume() }
    }

    func waitForEntries(_ count: Int = 1) async -> Bool {
        if entered >= count { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [entries] in
                for await value in entries where value >= count { return true }
                return false
            }
            group.addTask {
                // A deadline fails missing signals; elapsed time never proves completion.
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let observed = await group.next() ?? false
            group.cancelAll()
            return observed
        }
    }
}
