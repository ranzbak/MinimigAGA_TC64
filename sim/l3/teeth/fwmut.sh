#!/bin/bash
# A firmware run copy for a tooth: the tracked files of fw/ctrl_rv copied to
# <dir>/ctrl_rv, one sed applied to one file (it must change exactly one
# line), built under run.sh's date shim into <dir>/fwrv/RV32OSDA.BIN.
#   bash sim/l3/teeth/fwmut.sh <dir> <file in fw/ctrl_rv> <sed expression>
# With an empty sed expression the copy is built unchanged: its image must
# equal a default run's (the copy procedure reproduces the tree's build).
# Teeth (c) fdd.c and (f) cdaudio.c: sim/l3/README.md "Teeth (Task 19)".
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
dir=$(realpath -m -- "$1") file=$2 expr=$3
mkdir -p "$dir/ctrl_rv" "$dir/fwrv" "$dir/dateshim"
git -C "$root" ls-files fw/ctrl_rv | while IFS= read -r f; do
	mkdir -p "$dir/ctrl_rv/$(dirname "${f#fw/ctrl_rv/}")"
	cp "$root/$f" "$dir/ctrl_rv/${f#fw/ctrl_rv/}"
done
if [ -n "$expr" ]; then
	sed -i "$expr" "$dir/ctrl_rv/$file"
	n=$(diff "$root/fw/ctrl_rv/$file" "$dir/ctrl_rv/$file" | grep -c '^>' || true)
	[ "$n" = 1 ] || { echo "fwmut: the sed changed $n lines of $file (want 1)"; exit 1; }
	diff "$root/fw/ctrl_rv/$file" "$dir/ctrl_rv/$file" || true
fi
printf '%s\n' '#!/bin/sh' 'TZ=UTC exec /bin/date -d "${L3_DATE:-2026-01-01} 00:00:00" "$@"' > "$dir/dateshim/date"
chmod +x "$dir/dateshim/date"
PATH="$dir/dateshim:$PATH" make -s -C "$dir/ctrl_rv" TOP="$root" B="$dir/fwrv" > "$dir/make.log" 2>&1 \
	|| { tail -20 "$dir/make.log"; exit 1; }
echo "fwmut: $dir/fwrv/RV32OSDA.BIN, sha256 $(sha256sum "$dir/fwrv/RV32OSDA.BIN" | cut -c1-16)"
