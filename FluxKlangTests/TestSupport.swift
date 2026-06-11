//
//  TestSupport.swift
//  FluxKlangTests
//
//  Shared helpers for the test suites.
//

import Foundation

/// Polls `condition` until it becomes true or `timeout` elapses. Used to await
/// asynchronous demo-controller ingestion without sleeping for a fixed delay.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}
