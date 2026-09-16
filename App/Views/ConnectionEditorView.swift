import AppKit
import SwiftUI
import TBMFileKit

/// Add/edit sheet for a saved SFTP connection. Never displays or pre-fills a
/// stored password — editing a connection without retyping the password
/// leaves the Keychain-stored one untouched (see `ConnectionsViewModel.save`).
struct ConnectionEditorView: View {
    @State private var profile: ConnectionProfile
    @State private var password: String = ""
    private let isNew: Bool
    var onSave: (ConnectionProfile, _ newPassword: String?) -> Void
    var onCancel: () -> Void

    init(profile: ConnectionProfile?, onSave: @escaping (ConnectionProfile, String?) -> Void, onCancel: @escaping () -> Void) {
        self._profile = State(initialValue: profile ?? ConnectionProfile(name: "", host: "", username: ""))
        self.isNew = profile == nil
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $profile.name)
                TextField("Host", text: $profile.host)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", value: $profile.port, format: .number.grouping(.never))
                    .frame(width: 80)
                TextField("Username", text: $profile.username)
            }

            Section("Authentication") {
                Picker("Method", selection: $profile.authentication) {
                    ForEach(AuthenticationMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                switch profile.authentication {
                case .password:
                    SecureField(isNew ? "Password" : "Password (leave blank to keep unchanged)", text: $password)
                case .privateKey:
                    HStack {
                        TextField("Private Key Path", text: Binding(
                            get: { profile.privateKeyPath ?? "" },
                            set: { profile.privateKeyPath = $0.isEmpty ? nil : $0 }
                        ))
                        Button("Choose…") { chooseKeyFile() }
                    }
                    Text("Only unencrypted ed25519 keys are supported today — see DEPENDENCIES.md.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Options") {
                TextField("Remote Starting Directory", text: $profile.defaultRemotePath)
                Stepper("Connection Timeout: \(profile.timeoutSeconds)s", value: $profile.timeoutSeconds, in: 5...120, step: 5)
                Toggle("Keep Connection Alive", isOn: $profile.keepAlive)
                Toggle("Favorite", isOn: $profile.isFavorite)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isNew ? "Add" : "Save") {
                    onSave(profile, password.isEmpty ? nil : password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty || profile.host.trimmingCharacters(in: .whitespaces).isEmpty || profile.username.isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            profile.privateKeyPath = url.path
        }
    }
}
