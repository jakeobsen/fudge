import RaycastSwiftMacros

@raycast func greet(name: String) -> String {
    "Hello, \(name)"
}

@raycast
@MainActor
func fail() throws -> String {
    throw GreeterError.failed
}

// @raycast func commentedOut() {}

enum GreeterError: Error {
    case failed
}
