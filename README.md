# ayna

A native macOS ChatGPT client built with SwiftUI.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- 💬 Native macOS chat interface with streaming responses
- ☁️ Support for OpenAI, Azure OpenAI, and AIKit (local models via Podman)
- 🗂️ Conversation management with search
- 🎨 Clean, modern design with keyboard shortcuts
- 💾 Local data storage

## Requirements

- macOS 14.0+
- Xcode 15.0+
- OpenAI or Azure OpenAI API key

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

## Keyboard Shortcuts

- `Cmd+N` - New conversation
- `Cmd+,` - Settings
- `Enter` - Send message

## License

MIT License - see LICENSE file for details.
