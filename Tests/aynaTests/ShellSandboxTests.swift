//
//  ShellSandboxTests.swift
//  aynaTests
//
//  Unit tests for ShellSandbox command validation.
//

@testable import Ayna
import Foundation
import Testing

@Suite("ShellSandbox Tests")
struct ShellSandboxTests {
    private var sut: ShellSandbox

    init() {
        sut = ShellSandbox()
    }

    // MARK: - Allowed Commands

    @Test("Allows ls command")
    func allowsLs() {
        let result = sut.validate("ls")
        #expect(result == .allowed)
    }

    @Test("Allows ls with flags")
    func allowsLsWithFlags() {
        let result = sut.validate("ls -la")
        #expect(result == .allowed)
    }

    @Test("Allows git status")
    func allowsGitStatus() {
        let result = sut.validate("git status")
        #expect(result == .allowed)
    }

    @Test("Allows cat command")
    func allowsCat() {
        let result = sut.validate("cat file.txt")
        #expect(result == .allowed)
    }

    @Test("Allows grep command")
    func allowsGrep() {
        let result = sut.validate("grep -r 'pattern' .")
        #expect(result == .allowed)
    }

    @Test("Allows pwd command")
    func allowsPwd() {
        let result = sut.validate("pwd")
        #expect(result == .allowed)
    }

    @Test("Allows echo command")
    func allowsEcho() {
        let result = sut.validate("echo 'hello world'")
        #expect(result == .allowed)
    }

    // MARK: - Blocked Commands

    @Test("Blocks sudo command")
    func blocksSudo() {
        let result = sut.validate("sudo ls")
        if case let .blocked(reason) = result {
            #expect(reason.contains("sudo"))
        } else {
            Issue.record("Expected blocked for sudo")
        }
    }

    @Test("Blocks rm -rf /")
    func blocksRmRfRoot() {
        let result = sut.validate("rm -rf /")
        if case let .blocked(reason) = result {
            #expect(reason.contains("rm -rf"))
        } else {
            Issue.record("Expected blocked for rm -rf /")
        }
    }

    @Test("Blocks rm -rf ~")
    func blocksRmRfHome() {
        let result = sut.validate("rm -rf ~")
        if case let .blocked(reason) = result {
            #expect(reason.contains("rm -rf"))
        } else {
            Issue.record("Expected blocked for rm -rf ~")
        }
    }

    @Test("Blocks chmod 777")
    func blocksChmod777() {
        let result = sut.validate("chmod 777 file.txt")
        if case let .blocked(reason) = result {
            #expect(reason.contains("chmod 777"))
        } else {
            Issue.record("Expected blocked for chmod 777")
        }
    }

    @Test("Blocks fork bomb pattern")
    func blocksForkBomb() {
        let result = sut.validate(":(){ :|:& };:")
        if case .blocked = result {
            // Expected
        } else {
            Issue.record("Expected blocked for fork bomb")
        }
    }

    @Test("Blocks dd if= command")
    func blocksDd() {
        let result = sut.validate("dd if=/dev/zero of=/dev/sda")
        if case let .blocked(reason) = result {
            #expect(reason.contains("dd if="))
        } else {
            Issue.record("Expected blocked for dd")
        }
    }

    // MARK: - Commands Requiring Approval

    @Test("Requires approval for unknown commands")
    func requiresApprovalForUnknown() {
        let result = sut.validate("custom_script.sh")
        #expect(result == .requiresApproval)
    }

    @Test("Requires approval for rm with recursive flag")
    func requiresApprovalForRmRecursive() {
        let result = sut.validate("rm -r folder")
        #expect(result == .requiresApproval)
    }

    @Test("Requires approval for git push")
    func requiresApprovalForGitPush() {
        let result = sut.validate("git push origin main")
        #expect(result == .requiresApproval)
    }

    @Test("Requires approval for git push --force")
    func requiresApprovalForGitPushForce() {
        let result = sut.validate("git push --force")
        #expect(result == .requiresApproval)
    }

    @Test("Requires approval for chmod")
    func requiresApprovalForChmod() {
        let result = sut.validate("chmod 644 file.txt")
        #expect(result == .requiresApproval)
    }

    // MARK: - Command Chaining

    @Test("Blocks chained command with blocked component")
    func blocksChainedWithBlocked() {
        let result = sut.validate("ls && sudo rm -rf /")
        if case .blocked = result {
            // Expected
        } else {
            Issue.record("Expected blocked for chained command with sudo")
        }
    }

