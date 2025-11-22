//
//  MCPProcessTracker.swift
//  ayna
//
//  Created on 11/21/25.
//

import Darwin
import Foundation

/// Tracks spawned MCP server subprocesses so we can clean them up after crashes or force quits.
final class MCPProcessTracker: @unchecked Sendable {
    static let shared = MCPProcessTracker()

    private let storageURL: URL
    private var trackedPIDs: [String: pid_t] = [:]
    private let queue = DispatchQueue(label: "com.ayna.mcp.process-tracker", qos: .utility)

    private init() {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let supportDir = urls.first?.appendingPathComponent("Ayna", isDirectory: true)
        if let supportDir, !FileManager.default.fileExists(atPath: supportDir.path) {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        }
        storageURL = supportDir?.appendingPathComponent("mcp-processes.json") ?? URL(fileURLWithPath: "")
        loadFromDisk()
    }

    func register(serverName: String, pid: pid_t) {
        queue.sync {
            trackedPIDs[serverName] = pid
            persist()
            DiagnosticsLogger.log(
                .mcpService,
                level: .info,
                message: "📦 Tracking MCP server PID",
                metadata: ["server": serverName, "pid": "\(pid)"]
            )
        }
    }

    func unregister(serverName: String) {
        queue.sync {
            guard let pid = trackedPIDs.removeValue(forKey: serverName) else { return }
            persist()
            DiagnosticsLogger.log(
                .mcpService,
                level: .info,
                message: "🧹 Untracked MCP server PID",
                metadata: ["server": serverName, "pid": "\(pid)"]
            )
        }
    }

    func cleanupOrphanedProcesses() {
        queue.sync {
            guard !trackedPIDs.isEmpty else { return }
            DiagnosticsLogger.log(
                .mcpService,
                level: .info,
                message: "🧼 Cleaning up orphaned MCP processes",
                metadata: ["count": "\(trackedPIDs.count)"]
            )

            for (server, pid) in trackedPIDs {
                terminateProcess(pid: pid, serverName: server)
            }

            trackedPIDs.removeAll()
            persist()
        }
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
        do {
            let data = try JSONEncoder().encode(trackedPIDs)
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

    private func loadFromDisk() {
        guard !storageURL.path.isEmpty else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            trackedPIDs = try JSONDecoder().decode([String: pid_t].self, from: data)
        } catch {
            trackedPIDs = [:]
        }
    }
}
