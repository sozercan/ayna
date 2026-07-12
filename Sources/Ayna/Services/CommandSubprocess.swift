#if os(macOS)
    import Darwin
    import Foundation

    /// A shell subprocess launched as the leader of its own process group.
    ///
    /// Group ownership lets cancellation and timeout terminate the shell and every descendant,
    /// including background jobs that would otherwise retain stdout/stderr pipes indefinitely.
    final class CommandSubprocess: @unchecked Sendable {
        let processIdentifier: pid_t
        let standardOutput: FileHandle
        let standardError: FileHandle

        private init(
            processIdentifier: pid_t,
            standardOutput: FileHandle,
            standardError: FileHandle
        ) {
            self.processIdentifier = processIdentifier
            self.standardOutput = standardOutput
            self.standardError = standardError
        }

        static func start(command: String, workingDirectory: URL?) throws -> CommandSubprocess {
            var stdoutDescriptors: [Int32] = [0, 0]
            var stderrDescriptors: [Int32] = [0, 0]
            guard pipe(&stdoutDescriptors) == 0 else {
                throw posixError(errno)
            }
            guard pipe(&stderrDescriptors) == 0 else {
                close(stdoutDescriptors[0])
                close(stdoutDescriptors[1])
                throw posixError(errno)
            }

            var fileActions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&fileActions)
            posix_spawnattr_init(&attributes)
            defer {
                posix_spawn_file_actions_destroy(&fileActions)
                posix_spawnattr_destroy(&attributes)
            }

            posix_spawn_file_actions_adddup2(&fileActions, stdoutDescriptors[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&fileActions, stderrDescriptors[1], STDERR_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, stdoutDescriptors[0])
            posix_spawn_file_actions_addclose(&fileActions, stderrDescriptors[0])
            posix_spawn_file_actions_addclose(&fileActions, stdoutDescriptors[1])
            posix_spawn_file_actions_addclose(&fileActions, stderrDescriptors[1])

            if let workingDirectory {
                let result = workingDirectory.path.withCString {
                    posix_spawn_file_actions_addchdir(&fileActions, $0)
                }
                guard result == 0 else {
                    closePipeDescriptors(stdoutDescriptors, stderrDescriptors)
                    throw posixError(result)
                }
            }

            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)

            let arguments = ["/bin/zsh", "-c", command]
            var argumentPointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
            argumentPointers.append(nil)
            defer {
                argumentPointers.dropLast().forEach { free($0) }
            }

            var processIdentifier: pid_t = 0
            let spawnResult = "/bin/zsh".withCString { executable in
                argumentPointers.withUnsafeMutableBufferPointer { buffer in
                    posix_spawn(
                        &processIdentifier,
                        executable,
                        &fileActions,
                        &attributes,
                        buffer.baseAddress,
                        environ
                    )
                }
            }

            close(stdoutDescriptors[1])
            close(stderrDescriptors[1])
            guard spawnResult == 0 else {
                close(stdoutDescriptors[0])
                close(stderrDescriptors[0])
                throw posixError(spawnResult)
            }

            return CommandSubprocess(
                processIdentifier: processIdentifier,
                standardOutput: FileHandle(fileDescriptor: stdoutDescriptors[0], closeOnDealloc: true),
                standardError: FileHandle(fileDescriptor: stderrDescriptors[0], closeOnDealloc: true)
            )
        }

        var isRunning: Bool {
            if kill(processIdentifier, 0) == 0 {
                return true
            }
            return errno != ESRCH
        }

        func terminate() {
            signalProcessGroup(SIGTERM)
        }

        func forceKill() {
            signalProcessGroup(SIGKILL)
        }

        /// Waits for the shell leader, then tears down any background descendants in its group.
        func waitUntilExit() -> Int32 {
            var status: Int32 = 0
            while waitpid(processIdentifier, &status, 0) == -1, errno == EINTR {}

            terminateRemainingProcessGroup()
            return Self.exitCode(from: status)
        }

        func drainAvailableOutput() -> (stdout: Data, stderr: Data) {
            (
                Self.readAvailableData(from: standardOutput),
                Self.readAvailableData(from: standardError)
            )
        }

        func closeOutput() {
            standardOutput.readabilityHandler = nil
            standardError.readabilityHandler = nil
            try? standardOutput.close()
            try? standardError.close()
        }

        private func terminateRemainingProcessGroup() {
            guard kill(-processIdentifier, 0) == 0 else { return }
            _ = kill(-processIdentifier, SIGTERM)
            usleep(50000)
            if kill(-processIdentifier, 0) == 0 {
                _ = kill(-processIdentifier, SIGKILL)
            }
        }

        private func signalProcessGroup(_ signal: Int32) {
            if kill(-processIdentifier, signal) == -1, errno == ESRCH {
                _ = kill(processIdentifier, signal)
            }
        }

        private static func readAvailableData(from handle: FileHandle) -> Data {
            let descriptor = handle.fileDescriptor
            let oldFlags = fcntl(descriptor, F_GETFL)
            if oldFlags >= 0 {
                _ = fcntl(descriptor, F_SETFL, oldFlags | O_NONBLOCK)
            }
            defer {
                if oldFlags >= 0 {
                    _ = fcntl(descriptor, F_SETFL, oldFlags)
                }
            }

            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    result.append(buffer, count: count)
                } else if count == -1, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            return result
        }

        private static func exitCode(from waitStatus: Int32) -> Int32 {
            let signal = waitStatus & 0x7F
            if signal == 0 {
                return (waitStatus >> 8) & 0xFF
            }
            return signal
        }

        private static func closePipeDescriptors(_ stdout: [Int32], _ stderr: [Int32]) {
            stdout.forEach { close($0) }
            stderr.forEach { close($0) }
        }

        private static func posixError(_ code: Int32) -> NSError {
            NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
#endif
