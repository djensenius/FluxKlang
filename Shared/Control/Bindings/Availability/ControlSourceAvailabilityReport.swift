/// What the caller's live-origin set says about one binding's controller. `sourceAbsent` means only that the caller did
/// not list the origin as live: it does not say unplugged, lost or muted. The two last cases are never judged present
/// or absent.
enum ControlSourceAvailabilityStatus: Hashable, Sendable {
    /// The source id parses and its origin is in the live set.
    case available
    /// The source id parses and its origin is not in the live set.
    case sourceAbsent(ControlSourceOrigin)
    /// The source id does not start with `midi.`.
    case notMIDISource
    /// The source id starts with `midi.` but is not the canonical form of a `ControlSourceKey`.
    case malformedSource
}

/// One binding and its status. Built only inside this file.
struct ControlSourceAvailabilityEntry: Hashable, Sendable {
    let binding: BindingID
    let source: ControlSourceID
    let status: ControlSourceAvailabilityStatus

    fileprivate init(binding: BindingID, source: ControlSourceID, status: ControlSourceAvailabilityStatus) {
        self.binding = binding
        self.source = source
        self.status = status
    }
}

/// One entry per binding, ascending by binding id compared by UTF-8 bytes; the distinct origins of the `sourceAbsent`
/// entries, ascending by origin; and three counts that sum to `entries.count`. `unjudgedCount` is `notMIDISource` plus
/// `malformedSource`. Built only inside this file, by `ControlSourceAvailability.project`.
struct ControlSourceAvailabilityReport: Hashable, Sendable {
    let entries: [ControlSourceAvailabilityEntry]
    let absentOrigins: [ControlSourceOrigin]
    let availableCount: Int
    let absentCount: Int
    let unjudgedCount: Int

    fileprivate init(
        entries: [ControlSourceAvailabilityEntry], absentOrigins: [ControlSourceOrigin],
        availableCount: Int, absentCount: Int, unjudgedCount: Int
    ) {
        self.entries = entries
        self.absentOrigins = absentOrigins
        self.availableCount = availableCount
        self.absentCount = absentCount
        self.unjudgedCount = unjudgedCount
    }

    /// Judges the bindings in the order given (`project` passes them sorted) and totals the result.
    fileprivate static func assemble(
        sortedBindings: [ControlBinding], status: (ControlBinding) -> ControlSourceAvailabilityStatus
    ) -> Self {
        var entries: [ControlSourceAvailabilityEntry] = []
        entries.reserveCapacity(sortedBindings.count)
        var absent = Set<ControlSourceOrigin>()
        var availableCount = 0
        var absentCount = 0
        var unjudgedCount = 0
        for binding in sortedBindings {
            let judged = status(binding)
            switch judged {
            case .available:
                availableCount += 1
            case .sourceAbsent(let origin):
                absentCount += 1
                absent.insert(origin)
            case .notMIDISource, .malformedSource:
                unjudgedCount += 1
            }
            entries.append(ControlSourceAvailabilityEntry(binding: binding.id, source: binding.source, status: judged))
        }
        return Self(
            entries: entries, absentOrigins: absent.sorted(),
            availableCount: availableCount, absentCount: absentCount, unjudgedCount: unjudgedCount
        )
    }
}

/// Why `project` refused the whole call. Checked in this order, each over the whole input before the next, and all
/// before any source id is parsed: `tooManyBindings`, `tooManyLiveOrigins`, `duplicateBinding`. No partial report.
enum ControlSourceAvailabilityRefusal: Error, Hashable, Sendable {
    /// More than `ControlSourceAvailability.maximumBindings` bindings.
    case tooManyBindings(Int)
    /// More than 128 live origins.
    case tooManyLiveOrigins(Int)
    /// A binding id appears more than once; the smallest repeated id by UTF-8 bytes.
    case duplicateBinding(BindingID)
}

extension ControlSourceAvailability {
    /// Refusals are checked in the order of `ControlSourceAvailabilityRefusal`. An empty binding list gives an empty
    /// report; an empty live set makes every judgeable binding `sourceAbsent`. This is the only way to build a report.
    static func project(
        bindings: [ControlBinding], liveOrigins: Set<ControlSourceOrigin>
    ) throws(ControlSourceAvailabilityRefusal) -> ControlSourceAvailabilityReport {
        guard bindings.count <= maximumBindings else { throw .tooManyBindings(bindings.count) }
        guard liveOrigins.count <= maximumLiveOrigins else { throw .tooManyLiveOrigins(liveOrigins.count) }
        let sorted = bindings.sorted { precedes($0.id, $1.id) }
        try requireDistinct(sorted: sorted)
        return ControlSourceAvailabilityReport.assemble(sortedBindings: sorted) { status(of: $0, live: liveOrigins) }
    }

    private static func status(
        of binding: ControlBinding, live: Set<ControlSourceOrigin>
    ) -> ControlSourceAvailabilityStatus {
        do throws(ControlFeedbackMIDI1Refusal) {
            let key = try ControlFeedbackMIDI1SourceParser.parse(binding.source)
            return live.contains(key.origin) ? .available : .sourceAbsent(key.origin)
        } catch {
            switch error {
            case .notMIDISource:
                return .notMIDISource
            case .malformedSource, .unsupportedKind, .relativeProfile, .invalidProfile, .widthMismatch,
                 .controllerNotReadable, .stepOutOfRange, .tooManyMessages, .profileMissing:
                return .malformedSource
            }
        }
    }

    /// The input is sorted, so a repeated id sits next to its twin and the first such pair is the smallest.
    private static func requireDistinct(
        sorted: [ControlBinding]
    ) throws(ControlSourceAvailabilityRefusal) {
        for (previous, current) in zip(sorted, sorted.dropFirst())
        where previous.id.rawValue.utf8.elementsEqual(current.id.rawValue.utf8) {
            throw .duplicateBinding(current.id)
        }
    }

    private static func precedes(_ lhs: BindingID, _ rhs: BindingID) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }
}
