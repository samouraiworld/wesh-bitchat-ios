//
// TestEnvironment.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Process-level test-environment detection for singletons that must swap a
/// real OS-backed dependency (keychain, persistent defaults, notifications)
/// for an in-memory one under test. Mirrors the detection already used by
/// `NotificationService` and `LocationStateManager`.
enum TestEnvironment {
    /// The unit-test schemes set an explicit flag before App.init runs.
    /// Existing XCTest and CI detection also covers other test entry points.
    static let isRunningTests = detectsTests(
        environment: ProcessInfo.processInfo.environment,
        xctestClassPresent: NSClassFromString("XCTestCase") != nil
    )

    static func detectsTests(environment: [String: String], xctestClassPresent: Bool) -> Bool {
        environment["WESH_UNIT_TEST_HOST"] == "1" || xctestClassPresent ||
            environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["GITHUB_ACTIONS"] != nil ||
            environment["CI"] != nil
    }
}
