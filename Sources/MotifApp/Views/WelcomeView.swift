import SwiftUI
import MotifKit

struct WelcomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                Image(systemName: "film.stack")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Motif").font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Every clip described, every camera move measured.")
                        .font(.title3).foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 10) {
                    Button { app.showingNewProject = true } label: { Label("New Project", systemImage: "plus").frame(minWidth: 120) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button { app.openPanel() } label: { Text("Open…").frame(minWidth: 70) }
                }
                .controlSize(.large)
                .padding(.top, 6)
                Spacer()
                Text("Camera motion is measured on this Mac. Only a small, silent 360p proxy is ever sent for description — and never for projects marked on-device only.")
                    .font(.caption).foregroundStyle(Theme.textTertiary).frame(maxWidth: 360, alignment: .leading)
            }
            .padding(44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Text("Recent").font(.callout.weight(.medium)).foregroundStyle(Theme.textSecondary)
                if app.recents.isEmpty {
                    Text("Projects you open will appear here.").font(.callout).foregroundStyle(Theme.textTertiary).padding(.top, 4)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(app.recents, id: \.self) { url in RecentRow(url: url) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(width: 340)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panel)
            .overlay(alignment: .leading) { Theme.hairline.frame(width: 1) }
        }
        .background(Theme.surface)
    }
}

private struct RecentRow: View {
    @Environment(AppState.self) private var app
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button { app.open(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: "film").foregroundStyle(Theme.textSecondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct NewProjectSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source: URL?
    @State private var location = AppState.defaultLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Project").font(.title2.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text("Footage").foregroundStyle(Theme.textSecondary)
                    HStack {
                        Text(source?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Choose the folder of video clips")
                            .foregroundStyle(source == nil ? Theme.textTertiary : .primary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseSource() }
                    }
                }
                GridRow {
                    Text("Name").foregroundStyle(Theme.textSecondary)
                    TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Save in").foregroundStyle(Theme.textSecondary)
                    HStack {
                        Text(location.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Change…") { chooseLocation() }
                    }
                }
            }
            Text("Footage is read in place and never modified. The project file holds the catalog, thumbnails and proxies, so it stays browsable with the drive unplugged.")
                .font(.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let source else { return }
                    app.create(name: name.trimmingCharacters(in: .whitespaces), source: source, location: location)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(source == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the folder of footage"
        if panel.runModal() == .OK, let url = panel.url {
            source = url
            if name.isEmpty { name = url.lastPathComponent }
        }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { location = url }
    }
}
