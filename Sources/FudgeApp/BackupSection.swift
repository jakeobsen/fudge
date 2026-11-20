import AppKit
import FudgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Import / Export on the General page: which sheet shows, and the work (`Backup`, `BackupArchive`) off the main
/// thread. Passwords are passed straight through and never kept.
@MainActor
@Observable
final class BackupController {
    enum Sheet: Identifiable {
        case exportPassword
        case working(String)
        case exported(Backup.Summary, leftOut: [String], skipped: Int, file: String)
        case importPassword(URL, error: String?)
        case importSummary(URL, Backup.Contents)
        case imported(Backup.ImportResult)
        case failed(String)

        /// One id for every step, so the sheet changes in place instead of closing and opening again.
        var id: Int { 0 }
    }

    var sheet: Sheet?
    @ObservationIgnored private let paths: FudgePaths
    @ObservationIgnored private weak var settings: SettingsModel?

    init(paths: FudgePaths, settings: SettingsModel) {
        self.paths = paths
        self.settings = settings
    }

    /// `.fudgebackup`, declared in the app's Info.plist.
    static let fileType = UTType(filenameExtension: "fudgebackup", conformingTo: .data) ?? .data

    private static var fudgeVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? FudgeVersion.current
    }

    private var installed: [InstalledExtension] { InstalledExtension.all(in: paths.extensionsDirectory) }

    // MARK: Export

    func startExport() {
        sheet = .exportPassword
    }

    /// After the password sheet: where to save, then the encrypted file, written off the main thread.
    func export(password: String) {
        sheet = nil
        // The save panel opens once the sheet has gone.
        DispatchQueue.main.async { [self] in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.fileType]
            // The local date: ISO 8601 formatting would use GMT, and name the file yesterday after local midnight.
            let day = Date().formatted(
                .verbatim(
                    "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)", timeZone: .current,
                    calendar: .current))
            panel.nameFieldStringValue = "fudge-backup-\(day).fudgebackup"
            panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let file = panel.url else { return }
            sheet = .working("Encrypting the backup…")
            let (paths, installed, version) = (paths, installed, Self.fudgeVersion)
            Task {
                let result = await Task.detached { () -> Result<Backup.Export, Error> in
                    let export = Backup.collect(from: paths, installed: installed, fudgeVersion: version, now: Date())
                    return Result { try BackupArchive.write(export.entries, to: file, password: password) }
                        .map { export }
                }.value
                switch result {
                case .success(let export):
                    sheet = .exported(
                        export.summary, leftOut: export.leftOut, skipped: export.skipped, file: file.lastPathComponent)
                case .failure(let error):
                    sheet = .failed(Self.message(error))
                }
            }
        }
    }

    // MARK: Import

    func startImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        // A before-import backup isn't encrypted, so it takes no password.
        if BackupArchive.isEncrypted(file) {
            sheet = .importPassword(file, error: nil)
        } else {
            open(file, password: nil)
        }
    }

    /// Decrypts and checks the backup, writing nothing, then shows what's in it.
    func open(_ file: URL, password: String?) {
        sheet = .working("Opening the backup…")
        Task {
            let paths = paths
            let result = await Task.detached { Result { try Backup.open(file, password: password, paths: paths) } }
                .value
            switch result {
            case .success(let contents): sheet = .importSummary(file, contents)
            case .failure(BackupError.wrongPassword):
                sheet = .importPassword(file, error: BackupError.wrongPassword.description)
            case .failure(let error): sheet = .failed(Self.message(error))
            }
        }
    }

    /// After the summary's Import: the before-import backup, the parts, then everything is read again.
    func confirmImport(_ contents: Backup.Contents) {
        sheet = .working("Importing…")
        let (paths, installed, version) = (paths, installed, Self.fudgeVersion)
        Task {
            let result = await Task.detached {
                Result {
                    try Backup.apply(contents, to: paths, installed: installed, fudgeVersion: version, now: Date())
                }
            }.value
            switch result {
            case .success(let imported):
                settings?.imported()
                settings?.reload()
                sheet = .imported(imported)
            case .failure(let error):
                sheet = .failed(Self.message(error))
            }
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? BackupError)?.description ?? error.localizedDescription
    }
}

/// The Import / Export row at the bottom of General, as in Raycast.
struct BackupSection: View {
    let model: SettingsModel

    var body: some View {
        let backup = model.backup
        Section("Import / Export") {
            LabeledContent {
                HStack {
                    Button("Import…") { backup.startImport() }
                    Button("Export…") { backup.startExport() }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(
                        "Exporting backs up your settings, hotkeys, aliases, extension preferences, extension data "
                            + "and the list of installed extensions, in one password-protected file.")
                    Image(systemName: "info.circle")
                        .foregroundStyle(.tertiary)
                        .help(
                            "Extensions themselves aren't in the backup, only the list. Reinstall them after "
                                + "importing; the import lists them.")
                }
            }
        }
        .sheet(item: Binding(get: { backup.sheet }, set: { backup.sheet = $0 })) { sheet in
            BackupSheet(controller: backup, sheet: sheet)
        }
    }
}

