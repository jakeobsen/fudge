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
            Section {
                OwnAppSignInControls(model: model)
                RaycastLinksRow(model: model)
            }
            Section("Signed in") {
                if model.signIns.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.signIns) { entry in
                        HStack(spacing: 12) {
                            Text(entry.extensionID.flatMap(model.extensionTitle) ?? entry.extensionKey)
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
        .onAppear {
            model.loadSignIns()
            model.refreshRaycastLinks()
        }
        .overlay {
            // A snapshot run shows Show All's list here, over the page, since it never opens a popover
            // (`--sign-in-services-list`).
            if let names = model.snapshotServicesList, SignInServices.showsAll(names: names) {
                ZStack {
                    Color.black.opacity(0.15)
                    SignInServicesList(names: names)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .shadow(radius: 12)
                }
            }
        }
    }
}

/// **Extensions with their own sign-in** (SPEC-132 §5): its switch, with the line its consent sheet and onboarding
/// show. Turning it on shows the sheet first, on the Settings window or where `ask` puts it.
struct OwnAppSignInControls: View {
    @Bindable var model: SettingsModel
    var ask: ((LauncherModel.AlertRequest) async -> Bool)? = nil

    var body: some View {
        Toggle(isOn: Binding(get: { model.ownAppSignIn }, set: { model.setOwnAppSignIn($0, ask: ask) })) {
            Text(OwnAppSignIn.title)
            Text(OwnAppSignIn.explanation)
        }
    }
}

/// **Fudge opens Raycast links** (SPEC-140, D-114): a switch that shows who opens them, read from LaunchServices, never
/// stored. On registers Fudge Links and makes it the opener; off gives them back to the other app that claims them, and
/// can't be switched off while there's none.
struct RaycastLinksRow: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let toggle = model.raycastLinksToggle
        Toggle(isOn: Binding(get: { toggle.isOn }, set: { model.setRaycastLinks($0) })) {
            Text(RaycastLinksToggle.title)
            Text(RaycastLinksToggle.explanation)
            Text(toggle.note)
        }
        .disabled(!toggle.canChange)
        if let problem = model.raycastLinksProblem {
            Text(problem).font(.system(size: 11)).foregroundStyle(.red)
        }
    }
}

/// The sign-in server's choice: Off, Fudge's sign-in server, or Your own server… with its address, saved on ↵ when
/// it's valid, and why it wasn't. The Sign-in page's and onboarding's Sign-in step's, so both choose through the same
/// code and the same consent sheet; `ask` puts the sheets on onboarding's window instead of the Settings window.
/// The line under it names the services the server on screen offers, once it answers (SPEC-149): up to five, else
/// their number and **Show All**, whose popover lists them (SPEC-155). A popover anchors to the button in whichever
/// window it's in, so the Settings window and onboarding's both get it without `ask`.
struct SignInServerControls: View {
    @Bindable var model: SettingsModel
    var ask: ((LauncherModel.AlertRequest) async -> Bool)? = nil
    /// "Your own server…" was picked, and its address isn't saved yet.
    @State private var editingAddress = false
    @State private var address = ""
    @State private var services = SignInServicesLine()
    @State private var showingAll = false

    private enum Choice: Hashable { case off, fudge, own }

    private var choice: Choice {
        if editingAddress { return .own }
        switch model.signInServer {
        case .off: return .off
        case .fudge: return .fudge
        case .custom: return .own
        }
    }

    /// The server the line is for: none while an address of your own is typed and not saved.
    private var serverOnScreen: SignInServer? {
        SignInServices.serverOnScreen(saved: model.signInServer, ownChosen: choice == .own, typedAddress: address)
    }

    var body: some View {
        Picker(selection: Binding(get: { choice }, set: { pick($0) })) {
            Text("Off").tag(Choice.off)
            Text("Fudge's sign-in server").tag(Choice.fudge)
            Text("Your own server…").tag(Choice.own)
        } label: {
            Text("Sign-in server")
            if services.showsAll {
                HStack(spacing: 6) {
                    Text(services.text)
                    Button(SignInServices.showAllTitle) { showingAll = true }
                        .controlSize(.small)
                        .popover(isPresented: $showingAll, arrowEdge: .bottom) {
                            SignInServicesList(names: services.names)
                        }
                }
            } else {
                Text(services.text)
            }
        }
        // Asks on appearing and on every change of the server on screen; a change cancels the request before it.
        .task(id: serverOnScreen) {
            await services.load(serverOnScreen, using: model.signInServicesFetcher)
        }
        // The button goes when the server on screen changes, and its popover with it.
        .onChange(of: services.showsAll) { _, shows in
            if !shows { showingAll = false }
        }
        .onChange(of: services.names) { _, names in
            if model.snapshotServicesList != nil { model.snapshotServicesList = names }
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

/// Show All's list: every name the server on screen offers, one per row, in the server's order, under a heading.
/// Past 330 points it scrolls, and the last row it shows is cut partway, which hints that there's more. Esc or a click
/// outside closes the popover.
struct SignInServicesList: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SignInServices.listTitle).font(.headline)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        Text(name)
                    }
                }
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 330)
        }
        .padding(14)
        .fixedSize()
    }
}
