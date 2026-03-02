//
//  BuiltinToolService+Definitions.swift
//  Ayna
//
//  Tool definitions for builtin tool service.
//

import Foundation

#if os(macOS)
    extension BuiltinToolService {
        // MARK: - Tool Definitions

        /// Returns all tool definitions in OpenAI function format.
        func allToolDefinitions() -> [[String: Any]] {
            guard isEnabled else { return [] }

            return [
                readFileDefinition(),
                writeFileDefinition(),
                editFileDefinition(),
                listDirectoryDefinition(),
                searchFilesDefinition(),
                runCommandDefinition(),
                webFetchDefinition()
            ]
        }

        /// Returns context to inject into the system prompt describing agentic capabilities.
        func systemPromptContext() -> String? {
            guard isEnabled else { return nil }

            var context = """
            # Agentic Capabilities

            You have access to tools that allow you to interact with the user's filesystem and execute commands. \
            Use these tools proactively when the user asks about files, directories, or system information.

            Available tools:
            - **read_file**: Read the contents of a file
            - **write_file**: Create or overwrite a file
            - **edit_file**: Modify existing files by replacing specific text
            - **list_directory**: List files and subdirectories in a directory
            - **search_files**: Search for text patterns in files (like grep)
            - **run_command**: Execute shell commands
            - **web_fetch**: Fetch content from a URL as plain text

            When to use these tools:
            - When the user asks what's in a file or directory, use list_directory or read_file
            - When the user asks to find something, use search_files
            - When the user asks to create or modify files, use write_file or edit_file
            - When the user asks to run commands or scripts, use run_command
            - When the user asks to fetch a web page or API response, use web_fetch

            """

            if let root = projectRoot {
                context += "\nProject root: \(root.path)"
            }

            return context
        }

        /// Tool name constant for use in tool call routing
        static let toolNames: Set<String> = [
            "read_file", "write_file", "edit_file",
            "list_directory", "search_files", "run_command",
            "web_fetch"
        ]

        /// Checks if a tool name is a builtin tool
        static func isBuiltinTool(_ name: String) -> Bool {
            toolNames.contains(name)
        }

        func readFileDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.readFile,
                    "description": "Read the contents of a file. Returns the file content as text. Only works with text files (UTF-8).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "The absolute or relative path to the file to read"
                            ]
                        ] as [String: Any],
                        "required": ["path"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        func writeFileDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.writeFile,
                    "description": "Create or overwrite a file with the specified content. Creates parent directories if needed.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "The path where the file should be created or overwritten"
                            ],
                            "content": [
                                "type": "string",
                                "description": "The content to write to the file"
                            ]
                        ] as [String: Any],
                        "required": ["path", "content"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        func editFileDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.editFile,
                    "description": "Edit a file by replacing specific text. The old_text must match EXACTLY (byte-for-byte, including whitespace and indentation). Include enough context to make the match unique.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "The path to the file to edit"
                            ],
                            "old_text": [
                                "type": "string",
                                "description": "The exact text to find and replace. Must appear exactly once in the file."
                            ],
                            "new_text": [
                                "type": "string",
                                "description": "The text to replace old_text with. Can be empty to delete the matched text."
                            ]
                        ] as [String: Any],
                        "required": ["path", "old_text", "new_text"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        func listDirectoryDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.listDirectory,
                    "description": "List files and directories in a given path. Returns name, path, type (file/directory), size, and modification date.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "The directory path to list"
                            ]
                        ] as [String: Any],
                        "required": ["path"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        func searchFilesDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.searchFiles,
                    "description": "Search for a pattern in files recursively. Supports regular expressions. Returns matching lines with file path and line number.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "pattern": [
                                "type": "string",
                                "description": "The search pattern (regular expression)"
                            ],
                            "path": [
                                "type": "string",
                                "description": "The directory to search in"
                            ]
                        ] as [String: Any],
                        "required": ["pattern", "path"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        func runCommandDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.runCommand,
                    "description": "Execute a shell command. Safe commands (git, ls, cat, etc.) may run without approval. Dangerous commands require user approval.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": [
                                "type": "string",
                                "description": "The shell command to execute"
                            ],
                            "working_directory": [
                                "type": "string",
                                "description": "Optional working directory for the command"
                            ]
                        ] as [String: Any],
                        "required": ["command"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }

        func webFetchDefinition() -> [String: Any] {
            [
                "type": "function",
                "function": [
                    "name": ToolName.webFetch,
                    "description": "Fetch content from a URL and return it as plain text. Use for reading web pages, documentation, or API responses. Only HTTP/HTTPS URLs are supported.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "url": [
                                "type": "string",
                                "description": "The URL to fetch (must be http:// or https://)"
                            ]
                        ] as [String: Any],
                        "required": ["url"]
                    ] as [String: Any]
                ] as [String: Any]
            ]
        }
    }
#endif
