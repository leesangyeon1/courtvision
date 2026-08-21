import SwiftUI

/// The engine's view, drawn over a frame: rims (orange, end letter),
/// referees (black), players (A blue / B red / unassigned cyan; #number
/// top-right, action badge bottom-left), ball trail + ball. Shared by the
/// live Record screen and the Replay screen — they differ only in how a
/// normalized box maps to the view (`rect`/`point` closures).
struct MomentOverlay: View {
    let players: [Moment.PlayerState]
    let referees: [CGRect]
    let rims: [String: CGRect]
    let ballTrail: [BallTrack.Sample]
    /// Normalized (top-left origin) → view coordinates.
    let rect: (CGRect) -> CGRect
    let point: (CGPoint) -> CGPoint

    static func color(team: String?) -> Color {
        team == "A" ? .blue : team == "B" ? .red : .cyan
    }

    var body: some View {
        Canvas { context, _ in
            for (end, rim) in rims.sorted(by: { $0.key < $1.key }) {
                let r = rect(rim)
                context.stroke(Path(r), with: .color(.orange), lineWidth: 3)
                context.draw(Text(end).font(.caption.bold()).foregroundStyle(.orange),
                             at: CGPoint(x: r.minX + 2, y: r.minY - 8), anchor: .bottomLeading)
            }
            for (i, sample) in ballTrail.enumerated() {
                let vp = point(sample.point)
                let alpha = 0.25 + 0.75 * Double(i + 1) / Double(ballTrail.count)
                context.fill(Path(ellipseIn: CGRect(x: vp.x - 3, y: vp.y - 3, width: 6, height: 6)),
                             with: .color(.yellow.opacity(alpha)))
            }
            if let current = ballTrail.last {
                context.stroke(Path(ellipseIn: rect(current.box)), with: .color(.yellow), lineWidth: 2)
            }
            for ref in referees {
                context.stroke(Path(rect(ref)), with: .color(.black), lineWidth: 2)
            }
            for player in players {
                let color = Self.color(team: player.team)
                let r = rect(player.box)
                context.stroke(Path(r), with: .color(color), lineWidth: player.missedTicks == 0 ? 2 : 1)
                if let number = player.number {
                    context.draw(Text("#\(number)").font(.caption.bold()).foregroundStyle(color),
                                 at: CGPoint(x: r.maxX - 2, y: r.minY - 8), anchor: .bottomTrailing)
                }
                if player.action != .none {
                    context.draw(Text(player.action.short).font(.caption2.bold()).foregroundStyle(.orange),
                                 at: CGPoint(x: r.minX + 2, y: r.maxY + 2), anchor: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
