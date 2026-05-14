import Foundation
import MCP
import System
import UserNotifications

@MainActor
@Observable
final class MCPMonitor {
    var servers: [MCPServer] = []
    var conflictingToolNames: Set<String> = []
    var lastRefresh: Date?
    var isRefreshing = false
    var popoverOpenCount = 0
    var onStatusChange: (() -> Void)?

    private var pollingTask: Task<Void, Never>?
    private var fileWatchSources: [DispatchSourceFileSystemObject] = []
    private var fileChangeDebounce: DispatchWorkItem?

    var overallHealthy: Bool {
        !servers.isEmpty && servers.allSatisfy(\.status.isHealthy)
    }

    var allDown: Bool {
        !servers.isEmpty && !servers.contains(where: \.status.isHealthy)
    }

    func loadConfig() {
        let previous = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        var byFingerprint: [String: MCPServer] = [:]

        for source in MCPConfigSource.allSources {
            for path in source.paths() {
                guard let data = FileManager.default.contents(atPath: path) else { continue }
                let serverConfigs = MCPConfigParser.parse(data: data, rootKey: source.rootKey)
                for (name, config) in serverConfigs where config.isEnabled {
                    merge(
                        name: name, config: config,
                        sourceName: source.name, path: path,
                        into: &byFingerprint, preserving: previous
                    )
                }
            }
        }

        for plugin in ClaudeCodePluginLoader.load() {
            merge(
                name: plugin.name, config: plugin.config,
                sourceName: ClaudeCodePluginLoader.sourceName, path: plugin.manifestPath,
                into: &byFingerprint, preserving: previous
            )
        }

        servers = byFingerprint.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        conflictingToolNames = computeConflicts()
    }

    private func merge(
        name: String, config: MCPServerConfig,
        sourceName: String, path: String,
        into byFingerprint: inout [String: MCPServer],
        preserving previous: [String: MCPServer]
    ) {
        let fp = config.fingerprint
        if var existing = byFingerprint[fp] {
            if !existing.sourceNames.contains(sourceName) {
                existing.sourceNames.append(sourceName)
                existing.sourcePaths[sourceName] = path
            }
            byFingerprint[fp] = existing
        } else {
            var server = MCPServer(
                id: fp, name: name,
                sourceNames: [sourceName],
                sourcePaths: [sourceName: path],
                config: config
            )
            if let prev = previous[fp] { server.preserveRuntimeState(from: prev) }
            byFingerprint[fp] = server
        }
    }

    private func computeConflicts() -> Set<String> {
        var seenIn: [String: String] = [:]
        var conflicts: Set<String> = []
        for server in servers {
            for tool in server.tools {
                if let first = seenIn[tool.name] {
                    if first != server.id { conflicts.insert(tool.name) }
                } else {
                    seenIn[tool.name] = server.id
                }
            }
        }
        return conflicts
    }

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                await refreshAll()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func startFileWatching() {
        stopFileWatching()
        let paths = MCPConfigSource.allSources.flatMap { $0.paths() }
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.fileChangeDebounce?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.loadConfig()
                    Task { await self.refreshAll() }
                }
                self.fileChangeDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            fileWatchSources.append(source)
        }
    }

    func stopFileWatching() {
        fileWatchSources.forEach { $0.cancel() }
        fileWatchSources = []
    }

    func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let previousStatuses = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.status) })

        await withTaskGroup(of: (String, ServerStatus, [MCPTool], TimeInterval).self) { group in
            for server in servers {
                let serverID = server.id
                let config = server.config
                group.addTask {
                    let (status, tools, latency) = await MCPChecker.check(config: config)
                    return (serverID, status, tools, latency)
                }
            }
            for await (id, status, tools, latency) in group {
                guard let index = servers.firstIndex(where: { $0.id == id }) else { continue }
                servers[index].status = status
                servers[index].lastLatency = latency
                if !tools.isEmpty { servers[index].tools = tools }
            }
        }

        for server in servers {
            guard let previous = previousStatuses[server.id],
                  previous.isHealthy, !server.status.isHealthy else { continue }
            postServerDownNotification(server: server)
        }

        lastRefresh = Date()
        onStatusChange?()

        // Mark isLoadingTools before spawning tasks to prevent duplicate fetches
        // if refreshAll fires again before a task completes.
        for index in servers.indices where servers[index].config.transportType == .stdio
            && servers[index].status == .configured
            && servers[index].tools.isEmpty
            && !servers[index].isLoadingTools
            && !servers[index].toolsFailed
        {
            servers[index].isLoadingTools = true
            let serverID = servers[index].id
            Task { await fetchTools(for: serverID) }
        }

        conflictingToolNames = computeConflicts()
    }

    private func postServerDownNotification(server: MCPServer) {
        let content = UNMutableNotificationContent()
        content.title = "MCP Server Down"
        content.body = "\(server.name) is no longer running."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "server-down-\(server.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func fetchTools(for serverID: String) async {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].isLoadingTools = true
        servers[index].toolsFailed = false

        let config = servers[index].config
        let tools: [MCPTool]

        switch config.transportType {
        case .http:
            let (_, fetched) = await MCPChecker.checkHTTP(config: config)
            tools = fetched
        case .stdio:
            tools = await MCPChecker.fetchStdioTools(config: config)
        }

        guard let i = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[i].tools = tools
        servers[i].isLoadingTools = false
        // Only flag failure for stdio — an HTTP server with no tools is valid (resource-only).
        if tools.isEmpty && config.transportType == .stdio { servers[i].toolsFailed = true }
        conflictingToolNames = computeConflicts()
    }
}

