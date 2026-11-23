#!/usr/bin/env bash
# Opens a pull request into development with the place files update.sh rebuilt (SPEC-162).
#
#   scripts/geonames/open-pull-request.sh
#
# The "Update GeoNames database" workflow runs it after update.sh, with GH_TOKEN set to the workflow's own token.
# When neither places.tsv nor countries.tsv changed, it says so and stops: a new SOURCE alone isn't an update.
# Otherwise it commits runtime/vendor/geonames/ as github-actions[bot] on the branch geonames/<UTC date>-<run number>,
# pushes it, and opens the pull request with the old and new row counts and the town list's sha256 in its body.
# When GitHub refuses the pull request (the repository doesn't let workflows open them), it prints the branch's
# compare link instead, so the pull request can be opened by hand, and still succeeds.
set -euo pipefail

cd "$(dirname "$0")/../.."
folder=runtime/vendor/geonames

if git diff --quiet HEAD -- "$folder/places.tsv" "$folder/countries.tsv"; then
	echo "GeoNames' town list gives the same place files as before, so there's no pull request."
	exit 0
fi

# Rows in the committed file (none when it isn't committed yet) and in the rebuilt one.
committed_rows() {
	{ git show "HEAD:$folder/$1" 2>/dev/null || true; } | wc -l | tr -d ' '
}
rows() {
	wc -l <"$folder/$1" | tr -d ' '
}

date=$(date -u +%Y-%m-%d)
branch=geonames/$date-${GITHUB_RUN_NUMBER:?is set by the Update GeoNames database workflow, which runs this}
zip_sha=$(grep -A 1 '^url: .*/cities15000\.zip$' "$folder/SOURCE" | sed -n 's/^sha256: //p')
body=$(
	echo "Made by the \"Update GeoNames database\" workflow from GeoNames' files of $date."
	echo
	echo "- \`places.tsv\`: $(committed_rows places.tsv) towns before, $(rows places.tsv) now."
	echo "- \`countries.tsv\`: $(committed_rows countries.tsv) countries before, $(rows countries.tsv) now."
	echo "- \`cities15000.zip\`: sha256 \`$zip_sha\`."
	echo
	echo "\`runtime/vendor/geonames/SOURCE\` lists every file it was made from."
)

git switch --create "$branch"
git add -- "$folder"
git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
	commit --quiet --message "chore(data): update the calculator's places from GeoNames ($date)"
git push --quiet origin "$branch"
title="Update the calculator's places from GeoNames ($date)"
if ! gh pr create --base development --head "$branch" --title "$title" --body "$body"; then
	compare="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:?}/compare/development...$branch?expand=1"
	echo "::notice::GitHub didn't open the pull request, so open it by hand: $compare"
fi
