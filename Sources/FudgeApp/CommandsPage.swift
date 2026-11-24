import AppKit
import Carbon.HIToolbox
import FudgeCore
import SwiftUI

/// The Settings window's Commands page: Fudge's own command groups, then the quicklinks, then every installed
/// extension, each expanded to its commands, with each command's alias, hotkey and enabled state. Clicking "Record
/// Hotkey" records the next key press.
struct CommandsPage: View {
    @Bindable var model: SettingsModel
    @State private var search = ""
    @State private var collapsed: Set<CommandOwner> = []

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }
            TextField("Search Commands", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Type").frame(width: 80, alignment: .leading)
                Text("Alias").frame(width: 110, alignment: .leading)
                Text("Hotkey").frame(width: 150, alignment: .leading)
                Text("Enabled").frame(width: 60, alignment: .center)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.owner) { row in
                        groupRow(row)
                        if !collapsed.contains(row.owner) {
                            // By the command's whole id: a lazy stack keeps one row per id across every group, and
                            // two extensions of one name have commands of the same names.
                            ForEach(row.commands, id: \.id) { command in
                                commandRow(command, of: row)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { if let start = model.commandsSearch { search = start } }
    }

    /// The rows, as far as they match the search (`CommandsPageRows`).
    private var rows: [CommandsPageRows.Group] {
        CommandsPageRows.rows(
            groups: model.commandGroups, extensions: model.allExtensions, titles: model.extensionTitles, search: search)
    }

    private func groupRow(_ row: CommandsPageRows.Group) -> some View {
        let name = row.owner
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: collapsed.contains(name) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                iconView(row.icon)
                Text(row.title).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.type).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text("--").foregroundStyle(.tertiary).frame(width: 110, alignment: .leading)
            Text("--").foregroundStyle(.tertiary).frame(width: 150, alignment: .leading)
            Toggle(
                "",
                isOn: Binding(get: { model.isEnabled(owner: name) }, set: { model.setEnabled($0, owner: name) })
            )
            .labelsHidden()
            .accessibilityLabel("Enabled, \(row.title)")
            .frame(width: 60)
        }
        .opacity(model.isEnabled(owner: name) ? 1 : 0.45)
        .rowStyle()
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        }
    }

    private func commandRow(_ command: CommandsPageRows.Command, of row: CommandsPageRows.Group) -> some View {
        let id = command.id
        let enabled = model.isEnabled(command: id) && model.isEnabled(owner: row.owner)
        let reason = model.offByDefaultReason(command: id)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                iconView(command.icon)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        // The extension's name gives way first when the column is narrow.
                        Text(command.title).layoutPriority(1)
                        Text(row.title).foregroundStyle(.secondary)
                    }
                    if let reason {
                        // Why it's off until turned on (SPEC-109), on a line of its own so it's read whole.
                        Text(reason).font(.caption).foregroundStyle(.secondary).help(reason)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .lineLimit(1)
            .padding(.leading, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(command.type).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            AliasCell(model: model, commandID: id, dimmed: !enabled).frame(width: 110, alignment: .leading)
            HotkeyCell(model: model, commandID: id).frame(width: 150, alignment: .leading)
            Toggle(
                "", isOn: Binding(get: { model.isEnabled(command: id) }, set: { model.setEnabled($0, command: id) })
            )
            .labelsHidden()
            .accessibilityLabel("Enabled, \(command.title)")
            .frame(width: 60)
        }
        // A disabled command, or one of a disabled extension, is dimmed.
        .opacity(enabled ? 1 : 0.45)
        .rowStyle()
    }

    private func iconView(_ icon: CommandsPageRows.Icon) -> some View {
        let placeholder = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
        let image =
            switch icon {
            case .app:
                NSApp.applicationIconImage!
            case .symbol(let name):
                NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? placeholder
            case .asset(let file, let installed):
                file.map { installed.assetsDirectory.appendingPathComponent($0) }.flatMap(NSImage.init(contentsOf:))
                    ?? placeholder
            }
        return Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
    }
}

extension View {
    fileprivate func rowStyle() -> some View {
        font(.system(size: 13)).padding(.horizontal, 16).frame(minHeight: 30)
    }
}

/// A command's alias, edited in place: ↵ saves, Esc cancels, and empty removes it. A refused alias stays in the
/// field with the reason under it.
private struct AliasCell: View {
    let model: SettingsModel
    let commandID: String
    /// A disabled row's alias is dimmed here: the row's opacity doesn't reach the text field's AppKit drawing (seen
    /// in snapshots).
    let dimmed: Bool
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Add Alias", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(dimmed ? .secondary : .primary)
                .focused($editing)
                .onSubmit { model.setAlias(text, for: commandID) }
                .onKeyPress(.escape) {
                    text = model.alias(for: commandID) ?? ""
                    editing = false
                    return .handled
                }
            if let message = model.aliasMessages[commandID] {
                Text(message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .onAppear { text = model.alias(for: commandID) ?? "" }
        // A default alias goes when another command takes it, and comes back when that one lets it go.
        .onChange(of: model.alias(for: commandID)) { _, alias in
            if !editing { text = alias ?? "" }
        }
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
            } else if let note = model.hotkeyNotes[commandID] {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A hotkey as keycaps: `⌥` `S`. Character keys are labelled as the current keyboard layout types them.
struct Keycaps: View {
    let spec: HotKeySpec

    var body: some View {
        KeycapLabels(keys: spec.modifierSymbols + [KeyLayout.label(for: spec)])
    }
}

/// Keys as keycaps, each in its own rounded box: a hotkey's (`Keycaps`), or a menu item's shortcut as Search Menu
/// Items shows it.
struct KeycapLabels: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
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
