#!/bin/bash
# Builds Fudge's release disk image, signed with the Developer ID identity, notarized and stapled (FUD-44).
#
#   scripts/release.sh [--tag <tag> | --version <version>] [--ad-hoc-without-secrets]
#
# The release workflow runs it on a tag (and by hand, as a dry run), and `make release` on the maintainer's Mac,
# after `secret env apple`. It reads five variables, the workflow's secrets of the same names:
#
#   APPLE_CERTIFICATE_BASE64     the Developer ID Application certificate with its private key: a .p12, in base64
#   APPLE_CERTIFICATE_PASSWORD   the .p12's password
#   APPLE_ID                     the Apple Account that notarizes
#   APPLE_APP_SPECIFIC_PASSWORD  an app-specific password of that account
#   APPLE_TEAM_ID                the team the identity belongs to
#
# None of them, nor the identity's name, is ever printed: what the tools say is shown only when they fail, with
# those values replaced by ***. They reach only `security` and `notarytool`; the build runs without them, before the
# certificate is imported, so none of its code can sign or notarize anything.
#
# The certificate goes into a keychain of its own, in a temporary folder, deleted at the end however the script
# ends; nothing else is written to disk. Every executable is signed again inside-out with the hardened runtime and a
# timestamp (scripts/sign-app.sh), with the identity from that keychain alone, the app is notarized and stapled, then
# the disk image is made from it, signed, notarized and stapled. Gatekeeper's assessment of both is the last check.
#
# Without any of the five, --ad-hoc-without-secrets (the tag workflow, so a fork can still build) makes the ad hoc
# image instead and says so; otherwise that's a failure, as some of them without the others always is.
# --tag names the tag a release is built from (the tag workflow's): it's the version, and the build passes it to make
# as RELEASE_TAG, so `make release-check` refuses it unless it's a tag on this commit. Otherwise the version is
# --version, else what `git describe` says, as `make app` takes it. A tree with changes is refused, since the
# version names a commit. It never pushes or tags.
set -euo pipefail
cd "$(dirname "$0")/.."

secrets=(APPLE_CERTIFICATE_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID)
app=build/Fudge.app
version=
tag=
ad_hoc_without_secrets=no
usage='usage: scripts/release.sh [--tag <tag> | --version <version>] [--ad-hoc-without-secrets]'

fail() {
	printf 'release: %s\n' "$1" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case $1 in
	--tag)
		[ $# -ge 2 ] && [ -n "$2" ] || fail '--tag needs a tag'
		tag=$2
		shift 2
		;;
	--version)
		[ $# -ge 2 ] && [ -n "$2" ] || fail '--version needs a version'
		version=$2
		shift 2
		;;
	--ad-hoc-without-secrets)
		ad_hoc_without_secrets=yes
		shift
		;;
	*)
		printf '%s\n' "$usage" >&2
		exit 2
		;;
	esac
done
if [ -n "$tag" ] && [ -n "$version" ]; then
	printf '%s\n' "$usage" >&2
	exit 2
fi

present=()
missing=()
for name in "${secrets[@]}"; do
	if [ -n "${!name:-}" ]; then present+=("$name"); else missing+=("$name"); fi
