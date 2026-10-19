import SwiftUI
import ZCodeAppCore

/// Panneau « / » au-dessus du champ : commandes de l'hôte, skills, sous-agents (règles de ZCode Web).
struct SlashPanel: View {
    let sections: [SlashSection]
    let loading: Bool
    let pick: (SlashEntry) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Commandes, skills et sous-agents")
                    .font(ZCodeTypography.metadata)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fermer", action: close)
                    .font(ZCodeTypography.metadata)
                    .accessibilityIdentifier("slash-close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        Text(loading ? "Chargement…" : "Aucune correspondance.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(ZCodeTypography.smallHeading)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        ForEach(section.entries) { entry in
                            Button { pick(entry) } label: { row(entry) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("slash-row-\(entry.kind.rawValue)-\(entry.name)")
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slash-panel")
    }

    private func row(_ entry: SlashEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.insertion).font(ZCodeTypography.code)
                if let hint = entry.hint {
                    Text(hint).font(ZCodeTypography.monoCaption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !entry.detail.isEmpty {
                Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
