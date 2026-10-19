import SwiftUI
import ZCodeAppCore

struct HostEditorView: View {
    enum Mode: Identifiable {
        case add
        case edit(Host)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let host): host.id.uuidString
            }
        }
    }

    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?

    private var isEditing: Bool {
        if case .edit = mode { true } else { false }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Serveur") {
                    TextField("Nom (ex. MacBook Pro)", text: $name)
                    TextField("https://machine.tailnet.ts.net", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    SecureField(isEditing ? "Inchangé si vide" : "Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Token")
                } footer: {
                    Text("Le token donne un accès complet à l'hôte : il reste dans le Trousseau de cet iPhone.")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Modifier l'hôte" : "Nouvel hôte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }
                }
            }
            .onAppear {
                if case .edit(let host) = mode {
                    name = host.name
                    url = host.baseURL.absoluteString
                }
            }
        }
    }

    private func save() {
        do {
            switch mode {
            case .add:
                try model.hostStore.add(name: name, url: url, token: token)
            case .edit(let host):
                try model.hostStore.update(host.id, name: name, url: url, token: token)
                Task { await model.hostDidChange(host.id) }
            }
            dismiss()
        } catch let validation as HostValidationError {
            error = validation.message
        } catch {
            self.error = "Enregistrement impossible : \(error.localizedDescription)"
        }
    }
}
