import AppKit
import Carbon.HIToolbox
import FudgeCore
import SwiftUI

/// The Settings window's Commands page: every installed extension, expanded to its commands, with each command's
/// hotkey. Clicking "Record Hotkey" records the next key press.
struct CommandsPage: View {
    @Bindable var model: SettingsModel
    @State private var search = ""
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Commands", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Type").frame(width: 90, alignment: .leading)
                Text("Hotkey").frame(width: 170, alignment: .leading)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.installed.manifest.name) { row in
                        extensionRow(row.installed)
                        if !collapsed.contains(row.installed.manifest.name) {
                            ForEach(row.commands, id: \.name) { command in
                                commandRow(command, of: row.installed)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The extensions and commands that match the search; an extension that matches keeps all its commands.
    private var rows: [(installed: InstalledExtension, commands: [ExtensionManifest.Command])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.allExtensions.compactMap { installed in
            let commands = installed.manifest.commands.filter { $0.mode == "view" || $0.mode == "no-view" }
            guard !query.isEmpty else { return (installed, commands) }
            if installed.manifest.title.lowercased().contains(query) { return (installed, commands) }
            let matching = commands.filter { $0.title.lowercased().contains(query) }
            return matching.isEmpty ? nil : (installed, matching)
        }
    }

    private func extensionRow(_ installed: InstalledExtension) -> some View {
        let name = installed.manifest.name
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: collapsed.contains(name) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                icon(installed.manifest.icon, in: installed)
                Text(installed.manifest.title).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Extension").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text("--").foregroundStyle(.tertiary).frame(width: 170, alignment: .leading)
        }
        .rowStyle()
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        }
    }

    private func commandRow(_ command: ExtensionManifest.Command, of installed: InstalledExtension) -> some View {
        let id = FudgeSettings.commandID(extension: installed.manifest.name, command: command.name)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                icon(command.icon ?? installed.manifest.icon, in: installed)
                Text(command.title)
                Text(installed.manifest.title).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.leading, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Command").foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            HotkeyCell(model: model, commandID: id).frame(width: 170, alignment: .leading)
        }
        .rowStyle()
    }

    private func icon(_ file: String?, in installed: InstalledExtension) -> some View {
        let image =
            file.map { installed.assetsDirectory.appendingPathComponent($0) }.flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
        return Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
    }
}

extension View {
    fileprivate func rowStyle() -> some View {
        font(.system(size: 13)).padding(.horizontal, 16).frame(minHeight: 30)
    }
}

/// A command's hotkey: its keycaps, or "Record Hotkey". While recording, it takes the next key press: Esc
/// cancels, ⌫ or ⌦ on its own clears, anything else is recorded (fudge's own hotkeys are suspended meanwhile).
private struct HotkeyCell: View {
    let model: SettingsModel
    let commandID: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.recording == commandID {
                HotkeyRecordingPrompt { [model, commandID] key in
                    switch key {
                    case .cancel: model.cancelRecording()
                    case .clear: model.clearHotkey(commandID)
                    case .record(let spec): model.record(spec, for: commandID)
                    }
                }
            } else if let spec = model.hotkey(for: commandID) {
                HStack(spacing: 4) {
                    Button {
                        model.startRecording(commandID)
                    } label: {
                        Keycaps(spec: spec)
                    }
                    .buttonStyle(.plain)
                    if hovering {
                        Button {
                            model.clearHotkey(commandID)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove Hotkey")
                    }
                }
            } else {
                Button("Record Hotkey") { model.startRecording(commandID) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if let message = model.hotkeyMessages[commandID] {
                Text(message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A hotkey as keycaps: `⌥` `S`. Character keys are labelled as the current keyboard layout types them.
struct Keycaps: View {
    let spec: HotKeySpec

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array((spec.modifierSymbols + [KeyLayout.label(for: spec)]).enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

/// What a key types on the current keyboard layout, with no modifiers.
enum KeyLayout {
    static func label(for spec: HotKeySpec) -> String {
        // Named keys (Space, F5, ←, Keypad 5) keep their names; character keys follow the layout.
        guard spec.key.count == 1, let typed = character(for: UInt16(spec.keyCode)) else { return spec.keyLabel }
        return typed.uppercased()
    }

    static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: length)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }
}
