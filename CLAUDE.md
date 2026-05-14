# Squawk

A macOS menubar app that discovers MCP (Model Context Protocol) servers across all major AI coding tools, deduplicates them, and surfaces the tools they expose in a searchable interface.

## What it does

- Scans config files for 11 supported hosts (Claude Desktop, Claude Code, Cursor, Windsurf, VS Code, Cline, Roo Code, Zed, Amazon Q, JetBrains, and custom sources)
- Detects Claude Code plugins that expose MCP servers via `~/.claude/plugins/installed_plugins.json`
- Deduplicates servers that appear in multiple hosts by fingerprint (command+args or URL)
- Polls HTTP servers every 10 seconds by sending a raw `tools/list` JSON-RPC POST request directly — no SDK involved
- Validates stdio servers by resolving their command in PATH (and checking Docker daemon for docker-based servers)
- Eagerly fetches tool lists for all servers after the first health check; marks stdio servers as "Unavailable" if the fetch fails and stops retrying
- Watches config files for changes via DispatchSource and reloads instantly
- Shows a searchable, collapsible tool browser in an NSPopover

## Architecture

- **AppDelegate** — NSStatusItem setup, popover management, file watching lifecycle, global hotkey (⌘⇧M), animated menubar icon
- **MCPMonitor** — `@Observable` state, polling loop, file watchers, health checks, tool loading
- **MCPChecker** — static methods for stdio validation, HTTP health check, stdio tool fetching via MCP Swift SDK
- **MCPConfig** — config source definitions, JSON parsing, server/transport models, status enum
- **ClaudeCodePluginLoader** — reads `~/.claude/plugins/installed_plugins.json`, resolves each plugin's marketplace manifest and bin path, and surfaces MCP servers defined in the plugin's `mcpServers` config block
- **CustomSourceLoader** — loads additional config sources from `~/.config/squawk/sources.json`
- **PopoverView** — SwiftUI tool browser: search, collapsible server sections, click-to-copy, conflict detection
- **AboutView** — custom About window with icon, version, GitHub link
- **SettingsView** — launch at login toggle, global shortcut info

## Key decisions

- **Stdio = "Configured"** (blue dot): we validate the command exists, not that the server is running. Clients spawn stdio servers on demand, so "running" would be misleading.
- **HTTP = "Healthy"** (green dot): we confirm the server responds to MCP protocol requests.
- **toolsFailed** (orange dot, "Unavailable"): set when a stdio tool fetch attempt returns empty. Stops auto-retry. Not used for HTTP — an HTTP server with no tools is valid (resource-only server). Only overrides Configured/Healthy states; Stopped and Error take priority.
- **MCP Swift SDK** is used for stdio tool fetching only. HTTP uses a raw `URLSession` POST — the SDK's HTTP transport is SSE-based (persistent connection), which is too heavy for a 10-second health poll. Always call `await client.disconnect()` after stdio use — without it, SwiftNIO event loop threads keep running and cause ~200% CPU.
- **Shell PATH** (`MCPChecker.shellPath`): resolved once at startup by spawning `$SHELL -i -l -c 'printf ...'`. The `-i -l` flags source both login files and `.zshrc` so tools like bun, nvm, and cargo are found. A unique marker (`SQUAWK_PATH=`) extracts the value even if shell init writes to stdout. Falls back to well-known locations if the shell invocation fails.
- **Claude Code plugin bin resolution**: plugins declare their MCP server with a short command name (e.g. `"qmd"`). `ClaudeCodePluginLoader` maps that name to the absolute path in the plugin's `installPath/bin/` via `package.json`'s `bin` field. Without this, the command wouldn't be found since the plugin bin directory isn't on the system PATH.
- **Fixed popover frame** (380×500): prevents the window from resizing when search results change.
- File watcher events are debounced at 0.5s to prevent event flooding from causing repeated tool refetches.
- `loadConfig()` preserves existing tool data across reloads by matching server fingerprints — prevents tools being cleared and re-fetched on every config change.
- `conflictingToolNames` is a stored `Set<String>` updated at the end of `loadConfig()`, `refreshAll()`, and `fetchTools()` — not recomputed on every SwiftUI render.

## Status colors

- Blue = Configured (stdio, command resolved)
- Green = Healthy (HTTP, responding to MCP)
- Yellow = Mixed (some servers have issues)
- Red + pulse animation = All down

## Build requirements

- macOS 14+
- Xcode 15+
- App Sandbox **disabled** (required for filesystem access and process spawning)
- MCP Swift SDK package dependency (github.com/modelcontextprotocol/swift-sdk)
