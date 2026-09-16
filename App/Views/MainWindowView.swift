import SwiftUI

struct MainWindowView: View {
    @Environment(AppViewModel.self) private var appModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            VStack(spacing: 0) {
                HSplitView {
                    PaneView(pane: appModel.leftPane)
                        .frame(minWidth: 320)
                    PaneView(pane: appModel.rightPane)
                        .frame(minWidth: 320)
                }
                Divider()
                StatusBarView()
            }
        }
        .onAppear {
            appModel.leftPane.isFocused = true
        }
        .onChange(of: appModel.focusedPaneID) {
            appModel.leftPane.isFocused = appModel.focusedPaneID == appModel.leftPane.id
            appModel.rightPane.isFocused = appModel.focusedPaneID == appModel.rightPane.id
        }
        .alert(
            hostKeyAlertTitle,
            isPresented: Binding(
                get: { appModel.hostKeyConfirmation.pendingRequest != nil },
                set: { if !$0 { appModel.hostKeyConfirmation.respond(trusted: false) } }
            ),
            presenting: appModel.hostKeyConfirmation.pendingRequest
        ) { request in
            Button("Cancel", role: .cancel) { appModel.hostKeyConfirmation.respond(trusted: false) }
            Button(request.isChanged ? "Trust Anyway" : "Trust & Connect", role: request.isChanged ? .destructive : nil) {
                appModel.hostKeyConfirmation.respond(trusted: true)
            }
        } message: { request in
            Text(hostKeyAlertMessage(for: request))
        }
        .sheet(item: Binding(
            get: { appModel.transferCollisionCenter.pendingRequest },
            set: { if $0 == nil { appModel.transferCollisionCenter.respond(.cancel, applyToAll: false) } }
        )) { request in
            CollisionSheet(request: request) { resolution, applyToAll in
                appModel.transferCollisionCenter.respond(resolution, applyToAll: applyToAll)
            }
        }
    }

    private var hostKeyAlertTitle: String {
        appModel.hostKeyConfirmation.pendingRequest?.isChanged == true
            ? "⚠️ Host Key Changed"
            : "Verify Server Identity"
    }

    private func hostKeyAlertMessage(for request: HostKeyConfirmationRequest) -> String {
        if request.isChanged {
            return "The identity of \(request.host):\(request.port) has changed since you last connected — this could mean the server was reinstalled, or that someone is intercepting the connection.\n\nNew fingerprint:\n\(request.fingerprint)\n\nOnly continue if you're sure this is expected."
        }
        return "You're connecting to \(request.host):\(request.port) for the first time. Verify this fingerprint matches what your server admin (or `ssh-keygen -lf`) shows:\n\n\(request.fingerprint)"
    }
}
