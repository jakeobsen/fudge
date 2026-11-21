import CoreServices
import FudgeCore

/// Define Word's lookup: the plain-text definition Dictionary Services gives from the Mac's own dictionaries, offline.
struct DictionaryServicesLookup: DefinitionLookup {
    func definition(of word: String) async -> String? {
        await Task.detached {
            let text = word as CFString
            let range = CFRange(location: 0, length: CFStringGetLength(text))
            return DCSCopyTextDefinition(nil, text, range)?.takeRetainedValue() as String?
        }.value
    }
}
