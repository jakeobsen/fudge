import Foundation
import Testing

@testable import FudgeCore

/// Runs the extension host from source (runtime/src/host.ts) with the Node on this machine.
@Suite(.enabled(if: HostFixture.node != nil && HostFixture.runtimeInstalled, "needs Node 22.18+ and `make test`"))
struct ExtensionHostTests {
    @Test func launchesAViewCommandAndRoundTripsAnEvent() async throws {
        let host = try HostFixture.start()
        defer { host.stop() }
        var messages = host.messages.makeAsyncIterator()

        try host.send(
            .launch(
                session: "s1",
                entry: HostFixture.runtimeFixture("counter.cjs").path,
                mode: "view",
                launchProps: LaunchProps(arguments: ["name": "From Swift"])
            )
        )
        let first = try await next(&messages) { if case .render = $0 { true } else { false } }
        guard case .render(let session, let view?, let depth) = first else {
            Issue.record("no view")
            return
        }
        #expect(session == "s1")
        #expect(depth == 1)
        #expect(view.type == "List")
        #expect(view.string("navigationTitle") == "From Swift")
        #expect(view.children.first?.string("title") == "count 0")

        let action = try #require(view.first { $0.type == "Action" })
        #expect(action.hasCallback("onAction"))
        try host.send(.event(session: "s1", node: action.id, path: ["onAction"], args: []))
        let second = try await next(&messages) { if case .render = $0 { true } else { false } }
        guard case .render(_, let updated?, _) = second else {
            Issue.record("no view")
            return
        }
        #expect(updated.children.first?.string("title") == "count 1")

        try host.send(.unload(session: "s1"))
        let exit = try await next(&messages) { if case .exit = $0 { true } else { false } }
        #expect(exit == .exit(session: "s1", reason: "unloaded"))
    }

    @Test func answersPingsAndReportsProtocolErrors() async throws {
        let host = try HostFixture.start()
        defer { host.stop() }
        var messages = host.messages.makeAsyncIterator()
        try host.send(.ping(id: 9))
        #expect(try await next(&messages) { _ in true } == .pong(id: 9))
        try host.send(.pop(session: "nobody"))
        #expect(try await next(&messages) { _ in true } == .protocolError(message: "no running session `nobody`"))
    }

    @Test func theStreamEndsWhenTheHostStops() async throws {
        let host = try HostFixture.start()
        var messages = host.messages.makeAsyncIterator()
        host.stop()
        #expect(await messages.next() == nil)
    }
}

enum HostFixture {
    static let node = Runtime.locateNode()
    static let runtime = Fixtures.repository.appendingPathComponent("runtime", isDirectory: true)
    static var runtimeInstalled: Bool {
        FileManager.default.fileExists(atPath: runtime.appendingPathComponent("node_modules/react").path)
    }

    static func runtimeFixture(_ name: String) -> URL {
        runtime.appendingPathComponent("test/fixtures/\(name)")
    }

    static func start() throws -> ExtensionHost {
        try ExtensionHost(node: try #require(node), script: runtime.appendingPathComponent("src/host.ts"))
    }
}

struct Timeout: Error {}

/// The next message that matches, or `Timeout` after a few seconds.
func next(
    _ messages: inout AsyncStream<HostMessage>.Iterator,
    timeout: Duration = .seconds(10),
    where matches: (HostMessage) -> Bool
) async throws -> HostMessage {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        guard let message = await messages.next() else { throw Timeout() }
        if matches(message) { return message }
    }
    throw Timeout()
}

