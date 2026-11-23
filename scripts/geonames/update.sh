#!/usr/bin/env bash
# Rebuilds the calculator's place files in runtime/vendor/geonames/ from GeoNames' town list (SPEC-162).
#
#   scripts/geonames/update.sh [<folder>]
#
# Without a folder it downloads cities15000.zip and countryInfo.txt from GeoNames with `curl --fail`, keeping each
# response's headers. With one, it takes both files from that folder instead, each with its headers beside it as
# <file>.headers (what `curl --dump-header` writes), so files downloaded earlier give the same result.
#
# Either way it unzips the town list and runs make-places.py. It fails if places.tsv has fewer than 30,000 rows or
# countries.tsv fewer than 240, leaving runtime/vendor/geonames/ as it was, so a broken download never replaces the
# list. Otherwise it puts both files there, with SOURCE: each file's address, sha256, Last-Modified and download date.
#
# The "Update GeoNames database" workflow runs it, followed by open-pull-request.sh. Builds never run it: the app
# ships the committed files and never goes online for them.
set -euo pipefail

base=https://download.geonames.org/export/dump
files="cities15000.zip countryInfo.txt"
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$root/runtime/vendor/geonames

if [ "$#" -gt 1 ]; then
	echo "usage: scripts/geonames/update.sh [<folder with cities15000.zip and countryInfo.txt>]" >&2
	exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ "$#" -eq 1 ]; then
	for file in $files; do
		for path in "$1/$file" "$1/$file.headers"; do
			if [ ! -f "$path" ]; then
				echo "$path is missing" >&2
				exit 1
			fi
		done
		cp "$1/$file" "$1/$file.headers" "$work/"
	done
else
	for file in $files; do
		curl --fail --silent --show-error --location --retry 3 --dump-header "$work/$file.headers" \
			--output "$work/$file" "$base/$file"
	done
fi

sha256() {
	if command -v sha256sum >/dev/null; then
		sha256sum "$1" | cut -d ' ' -f 1
	else
		shasum -a 256 "$1" | cut -d ' ' -f 1
	fi
}

# A header's value from the last response in the file (after any redirect), without the line's carriage return.
header() {
	grep -i "^$1:" "$2" | tail -n 1 | cut -d ' ' -f 2- | tr -d '\r'
}

unzip -q -o "$work/cities15000.zip" cities15000.txt -d "$work"
python3 -I "$root/scripts/geonames/make-places.py" "$work/cities15000.txt" "$work/countryInfo.txt" "$work/made"

places=$(wc -l <"$work/made/places.tsv" | tr -d ' ')
countries=$(wc -l <"$work/made/countries.tsv" | tr -d ' ')
if [ "$places" -lt 30000 ] || [ "$countries" -lt 240 ]; then
	echo "Only $places towns and $countries countries: GeoNames' files look incomplete, so this isn't an update." >&2
	exit 1
fi

mkdir -p "$out"
cp "$work/made/places.tsv" "$work/made/countries.tsv" "$out/"
{
	echo "The GeoNames files that places.tsv and countries.tsv were made from, by scripts/geonames/update.sh."
	for file in $files; do
		echo
		echo "url: $base/$file"
		echo "sha256: $(sha256 "$work/$file")"
		echo "last-modified: $(header last-modified "$work/$file.headers")"
		echo "downloaded: $(header date "$work/$file.headers")"
	done
} >"$out/SOURCE"
echo "runtime/vendor/geonames/: $places towns and $countries countries"
