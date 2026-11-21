#!/bin/bash
# Prints the version of the next release (SPEC-128 §3), worked out from the conventional commit messages since the
# last one. The release workflow tags the release commit with it, and the maintainer names it before asking for one.
#
#   scripts/next-version.sh [<commit>]    prints the version as its tag (v0.2.0), for HEAD or the commit given
#
# The last release is the highest v1.2.3 tag (no pre-release suffix) in the commit's history. Every commit since then
# that isn't a merge counts:
#   - a breaking change (`type!:`, `type(scope)!:`, or a `BREAKING CHANGE:` or `BREAKING-CHANGE:` footer) bumps the
#     major version from 1.0.0 on, and the minor version below it;
#   - otherwise, any `feat:` or `feat(scope):` bumps the minor version;
#   - otherwise (`fix`, `docs`, `chore`, anything else) the patch version.
# Without a release in the history, the next is v0.1.0. With no commits since the last release there's nothing to
# release, so it fails, as does a shallow clone, which can't see the history and its tags.
#
# A release's tag is on its release commit, which is in development, so the history of a development commit has every
# release before it, as does mainline's through each merge's second parent.
set -euo pipefail

fail() {
	printf 'scripts/next-version.sh: %s\n' "$1" >&2
	exit 1
}

[ $# -le 1 ] || {
	echo 'usage: scripts/next-version.sh [<commit>]' >&2
	exit 2
}
commit=${1:-HEAD}
[ "$(git rev-parse --is-shallow-repository)" = false ] ||
	fail "this is a shallow clone, so it can't see the releases in the history"
git rev-parse --quiet --verify "$commit^{commit}" >/dev/null || fail "$commit isn't a commit"

# The highest full release in the commit's history, by version, not by date or distance.
last=$(git tag --list 'v*' --merged "$commit" |
	grep -Ex 'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)' |
	sort -t . -k 1.2,1n -k 2,2n -k 3,3n | tail -n 1 || true)

if [ -n "$last" ]; then
	range=$last..$commit
else
	range=$commit
fi

count=0
feature=no
breaking=no
while IFS= read -r -d '' message; do
	count=$((count + 1))
	subject=${message%%$'\n'*}
	if grep -Eq '^[A-Za-z]+(\([^)]*\))?!:' <<<"$subject" || grep -Eq '^BREAKING[ -]CHANGE:' <<<"$message"; then
		breaking=yes
	elif grep -Eiq '^feat(\([^)]*\))?:' <<<"$subject"; then
		feature=yes
	fi
done < <(git log --no-merges -z --format=%B "$range")

if [ -z "$last" ]; then
	[ $count -gt 0 ] || fail "$commit has no commits to release"
	echo v0.1.0
	exit 0
fi
[ $count -gt 0 ] || fail "nothing to release: no commits since $last, other than merges"

IFS=. read -r major minor patch <<<"${last#v}"
if [ $breaking = yes ] && [ "$major" -ge 1 ]; then
	echo "v$((major + 1)).0.0"
elif [ $breaking = yes ] || [ $feature = yes ]; then
	echo "v$major.$((minor + 1)).0"
else
	echo "v$major.$minor.$((patch + 1))"
fi
