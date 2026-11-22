#!/bin/bash
# Signs Fudge.app as it is, inside-out: each item in Contents/Helpers (the `fudge` tool, esbuild, Node.js and the
# Fudge Links app), then the app with App/Fudge.entitlements. Every signature has the hardened runtime, which notarizing needs (FUD-44).
# A helper that needs entitlements of its own has them in App/Helpers/<its file name>.entitlements, so every signing,
# a release's again with the Developer ID included, gives them; the others get none.
#
#   scripts/sign-app.sh <app> <identity> [<keychain>]
#
# <identity> is a SHA-1 hash or a name that `security find-identity -v -p codesigning` lists, or - for ad hoc.
# With <keychain>, the identity is looked for in that keychain alone (`codesign --keychain`): a release signs from
# a keychain of its own, and the same certificate in the login keychain would otherwise be a second match, or a key
# that asks for the password. A Developer ID signature is only ever notarized, which needs Apple's secure timestamp,
# so only that one goes over the network; every other signature has none. A Developer ID identity's name stays out
# of the output, since a release's log is public. On success it prints how it signed: "ad hoc", or "with" and the
# identity.
set -euo pipefail

[ $# -eq 2 ] || [ $# -eq 3 ] || { printf 'usage: scripts/sign-app.sh <app> <identity> [<keychain>]\n' >&2; exit 2; }
app=$1
identity=$2
root=$(cd "$(dirname "$0")/.." && pwd)
# Where codesign and security look for the identity: the keychain given, else the search list.
keychain=()
from_keychain=()
if [ $# -eq 3 ]; then
	keychain=("$3")
	from_keychain=(--keychain "$3")
fi

name=
if [ "$identity" = - ]; then
	timestamp=--timestamp=none
	shown='ad hoc'
else
	name=$(security find-identity -v -p codesigning ${keychain[@]+"${keychain[@]}"} 2>/dev/null |
		awk -F'"' -v id="$identity" '{ split($1, f, " ") } f[2] == id || $2 == id { print $2; exit }')
	case $name in
	'Developer ID Application: '*)
		timestamp=--timestamp
		shown='with Developer ID Application: <redacted>'
		;;
	*)
		timestamp=--timestamp=none
		shown="with ${name:-$identity}"
		;;
	esac
fi

# codesign's output is shown only when it fails, and never with a Developer ID identity's name in it.
sign() {
	local out
	if ! out=$(codesign --force --options runtime "$timestamp" ${from_keychain[@]+"${from_keychain[@]}"} \
		--sign "$identity" "$@" 2>&1); then
		case $shown in *'<redacted>') [ -z "$name" ] || out=${out//"$name"/<redacted>} ;; esac
		printf '%s\n' "$out" >&2
		printf 'codesign could not sign %s %s\n' "${*: -1}" "$shown" >&2
		exit 1
	fi
}

for helper in "$app"/Contents/Helpers/*; do
	own="$root/App/Helpers/${helper##*/}.entitlements"
	if [ -f "$own" ]; then
		sign --entitlements "$own" "$helper"
	else
		sign "$helper"
	fi
done
sign --entitlements "$root/App/Fudge.entitlements" "$app"
printf '%s\n' "$shown"
