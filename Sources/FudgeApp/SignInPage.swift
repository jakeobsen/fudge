import FudgeCore
import SwiftUI

/// The Settings window's Sign-in page (SPEC-056): the server extensions sign in through, and the sign-ins Fudge keeps
/// in the Keychain, each with Sign Out.
struct SignInPage: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            if let problem = model.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            Section {
                SignInServerControls(model: model)
            }
            Section("Signed in") {
                if model.signIns.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.signIns) { entry in
                        HStack(spacing: 12) {
                            Text(model.extensionTitle(entry.extensionName) ?? entry.extensionName)
                                .frame(minWidth: 160, alignment: .leading)
                            Text(entry.providerName).foregroundStyle(.secondary)
                                .frame(minWidth: 90, alignment: .leading)
                            if let date = entry.updatedAt {
                                Text(date, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Sign Out") { model.signOut(entry) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadSignIns() }
    }
}

/// The sign-in server's choice: Off, Fudge's sign-in server, or Your own server… with its address, saved on ↵ when
/// it's valid, and why it wasn't. The Sign-in page's and onboarding's Sign-in step's, so both choose through the same
/// code and the same consent sheet; `ask` puts the sheets on onboarding's window instead of the Settings window.
struct SignInServerControls: View {
    @Bindable var model: SettingsModel
    var ask: ((LauncherModel.AlertRequest) async -> Bool)? = nil
    /// "Your own server…" was picked, and its address isn't saved yet.
    @State private var editingAddress = false
    @State private var address = ""

    private enum Choice: Hashable { case off, fudge, own }

    private var choice: Choice {
        if editingAddress { return .own }
        switch model.signInServer {
        case .off: return .off
        case .fudge: return .fudge
        case .custom: return .own
        }
    }

    var body: some View {
        Picker(selection: Binding(get: { choice }, set: { pick($0) })) {
            Text("Off").tag(Choice.off)
            Text("Fudge's sign-in server").tag(Choice.fudge)
            Text("Your own server…").tag(Choice.own)
        } label: {
            Text("Sign-in server")
            Text(SignInServer.explanation)
        }
        .onAppear {
            if case .custom(let url) = model.signInServer { address = url.absoluteString }
        }
        .onChange(of: model.signInServer) { _, server in
            editingAddress = false
            if case .custom(let url) = server { address = url.absoluteString }
        }
        if choice == .own {
            LabeledContent("Server address") {
                TextField("", text: $address, prompt: Text("https://sign-in.example.com"))
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .onSubmit { model.setCustomSignInServer(address, ask: ask) }
            }
        }
        if let problem = model.signInProblem {
            Text(problem).font(.system(size: 11)).foregroundStyle(.red)
        }
    }

    private func pick(_ choice: Choice) {
        switch choice {
        case .off:
            editingAddress = false
            model.setSignInServer(.off, ask: ask)
        case .fudge:
            editingAddress = false
            model.setSignInServer(.fudge, ask: ask)
        case .own:
            if case .custom = model.signInServer { return }
            editingAddress = true
        }
    }
}
