import ImageIO
import SwiftUI
import UIKit
import ZCodeAppCore

/// Ouvre la visionneuse plein écran ; fourni par l'écran de la conversation. Toujours égal à lui-même (comme
/// `AttachmentLoader`) : passer par l'environnement n'invalide aucune cellule.
struct ImageGalleryOpener: Sendable, Equatable {
    var open: @MainActor @Sendable (ImageGallery) -> Void = { _ in }

    static func == (lhs: ImageGalleryOpener, rhs: ImageGalleryOpener) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var openImageGallery = ImageGalleryOpener()
}

enum ImageDecoding {
    /// Image réduite à `maxPixelSize` dès la lecture (orientation EXIF appliquée) : l'originale ne reste pas décodée en
    /// mémoire. Hors de l'acteur principal.
    nonisolated static func downsampled(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Images d'un message en plein écran : défilement entre elles, zoom (pincement, double toucher), partage, glisser
/// vers le bas pour fermer.
struct ImageViewer: View {
    let gallery: ImageGallery
    let loader: AttachmentLoader
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String
    @State private var loaded: [String: UIImage] = [:]
    @State private var hostLoaded: Set<String> = []                    // lues sur l'hôte (version finale)
    @State private var failed: Set<String> = []
    @State private var zoomed = false
    @State private var drag: CGFloat = 0

    init(gallery: ImageGallery, loader: AttachmentLoader) {
        self.gallery = gallery
        self.loader = loader
        _selection = State(initialValue: gallery.images[gallery.startIndex].id)
    }

    private var current: GalleryImage? { gallery.images.first { $0.id == selection } }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.6, drag / 400)).ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(gallery.images) { image in
                    page(image).tag(image.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: gallery.images.count > 1 ? .always : .never))
            .offset(y: drag)
            .simultaneousGesture(dismissGesture)
        }
        .overlay(alignment: .top) { toolbar }
        .statusBarHidden()
        .onChange(of: selection) { zoomed = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("image-viewer")
    }

    @ViewBuilder private func page(_ image: GalleryImage) -> some View {
        Group {
            if let picture = loaded[image.id] {
                ZoomableImage(image: picture) { zoomed = $0 }
                    .accessibilityLabel(image.fileName)
            } else if failed.contains(image.id) {
                ContentUnavailableView("Image indisponible", systemImage: "photo")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: image.id) { await load(image) }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Fermer")
            .accessibilityIdentifier("image-viewer-close")
            Spacer(minLength: 0)
            if let current {
                Text(current.fileName).font(.footnote).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            // Jamais la vignette de 240 px tant que l'image de l'hôte est attendue (sans `ref`, la vignette est tout ce qu'il y a).
            if let current, let picture = loaded[current.id], current.ref == nil || hostLoaded.contains(current.id) {
                ShareLink(item: Image(uiImage: picture), preview: SharePreview(current.fileName, image: Image(uiImage: picture))) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3.weight(.semibold))
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Partager")
                .accessibilityIdentifier("image-viewer-share")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
    }

    /// Glisser vers le bas pour fermer, seulement sans zoom (zoomé, le glissé déplace l'image) et si le geste est plus
    /// vertical qu'horizontal (sinon il fait défiler les images).
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !zoomed, value.translation.height > abs(value.translation.width) else { return }
                drag = value.translation.height
            }
            .onEnded { value in
                if !zoomed, ImageGallery.dismisses(horizontal: value.translation.width, vertical: value.translation.height) {
                    dismiss()
                } else {
                    withAnimation(.spring) { drag = 0 }
                }
            }
    }

    /// Vignette locale d'abord (composeur), puis l'image lue sur l'hôte, réduite à 4096 px. Une lecture annulée (page
    /// quittée) n'est pas un échec : elle est relancée au retour sur la page.
    private func load(_ image: GalleryImage) async {
        guard !hostLoaded.contains(image.id) else { return }
        failed.remove(image.id)
        if loaded[image.id] == nil, let thumbnail = image.thumbnail, let picture = UIImage(data: thumbnail) {
            loaded[image.id] = picture
        }
        if let ref = image.ref, let data = await loader.load(ref),
           let picture = await Task.detached(priority: .userInitiated, operation: {
               ImageDecoding.downsampled(data, maxPixelSize: 4096)
           }).value {
            loaded[image.id] = picture
            hostLoaded.insert(image.id)
        }
        if loaded[image.id] == nil, !Task.isCancelled { failed.insert(image.id) }
    }
}

/// Zoom d'UIKit : pincement (×1 à ×5), double toucher (×2,5 au point touché, ou retour à ×1).
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onZoomChange: onZoomChange) }

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.minimumZoomScale = 1
        view.maximumZoomScale = 5
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.delegate = context.coordinator
        view.imageView.image = image
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        context.coordinator.onZoomChange = onZoomChange
        if view.imageView.image !== image {
            view.imageView.image = image                                // l'image lue remplace la vignette
            // Remise à ×1 sans rappel synchrone : l'état SwiftUI ne s'écrit pas pendant une mise à jour de vue.
            context.coordinator.silenced = true
            view.setZoomScale(1, animated: false)
            context.coordinator.silenced = false
            let notify = onZoomChange
            Task { @MainActor in notify(false) }
        }
    }

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        var onZoomChange: (Bool) -> Void
        /// Vrai pendant une remise à ×1 déclenchée par `updateUIView`.
        var silenced = false

        init(onZoomChange: @escaping (Bool) -> Void) {
            self.onZoomChange = onZoomChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomingScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !silenced else { return }
            onZoomChange(scrollView.zoomScale > 1.01)
        }

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ZoomingScrollView else { return }
            if view.zoomScale > 1.01 {
                view.setZoomScale(1, animated: true)
                return
            }
            let point = gesture.location(in: view.imageView)
            let size = CGSize(width: view.bounds.width / 2.5, height: view.bounds.height / 2.5)
            view.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size),
                      animated: true)
        }
    }
}

/// Image ajustée à l'écran tant qu'elle n'est pas zoomée.
final class ZoomingScrollView: UIScrollView {
    let imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) non pris en charge")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale <= minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
        }
    }
}
