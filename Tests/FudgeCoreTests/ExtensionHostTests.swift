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

@Test func locatesNodeAndTheHostScript() throws {
    #expect(Runtime.locateNode(environment: ["FUDGE_NODE": "/x/node"], helpers: nil)?.path == "/x/node")
    #expect(
        Runtime.locateHostScript(environment: ["FUDGE_RUNTIME": "/x/host.ts"], resources: nil)?.path == "/x/host.ts")
    #expect(Runtime.locateHostScript(environment: [:], resources: URL(fileURLWithPath: "/nonexistent")) == nil)
}
