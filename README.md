# Ayna

Native macOS ChatGPT client built with SwiftUI.

## Highlights

- 💬 Fast, streaming chat interface tailored for macOS
- ☁️ Works with OpenAI and Azure OpenAI out of the box
- 🏠 Run local models through AIKit + Podman when you prefer everything on device
- 🛠️ Model Context Protocol (MCP) tools for search and filesystem access
- 🗂️ Conversation management with search, titles, and keyboard shortcuts

## Requirements

- macOS 14.0 or newer
- Xcode 15.0+ to build from source
- Swift 6.2.1 toolchain
- OpenAI or Azure OpenAI API key (optional if using local AIKit models)
- [Podman](https://podman-desktop.io/docs/installation) for AIKit containers (optional)

## Install & Run

Clone the repo, open the project in Xcode, and press `Cmd+R` with the “My Mac” target selected.

```bash
git clone https://github.com/yourusername/ayna.git
cd ayna
open ayna.xcodeproj
```

## Using Ayna

### Connect to OpenAI or Azure OpenAI
1. Launch the app and open Settings (`Cmd+,`).
2. In the API tab, pick a provider and add your API key (and Azure endpoint/deployment if needed).
3. Start a new chat with `Cmd+N` and begin messaging.

### Run Local Models with AIKit
1. Install Podman (GPU support recommended for speed).
2. In Settings → Models → AIKit, choose a model and select **Pull & Run**.
3. Chats sent while AIKit is running stay fully local.

### Use MCP Tools
1. Head to Settings → MCP Tools.
2. Enable servers like `brave-search` or `filesystem` and supply any required keys.
3. Ayna automatically calls tools when a response benefits from them.

## Keyboard Shortcuts

- `Cmd+N` — new conversation
- `Cmd+,` — open Settings
- `Enter` — send message (use `Shift+Enter` for a new line)

## Privacy & Security

- API keys live in the macOS Keychain, not on disk.
- Conversations are encrypted (AES-GCM) inside Application Support.
- No telemetry or analytics; everything stays on your Mac unless you call a cloud provider.

## Testing

Run lint + test locally before pushing changes:

```bash
swiftlint --strict
xcodebuild -scheme Ayna -destination 'platform=macOS' test
```

To focus on the new UI smoke tests (which launch the app with the deterministic `AYNA_UI_TESTING=1` environment and stubbed network calls):

```bash
xcodebuild -scheme Ayna -destination 'platform=macOS' -only-testing AynaUITests test
```

## Support & Contributing

Questions or bugs? Open an [issue](https://github.com/sozercan/ayna/issues) on GitHub.

Contributions are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md) for details.
