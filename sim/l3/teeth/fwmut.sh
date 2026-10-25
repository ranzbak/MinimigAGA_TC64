#!/bin/bash
# A firmware run copy for a tooth: the tracked files of fw/ctrl copied to
# <dir>/ctrl, one sed applied to one file (it must change exactly one
# line), built under run.sh's date shim into <dir>/fwrv/RV32OSDB.BIN (the
# name: fw/ctrl/fwname.mk, hostsim.sh hs_fwname).
#   bash sim/l3/teeth/fwmut.sh <dir> <file in fw/ctrl> <sed expression>
# With an empty sed expression the copy is built unchanged: its image must
# equal a default run's (the copy procedure reproduces the tree's build).
# Teeth (c) fdd.c and (f) cdaudio.c: sim/l3/README.md "Teeth (Task 19)".
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
ROOT=$root
# shellcheck source=../../common/hostsim.sh
. "$root/sim/common/hostsim.sh"     # hs_fwname
fw=$(hs_fwname)
dir=$(realpath -m -- "$1") file=$2 expr=$3
mkdir -p "$dir/ctrl" "$dir/fwrv" "$dir/dateshim"
git -C "$root" ls-files fw/ctrl | while IFS= read -r f; do
	mkdir -p "$dir/ctrl/$(dirname "${f#fw/ctrl/}")"
	cp "$root/$f" "$dir/ctrl/${f#fw/ctrl/}"
done
if [ -n "$expr" ]; then
	sed -i "$expr" "$dir/ctrl/$file"
	n=$(diff "$root/fw/ctrl/$file" "$dir/ctrl/$file" | grep -c '^>' || true)
	[ "$n" = 1 ] || { echo "fwmut: the sed changed $n lines of $file (want 1)"; exit 1; }
	diff "$root/fw/ctrl/$file" "$dir/ctrl/$file" || true
fi
printf '%s\n' '#!/bin/sh' 'TZ=UTC exec /bin/date -d "${L3_DATE:-2026-01-01} 00:00:00" "$@"' > "$dir/dateshim/date"
chmod +x "$dir/dateshim/date"
PATH="$dir/dateshim:$PATH" make -s -C "$dir/ctrl" TOP="$root" B="$dir/fwrv" > "$dir/make.log" 2>&1 \
	|| { tail -20 "$dir/make.log"; exit 1; }
echo "fwmut: $dir/fwrv/$fw, sha256 $(sha256sum "$dir/fwrv/$fw" | cut -c1-16)"
