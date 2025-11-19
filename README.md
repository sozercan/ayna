# Ayna

A native macOS ChatGPT client built for speed and simplicity.

## Features

- 💬 **Fast & Native**: Streaming chat interface tailored for macOS.
- ☁️ **Multi-Provider**: Works with OpenAI and Azure OpenAI out of the box.
- 🏠 **Local Models**: Run models locally for complete privacy.
- 🛠️ **MCP Support**: Use Model Context Protocol (MCP) tools
- 🎨 **Image Generation**: Create images using models like `gpt-image-1`.
- 🗂️ **Organization**: Searchable conversations with auto-generated titles.
- 🔒 **Secure**: API keys stored in Keychain; conversations encrypted on disk.
- 📝 **Export**: Save chats as Markdown or PDF.

## Getting Started

### Installation

1. Clone the repository.
2. Open `ayna.xcodeproj` in Xcode.
3. Run the app (`Cmd+R`).

### Requirements

- macOS 14.0 (Sonoma) or newer.
- An API key for OpenAI or Azure OpenAI (optional if using local models).

## User Guide

### Connect to AI Providers
1. Open **Settings** (`Cmd+,`) → **API**.
2. Select your provider (OpenAI or Azure) and enter your API key.
3. Start chatting!

### Run Local Models (AIKit)
1. Install [Podman](https://podman-desktop.io/) configured with [GPU access](https://podman-desktop.io/docs/podman/gpu).
2. In **Settings** → **Models** → **AIKit**, select a model and click **Pull & Run**.
3. Chats will now be processed locally on your machine.

### Enable Tools (MCP)
1. Go to **Settings** → **MCP Tools**.
2. Enable tools like `brave-search` or `filesystem` to give the AI more capabilities.

### Keyboard Shortcuts
- `Cmd+N`: New conversation
- `Cmd+,`: Open Settings
- `Enter`: Send message
- `Shift+Enter`: New line

## Privacy

- **No Telemetry**: We don't track your usage.
- **Local Storage**: Conversations are encrypted and stored only on your Mac if using local models.
- **Secure Keys**: API keys are stored securely in the macOS Keychain.

## Contributing

Developers, please see [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, architecture details, and testing guidelines.

## Support

Found a bug? Open an [issue](https://github.com/sozercan/ayna/issues).
