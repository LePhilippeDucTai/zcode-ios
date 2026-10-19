import SwiftUI
import ZCodeAppCore

/// Quota du Coding Plan en tête du composeur : deux anneaux concentriques (5 h à l'extérieur, semaine à l'intérieur)
/// et le restant des 5 h en texte, le restant de la semaine au centre. Un seul anneau si le fournisseur n'a pas de
/// fenêtre hebdomadaire.
struct QuotaRings: View {
    let quota: ComposerQuota

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                ring(quota.fiveHours, diameter: 31)
                if let weekly = quota.weekly {
                    ring(weekly, diameter: 23)
                    Text("\(weekly.percent)")
                        .font(.system(size: 8, weight: .semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .frame(width: 16)
                }
            }
            .frame(width: 34, height: 34)
            Text(quota.text)
                .font(ZCodeTypography.metadata)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.45)))
    }

    private func ring(_ ring: ComposerQuota.Ring, diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: ring.fraction)
                .stroke(color(ring.level), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }

    private func color(_ level: ComposerQuota.Level) -> Color {
        switch level {
        case .normal: .accentColor
        case .low: .orange
        case .critical: .red
        }
    }
}
