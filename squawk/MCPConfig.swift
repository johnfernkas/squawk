import Foundation

// MARK: - Config Sources

struct MCPConfigSource: Identifiable, Sendable {
    let id: String
    let name: String
    let rootKey: String
    let paths: @Sendable () -> [String]

    static let builtIn: [MCPConfigSource] = [
        claudeDesktop, claudeCode, cursor, windsurf,
        vsCode, vsCodeInsiders, cline, rooCode,
        zed, amazonQ, jetBrains,
    ]

    static var allSources: [MCPConfigSource] {
        builtIn + CustomSourceLoader.load()
    }

    nonisolated(unsafe) private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static let claudeDesktop = MCPConfigSource(
        id: "claude-desktop", name: "Claude Desktop", rootKey: "mcpServers",
        paths: { ["\(home)/Library/Application Support/Claude/claude_desktop_config.json"] })

    static let claudeCode = MCPConfigSource(
        id: "claude-code", name: "Claude Code", rootKey: "mcpServers",
        paths: { ["\(home)/.claude.json"] })

    static let cursor = MCPConfigSource(
        id: "cursor", name: "Cursor", rootKey: "mcpServers",
        paths: { ["\(home)/.cursor/mcp.json"] })

    static let windsurf = MCPConfigSource(
        id: "windsurf", name: "Windsurf", rootKey: "mcpServers",
        paths: { ["\(home)/.codeium/windsurf/mcp_config.json"] })

    static let vsCode = MCPConfigSource(
        id: "vscode", name: "VS Code", rootKey: "servers",
        paths: { ["\(home)/Library/Application Support/Code/User/mcp.json"] })

    static let vsCodeInsiders = MCPConfigSource(
        id: "vscode-insiders", name: "VS Code Insiders", rootKey: "servers",
        paths: { ["\(home)/Library/Application Support/Code - Insiders/User/mcp.json"] })

    static let cline = MCPConfigSource(
        id: "cline", name: "Cline", rootKey: "mcpServers",
        paths: { ["\(home)/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"] })

    static let rooCode = MCPConfigSource(
        id: "roo-code", name: "Roo Code", rootKey: "mcpServers",
        paths: { ["\(home)/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"] })

    static let zed = MCPConfigSource(
        id: "zed", name: "Zed", rootKey: "context_servers",
        paths: { ["\(home)/.config/zed/settings.json"] })

    static let amazonQ = MCPConfigSource(
        id: "amazon-q", name: "Amazon Q", rootKey: "mcpServers",
        paths: { ["\(home)/.aws/amazonq/mcp.json"] })

    static let jetBrains = MCPConfigSource(
        id: "jetbrains", name: "JetBrains", rootKey: "mcpServers",
        paths: {
            let base = "\(home)/Library/Application Support/JetBrains"
            guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
            return dirs.map { "\(base)/\($0)/mcp.json" }
                .filter { FileManager.default.fileExists(atPath: $0) }
        })
}

// MARK: - Config Parsing

struct MCPServerConfig: Codable, Sendable {
    let command: String?
    let args: [String]?
    let url: String?
    let headers: [String: String]?
    let env: [String: String]?
    let disabled: Bool?

    var transportType: TransportType {
        url != nil ? .http : .stdio
    }

    var isEnabled: Bool {
        disabled != true
    }

    var fingerprint: String {
        if let url { return "http:\(url)" }
        let cmd = command ?? ""
        let a = (args ?? []).joined(separator: " ")
        return "stdio:\(cmd) \(a)"
    }

    func with(command: String) -> MCPServerConfig {
        MCPServerConfig(command: command, args: args, url: url,
                        headers: headers, env: env, disabled: disabled)
    }
}

enum MCPConfigParser {
    static func parse(data: Data, rootKey: String) -> [String: MCPServerConfig] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serversDict = json[rootKey] as? [String: Any]
        else { return [:] }

        var result: [String: MCPServerConfig] = [:]
        for (name, value) in serversDict {
            guard let serverJSON = value as? [String: Any],
                  let serverData = try? JSONSerialization.data(withJSONObject: serverJSON),
                  let config = try? JSONDecoder().decode(MCPServerConfig.self, from: serverData)
            else { continue }
            result[name] = config
        }
        return result
    }
}

// MARK: - Types

enum TransportType: String, Sendable {
    case stdio
    case http = "HTTP"
}

enum ServerStatus: Sendable, Equatable {
    case unknown
    case configured  // stdio: command resolved, config valid
    case healthy     // HTTP: server responding to MCP requests
    case stopped     // HTTP: server not responding
    case error(String)

    var isHealthy: Bool {
        switch self {
        case .configured, .healthy: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .unknown: "Checking..."
        case .configured: "Configured"
        case .healthy: "Healthy"
        case .stopped: "Stopped"
        case .error(let msg): msg
        }
    }
}

