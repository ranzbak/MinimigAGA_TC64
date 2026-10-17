#!/bin/bash
# bin2hex.sh <in.bin> <out.hex>
# One 32-bit big-endian word per line (8 hex digits), file byte i in lane i:
# the romgen order.  od prints the bytes in file order, four per line; a short
# last line is padded with 00 so every byte keeps its lane.  "-" as <in.bin>
# reads stdin, "-" as <out.hex> writes stdout.
set -eu
if [ "$#" -ne 2 ]; then
	echo "usage: bin2hex.sh <in.bin> <out.hex>" >&2
	exit 2
fi
in=$1
out=$2
[ "$in" = "-" ] || [ -r "$in" ] || { echo "bin2hex.sh: cannot read $in" >&2; exit 1; }
words() {
	od -An -v -tx1 -w4 "$1" | awk '{ printf "%s%s%s%s\n", $1, ($2 == "" ? "00" : $2), ($3 == "" ? "00" : $3), ($4 == "" ? "00" : $4) }'
}
if [ "$out" = "-" ]; then
	words "$in"
else
	tmp=$(mktemp "$out.XXXXXX")
	trap 'rm -f "$tmp"' EXIT
	words "$in" > "$tmp"
	mv "$tmp" "$out"
	trap - EXIT
fi
