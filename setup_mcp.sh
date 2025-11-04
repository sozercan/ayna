#!/bin/bash

# MCP Integration Setup Script for ayna
# This script helps verify that your environment is ready for MCP integration

set -e

echo "🔍 Checking MCP Integration Prerequisites..."
echo ""

# Check Node.js
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    echo "✅ Node.js is installed: $NODE_VERSION"
else
    echo "❌ Node.js is NOT installed"
    echo "   Install with: brew install node"
    exit 1
fi

# Check npm
if command -v npm &> /dev/null; then
    NPM_VERSION=$(npm --version)
    echo "✅ npm is installed: $NPM_VERSION"
else
    echo "❌ npm is NOT installed"
    exit 1
fi

# Check npx
if command -v npx &> /dev/null; then
    echo "✅ npx is available"
else
    echo "❌ npx is NOT available"
    exit 1
fi

echo ""
echo "🧪 Testing MCP Server Availability..."
echo ""

# Test brave-search server
echo "Testing @modelcontextprotocol/server-brave-search..."
if npx -y @modelcontextprotocol/server-brave-search --version &> /dev/null; then
    echo "✅ Brave Search MCP server is accessible"
else
    echo "⚠️  Could not verify Brave Search server (this is OK, it will download on first use)"
fi

# Test filesystem server
echo "Testing @modelcontextprotocol/server-filesystem..."
if npx -y @modelcontextprotocol/server-filesystem --version &> /dev/null; then
    echo "✅ Filesystem MCP server is accessible"
else
    echo "⚠️  Could not verify Filesystem server (this is OK, it will download on first use)"
fi

echo ""
echo "✅ Environment check complete!"
echo ""
echo "📋 Next Steps:"
echo "   1. Build and run ayna in Xcode"
echo "   2. Open Settings → MCP Tools"
echo "   3. Configure your Brave API key (get one at https://brave.com/search/api/)"
echo "   4. Enable the servers you want to use"
echo "   5. Start chatting with tool support!"
echo ""
echo "📚 Read MCP_INTEGRATION.md for detailed setup instructions"
