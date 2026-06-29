//
//  AppTransportSecurityConfigurationTests.swift
//  aynaTests
//
//  Created on 3/17/26.
//

import Foundation
import Testing

@Suite(.tags(.fast))
struct AppTransportSecurityConfigurationTests {
    private var repositoryRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Shared Info.plist scopes insecure HTTP loads to loopback")
    func sharedInfoPlistScopesInsecureHTTPLoadsToLoopback() throws {
        let plistURL = repositoryRootURL.appendingPathComponent("Sources/Ayna/Info.plist")
        let plist = try loadPlist(at: plistURL)

        try assertScopesInsecureLoadsToLoopback(in: plist)
    }

    @Test("macOS build script scopes insecure HTTP ATS setting")
    func macOSBuildScriptScopesInsecureHTTPATSSetting() throws {
        let scriptURL = repositoryRootURL.appendingPathComponent("Scripts/build-app.sh")
        let contents = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(!contents.contains("<key>NSAllowsArbitraryLoads</key>\n        <true/>"))
        #expect(contents.contains("<key>localhost</key>"))
        #expect(contents.contains("<key>127.0.0.1</key>"))
        #expect(contents.contains("<key>::1</key>"))
        #expect(contents.contains("<key>NSExceptionAllowsInsecureHTTPLoads</key>"))
    }

    @Test("Package manifest embeds shared Info plist for macOS builds")
    func packageManifestEmbedsSharedInfoPlistForMacOSBuilds() throws {
        let packageURL = repositoryRootURL.appendingPathComponent("Package.swift")
        let contents = try String(contentsOf: packageURL, encoding: .utf8)

        #expect(contents.contains("-sectcreate"))
        #expect(contents.contains("__info_plist"))
        #expect(contents.contains("Sources/Ayna/Info.plist"))
    }

    private func loadPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw NSError(
                domain: "AppTransportSecurityConfigurationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected plist dictionary at \(url.path)"]
            )
        }
        return dictionary
    }

    private func assertScopesInsecureLoadsToLoopback(in plist: [String: Any]) throws {
        guard let ats = plist["NSAppTransportSecurity"] as? [String: Any] else {
            throw NSError(
                domain: "AppTransportSecurityConfigurationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing NSAppTransportSecurity dictionary"]
            )
        }

        #expect(ats["NSAllowsArbitraryLoads"] as? Bool != true)

        guard let exceptionDomains = ats["NSExceptionDomains"] as? [String: Any] else {
            throw NSError(
                domain: "AppTransportSecurityConfigurationTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Missing NSExceptionDomains dictionary"]
            )
        }

        #expect(loopbackDomain("localhost", in: exceptionDomains))
        #expect(loopbackDomain("127.0.0.1", in: exceptionDomains))
        #expect(loopbackDomain("::1", in: exceptionDomains))
    }

    private func loopbackDomain(_ domain: String, in exceptionDomains: [String: Any]) -> Bool {
        guard let settings = exceptionDomains[domain] as? [String: Any] else { return false }
        return settings["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true
    }
}
