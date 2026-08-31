import Foundation

/// Keeps command and dictation results in capture order while accounting for
/// every operation exactly once. A resolved result behind a stalled head arms
/// a timeout so the owning work can be cancelled before later text is pasted.
@MainActor
final class InjectionCoordinator {
    enum OperationKind: Equatable {
        case command
        case dictation
    }

    enum Outcome {
        case inject(String)
        case skip
    }

    private struct Operation {
        let kind: OperationKind
        var outcome: Outcome?
    }

    private let stallTimeout: TimeInterval
    private let injectionInterval: TimeInterval
    private let onInject: (String) -> Void
    private let onCancel: (Int, OperationKind) -> Void
    private let onProcessingCountChange: (Int) -> Void

    private var operations: [Int: Operation] = [:]
    private var nextSequence = 0
    private var sequenceCounter = 0
    private var drainPending = false
    private var headStallTimeout: DispatchWorkItem?
    private var stalledHeadSequence: Int?

    init(
        stallTimeout: TimeInterval,
        injectionInterval: TimeInterval = 0.4,
        onInject: @escaping (String) -> Void,
        onCancel: @escaping (Int, OperationKind) -> Void,
        onProcessingCountChange: @escaping (Int) -> Void
    ) {
        self.stallTimeout = stallTimeout
        self.injectionInterval = injectionInterval
        self.onInject = onInject
        self.onCancel = onCancel
        self.onProcessingCountChange = onProcessingCountChange
    }

    var pendingCount: Int { operations.count }
    var processingCount: Int { operations.count }
    var isProcessing: Bool { !operations.isEmpty }

    func begin(kind: OperationKind) -> Int {
        let sequence = sequenceCounter
        sequenceCounter += 1
        operations[sequence] = Operation(kind: kind, outcome: nil)
        onProcessingCountChange(operations.count)
        return sequence
    }

    func complete(_ sequence: Int, with outcome: Outcome) {
        guard var operation = operations[sequence], operation.outcome == nil else {
            return
        }
        operation.outcome = outcome
        operations[sequence] = operation
        drain()
    }

    func isPending(_ sequence: Int) -> Bool {
        operations[sequence] != nil
    }

    private func drain() {
        guard !drainPending else { return }

        while let operation = operations[nextSequence], let outcome = operation.outcome {
            if stalledHeadSequence == nextSequence {
                cancelHeadTimeout()
            }
            operations.removeValue(forKey: nextSequence)
            nextSequence += 1

            switch outcome {
            case .inject(let text):
                onInject(text)
                onProcessingCountChange(operations.count)
                drainPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + injectionInterval) { [weak self] in
                    guard let self else { return }
                    self.drainPending = false
                    self.drain()
                }
                return
            case .skip:
                onProcessingCountChange(operations.count)
            }
        }

        guard let head = operations[nextSequence], head.outcome == nil else { return }
        let hasResolvedFollower = operations.contains { sequence, operation in
            sequence > nextSequence && operation.outcome != nil
        }
        guard hasResolvedFollower else { return }

        let stalledSequence = nextSequence
        if stalledHeadSequence == stalledSequence, headStallTimeout != nil {
            return
        }
        cancelHeadTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stalledHeadSequence == stalledSequence else { return }
            self.headStallTimeout = nil
            self.stalledHeadSequence = nil
            guard
                  let stalled = self.operations[stalledSequence],
                  stalled.outcome == nil,
                  self.nextSequence == stalledSequence else { return }

            self.operations.removeValue(forKey: stalledSequence)
            self.nextSequence += 1
            self.onCancel(stalledSequence, stalled.kind)
            self.onProcessingCountChange(self.operations.count)
            self.drain()
        }
        stalledHeadSequence = stalledSequence
        headStallTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stallTimeout, execute: work)
    }

    private func cancelHeadTimeout() {
        headStallTimeout?.cancel()
        headStallTimeout = nil
        stalledHeadSequence = nil
    }
}