// MARK: - Duration Helper

extension Duration {
    var seconds: TimeInterval {
        let comps = self.components
        return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) * 1e-18
    }
}

// MARK: - Server Checking

enum MCPChecker {
    // Resolved once at startup by spawning the user's login+interactive shell.
    // -i -l sources both .zprofile and .zshrc, picking up bun, nvm, cargo, etc.
    // A unique marker lets us extract $PATH cleanly even if shell init writes to stdout.
    // Falls back to well-known tool locations if the shell invocation fails.
    static let shellPath: String = {
        let systemPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-i", "-l", "-c", "printf 'SQUAWK_PATH=%s' \"$PATH\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let range = output.range(of: "SQUAWK_PATH=") {
            let shellDerived = String(output[range.upperBound...])
            if !shellDerived.isEmpty { return shellDerived }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let wellKnown = ["\(home)/.bun/bin", "\(home)/.cargo/bin", "\(home)/.local/bin",
                         "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                         "/usr/sbin", "/sbin"]
        return (wellKnown + [systemPath]).filter { !$0.isEmpty }.joined(separator: ":")
    }()

    static func check(config: MCPServerConfig) async -> (ServerStatus, [MCPTool], TimeInterval) {
        let start = ContinuousClock.now
        switch config.transportType {
        case .stdio:
            let status = await checkStdio(config: config)
            let elapsed = ContinuousClock.now - start
            return (status, [], elapsed.seconds)
        case .http:
            let (status, tools) = await checkHTTP(config: config)
            let elapsed = ContinuousClock.now - start
            return (status, tools, elapsed.seconds)
        }
    }

    static func checkStdio(config: MCPServerConfig) async -> ServerStatus {
        guard let command = config.command else {
            return .error("No command configured")
        }

        guard resolveCommand(command) != nil else {
            return .error("Command not found: \(command)")
        }

        if command == "docker" || command.hasSuffix("/docker") {
            let dockerOK = await isDockerRunning()
            if !dockerOK {
                return .error("Docker not running")
            }
        }

        return .configured
    }

    private static func isDockerRunning() async -> Bool {
        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Bool, Error>) in
                let process = Process()
                process.executableURL = resolveCommand("docker")
                process.arguments = ["info"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                process.terminationHandler = { proc in
                    continuation.resume(returning: proc.terminationStatus == 0)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            return false
        }
    }

    static func checkHTTP(config: MCPServerConfig) async -> (ServerStatus, [MCPTool]) {
        guard let urlString = config.url,
              let url = URL(string: urlString)
        else {
            return (.error("Invalid URL"), [])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        if let headers = config.headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [String: String](),
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return (.error("Failed to encode request"), [])
        }
        request.httpBody = bodyData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return (.error("Invalid response"), [])
            }

            if (200...299).contains(httpResponse.statusCode) {
                let tools = parseToolsResponse(data)
                return (.healthy, tools)
            } else {
                return (.error("HTTP \(httpResponse.statusCode)"), [])
            }
        } catch {
            return (.stopped, [])
        }
    }

    static func fetchStdioTools(config: MCPServerConfig) async -> [MCPTool] {
        guard let command = config.command,
              let executableURL = resolveCommand(command) else { return [] }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = config.args ?? []

        var processEnv = ProcessInfo.processInfo.environment
        processEnv["PATH"] = MCPChecker.shellPath
        if let env = config.env { for (key, value) in env { processEnv[key] = value } }
        process.environment = processEnv

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do { try process.run() } catch { return [] }

        let client = Client(name: "Squawk", version: "1.0.0")
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        )

        do {
            let initResult = try await client.connect(transport: transport)
            let tools: [MCPTool]
            if initResult.capabilities.tools != nil {
                let (list, _) = try await client.listTools()
                tools = list.map { MCPTool(name: $0.name, description: $0.description) }
            } else {
                tools = []
            }
            await client.disconnect()
            process.terminate()
            return tools
        } catch {
            await client.disconnect()
            process.terminate()
            return []
        }
    }

    // MARK: - Helpers

    private static func resolveCommand(_ command: String) -> URL? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command)
                ? URL(fileURLWithPath: command) : nil
        }

        for dir in shellPath.split(separator: ":").map(String.init) {
            let fullPath = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return URL(fileURLWithPath: fullPath)
            }
        }
        return nil
    }

    private static func parseToolsResponse(_ data: Data) -> [MCPTool] {
        struct Response: Codable {
            let result: Result?
            struct Result: Codable {
                let tools: [Tool]?
                struct Tool: Codable {
                    let name: String
                    let description: String?
                }
            }
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let tools = response.result?.tools
        else { return [] }

        return tools.map { MCPTool(name: $0.name, description: $0.description) }
    }
}
