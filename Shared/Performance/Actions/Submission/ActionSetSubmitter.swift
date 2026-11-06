//
//  ActionSetSubmitter.swift
//  FluxKlang
//
//  Atomic admission of one action-set fire, and the scope sweep (#107 A2).
//  `ActionSetTriggerBuilder.decide` yields every member's stamp or none; this
//  submits them all or none. It stages copies of the value-type scheduler and
//  pending registry, submits every stamp into the copies, and publishes both
//  only when every member succeeded. Any refusal leaves the caller's
//  scheduler (session, clock, timeline), registry and ledger unchanged.
//
//  Cost: staging copies the scheduler and registry, O(scheduler size) per
//  fire or sweep. This is control-plane work only, never the render thread.
//
//  v1 keeps `notReady` as drop and report: a dropped decision submits
//  nothing and is returned unchanged; it is never deferred. `submit`
//  re-checks every member's readiness against the submit snapshot, so a
//  member that stopped being ready after `decide` drops the whole set with
//  nothing reserved. A readiness change AFTER admission can still drop that
//  member at commit (`.dropped`, `notReady`); that is the scheduler's job.
//

/// The caller's claim and trusted snapshots for one submission: the session token it believes
/// current, and the ledger/readiness the scheduler and registry are checked against.
///
/// This is a SNAPSHOT: `scheduler` holds copies of the ledger and readiness taken when it was built.
/// It MUST be rebuilt after every ledger bump, including `ActionSetSubmitter.userCancel`, which bumps
/// the caller's ledger `inout`, never this copy. A stale context still names the old cancel-scope
/// generation as current, so an old epoch would pass the staleness check and become pending handles
/// that commit later cancels.
struct ActionSetSubmitContext: Sendable {
    let session: TriggerSessionToken
    let scheduler: TriggerSchedulerContext

    var ledger: GenerationLedger { scheduler.ledger }
}

/// A free namespace: contract types such as `TriggerScheduler` are not extended from Performance code.
enum ActionSetSubmitter {
    /// Decides and submits one fire against ONE snapshot (`context.scheduler`'s ledger and readiness),
    /// which closes A1's same-snapshot caveat. Builder refusals surface as `.decision`.
    static func fire(_ resolved: ResolvedActionSet, request: ActionSetFireRequest, context: ActionSetSubmitContext,
                     scheduler: inout TriggerScheduler,
                     pending: inout ActionSetPendingTriggers) throws(ActionSetSubmitRefusal) -> ActionSetSubmission {
        let decision: ActionSetFireDecision
        do {
            decision = try ActionSetTriggerBuilder.decide(resolved, request: request,
                                                          readiness: context.scheduler.readiness,
                                                          ledger: context.ledger)
        } catch {
            throw .decision(error)
        }
        return try submit(decision, of: resolved, context: context, scheduler: &scheduler, pending: &pending)
    }

    /// Submits a decision for `resolved` all or nothing. Check order, all before any publication:
    /// 1. shape (one stamp per member, in member order, one shared cancel-scope generation);
    /// 2. registry capacity for every member, before any scheduler submit (so an unready set with a
    ///    nearly full registry throws `.pendingCapacity` rather than returning `.dropped`; both are atomic);
    /// 3. every requirement declared (`undeclaredRequirement`) and current (`staleRequirement`) in
    ///    `context.ledger`; an old epoch is refused, never admitted stale;
    /// 4. every member's readiness current (`ActionReadiness.isCurrent`) in `context.scheduler.readiness`;
    ///    otherwise the whole set is `.dropped` with an `ActionSetReadinessAggregate.evaluate` report and
    ///    nothing is reserved (no scheduler or registry entry, no trigger ID consumed);
    /// 5. registry staging (`duplicatePending`);
    /// 6. scheduler staging, member by member; the scheduler's error is kept as thrown.
    static func submit(_ decision: ActionSetFireDecision, of resolved: ResolvedActionSet,
                       context: ActionSetSubmitContext, scheduler: inout TriggerScheduler,
                       pending: inout ActionSetPendingTriggers) throws(ActionSetSubmitRefusal) -> ActionSetSubmission {
        switch decision {
        case .dropped(let report):
            let expected = resolved.set.id
            guard report.set == expected else { throw .setMismatch(expected: expected, actual: report.set) }
            return .dropped(report)
        case .fire(let stamps):
            return try admit(stamps, of: resolved, context: context, scheduler: &scheduler, pending: &pending)
        }
    }

    /// Bumps `cancelScope/<scope>` (`userCancel`), then sweeps the scheduler with `cancelStale`.
    /// Returns, in scheduler admission order, exactly the handles of the registered set members in
    /// `scope` that were still pending in the scheduler. Every set sharing the scope is cancelled
    /// together; other scopes survive. Repeating it bumps again and returns `[]`.
    ///
    /// The sweep is broader than `scope`: `cancelStale` also cancels, early, any request in another
    /// scope that was already stale against the ledger, with the same `.cancelled` outcome its commit
    /// would have produced. Those handles are not returned here; their outcomes reach `drain` like
    /// every cancellation, and their registry entries remain until `settle`d. A refusal changes nothing.
    /// Swept handles are matched to the registry by `TriggerID` only, not by session; rotating through
    /// `rotateSession(expected:scheduler:pending:)`, which requires an empty registry, keeps that sound.
    /// Rebuild any `ActionSetSubmitContext` afterwards: the bump goes to `ledger`, not to a context.
    static func userCancel(scope: GenerationSubject, ledger: inout GenerationLedger,
                           scheduler: inout TriggerScheduler,
                           pending: inout ActionSetPendingTriggers) throws(ActionSetSubmitRefusal) -> [TriggerHandle] {
        var stagedLedger = ledger
        var stagedPending = pending
        let cancelled: [TriggerID]
        do {
            cancelled = try stagedPending.userCancel(scope: scope, ledger: &stagedLedger)
        } catch {
            throw .cancel(error)
        }
        var stagedScheduler = scheduler
        let swept: [TriggerHandle]
        do {
            swept = try stagedScheduler.cancelStale(ledger: stagedLedger)
        } catch {
            throw .sweep(error)
        }
        let members = Set(cancelled)
        ledger = stagedLedger
        pending = stagedPending
        scheduler = stagedScheduler
        return swept.filter { members.contains($0.trigger) }
    }

