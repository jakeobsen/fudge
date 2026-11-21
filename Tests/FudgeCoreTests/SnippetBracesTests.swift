import Foundation
import Testing

@testable import FudgeCore

/// Saturday, 21 November 2026, 10:00 UTC.
private let context = QuicklinkTemplate.Context(
    clipboard: "copied", now: Date(timeIntervalSince1970: 1_795_255_200), locale: Locale(identifier: "en_US"),
    timeZone: TimeZone(identifier: "UTC")!, calendar: Calendar(identifier: .gregorian), makeUUID: { "U-1" })

/// The architect's snippet (FUD-130): a Python script with dict literals, a format string and an f-string, and
/// `{cursor}` after `logging.info("Hello world!")`.
private let pythonScript = #"""
    #!/usr/bin/env python3

    import argparse
    import logging
    import os
    import sys


    def cli_args() -> argparse.Namespace:
        """
        Commandline argument parser config. Defines and process command line arguments.

        :return: parsed args object - argparse.Namespace
        """
        # It's good practice to add the ArgumentDefaultsHelpFormatter formatter class.
        parser: argparse.ArgumentParser = argparse.ArgumentParser(
            formatter_class=argparse.ArgumentDefaultsHelpFormatter,
            prog="main.py",
            description="Change me to tell what I do :)")

        # Being able to control loglevel is always nice, this little snippet makes sure the default log level is 'info'
        # and allows the user to define the loglevel via either the argparse option or the environment variable 'loglevel'.
        # In this case the argparse option takes precedence over the environment variable.
        parser.add_argument("-l", "--loglevel",
                            choices=['debug', 'info', 'warning', 'error', 'critical'],
                            default=os.environ.get('loglevel', 'info'),
                            help="Set global loglevel. Can also be set using env variable 'loglevel'.")

        # Returns default "args" namespace for accessing the arguments defined above
        return parser.parse_args()


    def main(args: argparse.Namespace) -> int:
        """
        This is the main script loop where execution of this file begins.

        :param args: argparse.Namespace - argument parser namespace for accessing command line options.
        :return: exit code - this is used to tell the OS the status of the script.
        """
        # Default exit_code should be 0, which is the expected exit code by the OS. Anything not 0 means an error occurred.
        # Returning an exit code to the OS is nice, and extremely helpful when automating things.
        exit_code: int = 0

        # This is an example of how a logging configuration could be created.
        logging.basicConfig(
            level={
                "debug": logging.DEBUG,
                "info": logging.INFO,
                "warning": logging.WARNING,
                "error": logging.ERROR,
                "critical": logging.CRITICAL}[args.loglevel],
            format='%(asctime)s | %(lineno)-4d | %(message)s',
            datefmt='%Y/%m/%d %H:%M:%S')

        # Your code goes here!
        logging.info("Hello world!"){cursor}

        # Print the exit_code when debug logging is enabled.
        # Useful for debugging problems - and making sure the expected exit code is returned.
        logging.debug(f"Application exit code: {exit_code}")

        # returns the exit code, which is passed to sys.exit at the end for the OS to know
        # if the script succeeded or not.
        return exit_code


    if __name__ == "__main__":
        sys.exit(main(cli_args()))

    """#

@Test func theArchitectsPythonSnippetSavesAndPastesAsWritten() throws {
    let template = SnippetTemplate(pythonScript)
    #expect(template.problem == nil)
    #expect(SnippetDraft(name: "Python script", text: pythonScript).problems(among: []).isEmpty, "the form saves it")
    let parts = pythonScript.components(separatedBy: "{cursor}")
    #expect(parts.count == 2)
    let filled = template.fill(context: context)
    #expect(filled.text == parts[0] + parts[1], "every other brace pastes byte for byte")
    #expect(filled.text.contains(#"logging.debug(f"Application exit code: {exit_code}")"#))
    #expect(filled.text.contains("level={\n"))
    #expect(filled.afterCursor == parts[1].count, "the caret ends up right after logging.info(\"Hello world!\")")
    #expect(!template.usesClipboard)
}

@Test(arguments: [
    #"{ "debug": 1, "info": 2 }"#, "{name}", "{{x}}", "{}", "a { b", "a } b", "}{", "{\n  \"a\": 1\n}",
    "{clip\nboard}", "{ date }", "{exit_code}", "{0}", "{date: 1}", "{Query}", "{ {x} }",
])
func otherTextInBracesIsTheSnippetsOwn(text: String) {
    let template = SnippetTemplate(text)
    #expect(template.problem == nil, "\(text)")
    #expect(template.fill(context: context).text == text, "\(text) pastes as it is")
}

@Test func knownNamesArePlaceholdersWhereverTheySit() {
    func filled(_ text: String) -> String { SnippetTemplate(text).fill(context: context).text }
    #expect(filled("{clipboard}") == "copied")
    #expect(filled("{Date}").contains("2026"), "names ignore case")
    #expect(filled(#"{date format="yyyy-MM-dd"}"#) == "2026-11-21")
    #expect(filled(#"{time format="HH:mm"}"#) == "10:00")
    #expect(filled(#"{datetime format="EEE d MMM" | uppercase}"#) == "SAT 21 NOV")
    #expect(filled("{clipboard | uppercase}") == "COPIED")
    // An exact name is a placeholder wherever it sits, as in Raycast: the braces around it are text.
    #expect(filled(#"{{date format="yyyy"}}"#) == "{2026}")
    #expect(filled(#"{ {date format="yyyy"} }"#) == "{ 2026 }")
    let cursor = SnippetTemplate("x = {{cursor}}").fill(context: context)
    #expect(cursor.text == "x = {}" && cursor.afterCursor == 1)
}

@Test func aKnownNameUsedWronglyIsStillAProblem() {
    #expect(SnippetTemplate("a{cursor}b{Cursor}").problem == "A snippet can have only one {cursor}.")
    #expect(SnippetTemplate(#"{date bogus="x"}"#).problem == #"Fudge doesn't support “{date bogus="x"}” in a snippet."#)
    #expect(SnippetTemplate(#"{clipboard format="x"}"#).problem != nil, "only dates take a format")
    #expect(SnippetTemplate("{date|shout}").problem == "Fudge doesn't know the modifier “shout” in “{date|shout}”.")
    // Raycast's names Fudge can't fill say so, rather than paste their syntax.
    #expect(SnippetTemplate("{argument}").problem == "Fudge doesn't support “{argument}” in a snippet.")
    #expect(
        SnippetTemplate(#"{argument name="who"}"#).problem
            == #"Fudge doesn't support “{argument name="who"}” in a snippet."#)
    #expect(SnippetTemplate("{selection}").problem == "Fudge doesn't support “{selection}” in a snippet.")
    #expect(SnippetTemplate("{browser-tab}").problem != nil)
}

@Test func quicklinksStillReadEveryBraceAsAPlaceholder() {
    #expect(QuicklinkTemplate("https://x.test/{a b}").problem == "Fudge doesn't support “{a b}” in a quicklink.")
    #expect(QuicklinkTemplate("https://x.test/?q={").problem == "A “{” in the link has no “}” after it.")
    #expect(QuicklinkTemplate("https://x.test/}").problem == "A “}” in the link has no “{” before it.")
    #expect(QuicklinkTemplate("https://x.test/{name}").arguments.map(\.name) == ["name"])
    #expect(
        QuicklinkTemplate(#"https://x.test/{date format="yyyy"}"#).problem != nil, "a quicklink's date has no format")
}
