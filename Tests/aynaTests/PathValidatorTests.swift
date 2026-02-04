//
//  PathValidatorTests.swift
//  aynaTests
//
//  Unit tests for PathValidator path security validation.
//

@testable import Ayna
import Foundation
import Testing

@Suite("PathValidator Tests")
struct PathValidatorTests {
    private var sut: PathValidator

    init() {
        sut = PathValidator()
    }

    // MARK: - Basic Path Validation

    @Test("Allows normal file paths for read")
    func allowsNormalPathForRead() {
        let result = sut.validate("/tmp/test.txt", operation: .read)
        #expect(result.isAllowed)
    }

    @Test("Allows relative paths for read")
    func allowsRelativePathForRead() {
        let result = sut.validate("./test.txt", operation: .read)
        #expect(result.isAllowed)
    }

    @Test("Expands tilde in paths")
    func expandsTilde() {
        let url = sut.canonicalize("~/Documents")
        #expect(url != nil)
        #expect(url?.path.contains("Documents") == true)
        #expect(url?.path.hasPrefix("/Users") == true || url?.path.hasPrefix("/var") == true)
    }

    // MARK: - Protected Paths

    @Test("Requires approval for SSH directory")
    func requiresApprovalForSSH() {
        let result = sut.validate("~/.ssh/id_rsa", operation: .read)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("Protected path"))
        } else {
            Issue.record("Expected requiresApproval for ~/.ssh")
        }
    }

    @Test("Requires approval for AWS credentials")
    func requiresApprovalForAWS() {
        let result = sut.validate("~/.aws/credentials", operation: .read)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("Protected path"))
        } else {
            Issue.record("Expected requiresApproval for ~/.aws")
        }
    }

    @Test("Requires approval for etc directory")
    func requiresApprovalForEtc() {
        let result = sut.validate("/etc/passwd", operation: .read)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("Protected path"))
        } else {
            Issue.record("Expected requiresApproval for /etc")
        }
    }

    @Test("Requires approval for System directory")
    func requiresApprovalForSystem() {
        let result = sut.validate("/System/Library/test", operation: .read)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("Protected path"))
        } else {
            Issue.record("Expected requiresApproval for /System")
        }
    }

    // MARK: - Sensitive Filenames

    @Test("Requires approval for .env files")
    func requiresApprovalForEnvFile() {
        let result = sut.validate("/tmp/project/.env", operation: .read)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("Sensitive file"))
        } else {
            Issue.record("Expected requiresApproval for .env file")
        }
    }

    @Test("Requires approval for credentials.json")
    func requiresApprovalForCredentials() {
        let result = sut.validate("/tmp/credentials.json", operation: .read)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("Sensitive file"))
        } else {
            Issue.record("Expected requiresApproval for credentials.json")
        }
    }

    @Test("Requires approval for secrets.yaml")
    func requiresApprovalForSecrets() {
        let result = sut.validate("/tmp/secrets.yaml", operation: .read)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("Sensitive file"))
        } else {
            Issue.record("Expected requiresApproval for secrets.yaml")
        }
    }

    // MARK: - Project Boundary

    @Test("Allows write within project directory")
    func allowsWriteWithinProject() {
        let projectRoot = URL(fileURLWithPath: "/tmp/my-project")
        let validator = PathValidator(projectRoot: projectRoot)

        let result = validator.validate("/tmp/my-project/src/main.swift", operation: .write)
        #expect(result.isAllowed)
    }

    @Test("Requires approval for write outside project")
    func requiresApprovalForWriteOutsideProject() {
        let projectRoot = URL(fileURLWithPath: "/tmp/my-project")
        let validator = PathValidator(projectRoot: projectRoot)

        let result = validator.validate("/tmp/other-project/file.txt", operation: .write, requireApprovalOutsideProject: true)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("outside project"))
        } else {
            Issue.record("Expected requiresApproval for write outside project")
        }
    }

    // MARK: - isWithinProject

    @Test("Correctly identifies path within project")
    func identifiesPathWithinProject() {
        let projectRoot = URL(fileURLWithPath: "/tmp/my-project")
        let validator = PathValidator(projectRoot: projectRoot)

        #expect(validator.isWithinProject("/tmp/my-project/src/file.swift") == true)
        #expect(validator.isWithinProject("/tmp/other/file.swift") == false)
    }

    @Test("Returns false for isWithinProject when no project root")
    func returnsFalseWhenNoProjectRoot() {
        let validator = PathValidator(projectRoot: nil)
        #expect(validator.isWithinProject("/tmp/any/file.swift") == false)
    }

    // MARK: - Edge Cases

    @Test("Handles empty path")
    func handlesEmptyPath() {
        let result = sut.validate("", operation: .read)
        // Empty path will fail to canonicalize
        #expect(result.isAllowed || !result.isAllowed) // Just ensure no crash
    }

    @Test("Handles path with special characters")
    func handlesSpecialCharacters() {
        let result = sut.validate("/tmp/test file (1).txt", operation: .read)
        #expect(result.isAllowed)
    }

    // MARK: - Custom Configuration

    @Test("Respects custom protected paths")
    func respectsCustomProtectedPaths() {
        let validator = PathValidator(
            projectRoot: nil,
            protectedPaths: ["/custom/protected"],
            sensitiveFilenames: []
        )

        let result = validator.validate("/custom/protected/file.txt", operation: .read)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("Protected path"))
        } else {
            Issue.record("Expected requiresApproval for custom protected path")
        }
    }

    @Test("Respects custom sensitive filenames")
    func respectsCustomSensitiveFilenames() {
        let validator = PathValidator(
            projectRoot: nil,
            protectedPaths: [],
            sensitiveFilenames: ["custom-secret.txt"]
        )

        let result = validator.validate("/tmp/custom-secret.txt", operation: .read)
        if case let .requiresApproval(reason) = result {
            #expect(reason.contains("Sensitive file"))
        } else {
            Issue.record("Expected requiresApproval for custom sensitive filename")
        }
    }
}