    /// Forgets every drained outcome's trigger in the registry, so the registry and scheduler agree
    /// after `drain`. Returns, in outcome order, the triggers that were still registered.
    ///
    /// Matches the full handle: an outcome counts only when its handle's session is `scheduler`'s
    /// current session (pass the live scheduler the outcomes were drained from). Trigger IDs are unique
    /// only within a session, so a late outcome from before a `rotateSession` is skipped and can never
    /// remove a refired trigger's live entry. Settle before rotating, and rotate through
    /// `rotateSession(expected:scheduler:pending:)`, which refuses while any entry is unsettled. After a
    /// raw `TriggerScheduler.rotateSession`, an old session's unsettled entries are skipped here, keep
    /// their trigger IDs `duplicatePending`, and are cleared only by a `userCancel` of their scope.
    ///
    /// The registry holds at most `ActionSetPendingTriggers.maximumPending` (256) triggers, and only
    /// `settle` and a scope's `userCancel` forget them: a caller that drains but never settles fills it,
    /// after which every fire is refused with `.pendingCapacity`.
    @discardableResult
    static func settle(_ outcomes: [SessionOutcome], scheduler: TriggerScheduler,
                       pending: inout ActionSetPendingTriggers) -> [TriggerID] {
        let session = scheduler.currentToken
        var settled: [TriggerID] = []
        for outcome in outcomes where outcome.handle.session == session && pending.complete(outcome.handle.trigger) {
            settled.append(outcome.handle.trigger)
        }
        return settled
    }

    /// Rotates the scheduler's session (`TriggerScheduler.rotateSession`) only once every registry entry
    /// is settled; otherwise refuses with `.pendingNotSettled`, since `settle` skips an old session's
    /// outcomes. Drain, settle, then rotate. A refusal leaves the scheduler and registry unchanged.
    @discardableResult
    static func rotateSession(expected: TriggerSessionToken, scheduler: inout TriggerScheduler,
                              pending: ActionSetPendingTriggers) throws(ActionSetSubmitRefusal)
        -> TriggerSessionToken {
        guard pending.count == 0 else { throw .pendingNotSettled(count: pending.count) }
        var stagedScheduler = scheduler
        let token: TriggerSessionToken
        do {
            token = try stagedScheduler.rotateSession(expected: expected)
        } catch {
            throw .rotation(error)
        }
        scheduler = stagedScheduler
        return token
    }

    private static func admit(_ stamps: [TriggerStamp], of resolved: ResolvedActionSet,
                              context: ActionSetSubmitContext, scheduler: inout TriggerScheduler,
                              pending: inout ActionSetPendingTriggers) throws(ActionSetSubmitRefusal)
        -> ActionSetSubmission {
        let set = resolved.set
        _ = try ActionSetFireRecord.scope(of: stamps, set: set)
        guard stamps.count <= ActionSetPendingTriggers.maximumPending - pending.count else {
            throw .pendingCapacity(pending: pending.count, requested: stamps.count)
        }
        let ledger = context.ledger
        try requireCurrent(stamps, ledger: ledger)
        let readiness = context.scheduler.readiness
        guard stamps.allSatisfy({ readiness.isCurrent($0.action, ledger: ledger) }) else {
            let report = ActionSetReadinessAggregate.evaluate(resolved, readiness: readiness, ledger: ledger)
            return .dropped(ActionSetDropReport(set: set.id, reason: .notReady, readiness: report))
        }
        var stagedPending = pending
        for (index, stamp) in stamps.enumerated() {
            do {
                try stagedPending.register(stamp, ledger: ledger)
            } catch {
                throw .registry(index: index, error)
            }
        }
        var stagedScheduler = scheduler
        var handles: [TriggerHandle] = []
        for (index, stamp) in stamps.enumerated() {
            do {
                handles.append(try stagedScheduler.submit(stamp, session: context.session,
                                                          context: context.scheduler))
            } catch {
                throw .scheduler(index: index, error)
            }
        }
        let record = try ActionSetFireRecord.make(set: set, stamps: stamps, handles: handles)
        scheduler = stagedScheduler
        pending = stagedPending
        return .fired(record)
    }

    /// In member order, then requirement order: the first requirement the ledger never declared or
    /// holds at another generation refuses the fire.
    private static func requireCurrent(_ stamps: [TriggerStamp],
                                       ledger: GenerationLedger) throws(ActionSetSubmitRefusal) {
        for (index, stamp) in stamps.enumerated() {
            for requirement in stamp.requires {
                guard let live = ledger.generation(requirement.key) else {
                    throw .undeclaredRequirement(index: index, requirement.key)
                }
                guard live == requirement.generation else { throw .staleRequirement(index: index, requirement.key) }
            }
        }
    }
}
