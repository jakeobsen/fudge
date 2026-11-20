import Testing

@testable import FudgeCore

@Test func splitsMarkdownIntoBlocks() {
    let markdown = """
        # Title

        A paragraph
        over two lines.

        ## Section ##
        - one
        - two
          continued
            - nested
        - [x] done
        - [ ] todo

        1. first
        2) second

        ```swift
        let x = 1

        print(x)
        ```

        > quoted
        > text

        ---

        ![Logo](assets/logo.png "The logo")

        | Name | Value |
        |------|------:|
        | a \\| b | 1 |
        | c |
        """
    let expected: [MarkdownBlock] = [
        .heading(level: 1, text: "Title"),
        .paragraph("A paragraph over two lines."),
        .heading(level: 2, text: "Section"),
        .list([
            .init(marker: "•", level: 0, checked: nil, text: "one"),
            .init(marker: "•", level: 0, checked: nil, text: "two continued"),
            .init(marker: "•", level: 2, checked: nil, text: "nested"),
            .init(marker: "•", level: 0, checked: true, text: "done"),
            .init(marker: "•", level: 0, checked: false, text: "todo"),
        ]),
        .list([
            .init(marker: "1.", level: 0, checked: nil, text: "first"),
            .init(marker: "2.", level: 0, checked: nil, text: "second"),
        ]),
        .code(language: "swift", text: "let x = 1\n\nprint(x)"),
        .quote("quoted text"),
        .rule,
        .image(alt: "Logo", source: "assets/logo.png"),
        .table(header: ["Name", "Value"], rows: [["a | b", "1"], ["c", ""]]),
    ]
    let blocks = Markdown.blocks(markdown)
    #expect(blocks.count == expected.count)
    for (block, wanted) in zip(blocks, expected) {
        #expect(block == wanted)
    }
}

@Test func handlesTheEdgesOfBlocks() {
    #expect(Markdown.blocks("") == [])
    #expect(Markdown.blocks("```\nunclosed") == [.code(language: nil, text: "unclosed")])
    #expect(Markdown.blocks("#not a heading") == [.paragraph("#not a heading")])
    #expect(Markdown.blocks("Title\n===\nbody") == [.heading(level: 1, text: "Title"), .paragraph("body")])
    #expect(Markdown.blocks("Sub\n---") == [.heading(level: 2, text: "Sub")])
    #expect(Markdown.blocks("* * *") == [.rule])
    #expect(Markdown.blocks("hard  \nbreak\\\nhere") == [.paragraph("hard\nbreak\nhere")])
    #expect(
        Markdown.blocks("text\n- item") == [
            .paragraph("text"), .list([.init(marker: "•", level: 0, checked: nil, text: "item")]),
        ])
    #expect(
        Markdown.blocks("- a\n\n- b") == [
            .list([
                .init(marker: "•", level: 0, checked: nil, text: "a"),
                .init(marker: "•", level: 0, checked: nil, text: "b"),
            ])
        ])
    #expect(Markdown.blocks("a | b\nnot a table") == [.paragraph("a | b not a table")])
}
