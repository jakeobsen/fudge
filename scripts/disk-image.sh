#!/bin/bash
# Makes Fudge's disk image (SPEC-150): the app, a link to /Applications, and the Finder window they open in, with
# its picture and the icons' places.
#
#   scripts/disk-image.sh <app> <background.tiff> <FudgeDiskImage> <image.dmg>
#
# `make dmg-image` runs it. The app is copied as it is, never built or signed again: the release script notarizes and
# staples it before this runs. The image is HFS+, which Apple recommends over APFS for a disk image's background
# picture on older macOS. It's made writable first, from a staging folder, then mounted so FudgeDiskImage can write
# the window's .DS_Store, and finally compressed (UDZO) into <image.dmg>.
#
# Nothing shows on the screen: the one mount is -nobrowse -noautoopen, at a folder of its own beside the image, so no
# Finder window opens and nothing appears on the desktop. A detach that fails (a busy volume, as happens on build
# machines) is tried again, then forced, and however the script ends, the scratch image is detached and deleted.
set -euo pipefail

usage='usage: scripts/disk-image.sh <app> <background.tiff> <FudgeDiskImage> <image.dmg>'
[ $# -eq 4 ] || {
	printf '%s\n' "$usage" >&2
	exit 2
}

fail() {
	printf 'make dmg-image: %s\n' "$1" >&2
	exit 1
}

absolute() {
	printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
}

[ -d "$1" ] || fail "there is no $1; run make app first"
[ -f "$2" ] || fail "there is no $2"
[ -x "$3" ] || fail "there is no $3"
app=$(absolute "$1")
background=$(absolute "$2")
tool=$(absolute "$3")
mkdir -p "$(dirname "$4")"
image=$(absolute "$4")

# The staging folder, the writable scratch image and its mount point, all in one folder beside the image.
work=$(dirname "$image")/dmg
stage=$work/stage
scratch=$work/scratch.dmg
mount=$work/mount
# Tries and seconds between them for a detach, before it's forced.
detach_tries=${DISK_IMAGE_DETACH_TRIES:-5}
detach_wait=${DISK_IMAGE_DETACH_WAIT:-2}

mounted=no
detach() {
	local try
	for ((try = 1; try <= detach_tries; try++)); do
		if hdiutil detach -quiet "$mount"; then
			mounted=no
			return 0
		fi
		[ "$try" -eq "$detach_tries" ] || sleep "$detach_wait"
	done
	printf 'make dmg-image: %s is busy; forcing the detach\n' "$mount" >&2
	if hdiutil detach -force -quiet "$mount"; then
		mounted=no
		return 0
	fi
	return 1
}

cleanup() {
	local status=$?
	if [ $mounted = yes ] && ! detach; then
		# Deleting the folder now would reach into the mounted volume, so it stays, and says so.
		printf 'make dmg-image: could not detach %s; detach it, then delete %s\n' "$mount" "$work" >&2
		exit "$status"
	fi
	rm -rf -- "$work"
	exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

rm -rf -- "$work" "$image"
mkdir -p "$stage/.background" "$mount"
ditto "$app" "$stage/Fudge.app"
ln -s /Applications "$stage/Applications"
cp "$background" "$stage/.background/background.tiff"

hdiutil create -quiet -fs HFS+ -volname Fudge -srcfolder "$stage" -format UDRW -ov "$scratch" ||
	fail "hdiutil could not create the scratch image"
hdiutil attach -quiet -nobrowse -noautoopen -noverify -mountpoint "$mount" "$scratch" ||
	fail "hdiutil could not mount the scratch image"
mounted=yes

"$tool" layout "$mount" || fail "FudgeDiskImage could not lay out the window"
# What macOS may keep on a volume it has mounted writable, which the published image doesn't need.
rm -rf -- "$mount/.fseventsd" "$mount/.Trashes" "$mount/.Spotlight-V100"
extra=$(cd "$mount" && ls -A | grep -vxF -e .background -e .DS_Store -e Applications -e Fudge.app || true)
[ -z "$extra" ] || fail "the image's root holds more than Fudge.app, Applications, .background and .DS_Store: $extra"

detach || fail "could not detach $mount"
hdiutil convert -quiet "$scratch" -format UDZO -o "$image" -ov || fail "hdiutil could not compress the image"
