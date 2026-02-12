# Security Policy

## Supported Versions

We release patches for security vulnerabilities in the following versions:

| Version | Supported          |
| ------- | ------------------ |
| Latest  | :white_check_mark: |
| < Latest| :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability within Ayna, please send an email to the maintainers. All security vulnerabilities will be promptly addressed.

**Please do not report security vulnerabilities through public GitHub issues.**

### What to Include

When reporting a vulnerability, please include:

- A description of the vulnerability
- Steps to reproduce the issue
- Potential impact
- Any suggested fixes (optional)

### Response Timeline

- **Initial Response**: Within 48 hours of report
- **Status Update**: Within 7 days with assessment and timeline
- **Resolution**: Security fixes are prioritized and typically released within 30 days

## Security Best Practices

When using Ayna:

1. **API Keys**: Always store API keys in Keychain (never in code or UserDefaults)
2. **Encryption**: Conversations are encrypted at rest using Apple's CryptoKit
3. **Updates**: Keep Ayna updated to the latest version for security patches
4. **Permissions**: Review and grant only necessary system permissions

## Known Security Considerations

- **API Key Storage**: API keys are stored in the system Keychain with appropriate access controls
- **Conversation Encryption**: All conversations are encrypted using AES-GCM with keys stored securely
- **Network Communication**: All API communications use HTTPS/TLS
- **MCP Subprocess**: On macOS, MCP tools run in isolated subprocesses with limited permissions

## Disclosure Policy

When we receive a security report:

1. We confirm receipt and begin investigation
2. We work on a fix in a private repository
3. We prepare a security advisory
4. We release the fix and publish the advisory
5. We credit the reporter (unless anonymity is requested)

Thank you for helping keep Ayna and its users secure!
