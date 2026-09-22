import SwiftUI
import MotifKit

/// Draw a camera move, then find the shots that move like it.
struct ShotDesignerView: View {
    let project: ProjectModel
    @Bindable var designer: ShotDesignerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.hairline.frame(height: 1)
            HStack(spacing: 0) {
                sidebar.frame(width: 214)
                Theme.hairline.frame(width: 1)
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        viewport("Set", hint: "Drag the camera to move it · ⌥-drag to raise · drag the floor to orbit · scroll to zoom") {
                            StageView(kind: .overview, model: designer)
                        }
                        viewport("Camera", hint: "Drag to look · scroll to dolly · ⌥-drag to truck and pedestal · ⇧-drag to roll · ⌘-scroll or pinch to zoom") {
                            ZStack { StageView(kind: .camera, model: designer); Passepartout() }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 14)
                    CameraControls(designer: designer).padding(.horizontal, 16).padding(.vertical, 10)
                    Theme.hairline.frame(height: 1)
                    TimelinePanel(designer: designer)
                }
            }
        }
        .background(Theme.background)
        .focusable().focusEffectDisabled()
        .onKeyPress(.space) { designer.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { designer.jumpToKeyframe(-1); return .handled }
        .onKeyPress(.rightArrow) { designer.jumpToKeyframe(1); return .handled }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in designer.deleteCurrentKeyframe(); return .handled }
        .onKeyPress(keys: ["k"]) { _ in designer.setKeyframe(); return .handled }
        .onKeyPress(keys: ["z"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            designer.undo(); return .handled
        }
        .onDisappear { designer.stop() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            Button { project.designerOpen = false } label: { Label("Clips", systemImage: "chevron.left").font(.callout.weight(.medium)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            Theme.hairline.frame(width: 1, height: 18)
            TextField("Shot name", text: Binding(get: { designer.shot.name }, set: designer.rename))
                .textFieldStyle(.plain).font(.title3.weight(.semibold)).foregroundStyle(Theme.textPrimary).frame(maxWidth: 280)
            DurationControl(designer: designer)
            Toggle(isOn: Binding(get: { designer.shot.eased }, set: designer.setEased)) { Text("Ease in / out").font(.callout) }
                .toggleStyle(.checkbox).help("Ramp up at the start and settle at the end, as an operator would. Off holds a constant speed.")
            Spacer()
            Button { designer.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!designer.canUndo).help("Undo (⌘Z)")
            Button(designer.isSaved ? "Saved" : "Save") { designer.save() }.disabled(designer.isSaved).keyboardShortcut("s")
            Button {
                designer.stop()
                project.searchByShot(designer.shot, query: designer.makeQuery())
            } label: { Label("Find Similar Shots", systemImage: "sparkle.magnifyingglass") }
                .buttonStyle(.borderedProminent).tint(Theme.accent).keyboardShortcut(.return)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface)
    }

    // MARK: sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start from").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    FlowLayout(spacing: 5) {
                        ForEach(ShotTemplate.allCases) { template in
                            Button(template.rawValue) { designer.apply(template) }.buttonStyle(PillButtonStyle())
                        }
                    }
                    Text("A template is just keyframes — adjust it like anything you draw yourself.").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Saved shots").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button { designer.newShot() } label: { Image(systemName: "plus") }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help("New shot")
                    }
                    if designer.saved.isEmpty {
                        Text("Shots you save appear here, and in every project.").font(.caption2).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(designer.saved) { saved in SavedShotRow(shot: saved, designer: designer) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reads as").font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    if designer.chips.isEmpty { Text("—").foregroundStyle(Theme.textTertiary) }
                    ForEach(Array(designer.chips.enumerated()), id: \.offset) { _, chips in ChipRow(chips: chips, stability: nil, wraps: true) }
                    Text("The same vocabulary Motif gives your footage, measured from what you drew.").font(.caption2).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(14)
        }
        .background(Theme.panel)
    }

    private func viewport<Content: View>(_ title: String, hint: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            content()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1) }
            Text(hint).font(.caption2).foregroundStyle(Theme.textTertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(configuration.isPressed ? Theme.hover : Theme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
    }
}

