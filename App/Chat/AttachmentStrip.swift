import SwiftUI
import UIKit
import ZCodeAppCore

/// Vignettes des pièces jointes du prochain message : progression, échec (toucher pour réessayer), retrait.
struct AttachmentStrip: View {
    let conversation: ConversationModel
    @Environment(\.openImageGallery) private var openGallery

    var body: some View {
        if !conversation.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(conversation.attachments.enumerated()), id: \.element.id) { index, item in
                        tile(item)
                            .onTapGesture {
                                if let gallery = ImageGallery.composer(conversation.attachments, tapped: item.id) {
                                    openGallery.open(gallery)
                                }
                            }
                            .accessibilityAddTraits(item.mime.lowercased().hasPrefix("image/") ? .isButton : [])
                            .accessibilityHint(item.mime.lowercased().hasPrefix("image/") ? "Afficher en plein écran" : "")
                            .accessibilityIdentifier("composer-attachment-\(index)")
                            .overlay(alignment: .topTrailing) {
                                Button { conversation.removeAttachment(item.id) } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .accessibilityLabel("Retirer \(item.fileName)")
                                .accessibilityIdentifier("composer-attachment-remove-\(index)")
                                .offset(x: 6, y: -6)
                            }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private func tile(_ item: ComposerAttachment) -> some View {
        ZStack {
            if let data = item.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                VStack(spacing: 2) {
                    Image(systemName: "doc").font(.title3)
                    Text(item.fileName).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }
                .padding(4)
            }
            switch item.state {
            case .uploading:
                Color.black.opacity(0.3)
                ProgressView().tint(.white)
            case .failed(let message):
                Button { conversation.retryAttachment(item.id) } label: {
                    ZStack {
                        Color.black.opacity(0.4)
                        Image(systemName: "arrow.clockwise.circle.fill").font(.title2).foregroundStyle(.white)
                    }
                }
                .accessibilityLabel("Réessayer : \(message)")
            case .ready:
                EmptyView()
            }
        }
        .frame(width: 56, height: 56)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
