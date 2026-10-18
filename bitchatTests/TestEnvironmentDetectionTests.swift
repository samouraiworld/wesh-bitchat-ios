// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Combine
import Testing
@testable import bitchat

struct TestEnvironmentDetectionTests {
    @Test @MainActor
    func actualTestHostFlagPreventsRuntimeFactoryConstruction() {
        #expect(TestEnvironment.isRunningTests)
        var factoryCalls = 0
        let owner = AppRuntimeOwner(isTesting: TestEnvironment.isRunningTests) {
            factoryCalls += 1
            return SyntheticDetectionRuntime()
        }

        #expect(factoryCalls == 0)
        #expect(owner.runtime == nil)
    }

    @Test
    func explicitUnitTestHostFlagDoesNotNeedXCTestToBeLoaded() {
        #expect(TestEnvironment.detectsTests(environment: ["WESH_UNIT_TEST_HOST": "1"], xctestClassPresent: false))
    }

    @Test
    func ordinaryAppLaunchIsNotMistakenForAUnitTestHost() {
        #expect(!TestEnvironment.detectsTests(environment: [:], xctestClassPresent: false))
        #expect(!TestEnvironment.detectsTests(environment: ["WESH_UNIT_TEST_HOST": "0"], xctestClassPresent: false))
        #expect(!TestEnvironment.detectsTests(environment: ["WESH_UNIT_TEST_HOST": "true"], xctestClassPresent: false))
    }

    @Test
    func existingXCTestEntryPointsRemainRecognized() {
        #expect(TestEnvironment.detectsTests(environment: [:], xctestClassPresent: true))
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath"] {
            #expect(TestEnvironment.detectsTests(environment: [key: "synthetic"], xctestClassPresent: false))
        }
    }

    @Test
    func existingCIEntryPointsRemainRecognized() {
        for key in ["GITHUB_ACTIONS", "CI"] {
            #expect(TestEnvironment.detectsTests(environment: [key: "synthetic"], xctestClassPresent: false))
        }
    }
}

@MainActor
private final class SyntheticDetectionRuntime: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
}
