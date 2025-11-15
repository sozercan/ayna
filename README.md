# ayna

A native macOS ChatGPT client built with SwiftUI.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing guidance, and PR expectations.
```markdown
# ayna

A native macOS ChatGPT client built with SwiftUI.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- 💬 Native macOS chat interface with streaming responses
- ☁️ Support for OpenAI, Azure OpenAI, and AIKit (local models via Podman)
- 🛠️ MCP (Model Context Protocol) integration for tool calling (search, filesystem access)
- 🗂️ Conversation management with search
- 🎨 Clean, modern design with keyboard shortcuts
- 💾 Local data storage

## Requirements

- macOS 14.0+
- Xcode 15.0+

## Installation

```bash
git clone https://github.com/yourusername/ayna.git
cd ayna
open ayna.xcodeproj
```

Build and run with Cmd+R.

## Getting Started

### Cloud Providers (OpenAI/Azure OpenAI)
1. Launch the app
2. Go to Settings (Cmd+,) → API tab
3. Select your provider and enter API credentials
4. Start chatting with Cmd+N

### Local Models ([AIKit](https://kaito-project.github.io/aikit/docs))
1. Install [Podman](https://podman-desktop.io/docs/installation)
2. Set up [GPU access](https://podman-desktop.io/docs/podman/gpu) (recommended for performance)
3. Go to Settings → Models → New Model → AIKit tab
4. Select a model and click "Pull & Run Model"

### MCP Tools
1. Go to Settings → MCP Tools
2. Enable [brave-search](https://github.com/modelcontextprotocol/servers) for web search or [filesystem](https://github.com/modelcontextprotocol/servers) for file access
3. Provide any required API keys (e.g., Brave Search API key)
4. Tools automatically engage when relevant to your queries

## Keyboard Shortcuts

- `Cmd+N` - New conversation
- `Cmd+,` - Settings
- `Enter` - Send message

## Security

- API keys are stored exclusively in the macOS Keychain.
- Conversations are persisted locally in an AES-GCM encrypted store under Application Support.
- See `SECURITY.md` for the detailed threat model and operational guidance.

```