/// Each step's sheet.
struct BackupSheet: View {
    let controller: BackupController
    let sheet: BackupController.Sheet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch sheet {
            case .exportPassword:
                ExportPasswordStep(controller: controller)
            case .working(let text):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(text)
                }
                .frame(minHeight: 60)
            case .exported(let summary, let leftOut, let skipped, let file):
                Text("Backup exported").font(.headline)
                Text("\(file): \(summary.text).")
                if !leftOut.isEmpty {
                    Text(
                        "Left out to keep extension data under 100 MB: \(leftOut.formatted(.list(type: .and))). Their "
                            + "settings and preferences are in it."
                    )
                    .foregroundStyle(.secondary)
                }
                if skipped > 0 {
                    Text(
                        "\(skipped) \(skipped == 1 ? "item that isn't a regular file" : "items that aren't regular files") "
                            + "in Fudge's folder (links, or files outside it) \(skipped == 1 ? "was" : "were") skipped."
                    )
                    .foregroundStyle(.secondary)
                }
                buttons { Button("Done") { controller.sheet = nil }.keyboardShortcut(.defaultAction) }
            case .importPassword(let file, let error):
                ImportPasswordStep(controller: controller, file: file, error: error)
            case .importSummary(_, let contents):
                ImportSummaryStep(controller: controller, contents: contents)
            case .imported(let result):
                ImportedStep(controller: controller, result: result)
            case .failed(let message):
                Text("Import / Export").font(.headline)
                Text(message)
                buttons { Button("OK") { controller.sheet = nil }.keyboardShortcut(.defaultAction) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 420, alignment: .leading)
        .padding(20)
    }
}

/// The trailing row of buttons in a sheet.
@ViewBuilder
func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack {
        Spacer()
        content()
    }
}

/// Export, step 1: a password, twice, at least 8 characters.
private struct ExportPasswordStep: View {
    let controller: BackupController
    @State private var password = ""
    @State private var repeated = ""

    var body: some View {
        let short = password.count < BackupArchive.minimumPasswordLength
        let mismatch = !repeated.isEmpty && repeated != password
        Text("Export a backup").font(.headline)
        Text(
            "The backup holds your extensions' passwords and tokens, so it's protected with a password. You need it "
                + "to import the backup, and Fudge can't recover it.")
        SecureField("Password (at least \(BackupArchive.minimumPasswordLength) characters)", text: $password)
        SecureField("Repeat the password", text: $repeated)
        if mismatch {
            Text("The passwords don't match.").foregroundStyle(.red).font(.callout)
        }
        buttons {
            Button("Cancel", role: .cancel) { controller.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Continue…") {
                let chosen = password
                password = ""
                repeated = ""
                controller.export(password: chosen)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(short || repeated != password)
        }
    }
}

/// Import, step 2: the backup's password, again after a wrong one.
private struct ImportPasswordStep: View {
    let controller: BackupController
    let file: URL
    let error: String?
    @State private var password = ""

    var body: some View {
        Text("Enter the backup's password").font(.headline)
        Text(file.lastPathComponent).foregroundStyle(.secondary)
        SecureField("Password", text: $password)
        if let error {
            Text(error).foregroundStyle(.red).font(.callout)
        }
        buttons {
            Button("Cancel", role: .cancel) { controller.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Open") {
                let entered = password
                password = ""
                controller.open(file, password: entered)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(password.isEmpty)
        }
    }
}

/// Import, step 3: what's in the backup, and what importing replaces.
struct ImportSummaryStep: View {
    let controller: BackupController
    let contents: Backup.Contents

    var body: some View {
        Text("Import this backup?").font(.headline)
        Text(
            "Made on \(contents.manifest.created.formatted(date: .long, time: .shortened)) by Fudge "
                + "\(contents.manifest.fudgeVersion).")
        Text("\(contents.summary.text).")
        if contents.hadExtensionStore {
            Text("This backup had the Extension Store on. Turn it on in General if you want it.")
                .foregroundStyle(.secondary)
        }
        Text("Importing replaces your current settings and the data of the extensions in the backup.")
            .foregroundStyle(.secondary)
        buttons {
            Button("Cancel", role: .cancel) { controller.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Import", role: .destructive) { controller.confirmImport(contents) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
    }
}

/// Import, the end: the extensions to reinstall, and where the previous state is.
private struct ImportedStep: View {
    let controller: BackupController
    let result: Backup.ImportResult

    var body: some View {
        Text("Backup imported").font(.headline)
        if result.notInstalled.isEmpty {
            Text("Every extension in the backup is installed.")
        } else {
            Text("These extensions in the backup aren't installed. Reinstall them to use them:")
            ForEach(result.notInstalled, id: \.name) { listed in
                HStack(alignment: .firstTextBaseline) {
                    Text(listed.title)
                    Text(listed.source == .store ? "from the Extension Store" : "built from a local folder")
                        .foregroundStyle(.secondary)
                }
            }
        }
        if result.hadExtensionStore {
            Text("This backup had the Extension Store on. Turn it on in General if you want it.")
                .foregroundStyle(.secondary)
        }
        Text("Your settings from before the import are saved in \(result.beforeImport.lastPathComponent).")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        buttons { Button("Done") { controller.sheet = nil }.keyboardShortcut(.defaultAction) }
    }
}
