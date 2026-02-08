//
//  GitContextServiceTests.swift
//  aynaTests
//
//  Unit tests for GitContextService.
//

#if os(macOS)
    @testable import Ayna
    import Foundation
    import Testing

    @Suite("GitContextService Tests")
    @MainActor
    struct GitContextServiceTests {
        // MARK: - GitStatus Tests

        @Suite("GitStatus")
        struct GitStatusTests {
            @Test("Empty status is clean")
            func emptyStatusIsClean() {
                let status = GitContextService.GitStatus(
                    staged: [],
                    unstaged: [],
                    untracked: []
                )
                #expect(status.isClean)
            }

            @Test("Staged files make status not clean")
            func stagedFilesNotClean() {
                let status = GitContextService.GitStatus(
                    staged: ["file.txt"],
                    unstaged: [],
                    untracked: []
                )
                #expect(!status.isClean)
            }

            @Test("Unstaged files make status not clean")
            func unstagedFilesNotClean() {
                let status = GitContextService.GitStatus(
                    staged: [],
                    unstaged: ["file.txt"],
                    untracked: []
                )
                #expect(!status.isClean)
            }

            @Test("Untracked files make status not clean")
            func untrackedFilesNotClean() {
                let status = GitContextService.GitStatus(
                    staged: [],
                    unstaged: [],
                    untracked: ["file.txt"]
                )
                #expect(!status.isClean)
            }

            @Test("Summary shows clean for empty")
            func summaryShowsClean() {
                let status = GitContextService.GitStatus(
                    staged: [],
                    unstaged: [],
                    untracked: []
                )
                #expect(status.summary == "clean")
            }

            @Test("Summary shows counts")
            func summaryShowsCounts() {
                let status = GitContextService.GitStatus(
                    staged: ["a.txt", "b.txt"],
                    unstaged: ["c.txt"],
                    untracked: ["d.txt", "e.txt", "f.txt"]
                )
                let summary = status.summary
                #expect(summary.contains("2 staged"))
                #expect(summary.contains("1 modified"))
                #expect(summary.contains("3 untracked"))
            }
        }

        // MARK: - GitCommit Tests

        @Suite("GitCommit")
        struct GitCommitTests {
            @Test("Commit summary format")
            func summaryFormat() {
                let commit = GitContextService.GitCommit(
                    id: "abc123def456",
                    shortSha: "abc123d",
                    message: "Fix bug in parser",
                    author: "Test User",
                    date: Date()
                )
                #expect(commit.summary == "abc123d Fix bug in parser")
            }

            @Test("Commit uses ID for Identifiable")
            func identifiableId() {
                let commit = GitContextService.GitCommit(
                    id: "unique-sha",
                    shortSha: "short",
                    message: "Message",
                    author: "Author",
                    date: Date()
                )
                #expect(commit.id == "unique-sha")
            }
        }

        // MARK: - Service Tests

        @Suite("Service")
        @MainActor
        struct ServiceTests {
            @Test("Initial state has no context")
            func initialStateNoContext() {
                let sut = GitContextService()

                #expect(sut.currentBranch == nil)
                #expect(sut.status == nil)
                #expect(sut.recentCommits.isEmpty)
                #expect(sut.mainBranch == nil)
                #expect(sut.isClean)
            }

            @Test("isClean returns true when status is nil")
            func isCleanWhenStatusNil() {
                let sut = GitContextService()
                #expect(sut.isClean)
            }

            @Test("Reset clears all context")
            func resetClearsContext() {
                let sut = GitContextService()
                sut.reset()

                #expect(sut.currentBranch == nil)
                #expect(sut.status == nil)
                #expect(sut.recentCommits.isEmpty)
                #expect(sut.mainBranch == nil)
            }

            @Test("System prompt context returns nil without branch")
            func systemPromptContextNilWithoutBranch() {
                let sut = GitContextService()
                #expect(sut.systemPromptContext() == nil)
            }

            @Test("Brief summary returns nil without branch")
            func briefSummaryNilWithoutBranch() {
                let sut = GitContextService()
                #expect(sut.briefSummary() == nil)
            }
        }

        // MARK: - GitCommandResult Tests

        @Suite("GitCommandResult")
        struct GitCommandResultTests {
            @Test("Success result has zero exit code")
            func successResult() {
                let result = GitContextService.GitCommandResult(
                    exitCode: 0,
                    stdout: "output",
                    stderr: ""
                )
                #expect(result.exitCode == 0)
                #expect(result.stdout == "output")
                #expect(result.stderr.isEmpty)
            }

            @Test("Error result has non-zero exit code")
            func errorResult() {
                let result = GitContextService.GitCommandResult(
                    exitCode: 1,
                    stdout: "",
                    stderr: "error message"
                )
                #expect(result.exitCode != 0)
                #expect(result.stderr == "error message")
            }
        }
    }
#endif