    @Test("Allows chained safe commands")
    func allowsChainedSafe() {
        let result = sut.validate("ls && pwd")
        #expect(result == .allowed)
    }

    @Test("Requires approval for chain with unknown command")
    func requiresApprovalForChainWithUnknown() {
        let result = sut.validate("ls && custom_cmd")
        #expect(result == .requiresApproval)
    }

    @Test("Validates piped commands")
    func validatesPipedCommands() {
        let result = sut.validate("ls | grep test")
        #expect(result == .allowed)
    }

    @Test("Validates OR chained commands")
    func validatesOrChained() {
        let result = sut.validate("ls || pwd")
        #expect(result == .allowed)
    }

    @Test("Validates semicolon chained commands")
    func validatesSemicolonChained() {
        let result = sut.validate("ls; pwd")
        #expect(result == .allowed)
    }

    // MARK: - Command Name Extraction

    @Test("Extracts simple command name")
    func extractsSimpleName() {
        let name = sut.extractCommandName("ls -la")
        #expect(name == "ls")
    }

    @Test("Extracts command from path")
    func extractsFromPath() {
        let name = sut.extractCommandName("/usr/bin/git status")
        #expect(name == "git")
    }

    @Test("Handles environment variable prefix")
    func handlesEnvPrefix() {
        let name = sut.extractCommandName("FOO=bar ls")
        #expect(name == "ls")
    }

    @Test("Handles multiple env vars")
    func handlesMultipleEnvVars() {
        let name = sut.extractCommandName("FOO=bar BAZ=qux npm install")
        #expect(name == "npm")
    }

    // MARK: - Working Directory Validation

    @Test("Allows working directory in project")
    func allowsWorkingDirInProject() {
        let sandbox = ShellSandbox(
            projectRoot: URL(fileURLWithPath: "/tmp/project"),
            restrictToProjectDirectory: true
        )
        #expect(sandbox.isWorkingDirectoryAllowed("/tmp/project/src") == true)
    }

    @Test("Blocks working directory outside project")
    func blocksWorkingDirOutsideProject() {
        let sandbox = ShellSandbox(
            projectRoot: URL(fileURLWithPath: "/tmp/project"),
            restrictToProjectDirectory: true
        )
        #expect(sandbox.isWorkingDirectoryAllowed("/other/path") == false)
    }

    @Test("Allows any directory when restriction disabled")
    func allowsAnyDirWhenUnrestricted() {
        let sandbox = ShellSandbox(
            projectRoot: URL(fileURLWithPath: "/tmp/project"),
            restrictToProjectDirectory: false
        )
        #expect(sandbox.isWorkingDirectoryAllowed("/other/path") == true)
    }

    // MARK: - Custom Configuration

    @Test("Respects custom allowed commands")
    func respectsCustomAllowed() {
        let sandbox = ShellSandbox.withAdditionalAllowed(["mycustom"])
        let result = sandbox.validate("mycustom --flag")
        #expect(result == .allowed)
    }

    @Test("Respects custom blocked patterns")
    func respectsCustomBlocked() {
        let sandbox = ShellSandbox.withAdditionalBlocked(["dangerous_pattern"])
        let result = sandbox.validate("dangerous_pattern arg")
        if case .blocked = result {
            // Expected
        } else {
            Issue.record("Expected blocked for custom pattern")
        }
    }

    @Test("Blocks unlisted commands when configured")
    func blocksUnlistedWhenConfigured() {
        let sandbox = ShellSandbox(allowUnlistedCommands: false)
        let result = sandbox.validate("unknown_command")
        if case .blocked = result {
            // Expected
        } else {
            Issue.record("Expected blocked for unlisted command")
        }
    }

    // MARK: - Edge Cases

    @Test("Handles empty command")
    func handlesEmptyCommand() {
        let result = sut.validate("")
        if case let .blocked(reason) = result {
            #expect(reason.contains("Empty"))
        } else {
            Issue.record("Expected blocked for empty command")
        }
    }

    @Test("Handles whitespace-only command")
    func handlesWhitespaceCommand() {
        let result = sut.validate("   ")
        if case .blocked = result {
            // Expected
        } else {
            Issue.record("Expected blocked for whitespace command")
        }
    }

    @Test("Handles quoted strings in commands")
    func handlesQuotedStrings() {
        let result = sut.validate("echo 'hello; world'")
        #expect(result == .allowed)
    }

    @Test("Handles double-quoted strings")
    func handlesDoubleQuotes() {
        let result = sut.validate("echo \"test && test\"")
        #expect(result == .allowed)
    }
}
