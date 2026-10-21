#!/usr/bin/env python3
"""fatlist.py <image> <byte offset>: the expected directory listing of a FAT
image, from mtools (independent of fat.c): names and sizes from
`mdir -/ -a`, start clusters from `mshowfat`.

One line per entry, every directory of the tree, "." and ".." left out
(fat_test leaves them out too), sorted:
    <dir>|<D or F>|<8.3 name, 11 characters>|<size>|<start cluster>|<long name>
<dir> is "" for the root and "/Long Dir/Sub Dir" below it; a directory's size
is 0 (as in its entry).  python3 -I, standard library only.
"""
import os
import re
import subprocess
import sys

ENTRY = re.compile(r"^(.{8}) (.{3}) +(<DIR>|\d+) +\d{4}-\d\d-\d\d +\d+:\d\d(?:  (.*\S))? *$")


def mtools(*args):
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1", TZ="UTC")
    return subprocess.run(list(args), env=env, check=True, capture_output=True, text=True).stdout


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: fatlist.py <image> <byte offset>")
    img = "%s@@%s" % (sys.argv[1], sys.argv[2])
    entries = []
    cur = None
    for line in mtools("mdir", "-/", "-a", "-i", img, "::").splitlines():
        if line.startswith("Directory for ::"):
            cur = line[len("Directory for ::"):].rstrip("/")
            continue
        m = ENTRY.match(line)
        if not m or cur is None:
            continue
        base, ext, size, lfn = m.group(1), m.group(2), m.group(3), m.group(4) or ""
        if base.rstrip() in (".", ".."):
            continue
        isdir = size == "<DIR>"
        shown = lfn if lfn else (base.rstrip() + ("." + ext.rstrip() if ext.strip() else ""))
        entries.append([cur, "D" if isdir else "F", base + ext, "0" if isdir else size, shown, lfn])
    if not entries:
        sys.exit("fatlist: no entries in the mdir output of %s" % img)
    out = []
    for cur, kind, name, size, shown, lfn in entries:
        s = mtools("mshowfat", "-i", img, "::%s/%s" % (cur, shown)).strip()
        m = re.search(r"<(\d+)", s)
        if not m:
            sys.exit("fatlist: no start cluster in mshowfat output: %r" % s)
        out.append("|".join([cur, kind, name, size, m.group(1), lfn]))
    for line in sorted(out):
        print(line)


if __name__ == "__main__":
    main()