private struct SavedShotRow: View {
    let shot: DesignedShot
    let designer: ShotDesignerModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.viewfinder").font(.caption).foregroundStyle(designer.shot.id == shot.id ? Theme.accent : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 0) {
                Text(shot.name).font(.callout).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(String(format: "%.0f s · %d keyframes", shot.duration, shot.keyframes.count)).font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            if hovering { Button { designer.delete(shot) } label: { Image(systemName: "trash").font(.caption) }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary) }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(designer.shot.id == shot.id ? Theme.accent.opacity(0.08) : hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { designer.load(shot) }
        .onHover { hovering = $0 }
    }
}

private struct DurationControl: View {
    let designer: ShotDesignerModel

    var body: some View {
        HStack(spacing: 6) {
            Text("Duration").font(.callout).foregroundStyle(Theme.textSecondary)
            Button { designer.setDuration(designer.shot.duration - 1) } label: { Image(systemName: "minus") }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            Menu {
                ForEach([2, 3, 5, 8, 10, 15, 20, 30], id: \.self) { s in Button("\(s) seconds") { designer.setDuration(Double(s)) } }
            } label: { Text(String(format: "%.0f s", designer.shot.duration)).font(.callout.weight(.medium)).monospacedDigit() }
                .menuStyle(.borderlessButton).fixedSize()
            Button { designer.setDuration(designer.shot.duration + 1) } label: { Image(systemName: "plus") }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 1) }
        .help("Changing the duration stretches the move; it doesn't cut it off")
    }
}

/// Every camera parameter as a plain control, for when a gesture is too coarse or not discoverable.
private struct CameraControls: View {
    let designer: ShotDesignerModel

    var body: some View {
        HStack(spacing: 18) {
            nudge("Dolly", "minus", "plus") { $0.position -= $0.forward * 0.4 } _: { $0.position += $0.forward * 0.4 }
            nudge("Truck", "arrow.left", "arrow.right") { $0.position -= $0.right * 0.4 } _: { $0.position += $0.right * 0.4 }
            nudge("Pedestal", "arrow.down", "arrow.up") { $0.position.y -= 0.25 } _: { $0.position.y += 0.25 }
            nudge("Pan", "arrow.left", "arrow.right") { $0.yaw -= 4 } _: { $0.yaw += 4 }
            nudge("Tilt", "arrow.down", "arrow.up") { $0.pitch -= 3 } _: { $0.pitch += 3 }
            Theme.hairline.frame(width: 1, height: 20)
            slider("Lens", value: Binding(get: { log(Double(designer.pose.focal)) }, set: { v in designer.edit { $0.focal = Float(exp(v)) } }),
                   range: log(14)...log(200), readout: String(format: "%.0f mm", designer.pose.focal))
            slider("Roll", value: Binding(get: { Double(designer.pose.roll) }, set: { v in designer.edit { $0.roll = Float(v) } }),
                   range: -45...45, readout: String(format: "%+.0f°", designer.pose.roll))
            Button("Level") { designer.edit { $0.roll = 0 } }.controlSize(.small).disabled(designer.pose.roll == 0)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func nudge(_ title: String, _ less: String, _ more: String, _ decrease: @escaping (inout CameraPose) -> Void, _ increase: @escaping (inout CameraPose) -> Void) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(Theme.textSecondary)
            Button { designer.edit(decrease) } label: { Image(systemName: less).frame(width: 14, height: 14) }.buttonRepeatBehavior(.enabled)
            Button { designer.edit(increase) } label: { Image(systemName: more).frame(width: 14, height: 14) }.buttonRepeatBehavior(.enabled)
        }
        .controlSize(.small)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Theme.textSecondary)
            Slider(value: value, in: range).frame(width: 110).controlSize(.small)
            Text(readout).monospacedDigit().foregroundStyle(Theme.textPrimary).frame(width: 46, alignment: .leading)
        }
    }
}
