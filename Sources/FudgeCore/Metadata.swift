import Foundation

/// One row of a `Metadata` node (shared by `Detail.Metadata` and `List.Item.Detail.Metadata`).
public enum MetadataEntry: Sendable, Equatable {
    public struct Tag: Sendable, Equatable, Identifiable {
        /// The node id, which `onAction` events go to.
        public var id: Int
        public var text: String?
        public var icon: JSONValue?
        public var color: JSONValue?
        public var hasAction: Bool
    }

    case label(title: String, text: String?, color: JSONValue?, icon: JSONValue?)
    case link(title: String, text: String, target: String)
    case tags(title: String, tags: [Tag])
    case separator

    /// The entries of a Metadata node, in order.
    public static func entries(of metadata: UINode?) -> [MetadataEntry] {
        guard let metadata else { return [] }
        return metadata.children.compactMap(entry)
    }

    static func entry(_ node: UINode) -> MetadataEntry? {
        let title = node.string("title") ?? ""
        switch node.type {
        case "Metadata.Label":
            let text = ListContent.textWithTooltip(node.props["text"]).text
            var color: JSONValue?
            if case .object(let object) = node.props["text"] { color = object["color"].flatMap(ListContent.present) }
            return .label(title: title, text: text, color: color, icon: node.props["icon"].flatMap(ListContent.present))
        case "Metadata.Link":
            guard let target = node.string("target") else { return nil }
            return .link(title: title, text: node.string("text") ?? target, target: target)
        case "Metadata.TagList":
            let tags = node.children.filter { $0.type == "Metadata.TagList.Item" }.map { item in
                Tag(
                    id: item.id,
                    text: item.string("text"),
                    icon: item.props["icon"].flatMap(ListContent.present),
                    color: item.props["color"].flatMap(ListContent.present),
                    hasAction: item.hasCallback("onAction")
                )
            }
            return .tags(title: title, tags: tags)
        case "Metadata.Separator":
            return .separator
        default:
            return nil
        }
    }
}
