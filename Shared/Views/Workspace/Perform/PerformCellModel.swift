//
//  PerformCellModel.swift
//  FluxKlang
//
//  A value-only model of one perform cell (#102 P1): anatomy, states, input result and meter signal. No view, no
//  gesture, no command, no clock, no hardware.
//

struct PerformCellLabels: Equatable, Sendable {
    /// 1...128 utf8 bytes.
    var cell: String
    /// 0...128 utf8 bytes; empty means the cell has no binding.
    var binding: String
}

struct PerformCellInput: Equatable, Sendable {
    var descriptor: ParameterDescriptor
    /// The control value (the position). It is never a meter reading.
    var value: ParameterValue
    var labels: PerformCellLabels
    var facts: PerformCellFacts
    /// The measured signal. Only a `MeterDisplay` is accepted, so no number can be turned into a level.
    var meter: MeterDisplay
}

/// What the cell shows for its signal, separate from the control value.
enum PerformSignal: Equatable, Sendable {
    /// "Unavailable" with its reason; there is no level.
    case unavailable(MeterUnavailableReason)
    /// One signal per channel, in channel order, with at least one measured channel.
    case channels([MeterChannelSignal])

    /// The measured levels in dBFS, in channel order; empty when the signal is unavailable.
    var levelsDBFS: [Double] {
        guard case .channels(let signals) = self else { return [] }
        return signals.compactMap {
            if case .measured(let level, _) = $0 { level } else { nil }
        }
    }

    fileprivate init(_ display: MeterDisplay) throws(PerformCellRefusal) {
        switch display {
        case .unavailable(let reason):
            self = .unavailable(reason)
        case .channels(let displays):
            guard !displays.isEmpty else { throw .meterHasNoChannels }
            let signals = displays.map(\.signal)
            let reasons = signals.compactMap { signal -> MeterUnavailableReason? in
                if case .unavailable(let reason) = signal { reason } else { nil }
            }
            if reasons.count == signals.count, let first = reasons.first {
                self = .unavailable(first)
            } else {
                self = .channels(signals)
            }
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self { true } else { false }
    }
}

/// One perform cell: label, value, binding, pickup, states and signal. Only `make` builds one, so every model has
/// passed the checks below; storage is `let`.
struct PerformCellModel: Equatable, Sendable {
    let descriptor: ParameterDescriptor
    let value: ParameterValue
    let label: String
    /// Empty when the cell has no binding.
    let bindingLabel: String
    let pickup: PickupState?
    let editMode: Bool
    /// Every state that holds, in the fixed priority order (resyncing first, `meterUnavailable` last).
    let states: [PerformCellState]
    let inputResult: PerformInputResult
    let signal: PerformSignal
    /// True only on the update that moves the cell into `waitingForPickup`.
    let announcesPickup: Bool

    private init(input: PerformCellInput, evaluation: PerformCellEvaluation, signal: PerformSignal,
                 announcesPickup: Bool) {
        descriptor = input.descriptor
        value = input.value
        label = input.labels.cell
        bindingLabel = input.labels.binding
        pickup = input.facts.pickup
        editMode = input.facts.editMode
        states = evaluation.states
        inputResult = evaluation.inputResult
        self.signal = signal
        self.announcesPickup = announcesPickup
    }

    var parameterID: ParameterID { descriptor.fields.id }
    var hasBinding: Bool { !bindingLabel.isEmpty }

    /// Builds the model, or throws the first failing check in the order of `PerformCellRefusal`.
    ///
    /// `previous` is required: the model the host showed before this update, or nil on first sight. `announcesPickup`
    /// is true when `waitingForPickup` holds now and did not hold in `previous`; a nil `previous`, or one for another
    /// parameter, counts as not waiting, so the first sight of a waiting cell announces once.
    static func make(_ input: PerformCellInput,
                     previous: PerformCellModel?) throws(PerformCellRefusal) -> PerformCellModel {
        let controlClass = input.descriptor.fields.controlClass
        guard controlClass == .live || controlClass == .hazardous else { throw .classNotPerformable(controlClass) }
        do {
            try input.descriptor.check(input.value)
        } catch {
            throw .valueRefused(error)
        }
        try validate(input.labels)
        try validate(input.facts, hasBinding: !input.labels.binding.isEmpty)
        let signal = try PerformSignal(input.meter)
        let evaluation = PerformCellEvaluation(facts: input.facts, controlClass: controlClass,
                                               signalUnavailable: signal.isUnavailable)
        let waitedBefore = previous.map {
            $0.parameterID == input.descriptor.fields.id && $0.states.contains(.waitingForPickup)
        } ?? false
        return PerformCellModel(input: input, evaluation: evaluation, signal: signal,
                                announcesPickup: evaluation.states.contains(.waitingForPickup) && !waitedBefore)
    }

    private static func validate(_ labels: PerformCellLabels) throws(PerformCellRefusal) {
        let cellBytes = labels.cell.utf8.count
        guard cellBytes > 0 else { throw .emptyLabel }
        guard PerformCellLimits.labelBytes.contains(cellBytes) else { throw .labelTooLong(bytes: cellBytes) }
        let bindingBytes = labels.binding.utf8.count
        guard PerformCellLimits.bindingLabelBytes.contains(bindingBytes) else {
            throw .bindingLabelTooLong(bytes: bindingBytes)
        }
    }

    private static func validate(_ facts: PerformCellFacts, hasBinding: Bool) throws(PerformCellRefusal) {
        guard hasBinding || (facts.pickup == nil && !facts.controllerStale) else {
            throw .bindingFactsWithoutBinding
        }
        switch facts.pickup {
        case .engaged(let hardware), .waiting(let hardware):
            if let hardware, !(0...1).contains(hardware) { throw .invalidHardwarePosition }
        case .unavailable:
            guard facts.controllerStale else { throw .pickupUnavailableWithoutStaleController }
        case nil:
            break
        }
        guard facts.targetExists || !facts.pendingRemoval else { throw .pendingRemovalWithoutTarget }
    }
}
