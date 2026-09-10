//
//  TemporaryMoveAppModel.swift
//  FluxKlang
//

import Foundation

extension AppModel {
    func temporaryMoveImpact(
        applying move: TemporaryDeviceMove,
        returningHome: Bool = false
    ) -> (impact: TemporaryMoveRoutingImpact, hasErrors: Bool) {
        let current = studioConnections.connections
        let candidate = temporaryConnections(move: move, returningHome: returningHome)
        let previousCompiled = studioCompiledRouting(connections: current)
        let compiled = studioCompiledRouting(connections: candidate)
        let previous = current.effectiveHome
        let effective = candidate.effectiveHome
        let equipmentID = move.equipmentID
        return (
            TemporaryMoveRoutingImpact.transition(
                from: previousCompiled.settings,
                to: compiled.settings,
                previousInputConnectors: Set(previous.inputs.filter {
                    $0.equipmentID == equipmentID
                }.map(\.connector)),
                previousOutputConnectors: Set(previous.outputs.filter {
                    $0.equipmentID == equipmentID
                }.map(\.connector)),
                desiredInputConnectors: Set(effective.inputs.filter {
                    $0.equipmentID == equipmentID
                }.map(\.connector)),
                desiredOutputConnectors: Set(effective.outputs.filter {
                    $0.equipmentID == equipmentID
                }.map(\.connector))
            ),
            compiled.hasErrors
        )
    }

    func applyTemporaryMove(_ move: TemporaryDeviceMove) async throws -> TemporaryMoveVerification {
        guard isConnected else { throw TemporaryMoveApplyError.notConnected }
        try TemporaryMoveAllocator.validate(
            move,
            home: studioConnections.connections.home,
            equipment: equipment.items,
            existingMoves: studioConnections.connections.temporaryMoves
        )
        let preview = temporaryMoveImpact(applying: move)
        guard !preview.hasErrors else { throw TemporaryMoveApplyError.routingErrors }
        try await studioConnections.reserveTemporaryMove(move, equipment: equipment.items)
        await wing.apply(preview.impact.settings)
        let verification = await verify(preview.impact, previous: nil)
        try await studioConnections.activateTemporaryMove(
            move.activating(with: verification),
            equipment: equipment.items
        )
        return verification
    }

    func returnTemporaryMoveHome(_ moveID: TemporaryDeviceMove.ID) async throws -> TemporaryMoveVerification {
        guard isConnected else { throw TemporaryMoveApplyError.notConnected }
        guard let move = studioConnections.connections.temporaryMoves.first(where: { $0.id == moveID }) else {
            throw TemporaryMoveApplyError.missingMove
        }
        let returning = move.preparingReturn()
        let preview = temporaryMoveImpact(applying: returning, returningHome: true)
        guard !preview.hasErrors else { throw TemporaryMoveApplyError.routingErrors }
        await studioConnections.updateTemporaryMove(returning)
        await wing.apply(preview.impact.settings)
        let verification = await verify(preview.impact, previous: nil)
        if verification.state == .verified {
            await studioConnections.removeTemporaryMove(moveID)
        } else {
            var unresolved = returning
            unresolved.verification = verification
            await studioConnections.updateTemporaryMove(unresolved)
        }
        return verification
    }

    func verifyTemporaryMovesAfterReconnect() async {
        let moves = studioConnections.connections.temporaryMoves.filter { $0.lifecycle.isTracked }
        guard isConnected, !moves.isEmpty else { return }
        for move in moves {
            let impact = reconnectImpact(for: move)
            let verification = await verify(impact, previous: move.verification)
            var checked = move
            if checked.lifecycle == .readyToReturn, verification.state == .verified {
                await studioConnections.removeTemporaryMove(checked.id)
                continue
            }
            if checked.lifecycle == .readyToApply {
                checked.lifecycle = .active
            }
            checked.verification = verification
            await studioConnections.updateTemporaryMove(checked)
        }
    }

    private func reconnectImpact(for move: TemporaryDeviceMove) -> TemporaryMoveRoutingImpact {
        let desired = studioConnections.connections
        var previous = desired
        previous.temporaryMoves.removeAll { $0.id == move.id }
        if move.lifecycle == .readyToReturn {
            previous.temporaryMoves.append(move.activating(with: move.verification))
        }
        let previousHome = previous.effectiveHome
        let desiredHome = desired.effectiveHome
        let equipmentID = move.equipmentID
        return TemporaryMoveRoutingImpact.transition(
            from: studioCompiledRouting(connections: previous).settings,
            to: studioCompiledRouting(connections: desired).settings,
            previousInputConnectors: Set(previousHome.inputs.filter {
                $0.equipmentID == equipmentID
            }.map(\.connector)),
            previousOutputConnectors: Set(previousHome.outputs.filter {
                $0.equipmentID == equipmentID
            }.map(\.connector)),
            desiredInputConnectors: Set(desiredHome.inputs.filter {
                $0.equipmentID == equipmentID
            }.map(\.connector)),
            desiredOutputConnectors: Set(desiredHome.outputs.filter {
                $0.equipmentID == equipmentID
            }.map(\.connector))
        )
    }

    private func temporaryConnections(
        move: TemporaryDeviceMove,
        returningHome: Bool
    ) -> GlobalStudioConnections {
        var candidate = studioConnections.connections
        candidate.temporaryMoves.removeAll { $0.id == move.id || $0.equipmentID == move.equipmentID }
        if !returningHome {
            candidate.temporaryMoves.append(move.activating(with: move.verification))
        }
        return candidate
    }

    private func verify(
        _ impact: TemporaryMoveRoutingImpact,
        previous: TemporaryMoveVerification?
    ) async -> TemporaryMoveVerification {
        await wing.refreshForVerification(impact.expectedConfirmations.map(\.address))
        try? await Task.sleep(for: .milliseconds(300))
        return TemporaryMoveVerifier.verify(
            expected: impact.expectedConfirmations,
            confirmedValues: wing.confirmedValues,
            previous: previous
        )
    }
}
