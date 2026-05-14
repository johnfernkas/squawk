# Squawk

Squawk is a macOS menubar app that discovers and monitors [MCP (Model Context Protocol)](https://modelcontextprotocol.io/) servers across all major AI coding tools. It reads server configurations, deduplicates identical servers found in multiple hosts, and continuously polls their health -- giving you a single place to see what is running and what is not.

## Features

- **Auto-discovery** -- Scans configuration files for 11 supported hosts and merges them into a unified list, deduplicating servers that appear in more than one tool.
- **Live health monitoring** -- Polls every 10 seconds. Stdio servers are checked via `pgrep`; HTTP servers receive a `tools/list` JSON-RPC request.
- **Menubar status indicator** -- Green when all servers are healthy, red when any server is down, yellow while checks are pending.
- **Server detail popover** -- Click the menubar icon to see each server's status, transport type (stdio / HTTP), and which hosts reference it.
- **Tool introspection** -- Expand any server row to fetch and display its available MCP tools via the MCP Swift SDK.

## Supported Hosts

| Host | Config Root Key | Config Location |
|------|----------------|-----------------|
| Claude Desktop | `mcpServers` | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Claude Code | `mcpServers` | `~/.claude.json` |
| Cursor | `mcpServers` | `~/.cursor/mcp.json` |
| Windsurf | `mcpServers` | `~/.codeium/windsurf/mcp_config.json` |
| VS Code | `servers` | `~/Library/Application Support/Code/User/mcp.json` |
| VS Code Insiders | `servers` | `~/Library/Application Support/Code - Insiders/User/mcp.json` |
| Cline | `mcpServers` | `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json` |
| Roo Code | `mcpServers` | `~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json` |
| Zed | `context_servers` | `~/.config/zed/settings.json` |
| Amazon Q | `mcpServers` | `~/.aws/amazonq/mcp.json` |
| JetBrains IDEs | `mcpServers` | `~/Library/Application Support/JetBrains/*/mcp.json` |

## How It Works

1. **Config loading** -- On launch, Squawk reads every known config path, parses the JSON, and extracts server entries from the appropriate root key (`mcpServers`, `servers`, or `context_servers`). Servers that share the same command+args or URL are merged and tagged with all hosts that reference them. File watchers detect config changes instantly without requiring a manual refresh.
2. **Health polling** -- A background task runs every 10 seconds. For each server it spawns a concurrent check:
   - *stdio* servers: resolves the command in `PATH` and, for Docker-based servers, verifies the daemon is running via `docker info`. Returns **Configured** if valid, an error otherwise.
   - *HTTP* servers: sends a `POST` with a `tools/list` JSON-RPC payload and treats any 2xx response as **Healthy**. Tools returned in that response are cached for display.
3. **Tool loading** -- After the first health check, Squawk eagerly fetches tools from every server in the background. HTTP tools come from the health check response. Stdio tools are fetched by spawning the server process and performing an MCP handshake via the MCP Swift SDK's `StdioTransport`.
4. **Status display** -- The menubar icon updates after each polling cycle and animates when a problem is detected. Clicking it opens a searchable tool browser grouped by server. Right-clicking a server reveals options to reload its tools or jump directly to its config file.

## Tech Stack

- **SwiftUI + AppKit** -- `NSStatusItem` for the menubar icon, `NSPopover` for the detail view, SwiftUI for all UI content.
- **MCP Swift SDK** ([github.com/modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)) -- Used for stdio transport tool introspection via `Client.connect` and `Client.listTools`.
- **@Observable** -- Reactive state management for the server list and polling status.
- **Structured concurrency** -- `TaskGroup` for concurrent health checks, `Task.sleep` for the polling interval.

## Project Structure

```
squawk/
  squawkApp.swift      App entry point; sets activation policy to .accessory (no dock icon)
  AppDelegate.swift    NSStatusItem setup, popover management, status icon updates
  MCPConfig.swift      Config source definitions, JSON parsing, server/transport models
  MCPMonitor.swift     Health polling loop, MCP protocol communication, tool fetching
  PopoverView.swift    SwiftUI popover UI (server list, tool rows, empty state)
```

## Getting Started

1. Clone the repository:
   ```
   git clone https://github.com/johnfernkas/squawk.git
   cd squawk
   ```
2. Open `squawk.xcodeproj` in Xcode 15 or later.
3. Add the MCP Swift SDK package dependency:
   - File > Add Package Dependencies
   - Enter `https://github.com/modelcontextprotocol/swift-sdk`
4. Disable the App Sandbox:
   - Select the squawk target > Signing & Capabilities
   - Remove the App Sandbox capability (Squawk needs filesystem access to read config files and process spawning for `pgrep` and stdio servers)
5. Build and run (Cmd+R). The Squawk icon will appear in your menubar.

## Requirements

- macOS 14.0+
- Xcode 15+
- App Sandbox **disabled** (filesystem access and process spawning are required)
- MCP Swift SDK package dependency

## Roadmap

- **Config management** -- Enable or disable individual servers directly from the Squawk popover.
- **Historical health data** -- Record uptime and status history over time for each server.
- **Tool input schema** -- Expand a tool to see its parameters and required arguments.

## License

MIT License

Copyright (c) 2025 John Fernkas

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