done
if [ ${#missing[@]} -eq 0 ]; then
	signing=developer-id
elif [ ${#present[@]} -eq 0 ] && [ $ad_hoc_without_secrets = yes ]; then
	signing=ad-hoc
elif [ ${#present[@]} -eq 0 ]; then
	fail "none of the signing variables is set (${secrets[*]}); on the maintainer's Mac, run secret env apple first"
else
	fail "these signing variables aren't set: ${missing[*]}"
fi

[ -z "$(git status --porcelain)" ] || fail 'the tree has changes; a release is built from a commit as it is'
# What make is told: a tag as RELEASE_TAG, which the Makefile takes as the version once it has checked the tag is
# on this commit; anything else as VERSION.
if [ -n "$tag" ]; then
	version=$tag
	version_args=(RELEASE_TAG="$tag")
else
	version=${version:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}
	version_args=(VERSION="$version")
fi
dmg=build/Fudge-${version#v}.dmg

# Each value of the five, and the identity's name once it's known, as *** in what's shown.
identity_name=
redact() {
	local text name
	text=$(cat)
	for name in "${secrets[@]}"; do
		[ -z "${!name:-}" ] || text=${text//"${!name}"/***}
	done
	[ -z "$identity_name" ] || text=${text//"$identity_name"/***}
	printf '%s\n' "$text"
}

# What the build runs gets none of the five.
without_secrets=(env)
for name in "${secrets[@]}"; do without_secrets+=(-u "$name"); done

say_outcome() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		printf 'signing=%s\ndmg=%s\n' "$signing" "$dmg" >>"$GITHUB_OUTPUT"
	fi
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s: %s\n' "${dmg##*/}" "$1" >>"$GITHUB_STEP_SUMMARY"
	fi
	printf '→ built %s: %s\n' "$dmg" "$1"
}

"${without_secrets[@]}" make --no-print-directory app CONFIG=release SIGN_IDENTITY=- "${version_args[@]}"

if [ $signing = ad-hoc ]; then
	"${without_secrets[@]}" make --no-print-directory dmg-image "${version_args[@]}"
	[ -z "${GITHUB_ACTIONS:-}" ] ||
		printf '::warning::No signing secrets, so this build is signed ad hoc and not notarized\n'
	say_outcome 'signed ad hoc and not notarized, since none of the signing variables is set'
	exit 0
fi

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fudge-release.XXXXXX")
keychain=$work/signing.keychain-db
keychain_made=no
cleanup() {
	[ $keychain_made = no ] || security delete-keychain "$keychain" >/dev/null 2>&1 || true
	[ -z "$work" ] || rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# The keychain, with a random password nobody sees, locked again after six hours (a CI job's longest).
keychain_password=$(openssl rand -hex 24)
security create-keychain -p "$keychain_password" "$keychain"
keychain_made=yes
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
(umask 077 && printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode >"$work/certificate.p12") 2>/dev/null ||
	fail "APPLE_CERTIFICATE_BASE64 isn't base64"
# -x: the private key can't be exported again. Only codesign may use it, without asking (the partition list), and
# that command's output lists the key's attributes, its name among them, so it's never shown.
if ! out=$(security import "$work/certificate.p12" -k "$keychain" -f pkcs12 -P "$APPLE_CERTIFICATE_PASSWORD" \
	-T /usr/bin/codesign -x 2>&1); then
	redact <<<"$out" >&2
	fail "couldn't import APPLE_CERTIFICATE_BASE64 with APPLE_CERTIFICATE_PASSWORD (see above)"
fi
rm -f -- "$work/certificate.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" \
	>/dev/null 2>&1 || fail "couldn't let codesign use the certificate's key"

# codesign finds an identity only through the search list. Deleting the keychain takes it out again.
search_list=()
while IFS= read -r entry; do
	entry=${entry#"${entry%%[![:space:]]*}"}
	entry=${entry#\"}
	entry=${entry%\"}
	[ -z "$entry" ] || search_list+=("$entry")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" ${search_list[@]+"${search_list[@]}"}

identity_line=$(security find-identity -v -p codesigning "$keychain" | grep -m 1 '"Developer ID Application: ' || true)
identity=$(awk '{ print $2 }' <<<"$identity_line")
identity_name=$(sed -e 's/^[^"]*"//' -e 's/"[^"]*$//' <<<"$identity_line")
[ -n "$identity" ] && [ -n "$identity_name" ] ||
	fail 'APPLE_CERTIFICATE_BASE64 has no valid Developer ID Application identity'

# notarytool keeps the account in the same keychain, and reads it from there for each submission.
profile=fudge-release
if ! out=$(xcrun notarytool store-credentials "$profile" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
	--password "$APPLE_APP_SPECIFIC_PASSWORD" --keychain "$keychain" --validate 2>&1); then
	redact <<<"$out" >&2
	fail "Apple didn't accept APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID (see above)"
fi

json_field() {
	plutil -extract "$1" raw -o - - 2>/dev/null || true
}

notarize() {
	local file=$1 out status id
	out=$(xcrun notarytool submit "$file" --keychain-profile "$profile" --keychain "$keychain" --wait --timeout 1h \
		--output-format json 2>"$work/notarytool.log") || true
	status=$(json_field status <<<"$out")
	id=$(json_field id <<<"$out")
	if [ "$status" != Accepted ]; then
		{ printf '%s\n' "$out"; cat "$work/notarytool.log"; } | redact >&2
		# Apple's log says what it refused, file by file.
		if [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" --keychain "$keychain" \
			"$work/notarization.json" >/dev/null 2>&1; then
			redact <"$work/notarization.json" >&2
		fi
		fail "notarizing ${file##*/} ended ${status:-without a status}${id:+ (submission $id)}"
	fi
	printf '→ notarized %s (submission %s)\n' "${file##*/}" "$id"
}

staple() {
	local out
	if ! out=$(xcrun stapler staple "$1" 2>&1) || ! out=$(xcrun stapler validate "$1" 2>&1); then
		redact <<<"$out" >&2
		fail "couldn't staple ${1##*/}"
	fi
	printf '→ stapled %s\n' "${1##*/}"
}

# Gatekeeper's verdict, as a downloaded copy gets it: notarized. Its origin line names the identity, so it's never
# shown. Where Gatekeeper is off (a CI runner may have it off), it says so and accepts anything, so that's only noted.
assess() {
	local out source
	if ! out=$(spctl --assess -v "$@" 2>&1); then
		grep -v '^origin=' <<<"$out" | redact >&2
		fail "Gatekeeper refuses ${*: -1}"
	fi
	case $out in
	*'override=security disabled'*)
		printf '→ Gatekeeper is off here, so it accepts %s unchecked; its ticket is stapled\n' "${*: -1}"
		;;
	*)
		source=$(sed -n 's/^source=//p' <<<"$out")
		[ "$source" = 'Notarized Developer ID' ] ||
			fail "Gatekeeper accepts ${*: -1} as ${source:-something unknown}, not as notarized"
		printf '→ Gatekeeper accepts %s: %s\n' "${*: -1}" "$source"
		;;
	esac
}

# Both signings take the identity from this keychain alone, so a Mac that also has the Developer ID in its login
# keychain (`make release`) neither finds it twice nor asks for that key's password.
signed=$("${without_secrets[@]}" scripts/sign-app.sh "$app" "$identity" "$keychain")
printf '→ signed %s %s, hardened runtime\n' "$app" "$signed"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$work/Fudge.zip"
notarize "$work/Fudge.zip"
staple "$app"

"${without_secrets[@]}" make --no-print-directory dmg-image "${version_args[@]}"
if ! out=$(codesign --force --timestamp --keychain "$keychain" --sign "$identity" "$dmg" 2>&1); then
	redact <<<"$out" >&2
	fail "couldn't sign $dmg"
fi
notarize "$dmg"
staple "$dmg"

assess --type execute "$app"
assess --type open --context context:primary-signature "$dmg"
say_outcome 'signed with Developer ID, notarized and stapled'
