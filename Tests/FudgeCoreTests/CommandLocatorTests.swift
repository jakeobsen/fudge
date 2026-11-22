import Foundation
import Testing

@testable import FudgeCore

private func installed(_ json: String) throws -> InstalledExtension {
    let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    return InstalledExtension(manifest: manifest, directory: URL(fileURLWithPath: "/nonexistent/\(manifest.name)"))
}

private func extensions() throws -> [InstalledExtension] {
    [
        try installed(
            #"""
            {"name":"tools","title":"Tools","author":"me","commands":[
              {"name":"list","title":"List Things","mode":"view","arguments":[
                {"name":"query","type":"text","required":true},{"name":"mode","type":"dropdown","data":[]}]},
              {"name":"refresh","title":"Refresh","mode":"no-view"},
              {"name":"status","title":"Status","mode":"menu-bar"}]}
            """#),
        try installed(
            #"""
            {"name":"other","title":"Other Tools","owner":"acme","author":"alice","commands":[
              {"name":"show","title":"Show","mode":"view"}]}
            """#),
        try installed(
            #"""
            {"name":"solo","title":"Solo","author":"bob","commands":[{"name":"run","title":"Run","mode":"no-view"}]}
            """#),
    ]
}

private func request(_ params: String) throws -> LaunchRequest {
    try LaunchRequest(params: JSONDecoder().decode(JSONValue.self, from: Data(params.utf8)))
}

@Test func readsALaunchRequestWithNullAsAbsentAndArgumentsAsStrings() throws {
    let read = try request(
        #"""
        {"name":"list","type":"background","extensionName":"other","ownerOrAuthorName":"acme",
         "arguments":{"query":"x","count":3,"ratio":1.5,"on":true,"gone":null},
         "context":{"at":{"$date":"2026-11-20T12:00:00.000Z"}},"fallbackText":null}
        """#)
    #expect(read.name == "list")
    #expect(read.type == .background)
    #expect(read.extensionName == "other")
    #expect(read.ownerOrAuthorName == "acme")
    #expect(read.arguments == ["query": "x", "count": "3", "ratio": "1.5", "on": "true"])
    #expect(read.context == .object(["at": .object(["$date": .string("2026-11-20T12:00:00.000Z")])]))
    #expect(read.fallbackText == nil)

    let plain = try request(#"{"name":"list","type":"userInitiated","arguments":null,"context":null}"#)
    #expect(plain.type == .userInitiated && plain.arguments.isEmpty && plain.context == nil)
}

@Test func refusesMalformedLaunchRequests() {
    func message(_ params: String) -> String? {
        do {
            _ = try request(params)
            return nil
        } catch {
            return String(describing: error)
        }
    }
    #expect(message(#"{"type":"userInitiated"}"#) == "launchCommand: name is required")
    #expect(
        message(#"{"name":"a","type":"later"}"#)
            == "launchCommand: type must be LaunchType.UserInitiated or LaunchType.Background")
    #expect(
        message(#"{"name":"a","type":"background","extensionName":"x"}"#)
            == "launchCommand: ownerOrAuthorName is required with extensionName")
    #expect(
        message(#"{"name":"a","type":"background","ownerOrAuthorName":"x"}"#)
            == "launchCommand: extensionName is required with ownerOrAuthorName")
    #expect(
        message(#"{"name":"a","type":"background","arguments":{"q":["x"]}}"#)
            == #"launchCommand: argument "q" must be a string"#)
    #expect(message(#"{"name":"a","type":"background","context":"x"}"#) == "launchCommand: context must be an object")
}

@Test func findsACommandOfTheCallersOwnExtensionAndFillsItsArguments() throws {
    let target = try CommandLocator.locate(
        LaunchRequest(
            name: "list", type: .userInitiated, arguments: ["query": "x", "extra": "dropped"],
            context: .object(["from": .string("a")]), fallbackText: "typed"),
        caller: "tools", in: extensions())
    #expect(target.installed.manifest.name == "tools")
    #expect(target.command.name == "list")
    #expect(!target.isOtherExtension)
    #expect(target.rootItemID == "command:tools/list")
    #expect(
        target.launchProps
            == LaunchProps(
                arguments: ["query": "x", "mode": ""], launchType: "userInitiated", fallbackText: "typed",
                launchContext: .object(["from": .string("a")])))
    #expect(target.missingArgument == nil)
}

/// SPEC-143: a command named as Raycast accepts it is found by its name exactly as written, its case included.
@Test func findsACamelCaseCommandByItsExactName() throws {
    let camel = try installed(
        #"""
        {"name":"made-up","title":"Made Up","author":"me","commands":[
          {"name":"caffeinateWhile","title":"Stay Awake","mode":"no-view"},
          {"name":"show-recent.command","title":"Show Recent","mode":"view"}]}
        """#)
    var settings = FudgeSettings()
    settings.commands["made-up/caffeinateWhile"] = .init(hotkey: "option+w")
    let target = try CommandLocator.locate(
        try request(#"{"name":"caffeinateWhile","type":"background"}"#), caller: "made-up", in: [camel],
        settings: settings)
    #expect(target.command.name == "caffeinateWhile")
    #expect(target.rootItemID == "command:made-up/caffeinateWhile")
    let dotted = try CommandLocator.locate(
        LaunchRequest(name: "show-recent.command", type: .userInitiated), caller: "made-up", in: [camel])
    #expect(dotted.command.name == "show-recent.command")
    #expect(throws: LaunchCommandError.commandNotFound(command: "caffeinatewhile", extension: "made-up")) {
        try CommandLocator.locate(
            LaunchRequest(name: "caffeinatewhile", type: .background), caller: "made-up", in: [camel])
    }
    settings.setEnabled(false, commandID: "made-up/caffeinateWhile")
    #expect(throws: LaunchCommandError.disabled(command: "caffeinateWhile")) {
        try CommandLocator.locate(
            LaunchRequest(name: "caffeinateWhile", type: .background), caller: "made-up", in: [camel],
            settings: settings)
    }
}

@Test func findsAnotherExtensionsCommandByOwnerOrElseAuthor() throws {
    let byOwner = try CommandLocator.locate(
        LaunchRequest(name: "show", type: .userInitiated, extensionName: "other", ownerOrAuthorName: "acme"),
        caller: "tools", in: extensions())
    #expect(byOwner.installed.manifest.name == "other")
    #expect(byOwner.isOtherExtension)

    let byAuthor = try CommandLocator.locate(
        LaunchRequest(name: "run", type: .background, extensionName: "solo", ownerOrAuthorName: "bob"),
        caller: "tools", in: extensions())
    #expect(byAuthor.installed.manifest.name == "solo")
    #expect(byAuthor.launchProps.launchType == "background")

    // With an owner, the author doesn't name the extension.
    #expect(throws: LaunchCommandError.extensionNotInstalled(owner: "alice", name: "other")) {
        try CommandLocator.locate(
            LaunchRequest(name: "show", type: .userInitiated, extensionName: "other", ownerOrAuthorName: "alice"),
            caller: "tools", in: extensions())
    }
}

@Test func namesWhatIsMissing() throws {
    #expect(
        LaunchCommandError.extensionNotInstalled(owner: "acme", name: "gone").description
            == #"Extension "acme/gone" isn't installed"#)
    #expect(throws: LaunchCommandError.commandNotFound(command: "nope", extension: "tools")) {
        try CommandLocator.locate(LaunchRequest(name: "nope", type: .userInitiated), caller: "tools", in: extensions())
    }
    #expect(
        LaunchCommandError.commandNotFound(command: "nope", extension: "tools").description
            == #"No command "nope" in extension "tools""#)
    #expect(throws: LaunchCommandError.extensionNotInstalled(owner: "acme", name: "gone")) {
        try CommandLocator.locate(
            LaunchRequest(name: "x", type: .userInitiated, extensionName: "gone", ownerOrAuthorName: "acme"),
            caller: "tools", in: extensions())
    }
}

@Test func backgroundLaunchesAreForNoViewAndActiveMenuBarCommands() throws {
    let commands = try extensions()[0].manifest.commands
    let (list, refresh, status) = (commands[0], commands[1], commands[2])
    #expect(throws: Never.self) { try CommandLocator.checkMode(refresh, type: .background) }
    #expect(throws: Never.self) { try CommandLocator.checkMode(list, type: .userInitiated) }
    #expect(throws: LaunchCommandError.notInBackground(command: "list")) {
        try CommandLocator.checkMode(list, type: .background)
    }
    #expect(
        LaunchCommandError.notInBackground(command: "list").description
            == #""list" can't be launched in the background"#)
    #expect(throws: Never.self) { try CommandLocator.checkMode(status, type: .userInitiated) }
    #expect(throws: Never.self) {
        try CommandLocator.checkMode(status, type: .userInitiated, isActiveInMenuBar: true)
    }
    #expect(throws: Never.self) { try CommandLocator.checkMode(status, type: .background, isActiveInMenuBar: true) }
    #expect(throws: LaunchCommandError.notActiveInMenuBar(command: "status")) {
        try CommandLocator.checkMode(status, type: .background)
    }
    #expect(
        LaunchCommandError.notActiveInMenuBar(command: "status").description
            == #""status" isn't active in the menu bar"#)
}

@Test func aMissingRequiredArgumentShowsTheFieldsOrFailsInTheBackground() throws {
    let target = try CommandLocator.locate(
        LaunchRequest(name: "list", type: .userInitiated, arguments: ["mode": "all"]), caller: "tools",
        in: extensions())
    #expect(target.missingArgument?.name == "query")
    #expect(try CommandLocator.checkArguments(target, type: .userInitiated) == false)
    #expect(throws: LaunchCommandError.missingArgument(argument: "query", command: "list")) {
        try CommandLocator.checkArguments(target, type: .background)
    }
    #expect(
        LaunchCommandError.missingArgument(argument: "query", command: "list").description
            == #"Missing required argument "query" for "list""#)

    let filled = try CommandLocator.locate(
        LaunchRequest(name: "list", type: .background, arguments: ["query": "x"]), caller: "tools", in: extensions())
    #expect(try CommandLocator.checkArguments(filled, type: .background))
}

@Test func anUnsetRequiredPreferenceOpensSettingsOrFailsInTheBackground() throws {
    let target = try CommandLocator.locate(
        LaunchRequest(name: "refresh", type: .background), caller: "tools", in: extensions())
    let token = try JSONDecoder().decode(
        ExtensionManifest.Preference.self,
        from: Data(#"{"name":"token","type":"password","title":"API Token","required":true}"#.utf8))
    let host = try JSONDecoder().decode(
        ExtensionManifest.Preference.self, from: Data(#"{"name":"host","type":"textfield","required":true}"#.utf8))
    #expect(try CommandLocator.checkPreferences([], of: target, type: .background))
    #expect(try CommandLocator.checkPreferences([token], of: target, type: .userInitiated) == false)
    #expect(throws: LaunchCommandError.missingPreferences(extensionTitle: "Tools", names: ["API Token", "host"])) {
        try CommandLocator.checkPreferences([token, host], of: target, type: .background)
    }
    #expect(
        LaunchCommandError.missingPreferences(extensionTitle: "Tools", names: ["API Token", "host"]).description
            == #""Tools" needs these preferences set: API Token, host"#)
}

@Test func remembersWhichExtensionsMayOpenOthers() throws {
    var permissions = LaunchPermissions()
    #expect(permissions.answer(caller: "tools", target: "other") == nil)
    permissions.record(true, caller: "tools", target: "other")
    permissions.record(false, caller: "tools", target: "solo")
    #expect(permissions.answer(caller: "tools", target: "other") == true)
    #expect(permissions.answer(caller: "tools", target: "solo") == false, "a denial is remembered too")
    #expect(permissions.answer(caller: "other", target: "tools") == nil, "each direction is asked separately")

    let file = try Fixtures.temporaryDirectory().appendingPathComponent("nested/launch-permissions.json")
    try permissions.save(to: file)
    #expect(LaunchPermissions.load(from: file) == permissions)
    let json = try JSONDecoder().decode([String: [String: Bool]].self, from: Data(contentsOf: file))
    #expect(json == ["tools": ["other": true, "solo": false]])
    #expect(LaunchPermissions.load(from: file.appendingPathExtension("missing")) == LaunchPermissions())
    #expect(
        LaunchCommandError.notAllowed(extensionTitle: "Other Tools").description
            == #"Not allowed to launch commands of "Other Tools""#)
}

@Test func theLaunchMessageCarriesTheContext() throws {
    let message = AppMessage.launch(
        session: "s1", entry: "/x.cjs", mode: "view",
        launchProps: LaunchProps(arguments: [:], launchContext: .object(["from": .string("a")])))
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(message))
    guard case .object(let object) = json, case .object(let props) = object["launchProps"] else {
        Issue.record("no launchProps")
        return
    }
    #expect(props["launchContext"] == .object(["from": .string("a")]))
    let without = try JSONDecoder().decode(
        JSONValue.self,
        from: JSONEncoder().encode(
            AppMessage.launch(session: "s1", entry: "/x.cjs", mode: "view", launchProps: .init())))
    guard case .object(let plain) = without, case .object(let plainProps) = plain["launchProps"] else { return }
    #expect(plainProps["launchContext"] == nil, "no context, no key")
}

@Test func launchPermissionsListAndForgetAnswers() throws {
    var permissions = LaunchPermissions()
    permissions.record(false, caller: "tools", target: "other")
    permissions.record(true, caller: "alpha", target: "zeta")
    permissions.record(true, caller: "alpha", target: "beta")
    #expect(
        permissions.entries == [
            .init(caller: "alpha", target: "beta", allowed: true),
            .init(caller: "alpha", target: "zeta", allowed: true),
            .init(caller: "tools", target: "other", allowed: false),
        ], "sorted by caller, then target")
    #expect(
        LaunchPermissions.Entry(caller: "a", target: "b", allowed: true).id
            == LaunchPermissions.Entry(caller: "a", target: "b", allowed: false).id,
        "a changed answer keeps its row")
    #expect(
        LaunchPermissions.Entry(caller: "a", target: "bc", allowed: true).id
            != LaunchPermissions.Entry(caller: "ab", target: "c", allowed: true).id)

    permissions.forget(caller: "alpha", target: "beta")
    permissions.forget(caller: "tools", target: "other")
    permissions.forget(caller: "nobody", target: "x")
    #expect(permissions.answers == ["alpha": ["zeta": true]], "a caller with no answers left is gone")
    #expect(permissions.answer(caller: "tools", target: "other") == nil, "asked again next time")

    let file = try Fixtures.temporaryDirectory().appendingPathComponent("launch-permissions.json")
    var stored = LaunchPermissions(answers: ["a": ["b": true, "c": false], "d": ["e": true]])
    try stored.save(to: file)
    stored = LaunchPermissions.load(from: file)
    stored.record(true, caller: "a", target: "c")
    stored.forget(caller: "d", target: "e")
    try stored.save(to: file)
    #expect(LaunchPermissions.load(from: file).answers == ["a": ["b": true, "c": true]], "other answers are kept")
}

@Test func launchPermissionsNeverOverwriteAFileTheyCantRead() throws {
    let file = try Fixtures.temporaryDirectory().appendingPathComponent("launch-permissions.json")
    #expect(!LaunchPermissions.isUnreadable(file), "a missing file is fine")
    try Data("  \n".utf8).write(to: file)
    #expect(!LaunchPermissions.isUnreadable(file), "a blank one too")
    try LaunchPermissions(answers: ["a": ["b": true]]).save(to: file)

    for broken in ["not json", "[1, 2]", #"{"a": {"b": "yes"}}"#] {
        try Data(broken.utf8).write(to: file)
        #expect(LaunchPermissions.isUnreadable(file), "\(broken)")
        #expect(LaunchPermissions.load(from: file) == LaunchPermissions())
        #expect(throws: LaunchPermissions.Unreadable()) {
            try LaunchPermissions(answers: ["x": ["y": true]]).save(to: file)
        }
        #expect(try Data(contentsOf: file) == Data(broken.utf8), "left byte for byte")
    }
    #expect(LaunchPermissions.Unreadable().description.hasSuffix("Fix or remove it, then try again."))
}

@Test func aDisabledCommandOrExtensionIsRefused() throws {
    var settings = FudgeSettings()
    settings.commands["tools/refresh"] = .init(enabled: false)
    #expect(throws: LaunchCommandError.disabled(command: "refresh")) {
        try CommandLocator.locate(
            request(#"{"name":"refresh","type":"background"}"#), caller: "tools", in: extensions(), settings: settings)
    }
    #expect(LaunchCommandError.disabled(command: "refresh").description == #"Command "refresh" is disabled"#)
    settings = FudgeSettings(extensions: ["solo": .init(enabled: false)])
    #expect(throws: LaunchCommandError.disabled(command: "run")) {
        try CommandLocator.locate(
            request(#"{"name":"run","type":"background","extensionName":"solo","ownerOrAuthorName":"bob"}"#),
            caller: "tools", in: extensions(), settings: settings)
    }
    let enabled = try CommandLocator.locate(
        request(#"{"name":"refresh","type":"background"}"#), caller: "tools", in: extensions(),
        settings: FudgeSettings())
    #expect(enabled.command.name == "refresh")
}

@Test func aBackgroundCallersUserInitiatedRequestRunsAsBackground() throws {
    // SPEC-045: a menu-bar command's interval refresh (or a background launch) asking for UserInitiated must not
    // bring Fudge forward, so it gets no panel, no argument fields and no Settings.
    let asked = LaunchRequest(name: "list", type: .userInitiated, arguments: ["mode": "all"])
    #expect(asked.asCalled(from: .userInitiated) == asked)
    let downgraded = asked.asCalled(from: .background)
    #expect(downgraded.type == .background)
    #expect(downgraded.name == "list" && downgraded.arguments == ["mode": "all"], "only the type changes")
    let background = LaunchRequest(name: "refresh", type: .background)
    #expect(background.asCalled(from: .userInitiated) == background, "a Background request stays Background")
    #expect(background.asCalled(from: .background) == background)

    // It then fails where a Background launch would, instead of showing anything.
    let commands = try extensions()[0].manifest.commands
    #expect(throws: LaunchCommandError.notInBackground(command: "list")) {
        try CommandLocator.checkMode(commands[0], type: downgraded.type)
    }
    #expect(throws: LaunchCommandError.notActiveInMenuBar(command: "status")) {
        try CommandLocator.checkMode(
            commands[2], type: LaunchRequest(name: "status", type: .userInitiated).asCalled(from: .background).type)
    }
    let target = try CommandLocator.locate(downgraded, caller: "tools", in: extensions())
    #expect(target.launchProps.launchType == "background", "the launched command sees how it really runs")
    #expect(throws: LaunchCommandError.missingArgument(argument: "query", command: "list")) {
        try CommandLocator.checkArguments(target, type: downgraded.type)
    }
    let token = try JSONDecoder().decode(
        ExtensionManifest.Preference.self, from: Data(#"{"name":"token","type":"password","required":true}"#.utf8))
    let refresh = try CommandLocator.locate(
        LaunchRequest(name: "refresh", type: .userInitiated).asCalled(from: .background), caller: "tools",
        in: extensions())
    #expect(throws: LaunchCommandError.missingPreferences(extensionTitle: "Tools", names: ["token"])) {
        try CommandLocator.checkPreferences([token], of: refresh, type: .background)
    }
}
