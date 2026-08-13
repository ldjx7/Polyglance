import AppKit

@MainActor
final class ApplicationTerminationCoordinator {
    typealias HasPendingWork = @MainActor () -> Bool
    typealias Prepare = @MainActor () async -> Bool
    typealias Reply = @MainActor (Bool) -> Void

    private let hasPendingWork: HasPendingWork
    private let prepare: Prepare
    private var isPreparing = false
    private var pendingReplies: [Reply] = []

    init(
        hasPendingWork: @escaping HasPendingWork,
        prepare: @escaping Prepare
    ) {
        self.hasPendingWork = hasPendingWork
        self.prepare = prepare
    }

    func requestTermination(reply: @escaping Reply) -> NSApplication.TerminateReply {
        if isPreparing {
            pendingReplies.append(reply)
            return .terminateLater
        }
        guard hasPendingWork() else {
            return .terminateNow
        }

        isPreparing = true
        pendingReplies.append(reply)
        Task { @MainActor [self] in
            let shouldTerminate = await prepare()
            isPreparing = false
            let replies = pendingReplies
            pendingReplies.removeAll(keepingCapacity: false)
            replies.forEach { $0(shouldTerminate) }
        }
        return .terminateLater
    }
}
