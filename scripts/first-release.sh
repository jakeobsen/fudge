#!/bin/bash
# Says whether a tag is Fudge's first release (SPEC-117 §5), for the release workflow, which then gives it the
# hand-written .github/first-release-notes.md instead of GitHub's generated notes, which would list every pull request
# so far.
#
#   scripts/first-release.sh <tag>    prints first=true or first=false, for $GITHUB_OUTPUT
#
# It's the first when no full release (v1.2.3, with no pre-release suffix) other than itself is in the history of the
# commit checked out, so v0.1.0 is the first after a v0.1.0-rc.1 too. Only the whole history can tell, so a shallow
# clone fails rather than guess.
set -euo pipefail

tag=${1:?usage: scripts/first-release.sh <tag>}
if [ "$(git rev-parse --is-shallow-repository)" != false ]; then
	echo "scripts/first-release.sh: this is a shallow clone, so it can't tell whether $tag is the first release" >&2
	exit 1
fi
tags=$(git tag --list 'v*' --merged HEAD)
earlier=$(printf '%s\n' "$tags" | grep -Ex 'v[0-9]+\.[0-9]+\.[0-9]+' | grep -cvxF -e "$tag" || true)
if [ "$earlier" = 0 ]; then
	echo first=true
else
	echo first=false
fi
