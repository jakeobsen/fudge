import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// scripts/disk-image.sh, which `make dmg-image` runs (SPEC-150), with a made-up hdiutil first on PATH: it keeps each
// "image" as a folder and logs every call, so the detach's retries, its forcing and the clean-up are tried here
// without mounting anything. A failed release run costs money and another approval, so a busy detach must not fail it.
const script = fileURLToPath(new URL("../../scripts/disk-image.sh", import.meta.url));

const fakeHdiutil = `#!/bin/bash
set -eu
printf '%s\\n' "$*" >>"$FAKE_LOG"
command=$1
shift
last=\${!#}
case $command in
create)
	while [ "$1" != -srcfolder ]; do shift; done
	mkdir -p "$last.d" && cp -R "$2/." "$last.d/" && touch "$last"
	;;
attach)
	while [ "$1" != -mountpoint ]; do shift; done
	cp -R "$last.d/." "$2/"
	;;
detach)
	tries=$(cat "$FAKE_TRIES" 2>/dev/null || echo 0)
	echo $((tries + 1)) >"$FAKE_TRIES"
	case " $* " in
	*" -force "*) [ "\${FAKE_FORCE_FAILS:-no}" = no ] || exit 16 ;;
	*) [ "$tries" -ge "\${FAKE_DETACH_FAILS:-0}" ] || exit 16 ;;
	esac
	find "$last" -mindepth 1 -delete
	;;
convert)
	while [ "$1" != -o ]; do shift; done
	touch "$2"
	;;
esac
`;

const fakeTool = `#!/bin/bash
[ "\${FAKE_TOOL_FAILS:-no}" = no ] || exit 1
[ "$1" = layout ] && printf 'layout' >"$2/.DS_Store"
`;

interface Run {
    status: number | null;
    stderr: string;
    calls: string[];
    work: string;
    image: string;
}

function makeImage(env: Record<string, string>): Run {
    const folder = mkdtempSync(join(tmpdir(), "fudge-disk-image-"));
    try {
        const bin = join(folder, "bin");
        mkdirSync(bin);
        writeFileSync(join(bin, "hdiutil"), fakeHdiutil);
        chmodSync(join(bin, "hdiutil"), 0o755);
        const tool = join(folder, "FudgeDiskImage");
        writeFileSync(tool, fakeTool);
        chmodSync(tool, 0o755);
        const app = join(folder, "Fudge.app");
        mkdirSync(join(app, "Contents"), { recursive: true });
        writeFileSync(join(app, "Contents", "Info.plist"), "<plist/>");
        const background = join(folder, "background.tiff");
        writeFileSync(background, "made up");
        const log = join(folder, "hdiutil.log");
        const image = join(folder, "build", "Fudge-0.1.0.dmg");
        const result = spawnSync("bash", [script, app, background, tool, image], {
            encoding: "utf8",
            env: {
                ...process.env,
                PATH: `${bin}:${process.env.PATH}`,
                FAKE_LOG: log,
                FAKE_TRIES: join(folder, "tries"),
                DISK_IMAGE_DETACH_WAIT: "0",
                ...env,
            },
        });
        const work = join(folder, "build", "dmg");
        return {
            status: result.status,
            stderr: result.stderr,
            calls: existsSync(log) ? readFileSync(log, "utf8").trim().split("\n") : [],
            work: existsSync(work) ? "left" : "gone",
            image: existsSync(image) ? "made" : "none",
        };
    } finally {
        rmSync(folder, { recursive: true, force: true });
    }
}

const commands = (run: Run): string[] => run.calls.map((call) => call.split(" ")[0]);

test("the image is made from a mount no one sees, and the scratch folder goes", () => {
    const run = makeImage({});
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.image, "made");
    assert.equal(run.work, "gone");
    const attach = run.calls.find((call) => call.startsWith("attach"));
    assert.match(attach ?? "", / -nobrowse /);
    assert.match(attach ?? "", / -noautoopen /);
    assert.match(run.calls[0], /^create -quiet -fs HFS\+ -volname Fudge -srcfolder /);
    assert.match(run.calls[3], / -format UDZO -o /);
    assert.deepEqual(commands(run), ["create", "attach", "detach", "convert"]);
});

test("a detach that fails is tried again, and the image is still made", () => {
    const run = makeImage({ FAKE_DETACH_FAILS: "2" });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.image, "made");
    assert.equal(run.work, "gone");
    assert.equal(run.calls.filter((call) => call.startsWith("detach -quiet")).length, 3);
    assert.equal(run.calls.filter((call) => call.includes("-force")).length, 0);
});

test("a detach that keeps failing is forced", () => {
    const run = makeImage({ FAKE_DETACH_FAILS: "99" });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.image, "made");
    assert.equal(run.work, "gone");
    assert.equal(run.calls.filter((call) => call.startsWith("detach -quiet")).length, 5);
    assert.equal(run.calls.filter((call) => call.startsWith("detach -force")).length, 1);
    assert.match(run.stderr, /is busy; forcing the detach/);
});

test("when the layout fails, the scratch image is still detached and deleted, and there's no image", () => {
    const run = makeImage({ FAKE_TOOL_FAILS: "yes" });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /FudgeDiskImage could not lay out the window/);
    assert.equal(run.image, "none");
    assert.equal(run.work, "gone");
    assert.ok(run.calls.some((call) => call.startsWith("detach")), "detached");
    assert.ok(!run.calls.some((call) => call.startsWith("convert")), "not compressed");
});

test("a scratch image that can't be detached at all is left, and the error says where", () => {
    const run = makeImage({ FAKE_DETACH_FAILS: "99", FAKE_FORCE_FAILS: "yes" });
    assert.equal(run.status, 1);
    assert.equal(run.image, "none");
    assert.equal(run.work, "left");
    assert.match(run.stderr, /could not detach .*mount; detach it, then delete .*dmg/);
});
