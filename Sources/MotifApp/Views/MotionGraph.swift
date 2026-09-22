import SwiftUI
import MotifKit

/// Seven lanes, one per motion channel, across the clip's timeline. Each lane is centred on zero and soft-clipped so a
/// `slow` move is already clearly visible and a whip pan still fits; segment boundaries and the playhead run through all lanes.
/// One stretch of trajectory: rows of seven channel rates, evenly spaced between `start` and `end`.
struct MotionTrack {
    var start: Double, end: Double, rows: [[Float]]
}

struct MotionGraph: View {
    let tracks: [MotionTrack]
    let duration: Double
    let time: Double
    let loop: ClosedRange<Double>?
    let onScrub: (Double) -> Void

    private let labelWidth: CGFloat = 58

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: labelWidth, y: 0, width: max(1, geo.size.width - labelWidth), height: geo.size.height)
            let laneHeight = plot.height / 7
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    draw(&ctx, plot: plot, laneHeight: laneHeight)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(MotionChannel.allCases, id: \.self) { channel in
                        Text(channel.name).font(.caption2).foregroundStyle(Theme.colour(channel).opacity(0.9))
                            .frame(width: labelWidth - 8, height: laneHeight, alignment: .leading)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0 else { return }
                onScrub(min(duration, max(0, Double((value.location.x - plot.minX) / plot.width) * duration)))
            })
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1) }
    }

    private func draw(_ ctx: inout GraphicsContext, plot: CGRect, laneHeight: CGFloat) {
        guard duration > 0 else { return }
        func x(_ t: Double) -> CGFloat { plot.minX + CGFloat(t / duration) * plot.width }

        if let loop {
            ctx.fill(Path(CGRect(x: x(loop.lowerBound), y: 0, width: x(loop.upperBound) - x(loop.lowerBound), height: plot.height)),
                     with: .color(Theme.accent.opacity(0.08)))
        }
        for c in 0..<7 {
            let mid = (CGFloat(c) + 0.5) * laneHeight
            var zero = Path(); zero.move(to: CGPoint(x: plot.minX, y: mid)); zero.addLine(to: CGPoint(x: plot.maxX, y: mid))
            ctx.stroke(zero, with: .color(.black.opacity(0.07)), lineWidth: 1)
        }
        for track in tracks.dropFirst() {
            var line = Path(); line.move(to: CGPoint(x: x(track.start), y: 0)); line.addLine(to: CGPoint(x: x(track.start), y: plot.height))
            ctx.stroke(line, with: .color(.black.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        for channel in MotionChannel.allCases {
            let c = channel.rawValue
            let mid = (CGFloat(c) + 0.5) * laneHeight, half = laneHeight / 2 - 2
            let scale = MotionSpec.slowBelow[c] * 1.2
            var trace = Path(), fill = Path(), started = false
            for track in tracks {
                let rows = track.rows
                guard !rows.isEmpty else { continue }
                let step = (track.end - track.start) / Double(rows.count)
                for (i, row) in rows.enumerated() {
                    let px = x(track.start + (Double(i) + 0.5) * step)
                    // Soft-clip so a whip pan doesn't flatten everything else in its lane.
                    let v = CGFloat(tanh(Double(row[c] / scale)))
                    let point = CGPoint(x: px, y: mid - v * half)
                    if started { trace.addLine(to: point); fill.addLine(to: point) }
                    else { trace.move(to: point); fill.move(to: CGPoint(x: px, y: mid)); fill.addLine(to: point); started = true }
                }
            }
            if started {
                fill.addLine(to: CGPoint(x: trace.currentPoint?.x ?? plot.maxX, y: mid)); fill.closeSubpath()
                ctx.fill(fill, with: .color(Theme.colour(channel).opacity(0.13)))
                ctx.stroke(trace, with: .color(Theme.colour(channel)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            }
        }

        var playhead = Path(); playhead.move(to: CGPoint(x: x(min(time, duration)), y: 0)); playhead.addLine(to: CGPoint(x: x(min(time, duration)), y: plot.height))
        ctx.stroke(playhead, with: .color(Theme.textPrimary.opacity(0.8)), lineWidth: 1)
    }
}
