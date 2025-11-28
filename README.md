# Ayna

A native macOS ChatGPT client built for speed and simplicity.

## Features

- 💬 **Fast & Native**: Streaming chat interface tailored for macOS.
- ☁️ **Multi-Provider**: Works with OpenAI-compatible endpoints, including OpenAI, Azure OpenAI, [GitHub Models](https://github.com/marketplace/models), [Gemini](https://ai.google.dev/gemini-api/docs/openai) and [Claude](https://platform.claude.com/docs/en/api/openai-sdk) providers.
- 🔀 **Multi-Model Chat**: Compare responses from multiple models simultaneously.
- 🍎 **Apple Intelligence**: Uses the on-device Apple Intelligence API when available on macOS.
- 🏠 **Local Models**: Run models locally for complete privacy.
- 🛠️ **MCP Support**: Use Model Context Protocol (MCP) tools.
- 🎨 **Image Generation**: Create images using models like `gpt-image-1`.
- 🗂️ **Organization**: Searchable conversations with auto-generated titles.
- 🔒 **Secure**: API keys stored in Keychain; conversations encrypted on disk.
- 📝 **Export**: Save chats as Markdown or PDF.

## Getting Started

### Installation

1. Grab the latest `.dmg` from the [Releases page](https://github.com/sozercan/ayna/releases).
2. Open the disk image and drag **Ayna.app** into your **Applications** folder.
3. App is quarantined because it's not notarized. To remove the quarantine, run this command in Terminal:
  ```bash
  xattr -dr com.apple.quarantine /Applications/Ayna.app
  ```
4. Launch **Ayna** from Applications.

### Homebrew

You can also install Ayna via Homebrew:

```bash
brew tap sozercan/ayna
brew install --cask ayna
```

### Requirements

- macOS 14.0 (Sonoma) or newer.
- An API key for OpenAI, Azure OpenAI, Gemini or Claude, or a GitHub account for GitHub Models (optional if using local models).

## User Guide

### Connect to AI Providers
1. Open **Settings** (`Cmd+,`) → **API**.
2. Select your provider and add a model:
   - **OpenAI**: Use the default endpoint or a custom OpenAI-compatible endpoint.
   - **Azure OpenAI**: Use `https://<resource>.openai.azure.com` with your deployment name as the model.
   - **GitHub Models**: Sign in with your GitHub account (OAuth) or use a Personal Access Token with `models:read` permission.
   - **Apple Intelligence / AIKit**: For on-device/local inference.
3. Start chatting!

### Multi-Model Chat
1. Start a **New Chat** (`Cmd+N`).
2. In the model selector, choose **multiple models** (e.g., GPT-4o and Claude 3.5 Sonnet).
3. Send your prompt.
4. Ayna will stream responses from all selected models in parallel, allowing you to compare their outputs side-by-side.

### Run Local Models (AIKit)
1. Install [Podman](https://podman-desktop.io/) configured with [GPU access](https://podman-desktop.io/docs/podman/gpu).
2. In **Settings** → **Models** → **AIKit**, select a model and click **Pull & Run**.
3. Chats will now be processed locally on your machine.

### Enable Tools (MCP)
1. Go to **Settings** → **MCP Tools**.
2. Enable the default `wassette` runtime (requires the [Wassette CLI](https://github.com/microsoft/wassette) and runs `wassette serve --stdio`) or add any other MCP server to give the AI more capabilities.

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
