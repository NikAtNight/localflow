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
        let trace: DictationTrace?
        var outcome: Outcome?
    }

    private let stallTimeout: TimeInterval
    private let injectionInterval: TimeInterval
    private let scheduleStall: (TimeInterval, DispatchWorkItem) -> Void
    private let onInject: (String) -> Void
    private let onCancel: (Int, OperationKind) -> Void
    private let onProcessingCountChange: (Int) -> Void

    private var operations: [Int: Operation] = [:]
    private var nextSequenceToDrain = 0
    private var sequenceNumberCounter = 0
    private var drainPending = false
    private var headStallTimeout: DispatchWorkItem?
    private var stalledHeadSequence: Int?

    init(
        stallTimeout: TimeInterval,
        injectionInterval: TimeInterval = 0.4,
        scheduleStall: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        onInject: @escaping (String) -> Void,
        onCancel: @escaping (Int, OperationKind) -> Void,
        onProcessingCountChange: @escaping (Int) -> Void
    ) {
        self.stallTimeout = stallTimeout
        self.injectionInterval = injectionInterval
        self.scheduleStall = scheduleStall
        self.onInject = onInject
        self.onCancel = onCancel
        self.onProcessingCountChange = onProcessingCountChange
    }

    var pendingCount: Int { operations.count }

    func begin(kind: OperationKind, trace: DictationTrace? = DictationTrace.current) -> Int {
        let sequence = sequenceNumberCounter
        sequenceNumberCounter += 1
        operations[sequence] = Operation(kind: kind, trace: trace, outcome: nil)
        onProcessingCountChange(operations.count)
        return sequence
    }

    func complete(_ sequence: Int, with outcome: Outcome) {
        guard var operation = operations[sequence], operation.outcome == nil else {
            return
        }
        operation.outcome = outcome
        operation.trace?.record(.injectionQueued, fields: [
            .sequence: Double(sequence), .pendingCount: Double(operations.count)
        ])
        operations[sequence] = operation
        drain()
    }

    func isPending(_ sequence: Int) -> Bool {
        operations[sequence] != nil
    }

    private func drain() {
        guard !drainPending else { return }

        while let operation = operations[nextSequenceToDrain], let outcome = operation.outcome {
            if stalledHeadSequence == nextSequenceToDrain {
                cancelHeadTimeout()
            }
            operations.removeValue(forKey: nextSequenceToDrain)
            nextSequenceToDrain += 1

            switch outcome {
            case .inject(let text):
                operation.trace?.record(.injectionStarted, fields: [.sequence: Double(nextSequenceToDrain - 1)])
                DictationTrace.$current.withValue(operation.trace) { onInject(text) }
                onProcessingCountChange(operations.count)
                drainPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + injectionInterval) { [weak self] in
                    guard let self else { return }
                    self.drainPending = false
                    self.drain()
                }
                return
            case .skip:
                operation.trace?.record(.injectionSkipped)
                onProcessingCountChange(operations.count)
            }
        }

        guard let head = operations[nextSequenceToDrain], head.outcome == nil else { return }
        let hasResolvedFollower = operations.contains { sequence, operation in
            sequence > nextSequenceToDrain && operation.outcome != nil
        }
        guard hasResolvedFollower else { return }

        let stalledSequence = nextSequenceToDrain
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
                  self.nextSequenceToDrain == stalledSequence else { return }

            self.operations.removeValue(forKey: stalledSequence)
            stalled.trace?.record(.injectionSkipped, status: .cancelled)
            self.nextSequenceToDrain += 1
            self.onCancel(stalledSequence, stalled.kind)
            self.onProcessingCountChange(self.operations.count)
            self.drain()
        }
        stalledHeadSequence = stalledSequence
        headStallTimeout = work
        scheduleStall(stallTimeout, work)
    }

    private func cancelHeadTimeout() {
        headStallTimeout?.cancel()
        headStallTimeout = nil
        stalledHeadSequence = nil
    }
}
