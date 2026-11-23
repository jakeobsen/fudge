#!/usr/bin/env python3
"""Writes the calculator's place files (SPEC-162) from GeoNames' town list and country names.

    scripts/geonames/make-places.py <cities15000.txt> <countryInfo.txt> <folder>

`scripts/geonames/update.sh` runs it. It writes two UTF-8 files into <folder>, one record per line, tab-separated:

    places.tsv      name, ASCII name (empty when it's the name), country code, population, IANA time zone, and the
                    alternate names written in Latin letters with a capital, joined by "|"
    countries.tsv   ISO country code, English name

places.tsv is sorted by country code, ASCII name and GeoNames id, countries.tsv by code, both compared as bytes. No
Unicode tables are used (no folding, normalization or unicodedata): names are kept as GeoNames writes them, and the
alternate-name filter looks only at code point ranges and ASCII capitals. So the same download gives the same bytes on
any Python 3. Fudge folds names itself when it loads the files.

A name holding an em dash is left out, and a town whose own name holds one is left out entirely: Fudge never shows one.
"""

import os
import sys

EM_DASH = "\u2014"

# Latin letters and combining marks, by code point range (fixed here, not read from unicodedata).
LATIN = [(0x00C0, 0x024F), (0x1E00, 0x1EFF), (0x0300, 0x036F), (0x2C60, 0x2C7F), (0xA720, 0xA7FF)]
ASCII_ALLOWED = set(" -'.()&/")


def latin_only(name):
    """Whether every character is an ASCII letter, digit or name punctuation, or a Latin letter or mark."""
    for character in name:
        point = ord(character)
        if point < 0x80:
            if not (character.isalnum() or character in ASCII_ALLOWED):
                return False
        elif point in (0x00D7, 0x00F7) or not any(low <= point <= high for low, high in LATIN):
            return False
    return True


def has_capital(name):
    """An ASCII capital or a Latin-1 one (À to Þ): GeoNames' own transliterations are all lower case."""
    return any("A" <= character <= "Z" or 0x00C0 <= ord(character) <= 0x00DE for character in name)


def places(path):
    rows = []
    with open(path, encoding="utf-8") as file:
        for line in file:
            columns = line.rstrip("\n").split("\t")
            if len(columns) != 19:
                raise SystemExit(f"{path}: a line has {len(columns)} columns, not 19: {line[:80]!r}")
            geonameid, name, ascii_name, alternates = columns[0], columns[1], columns[2], columns[3]
            country, population, zone = columns[8], columns[14], columns[17]
            if not name or not country or not zone or EM_DASH in name or EM_DASH in ascii_name:
                continue
            for text in (name, ascii_name):
                if "\t" in text or "|" in text:
                    raise SystemExit(f"{path}: GeoNames row {geonameid} has a tab or a | in its name")
            seen = {name, ascii_name}
            kept = []
            for alternate in alternates.split(",") if alternates else []:
                alternate = alternate.strip()
                if (
                    not alternate
                    or alternate in seen
                    or "|" in alternate
                    or EM_DASH in alternate
                    or not latin_only(alternate)
                    or not has_capital(alternate)
                ):
                    continue
                seen.add(alternate)
                kept.append(alternate)
            fields = [name, "" if ascii_name == name else ascii_name, country, str(int(population or 0)), zone]
            rows.append(((country.encode(), ascii_name.encode(), int(geonameid)), fields + ["|".join(kept)]))
    rows.sort(key=lambda row: row[0])
    return ["\t".join(fields) for _, fields in rows]


def countries(path):
    rows = []
    with open(path, encoding="utf-8") as file:
        for line in file:
            if line.startswith("#") or not line.strip():
                continue
            columns = line.rstrip("\n").split("\t")
            code, name = columns[0], columns[4]
            if not code or not name or EM_DASH in name:
                continue
            rows.append((code.encode(), f"{code}\t{name}"))
    rows.sort()
    return [text for _, text in rows]


def write(path, lines):
    with open(path, "wb") as file:
        file.write(("\n".join(lines) + "\n").encode("utf-8"))


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: make-places.py <cities15000.txt> <countryInfo.txt> <folder>")
    cities_path, countries_path, folder = sys.argv[1:]
    os.makedirs(folder, exist_ok=True)
    town_lines = places(cities_path)
    country_lines = countries(countries_path)
    write(os.path.join(folder, "places.tsv"), town_lines)
    write(os.path.join(folder, "countries.tsv"), country_lines)
    print(f"places.tsv: {len(town_lines)} towns; countries.tsv: {len(country_lines)} countries")


if __name__ == "__main__":
    main()
