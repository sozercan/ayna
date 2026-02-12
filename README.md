# Ayna

A native macOS, iOS, and watchOS ChatGPT client built for speed and simplicity.

## Features

- 💬 **Fast & Native**: Streaming chat interface tailored for Apple platforms.
- ☁️ **Multi-Provider**: Native support for OpenAI, [Anthropic](https://www.anthropic.com), Azure OpenAI, and [GitHub Models](https://github.com/marketplace/models). Also works with any OpenAI-compatible endpoint (Gemini, Ollama, etc.).
- 🔀 **Multi-Model Chat**: Compare responses from multiple models simultaneously.
- 🍎 **Apple Intelligence**: Uses the on-device Apple Intelligence API when available (macOS/iOS).
- 🏠 **Local Models**: Connect to local servers like Ollama via custom endpoint.
- 🛠️ **MCP Support**: Use Model Context Protocol (MCP) tools.
- 🎨 **Image Generation**: Create images using models like `gpt-image-1`.
- 🧠 **Memory**: Remember facts across conversations with natural language commands.
- 🗂️ **Organization**: Searchable conversations with auto-generated titles.
- 🔒 **Secure**: API keys stored in Keychain; conversations encrypted on disk.
- 📝 **Export**: Save chats as Markdown or PDF.
- ⌚ **watchOS Companion**: Quick chat access from your Apple Watch.

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

- macOS 14.0 (Sonoma) or newer, iOS 17.0 or newer, or watchOS 10.0 or newer.
- An API key for OpenAI, Anthropic, or Azure OpenAI, or a GitHub account for GitHub Models (optional if using local models).

## User Guide

### Connect to AI Providers
1. Open **Settings** (`Cmd+,`) → **Models**.
2. Select your provider and add a model:
   - **OpenAI**: Use the default endpoint or a custom OpenAI API-compatible endpoint.
   - **Anthropic**: Use the default endpoint or a custom Anthropic API-compatible endpoint.
   - **Azure**: Use `https://<resource>.openai.azure.com` (Azure OpenAI) or `https://<resource>.services.ai.azure.com` (Microsoft Foundry) with your deployment name as the model.
   - **GitHub Models**: Sign in with your GitHub account.
   - **Apple Intelligence**: For on-device inference.
3. Start chatting!

### Multi-Model Chat
1. Start a **New Chat** (`Cmd+N`).
2. In the model selector, choose **multiple models** (e.g., GPT-4o and Claude 3.5 Sonnet).
3. Send your prompt.
4. Ayna will stream responses from all selected models in parallel, allowing you to compare their outputs side-by-side.

### Enable Tools (MCP)
1. Go to **Settings** → **Tools**.
2. Add an MCP server to give the AI more capabilities.

### Keyboard Shortcuts

| Action | Shortcut | Context |
|--------|----------|---------|
| New conversation | `⌘N` | macOS |
| Open Settings | `⌘,` | macOS |
| Send message | `↵` (Enter) | macOS, iOS, watchOS |
| New line in message | `⇧↵` (Shift+Enter) | macOS |
| Dismiss panel | `⎋` (Escape) | macOS (Floating Panel) |
| Send and open main window | `⌘↵` (Cmd+Enter) | macOS (Floating Panel) |
| Show floating panel | `⌘⇧Space` | macOS (Global Hotkey)* |

*Requires "Work with Apps" feature enabled in Settings.

## Privacy

- **No Telemetry**: We don't track your usage.
- **Local Storage**: Conversations are encrypted and stored only on your device.
- **Secure Keys**: API keys are stored securely in the system Keychain.

## Contributing

Developers, please see [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, architecture details, and testing guidelines.

## Support

Found a bug? Open an [issue](https://github.com/sozercan/ayna/issues).