@Test func decodesHostMessagesAndUnknownTypes() throws {
    let decode = { (json: String) in try JSONDecoder().decode(HostMessage.self, from: Data(json.utf8)) }
    #expect(try decode(#"{"type":"pong","id":3}"#) == .pong(id: 3))
    #expect(
        try decode(#"{"type":"exit","session":"s","reason":"finished"}"#) == .exit(session: "s", reason: "finished"))
    #expect(
        try decode(#"{"type":"render","session":"s","view":null,"depth":1}"#)
            == .render(session: "s", view: nil, depth: 1))
    #expect(try decode(#"{"type":"somethingNew","session":"s"}"#) == .unknown(type: "somethingNew"))
    let rpc = try decode(#"{"type":"rpc","session":"s","id":1,"method":"toast.show","params":{"title":"Hi"}}"#)
    #expect(rpc == .rpc(session: "s", id: 1, method: "toast.show", params: .object(["title": .string("Hi")])))
    #expect(rpc.session == "s")
}

@Test func readsHostLinesAsJSONDecoderDoes() throws {
    let lines = [
        #"{"type":"pong","id":3}"#,
        #"{"type":"protocolError","message":"no running session `s`"}"#,
        #"{"type":"render","session":"s","view":null,"depth":1}"#,
        #"{"type":"render","session":"s","depth":2,"view":{"id":9,"type":"List","props":{"isLoading":true,"#
            + #""filtering":false,"n":1.5,"none":null,"onSearchTextChange":{"$fn":["onSearchTextChange"]}},"children":["#
            + #"{"id":4,"type":"List.Item","props":{"title":"é 😀 \"q\" \u0001","keywords":["a",""],"#
            + #""accessories":[{"date":{"$date":"2026-11-20T00:00:00.000Z"}},{"text":"0"}],"actions":{"$deferred":true}},"#
            + #""children":[]}]}}"#,
        #"{"type":"slots","session":"s","items":[{"id":4,"slots":{"actions":{"id":2,"type":"ActionPanel","props":{},"#
            + #""children":[{"id":1,"type":"Action","props":{"title":"Open","onAction":{"$fn":["onAction"]}},"#
            + #""children":[]}]},"detail":null}},{"id":7,"slots":{}}]}"#,
        #"{"type":"rpc","session":"s","id":1,"method":"toast.show","params":{"title":"Hi","n":[1,0,true,false]}}"#,
        #"{"type":"rpc","session":"s","id":2,"method":"window.close"}"#,
        #"{"type":"rpc","session":"s","id":4,"method":"m","params":{"big":12345678901234567890,"#
            + #""exact":9007199254740993,"negative":-42,"zero":0,"minusZero":-0,"small":1e-7,"huge":1e300,"#
            + #""escaped":"é😀\n\t\\\/","nested":[[1,[true,[false,null]]],{"a":{"b":"c"}}]}}"#,
        #"{"type":"error","session":"s","message":"boom","stack":"at x","fatal":true}"#,
        #"{"type":"error","session":"s","message":"boom","fatal":false}"#,
        #"{"type":"log","session":"s","level":"info","message":"hello"}"#,
        #"{"type":"eventSettled","session":"s"}"#,
        #"{"type":"exit","session":"s","reason":"finished"}"#,
        #"{"type":"somethingNew","session":"s"}"#,
    ]
    for line in lines {
        let data = Data(line.utf8)
        #expect(try HostMessage(line: data) == JSONDecoder().decode(HostMessage.self, from: data), "\(line)")
    }
    // Both refuse a line that isn't a message.
    let refused = [
        #"{"type":"pong"}"#, #"{"id":3}"#, #"[1]"#, #"{"type":"exit","session":"s","reason":"#,
        #"{"type":"rpc","session":"s","id":3,"method":"m","params":{"x":1e400}}"#,
    ]
    for line in refused {
        #expect(throws: (any Error).self) { try HostMessage(line: Data(line.utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(HostMessage.self, from: Data(line.utf8)) }
    }
    // 1 and 0 stay numbers; true and false stay Booleans.
    #expect(
        try HostMessage(line: Data(#"{"type":"rpc","session":"s","id":1,"method":"m","params":[1,0,true]}"#.utf8))
            == .rpc(session: "s", id: 1, method: "m", params: .array([.number(1), .number(0), .bool(true)])))
    let slots = try HostMessage(line: Data(lines[4].utf8))
    guard case .slots("s", let items) = slots else {
        Issue.record("not slots: \(slots)")
        return
    }
    #expect(items.map(\.id) == [4, 7])
    #expect(items[0].actions?.children.first?.string("title") == "Open")
    #expect(items[0].detail == nil)
    #expect(items[1] == ItemSlots(id: 7))
}

@Test func theFastPathReadsEveryNumberAsJSONDecoderDoes() throws {
    // Compared bit for bit. NSDecimalNumber's doubleValue was a step off for the first two.
    let numbers = [
        "0.00034445413621142507", "123456789012345680000", "12345678901234567890", "9007199254740993",
        "18446744073709551615", "18446744073709551616", "-9223372036854775808", "-9223372036854775809",
        "100000000000000000000000000000000000000000", "0.1234567890123456789012345678901234567890123", "0", "1",
        "-42", "1.5", "0.1", "0.30000000000000004", "123456789.12345678", "3.141592653589793", "1e-7", "-1.5e-10",
        "1E2", "1e300", "2.2250738585072014e-308", "5e-324", "1.7976931348623157e308", "-0.0",
    ]
    for number in numbers {
        let data = Data("[\(number)]".utf8)
        guard case .array(let fast) = try JSONValue.parse(data), case .number(let read)? = fast.first,
            case .array(let decoded) = try JSONDecoder().decode(JSONValue.self, from: data),
            case .number(let expected)? = decoded.first
        else {
            Issue.record("\(number) isn't a number on both paths")
            continue
        }
        #expect(read.bitPattern == expected.bitPattern, "\(number): \(read) against \(expected)")
    }
    // As a message, too.
    let line = Data(#"{"type":"rpc","session":"s","id":1,"method":"m","params":[0.00034445413621142507]}"#.utf8)
    guard case .rpc(_, _, _, .array(let params)) = try HostMessage(line: line), case .number(let value)? = params.first
    else {
        Issue.record("not an rpc with a number")
        return
    }
    #expect(value.bitPattern == 0.00034445413621142507.bitPattern)
}

@Test func encodesAppMessagesInTheHostsShape() throws {
    let encode = { (message: AppMessage) in
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? NSDictionary
    }
    #expect(
        try encode(.event(session: "s", node: 4, path: ["onAction"], args: [.string("x")])) == [
            "type": "event", "session": "s", "node": 4, "path": ["onAction"], "args": ["x"],
        ])
    #expect(
        try encode(.rpcResult(session: "s", id: 2, result: nil, error: "nope")) == [
            "type": "rpcResult", "session": "s", "id": 2, "error": "nope",
        ])
    #expect(try encode(.slots(session: "s", nodes: [4, 7])) == ["type": "slots", "session": "s", "nodes": [4, 7]])
}

@Test func readsNodesHeldInProps() throws {
    let json = #"""
        {"id":5,"type":"List.Item","props":{"title":"a","actions":{"id":2,"type":"ActionPanel","props":{},
        "children":[{"id":1,"type":"Action","props":{"title":"Open","onAction":{"$fn":["onAction"]}},"children":[]}]}},
        "children":[]}
        """#
    let item = try JSONDecoder().decode(UINode.self, from: Data(json.utf8))
    let panel = try #require(item.node("actions"))
    #expect(panel.type == "ActionPanel")
    #expect(panel.children.first?.hasCallback("onAction") == true)
    #expect(item.first { $0.type == "Action" }?.string("title") == "Open")
    #expect(item.node("title") == nil)
}

@Test func splitsLinesAcrossChunks() {
    let lines = LineSplitter()
    #expect(lines.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
    #expect(lines.append(Data(":2}\n\n".utf8)) == [Data("{\"b\":2}".utf8)])
}

@Test func splitsALongLineArrivingInManyChunks() {
    let lines = LineSplitter()
    let long = Data(repeating: UInt8(ascii: "x"), count: 1_000_000)
    var stream = Data("a\n".utf8) + long + Data("\nb\nc".utf8)
    var found: [Data] = []
    while !stream.isEmpty {
        let chunk = stream.prefix(65_536)
        stream.removeFirst(chunk.count)
        found += lines.append(Data(chunk))
    }
    #expect(found == [Data("a".utf8), long, Data("b".utf8)])
    // What's left waits for its newline, including one that arrives on its own.
    #expect(lines.append(Data("d".utf8)) == [])
    #expect(lines.append(Data("\n".utf8)) == [Data("cd".utf8)])
    #expect(lines.append(Data("\n\ne\nf\n".utf8)) == [Data("e".utf8), Data("f".utf8)])
}

@Test func locatesNodeAndTheHostScript() throws {
    #expect(Runtime.locateNode(environment: ["FUDGE_NODE": "/x/node"], helpers: nil)?.path == "/x/node")
    #expect(
        Runtime.locateHostScript(environment: ["FUDGE_RUNTIME": "/x/host.ts"], resources: nil)?.path == "/x/host.ts")
    #expect(Runtime.locateHostScript(environment: [:], resources: URL(fileURLWithPath: "/nonexistent")) == nil)
}
