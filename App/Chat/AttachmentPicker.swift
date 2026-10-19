import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZCodeAppCore

/// Bouton « + » du composeur : photothèque, appareil photo, Fichiers, presse-papiers, prompts favoris.
struct AttachmentPicker: View {
    let conversation: ConversationModel
    @Binding var draft: String
    @Environment(AppModel.self) private var model
    @State private var showingPhotos = false
    @State private var showingCamera = false
    @State private var showingFiles = false
    @State private var photos: [PhotosPickerItem] = []
    /// Éléments qui n'ont pas pu être ajoutés (illisibles) : signalés une fois le lot traité.
    @State private var failures: [String] = []
    @State private var showingFavorites = false
    @State private var showingSave = false
    @State private var saveTitle = ""

    private var remaining: Int { ConversationModel.maxAttachments - conversation.attachments.count }

    var body: some View {
        Menu {
            Section {
                Button { showingPhotos = true } label: { Label("Photothèque", systemImage: "photo.on.rectangle") }
                    .disabled(remaining <= 0)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showingCamera = true } label: { Label("Appareil photo", systemImage: "camera") }
                        .disabled(remaining <= 0)
                }
                Button { showingFiles = true } label: { Label("Fichiers", systemImage: "folder") }
                    .disabled(remaining <= 0)
                if UIPasteboard.general.hasImages {
                    Button { pasteImage() } label: { Label("Coller l'image", systemImage: "doc.on.clipboard") }
                        .disabled(remaining <= 0)
                }
            }
            Section("Prompts favoris") {
                ForEach(Array(model.promptStore.favorites.enumerated()), id: \.element.id) { index, favorite in
                    Button(favorite.title) { draft = PromptStore.inserting(favorite.text, into: draft) }
                        .accessibilityIdentifier("prompt-favorite-\(index)")
                }
                Button {
                    saveTitle = PromptStore.defaultTitle(for: draft)
                    showingSave = true
                } label: {
                    Label("Enregistrer le brouillon comme favori", systemImage: "star")
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("prompt-save-favorite")
                Button { showingFavorites = true } label: { Label("Gérer les favoris…", systemImage: "list.star") }
                    .accessibilityIdentifier("prompt-favorites")
            }
        } label: {
            Image(systemName: "plus.circle.fill").font(.title)
        }
        .disabled(conversation.routing == "reject")
        .accessibilityLabel("Joindre un fichier ou insérer un favori")
        .accessibilityIdentifier("composer-attach")
        .photosPicker(isPresented: $showingPhotos, selection: $photos, maxSelectionCount: max(remaining, 1),
                      matching: .images)
        .onChange(of: photos) { Task { await addPhotos() } }
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addFiles(urls) }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                Task { await addImage(image, label: "Photo", png: false) }
            }
            .ignoresSafeArea()
        }
        .alert("Pièce jointe non ajoutée", isPresented: Binding(get: { !failures.isEmpty }, set: { if !$0 { failures = [] } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failures.map { "Impossible d'ajouter « \($0) »." }.joined(separator: "\n"))
        }
        .sheet(isPresented: $showingFavorites) {
            PromptFavoritesView(store: model.promptStore) { draft = PromptStore.inserting($0, into: draft) }
        }
        .alert("Enregistrer comme favori", isPresented: $showingSave) {
            TextField("Titre", text: $saveTitle)
            Button("Enregistrer") { model.promptStore.add(title: saveTitle, text: draft) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Le brouillon devient un prompt favori sur cet iPhone, pour tous les hôtes.")
        }
    }

    /// Un élément après l'autre : l'ordre des vignettes est celui de la sélection ; le travail lourd est hors du fil principal.
    private func addPhotos() async {
        let items = photos
        photos = []
        var failed: [String] = []
        for (index, item) in items.enumerated() {
            let name = AttachmentImages.generatedName("Image", index: index, ext: "jpg")
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let prepared = await AttachmentImages.prepareOffMain(data, fileName: name) else { failed.append(name); continue }
            add(prepared)
        }
        failures.append(contentsOf: failed)
    }

    private func addFiles(_ urls: [URL]) {
        Task {
            var failed: [String] = []
            for url in urls {
                guard let prepared = await AttachmentImages.prepareFile(at: url) else { failed.append(url.lastPathComponent); continue }
                add(prepared)
            }
            failures.append(contentsOf: failed)
        }
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image else { return }
        Task { await addImage(image, label: "Image collée", png: true) }
    }

    private func addImage(_ image: UIImage, label: String, png: Bool) async {
        let name = AttachmentImages.generatedName(label, index: 0, ext: png ? "png" : "jpg")
        guard let prepared = await AttachmentImages.prepare(image: image, fileName: name, png: png) else {
            failures.append(name)
            return
        }
        add(prepared)
    }

    private func add(_ prepared: PreparedAttachment) {
        conversation.attach(data: prepared.data, fileName: prepared.fileName, mime: prepared.mime,
                            thumbnail: prepared.thumbnail)
    }
}

/// Appareil photo système (pas d'équivalent SwiftUI).
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
