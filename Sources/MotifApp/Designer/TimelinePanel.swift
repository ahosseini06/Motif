import SwiftUI
import MotifKit

/// Transport, keyframe track and the live motion graph, sharing one time axis.
struct TimelinePanel: View {
    @Bindable var designer: ShotDesignerModel
    private let labelWidth: CGFloat = 68          // MotionGraph's label column + padding, so the axes line up

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { designer.jumpToKeyframe(-1) } label: { Image(systemName: "backward.end.fill") }.help("Previous keyframe (←)")
                Button { designer.togglePlayback() } label: { Image(systemName: designer.isPlaying ? "pause.fill" : "play.fill").frame(width: 14) }.help("Play (space)")
                Button { designer.jumpToKeyframe(1) } label: { Image(systemName: "forward.end.fill") }.help("Next keyframe (→)")
                Text(String(format: "%.2f / %.1f s", designer.time, designer.shot.duration)).font(.callout).monospacedDigit().foregroundStyle(Theme.textSecondary).frame(width: 96, alignment: .leading)
                Theme.hairline.frame(width: 1, height: 16)
                Button { designer.setKeyframe() } label: { Label(designer.currentKeyframe == nil ? "Add Keyframe" : "Update Keyframe", systemImage: "diamond.fill") }
                    .help("Keyframe the camera here (K)")
                    .tint(designer.hasUnkeyedChange ? Theme.accent : nil)
                Button { designer.deleteCurrentKeyframe() } label: { Image(systemName: "trash") }
                    .disabled(designer.currentKeyframe == nil || designer.shot.keyframes.count < 2).help("Delete this keyframe (⌫)")
                Toggle(isOn: $designer.autoKey) { Text("Auto-key") }.toggleStyle(.checkbox)
                    .help("On: moving the camera writes a keyframe at the playhead. Off: moves are temporary until you add a keyframe.")
                Spacer()
                Text(hint).font(.caption).foregroundStyle(designer.hasUnkeyedChange ? Theme.accent : Theme.textTertiary)
            }
            .controlSize(.small).font(.callout)

            KeyframeTrack(designer: designer).frame(height: 38).padding(.leading, labelWidth).padding(.trailing, 10)
            MotionGraph(tracks: designer.tracks, duration: designer.shot.duration, time: designer.time, loop: nil) { designer.seek($0) }
                .frame(height: 148)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.surface)
    }

    private var hint: String {
        if designer.hasUnkeyedChange { return "Camera moved — add a keyframe to keep it" }
        if designer.shot.keyframes.count == 1 { return "Move the playhead to where the move ends, then move the camera" }
        return "Drag a diamond to retime it"
    }
}

private struct KeyframeTrack: View {
    let designer: ShotDesignerModel

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width), duration = max(designer.shot.duration, 0.001)
            let x: (Double) -> CGFloat = { CGFloat($0 / duration) * width }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: 14, width: size.width, height: 16), cornerRadius: 4), with: .color(Theme.hover))
                    let step: Double = duration > 40 ? 10 : duration > 16 ? 5 : duration > 6 ? 2 : 1
                    var t = 0.0
                    while t <= duration + 0.001 {
                        var tick = Path(); tick.move(to: CGPoint(x: x(t), y: 8)); tick.addLine(to: CGPoint(x: x(t), y: 14))
                        ctx.stroke(tick, with: .color(Theme.textTertiary.opacity(0.7)), lineWidth: 1)
                        ctx.draw(Text(String(format: "%.0f", t)).font(.system(size: 9)).foregroundStyle(Theme.textTertiary), at: CGPoint(x: x(t) + 2, y: 4), anchor: .leading)
                        t += step
                    }
                    var playhead = Path(); playhead.move(to: CGPoint(x: x(designer.time), y: 6)); playhead.addLine(to: CGPoint(x: x(designer.time), y: size.height))
                    ctx.stroke(playhead, with: .color(Theme.textPrimary.opacity(0.8)), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    designer.seek(Double(value.location.x / width) * duration, snapping: true)
                })

                ForEach(designer.shot.keyframes) { key in
                    let current = abs(key.time - designer.time) < 0.06
                    Image(systemName: "diamond.fill")
                        .font(.system(size: current ? 13 : 11))
                        .foregroundStyle(current ? Theme.accent : Theme.surface)
                        .overlay { Image(systemName: "diamond").font(.system(size: current ? 13 : 11)).foregroundStyle(Theme.accent) }
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                        .position(x: x(key.time), y: 22)
                        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("track")).onChanged { value in
                            designer.retime(key.id, to: Double(value.location.x / width) * duration)
                        })
                        .simultaneousGesture(TapGesture().onEnded { designer.seek(key.time) })
                        .help(String(format: "Keyframe at %.2f s", key.time))
                }
            }
            .coordinateSpace(name: "track")
        }
    }
}
