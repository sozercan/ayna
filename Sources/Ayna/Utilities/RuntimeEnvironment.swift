import Foundation

/// Process/runtime detection used to keep tests and SwiftPM helper tools away from
/// the production Keychain namespace.
enum RuntimeEnvironment {
    static let productionKeychainServiceIdentifier = "com.sertacozercan.ayna"
    static let developmentKeychainServiceIdentifier = "com.sertacozercan.ayna.dev"
    static let unitTestKeychainServiceIdentifier = "com.sertacozercan.ayna.tests"
    static let uiTestKeychainServiceIdentifier = "com.sertacozercan.ayna.ui-tests"

    static let productionApplicationSupportDirectoryName = "Ayna"
    static let developmentApplicationSupportDirectoryName = "Ayna-Dev"
    static let unitTestApplicationSupportDirectoryName = "Ayna-Tests"
    static let uiTestApplicationSupportDirectoryName = "Ayna-UITests"

    private static let uiTestFlag = "AYNA_UI_TESTING"
    private static let uiTestLaunchArgument = "--ui-testing"
    private static let uiTestUserDefaultsArgument = "-AYNA_UI_TESTING"

    static var isUITesting: Bool {
        isUITesting(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static var isRunningUnitTests: Bool {
        isRunningUnitTests(
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment,
            bundlePath: Bundle.main.bundleURL.path,
            hasSwiftTestingRuntime: hasSwiftTestingRuntime
        )
    }

    static var defaultKeychainServiceIdentifier: String {
        defaultKeychainServiceIdentifier(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment,
            bundlePath: Bundle.main.bundleURL.path,
            isUITesting: isUITesting,
            isRunningUnitTests: isRunningUnitTests
        )
    }

    static var defaultApplicationSupportDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent(defaultApplicationSupportDirectoryName, isDirectory: true)
    }

    static var defaultApplicationSupportDirectoryName: String {
        defaultApplicationSupportDirectoryName(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            processName: ProcessInfo.processInfo.processName,
            environment: ProcessInfo.processInfo.environment,
            bundlePath: Bundle.main.bundleURL.path,
            isUITesting: isUITesting,
            isRunningUnitTests: isRunningUnitTests
        )
    }

    static func isUITesting(arguments: [String], environment: [String: String]) -> Bool {
        environment[uiTestFlag] == "1" ||
            arguments.contains(uiTestLaunchArgument) ||
            arguments.contains(uiTestUserDefaultsArgument)
    }

    static func isRunningUnitTests(
        processName: String,
        environment: [String: String],
        bundlePath: String,
        hasSwiftTestingRuntime: Bool
    ) -> Bool {
        processName == "swiftpm-testing-helper" ||
            environment["XCTestConfigurationFilePath"] != nil ||
            environment["SWIFT_TESTING_ENABLED"] == "1" ||
            bundlePath.hasSuffix(".xctest") ||
            bundlePath.contains("/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents") ||
            hasSwiftTestingRuntime
    }

    static func defaultKeychainServiceIdentifier(
        bundleIdentifier: String?,
        processName: String,
        environment: [String: String],
        bundlePath: String,
        isUITesting: Bool,
        isRunningUnitTests: Bool
    ) -> String {
        if let override = environment["AYNA_KEYCHAIN_SERVICE_IDENTIFIER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return override
        }

        if isRunningUnitTests {
            return unitTestKeychainServiceIdentifier
        }

        if isUITesting {
            return uiTestKeychainServiceIdentifier
        }

        if isProductionAppBundle(bundleIdentifier: bundleIdentifier) {
            return productionKeychainServiceIdentifier
        }

        // SwiftPM/dev command-line launches do not have the app bundle's stable
        // code-signing identity. Give them a stable, separate namespace so they
        // never ask to access credentials created by Ayna.app.
        if isSwiftPMOrDevelopmentLaunch(
            bundleIdentifier: bundleIdentifier,
            processName: processName,
            bundlePath: bundlePath
        ) {
            return developmentKeychainServiceIdentifier
        }

        return productionKeychainServiceIdentifier
    }

    static func defaultApplicationSupportDirectoryName(
        bundleIdentifier: String?,
        processName: String,
        environment: [String: String],
        bundlePath: String,
        isUITesting: Bool,
        isRunningUnitTests: Bool
    ) -> String {
        if let override = environment["AYNA_APPLICATION_SUPPORT_DIRECTORY_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            return override
        }

        if isRunningUnitTests {
            return unitTestApplicationSupportDirectoryName
        }

        if isUITesting {
            return uiTestApplicationSupportDirectoryName
        }

        if isProductionAppBundle(bundleIdentifier: bundleIdentifier) {
            return productionApplicationSupportDirectoryName
        }

        if isSwiftPMOrDevelopmentLaunch(
            bundleIdentifier: bundleIdentifier,
            processName: processName,
            bundlePath: bundlePath
        ) {
            return developmentApplicationSupportDirectoryName
        }

        return productionApplicationSupportDirectoryName
    }

    private static func isProductionAppBundle(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == productionKeychainServiceIdentifier ||
            bundleIdentifier == "com.sertacozercan.ayna.watchkitapp"
    }

    private static func isSwiftPMOrDevelopmentLaunch(
        bundleIdentifier: String?,
        processName: String,
        bundlePath: String
    ) -> Bool {
        bundleIdentifier == nil ||
            processName == "Ayna" ||
            bundlePath.contains("/.build/")
    }

    private static var hasSwiftTestingRuntime: Bool {
        NSClassFromString("Testing.Test") != nil ||
            NSClassFromString("_Testing.Case") != nil
    }
}