struct MCPTool: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String?
}

struct MCPServer: Identifiable {
    let id: String
    let name: String
    var sourceNames: [String]
    var sourcePaths: [String: String] = [:]  // source name → config file path
    let config: MCPServerConfig
    var status: ServerStatus = .unknown
    var tools: [MCPTool] = []
    var isLoadingTools = false
    // True when a stdio tool fetch was attempted and returned empty — stops auto-retry.
    // Not set for HTTP servers; an empty tool list there is valid (resource-only server).
    var toolsFailed = false
    var lastLatency: TimeInterval?

    mutating func preserveRuntimeState(from prev: MCPServer) {
        tools = prev.tools
        status = prev.status
        isLoadingTools = prev.isLoadingTools
        toolsFailed = prev.toolsFailed
        lastLatency = prev.lastLatency
    }
}

// MARK: - Claude Code Plugin Loader

enum ClaudeCodePluginLoader {
    static let sourceName = "Claude Code Plugins"

    private static let pluginsBase = FileManager.default
        .homeDirectoryForCurrentUser.path + "/.claude/plugins"

    struct InstalledPlugins: Codable {
        let version: Int
        let plugins: [String: [PluginInstall]]

        struct PluginInstall: Codable {
            let scope: String
            let installPath: String
            let version: String
        }
    }

    struct MarketplaceManifest: Codable {
        let plugins: [PluginEntry]

        struct PluginEntry: Codable {
            let name: String
            let mcpServers: [String: MCPServerConfig]?
        }
    }

    struct PluginServer {
        let name: String
        let config: MCPServerConfig
        let manifestPath: String
    }

    static func load() -> [PluginServer] {
        let installedPath = "\(pluginsBase)/installed_plugins.json"
        guard let data = FileManager.default.contents(atPath: installedPath),
              let installed = try? JSONDecoder().decode(InstalledPlugins.self, from: data)
        else { return [] }

        var results: [PluginServer] = []

        for (pluginKey, installs) in installed.plugins {
            guard let install = installs.first else { continue }

            let parts = pluginKey.split(separator: "@", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let pluginName = String(parts[0])
            let marketplaceName = String(parts[1])

            let manifestPath = "\(pluginsBase)/marketplaces/\(marketplaceName)/.claude-plugin/marketplace.json"
            guard let manifestData = FileManager.default.contents(atPath: manifestPath),
                  let manifest = try? JSONDecoder().decode(MarketplaceManifest.self, from: manifestData),
                  let pluginEntry = manifest.plugins.first(where: { $0.name == pluginName }),
                  let mcpServers = pluginEntry.mcpServers
            else { continue }

            let binMap = resolveBins(installPath: install.installPath)

            for (serverName, serverConfig) in mcpServers {
                let resolvedConfig = resolveCommand(in: serverConfig, binMap: binMap)
                results.append(PluginServer(name: serverName, config: resolvedConfig, manifestPath: manifestPath))
            }
        }

        return results
    }

    private static func resolveBins(installPath: String) -> [String: String] {
        let pkgPath = "\(installPath)/package.json"
        guard let data = FileManager.default.contents(atPath: pkgPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        if let binDict = json["bin"] as? [String: String] {
            return binDict.mapValues { "\(installPath)/\($0)" }
        } else if let binStr = json["bin"] as? String,
                  let rawName = json["name"] as? String {
            let name = rawName.split(separator: "/").last.map(String.init) ?? rawName
            return [name: "\(installPath)/\(binStr)"]
        }
        return [:]
    }

    private static func resolveCommand(in config: MCPServerConfig, binMap: [String: String]) -> MCPServerConfig {
        guard let command = config.command, let resolved = binMap[command] else { return config }
        return config.with(command: resolved)
    }
}

// MARK: - Custom Sources

enum CustomSourceLoader {
    private static let configPath = FileManager.default
        .homeDirectoryForCurrentUser.path + "/.config/squawk/sources.json"

    struct SourceFile: Codable {
        let sources: [Entry]

        struct Entry: Codable {
            let name: String
            let path: String
            let rootKey: String?
        }
    }

    static func load() -> [MCPConfigSource] {
        guard let data = FileManager.default.contents(atPath: configPath),
              let file = try? JSONDecoder().decode(SourceFile.self, from: data)
        else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return file.sources.map { entry in
            let resolvedPath = entry.path.replacingOccurrences(of: "~", with: home)
            let key = entry.rootKey ?? "mcpServers"
            return MCPConfigSource(
                id: "custom-\(entry.name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                name: entry.name,
                rootKey: key,
                paths: { [resolvedPath] }
            )
        }
    }
}
