//
//  MCPProcessTracker.swift
//  ayna
//
//  Created on 11/21/25.
//

#if os(macOS)
import Darwin
import Foundation
import os

/// Tracks spawned MCP server subprocesses so we can clean them up after crashes or force quits.
final class MCPProcessTracker: Sendable {
    static let shared = MCPProcessTracker()

    private let storageURL: URL
    private let lock: OSAllocatedUnfairLock<[String: pid_t]>

    private init() {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let supportDir = urls.first?.appendingPathComponent("Ayna", isDirectory: true)
        if let supportDir, !FileManager.default.fileExists(atPath: supportDir.path) {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        }
        storageURL = supportDir?.appendingPathComponent("mcp-processes.json") ?? URL(fileURLWithPath: "")

        // Load initial state
        var initialPIDs: [String: pid_t] = [:]
        if !storageURL.path.isEmpty {
            do {
                let data = try Data(contentsOf: storageURL)
                initialPIDs = try JSONDecoder().decode([String: pid_t].self, from: data)
            } catch {
                initialPIDs = [:]
            }
        }
        lock = OSAllocatedUnfairLock(initialState: initialPIDs)
    }

    func register(serverName: String, pid: pid_t) {
        lock.withLock { trackedPIDs in
            if let existingPid = trackedPIDs[serverName], existingPid != pid {
                kill(existingPid, SIGTERM)
            }
            trackedPIDs[serverName] = pid
        }
        persist()
        DiagnosticsLogger.log(
            .mcpService,
            level: .info,
            message: "📦 Tracking MCP server PID",
            metadata: ["server": serverName, "pid": "\(pid)"]
        )
    }

    func unregister(serverName: String) {
        let pid = lock.withLock { trackedPIDs -> pid_t? in
            trackedPIDs.removeValue(forKey: serverName)
        }
        guard let pid else { return }
        persist()
        DiagnosticsLogger.log(
            .mcpService,
            level: .info,
            message: "🧹 Untracked MCP server PID",
            metadata: ["server": serverName, "pid": "\(pid)"]
        )
    }

    func cleanupOrphanedProcesses() {
        let pidsToClean = lock.withLock { trackedPIDs -> [String: pid_t] in
            guard !trackedPIDs.isEmpty else { return [:] }
            let copy = trackedPIDs
            trackedPIDs.removeAll()
            return copy
        }

        guard !pidsToClean.isEmpty else { return }

        DiagnosticsLogger.log(
            .mcpService,
            level: .info,
            message: "🧼 Cleaning up orphaned MCP processes",
            metadata: ["count": "\(pidsToClean.count)"]
        )

        for (server, pid) in pidsToClean {
            guard pid > 0 else { continue }
            if kill(pid, 0) == 0 {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .info,
                    message: "⚠️ Found persisted MCP PID still running; not terminating to avoid PID reuse risk",
                    metadata: ["server": server, "pid": "\(pid)"]
                )
            } else {
                DiagnosticsLogger.log(
                    .mcpService,
                    level: .info,
                    message: "ℹ️ Persisted MCP PID no longer exists",
                    metadata: ["server": server, "pid": "\(pid)"]
                )
            }
        }
        persist()
    }

    private func terminateProcess(pid: pid_t, serverName: String) {
        guard pid > 0 else { return }
        if kill(pid, 0) != 0 {
            DiagnosticsLogger.log(
                .mcpService,
                level: .info,
                message: "ℹ️ PID already gone",
                metadata: ["server": serverName, "pid": "\(pid)"]
            )
            return
        }

        DiagnosticsLogger.log(
            .mcpService,
            level: .info,
            message: "🛑 Sending SIGTERM to orphaned MCP process",
            metadata: ["server": serverName, "pid": "\(pid)"]
        )
        kill(pid, SIGTERM)
        waitForExit(pid: pid)

        if kill(pid, 0) == 0 {
            DiagnosticsLogger.log(
                .mcpService,
                level: .info,
                message: "⚠️ SIGTERM failed; sending SIGKILL",
                metadata: ["server": serverName, "pid": "\(pid)"]
            )
            kill(pid, SIGKILL)
            waitForExit(pid: pid)
        }
    }

    private func waitForExit(pid: pid_t) {
        for _ in 0 ..< 10 {
            if kill(pid, 0) != 0 {
                break
            }
            usleep(50000)
        }
    }

    private func persist() {
        guard !storageURL.path.isEmpty else { return }
        let currentPIDs = lock.withLock { $0 }
        do {
            let data = try JSONEncoder().encode(currentPIDs)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            DiagnosticsLogger.log(
                .mcpService,
                level: .error,
                message: "Failed to persist MCP process tracker",
                metadata: ["error": error.localizedDescription]
            )
        }
    }
}
#endif
