@testable import Ayna
import Testing

@Suite("Runtime Environment Tests")
struct RuntimeEnvironmentTests {
    @Test
    func `swiftPM testing helper is detected as unit test process`() {
        #expect(RuntimeEnvironment.isRunningUnitTests(
            processName: "swiftpm-testing-helper",
            environment: [:],
            bundlePath: "/tmp/swiftpm-testing-helper",
            hasSwiftTestingRuntime: false
        ))
    }

    @Test
    func `unit tests use a separate keychain service identifier`() {
        let identifier = RuntimeEnvironment.defaultKeychainServiceIdentifier(
            bundleIdentifier: nil,
            processName: "swiftpm-testing-helper",
            environment: [:],
            bundlePath: "/tmp/swiftpm-testing-helper",
            isUITesting: false,
            isRunningUnitTests: true
        )

        #expect(identifier == RuntimeEnvironment.unitTestKeychainServiceIdentifier)
        #expect(identifier != RuntimeEnvironment.productionKeychainServiceIdentifier)
    }

    @Test
    func `ui tests are detected from launch environment`() {
        #expect(RuntimeEnvironment.isUITesting(
            arguments: [],
            environment: ["AYNA_UI_TESTING": "1"]
        ))
    }

    @Test
    func `ui tests use a separate keychain service identifier`() {
        let identifier = RuntimeEnvironment.defaultKeychainServiceIdentifier(
            bundleIdentifier: RuntimeEnvironment.productionKeychainServiceIdentifier,
            processName: "Ayna",
            environment: [:],
            bundlePath: "/Applications/Ayna.app",
            isUITesting: true,
            isRunningUnitTests: false
        )

        #expect(identifier == RuntimeEnvironment.uiTestKeychainServiceIdentifier)
        #expect(identifier != RuntimeEnvironment.productionKeychainServiceIdentifier)
    }

    @Test
    func `swiftPM development launches use stable development keychain service`() {
        let identifier = RuntimeEnvironment.defaultKeychainServiceIdentifier(
            bundleIdentifier: nil,
            processName: "Ayna",
            environment: [:],
            bundlePath: "/Users/example/ayna/.build/debug/Ayna",
            isUITesting: false,
            isRunningUnitTests: false
        )

        #expect(identifier == RuntimeEnvironment.developmentKeychainServiceIdentifier)
    }

    @Test
    func `dev keychain namespace uses separate encrypted storage directory`() {
        let directoryName = RuntimeEnvironment.defaultApplicationSupportDirectoryName(
            bundleIdentifier: nil,
            processName: "Ayna",
            environment: [:],
            bundlePath: "/Users/example/ayna/.build/debug/Ayna",
            isUITesting: false,
            isRunningUnitTests: false
        )

        #expect(directoryName == RuntimeEnvironment.developmentApplicationSupportDirectoryName)
        #expect(directoryName != RuntimeEnvironment.productionApplicationSupportDirectoryName)
    }

    @Test
    func `production keychain namespace uses production encrypted storage directory`() {
        let directoryName = RuntimeEnvironment.defaultApplicationSupportDirectoryName(
            bundleIdentifier: RuntimeEnvironment.productionKeychainServiceIdentifier,
            processName: "Ayna",
            environment: [:],
            bundlePath: "/Applications/Ayna.app",
            isUITesting: false,
            isRunningUnitTests: false
        )

        #expect(directoryName == RuntimeEnvironment.productionApplicationSupportDirectoryName)
    }

    @Test
    func `signed app bundle uses production keychain service`() {
        let identifier = RuntimeEnvironment.defaultKeychainServiceIdentifier(
            bundleIdentifier: RuntimeEnvironment.productionKeychainServiceIdentifier,
            processName: "Ayna",
            environment: [:],
            bundlePath: "/Applications/Ayna.app",
            isUITesting: false,
            isRunningUnitTests: false
        )

        #expect(identifier == RuntimeEnvironment.productionKeychainServiceIdentifier)
    }
}
