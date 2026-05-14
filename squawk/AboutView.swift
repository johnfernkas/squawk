import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 96 * 0.225))
                }

                VStack(spacing: 4) {
                    Text("Squawk")
                        .font(.system(size: 22, weight: .bold))
                    Text("Version \(version)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Text("Discovers MCP servers across all your AI coding tools and surfaces the tools they expose.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 32)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            Divider()

            HStack {
                Text("By John Fernkas")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Link("GitHub →", destination: URL(string: "https://github.com/johnfernkas/squawk")!)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: 320)
    }
}
