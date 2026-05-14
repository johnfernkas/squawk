import AppKit
import SwiftUI

struct PopoverView: View {
    var monitor: MCPMonitor
    @State private var searchText = ""
    @State private var expandedServers: Set<String> = []

    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var searchResults: [(tool: MCPTool, server: MCPServer)] {
        guard !searchQuery.isEmpty else { return [] }
        let q = searchQuery.lowercased()
        return monitor.servers.flatMap { server in
            server.tools.filter {
                $0.name.lowercased().contains(q) ||
                ($0.description?.lowercased().contains(q) ?? false)
            }.map { (tool: $0, server: server) }
        }
    }

    private var totalToolCount: Int {
        monitor.servers.reduce(0) { $0 + $1.tools.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 380, height: 500)
        .onChange(of: monitor.popoverOpenCount) {
            expandedServers = []
            searchText = ""
        }
    }

    // MARK: - Header

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            TextField("Search tools…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
            Divider().frame(height: 16)
            if monitor.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    monitor.loadConfig()
                    Task { await monitor.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(monitor.isRefreshing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if monitor.servers.isEmpty {
            emptyState
        } else if !searchQuery.isEmpty {
            searchResultsView
        } else {
            serverListView
        }
    }

    private var serverListView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(monitor.servers) { server in
                    ServerSectionView(
                        server: server,
                        isExpanded: expandedServers.contains(server.id),
                        conflictingToolNames: monitor.conflictingToolNames,
                        monitor: monitor
                    ) {
                        if expandedServers.contains(server.id) {
                            expandedServers.remove(server.id)
                        } else {
                            expandedServers.insert(server.id)
                        }
                    }
                    if server.id != monitor.servers.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var searchResultsView: some View {
        if searchResults.isEmpty {
            VStack {
                Spacer()
                Text("No tools matching \"\(searchQuery)\"")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(searchResults, id: \.tool.id) { item in
                        ToolRowView(
                            tool: item.tool,
                            serverName: item.server.name,
                            isConflicting: monitor.conflictingToolNames.contains(item.tool.name)
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No MCP servers found")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Configure an MCP server in Claude Desktop,\nCursor, VS Code, or another supported client\nand Squawk will pick it up automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button("Learn about MCP →") {
                    NSWorkspace.shared.open(URL(string: "https://modelcontextprotocol.io")!)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.blue)
                .padding(.top, 2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !monitor.servers.isEmpty {
                Text("\(monitor.servers.count) server\(monitor.servers.count == 1 ? "" : "s") · \(totalToolCount) tool\(totalToolCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let lastRefresh = monitor.lastRefresh {
                Text("Updated \(lastRefresh, style: .relative) ago")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Server Section

struct ServerSectionView: View {
    let server: MCPServer
    let isExpanded: Bool
    let conflictingToolNames: Set<String>
    var monitor: MCPMonitor
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            serverHeader
            if isExpanded {
                toolsContent
                    .transition(.opacity)
            }
        }
    }

    private var serverHeader: some View {
        Button(action: onToggle) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(server.config.transportType.rawValue.lowercased())
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        if !server.sourceNames.isEmpty {
                            Text("· " + server.sourceNames.joined(separator: ", "))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(server.sourceNames.joined(separator: "\n"))
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if server.tools.contains(where: { conflictingToolNames.contains($0.name) }) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help("One or more tools conflict with another server")
                    }
                    if !server.tools.isEmpty {
                        Text("\(server.tools.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    } else if server.isLoadingTools {
                        ProgressView().controlSize(.mini)
                    }
                    statusDot
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reload Tools") {
                Task { await monitor.fetchTools(for: server.id) }
            }
            Divider()
            if server.sourcePaths.isEmpty {
                Text("No config file found")
            } else {
                ForEach(server.sourceNames.filter { server.sourcePaths[$0] != nil }, id: \.self) { name in
                    Button("Open \(name) Config") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: server.sourcePaths[name]!))
                    }
                }
            }
        }
    }

    private var statusDot: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(server.toolsFailed ? "Unavailable" : server.status.label)
                .font(.system(size: 10))
                .foregroundStyle(statusColor)
            if let latency = server.lastLatency, server.config.transportType == .http {
                Text("· \(formatLatency(latency))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var toolsContent: some View {
        if server.isLoadingTools {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading tools…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.leading, 17)
            .padding(.bottom, 10)
        } else if server.toolsFailed {
            Text("Failed to load tools")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.leading, 17)
                .padding(.bottom, 10)
        } else if server.tools.isEmpty {
            Text("No tools available")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
                .padding(.horizontal, 12)
                .padding(.leading, 17)
                .padding(.bottom, 10)
        } else {
            VStack(spacing: 0) {
                ForEach(server.tools) { tool in
                    ToolRowView(
                        tool: tool,
                        serverName: nil,
                        isConflicting: conflictingToolNames.contains(tool.name)
                    )
                }
            }
            .padding(.leading, 17)
            .padding(.bottom, 4)
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .unknown: return .gray
        // toolsFailed only overrides non-error states — stopped/error take priority.
        case .configured: return server.toolsFailed ? .orange : .blue
        case .healthy: return server.toolsFailed ? .orange : .green
        case .stopped: return .red
        case .error: return .orange
        }
    }
}

// MARK: - Tool Row

struct ToolRowView: View {
    let tool: MCPTool
    let serverName: String?
    let isConflicting: Bool
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        Button(action: copyToolName) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tool.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                        if isConflicting {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help("Another server exposes a tool with this name. The client may use either one.")
                        }
                        if let serverName {
                            Text(serverName)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    if let description = tool.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copied ? Color.green : (isHovered ? Color.secondary : Color.primary.opacity(0.25)))
                    .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isHovered ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func copyToolName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tool.name, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }
}

// MARK: - Helpers

private func formatLatency(_ latency: TimeInterval) -> String {
    latency >= 1.0 ? String(format: "%.1fs", latency) : "\(Int(latency * 1000))ms"
}
