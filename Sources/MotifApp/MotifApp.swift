import SwiftUI
import SceneKit
import MotifKit

@main
struct MotifApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.light)
                .tint(Theme.accent)
                .frame(minWidth: 900, minHeight: 560)
                .onOpenURL { app.open($0) }
        }
        .defaultSize(width: 1480, height: 920)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { app.showingNewProject = true }.keyboardShortcut("n")
                Button("Open Project…") { app.openPanel() }.keyboardShortcut("o")
                Button("Close Project") { app.close() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(app.current == nil)
            }
        }

        Settings {
            SettingsView().environment(app).preferredColorScheme(.light).tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let model = app.current {
                ProjectView(model: model).id(ObjectIdentifier(model))
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $app.showingNewProject) { NewProjectSheet() }
        .alert("Couldn't open project", isPresented: .init(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(app.errorMessage ?? "") }
    }
}

@MainActor @Observable
final class AppState {
    var current: ProjectModel?
    var showingNewProject = false
    var errorMessage: String?
    var recents: [URL] = []
    /// Bumped when the API key changes so open projects pick up the new tagger.
    var hasAPIKey = Settings.apiKey != nil

    init() {
        refreshRecents()
        // `Motif.app --open <project>` for scripted launches.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count { open(URL(fileURLWithPath: args[i + 1])) }
        if let i = args.firstIndex(of: "--select"), i + 1 < args.count, let id = Int64(args[i + 1]) { current?.selection = id }
        if let i = args.firstIndex(of: "--desc"), i + 1 < args.count { current?.descriptionQuery = args[i + 1] }
        if let i = args.firstIndex(of: "--move"), i + 1 < args.count { current?.movementText = args[i + 1] }
        if let i = args.firstIndex(of: "--designer") {
            if i + 1 < args.count, let template = ShotTemplate.allCases.first(where: { $0.rawValue.lowercased() == args[i + 1].lowercased() }) { current?.designer.apply(template) }
            current?.designer.seek((current?.designer.shot.duration ?? 0) * 0.6)
            current?.designerOpen = true
        }
        if let i = args.firstIndex(of: "--search-shot"), i + 1 < args.count,
           let template = ShotTemplate.allCases.first(where: { $0.rawValue.lowercased() == args[i + 1].lowercased() }), let model = current {
            model.designer.apply(template)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))                      // let the search index load first
                model.searchByShot(model.designer.shot, query: model.designer.makeQuery())
            }
        }
        if let i = args.firstIndex(of: "--stage-snapshot"), i + 1 < args.count, let designer = current?.designer { Snapshot.stage(designer, to: args[i + 1]) }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.schedule(to: args[i + 1], delay: args.firstIndex(of: "--delay").flatMap { Double(args[$0 + 1]) } ?? 5)
        }
    }

    func refreshRecents() {
        recents = Settings.recentProjects.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func open(_ url: URL) {
        do {
            current?.shutdown()
            current = ProjectModel(project: try Project.open(at: url))
            Settings.noteRecent(url)
            refreshRecents()
        } catch { errorMessage = error.localizedDescription }
    }

    func create(name: String, source: URL, location: URL) {
        do {
            let url = location.appendingPathComponent(name).appendingPathExtension(Project.fileExtension)
            try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
            current?.shutdown()
            current = ProjectModel(project: try Project.create(at: url, name: name, source: source))
            Settings.noteRecent(url)
            refreshRecents()
        } catch { errorMessage = error.localizedDescription }
    }

    func close() {
        current?.shutdown()
        current = nil
        refreshRecents()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: Project.fileExtension) ?? .package]
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseDirectories = true       // a .motif made before the type was registered is a plain folder
        panel.directoryURL = Self.defaultLocation
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func apiKeyChanged() {
        hasAPIKey = Settings.apiKey != nil
        current?.refreshTagger()
    }

    static var defaultLocation: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Motif", isDirectory: true)
    }
}

/// `--snapshot <png>`: the app draws its own window into a file, so the UI can be checked in scripted runs
/// without screen-recording permission. Video layers render black; everything else is what's on screen.
/// Launch through LaunchServices (`open Motif.app --args …`): run straight from a shell the app never activates and has no window.
@MainActor
enum Snapshot {
    /// The designer's two cameras rendered offscreen (the on-screen views are Metal and don't appear in a window snapshot).
    static func stage(_ designer: ShotDesignerModel, to directory: String) {
        let controller = designer.stageController
        let size = CGSize(width: 900, height: 560)
        controller.setCameraViewSize(size)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = controller.stage.scene
        for (name, camera) in [("overview", controller.overviewCamera), ("camera", controller.shotCamera)] {
            renderer.pointOfView = camera
            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("stage-\(name).png"))
            }
        }
    }

    static func schedule(to path: String, delay: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            NSApp.activate()
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) ?? NSApp.windows.first(where: { $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(3) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
