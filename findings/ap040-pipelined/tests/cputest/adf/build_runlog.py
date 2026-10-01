#!/usr/bin/env python3.10
"""Build cputest040_log.hdf: the full 68040 corpus plus a resumable runner that
logs to a file on the HDF itself (the Amiga serial port is not usable yet).

  :cputest              runner from cputester.7z, unmodified
  :RunLog               AmigaDOS script (s-bit), one cputest call per instruction:
                          Echo  "=== <group>/<insn>"      >>:cputest.log
                          cputest <group>/<insn> -68040   >>:cputest.log
                          Echo  "=== end <group>/<insn>"  >>:cputest.log
                        Every call reopens and closes the log, so a crash loses
                        at most the instruction that crashed.  Before it starts,
                        each instruction leaves a marker in :st/; after a crash
                        and reboot RunLog skips everything with a marker, so the
                        crashing instruction shows in the log as a "===" line
                        without its "=== end" line, and the run carries on.
  :s/startup-sequence   same script as RunLog (the bare HDF has no C:)
  :data/4_<GROUP>/...   corpus (integer groups from ../data040, FPU groups
                        from ../fpu/<GROUP>/data040 when generated)

Start over: Delete :st/#? and :cputest.log, reboot.
Read the log back on the PC:
  python3.10 -m amitools.tools.xdftool cputest040_log.hdf read cputest.log out.log

usage: build_runlog.py [OUT.hdf] [--groups g1,g2,..] [--flags "-nofpiar ..."]
  --groups  run only these runner groups (e.g. fpack,fint,fillg)
  --flags   extra cputest options on every call (e.g. --flags=-nofpiar; the = is needed)
  --only    a file of <group>/<insn> lines: run just those (the data stays whole)
"""
import argparse, os, shutil, subprocess, sys

SP = os.path.dirname(os.path.abspath(__file__))
CT = os.path.dirname(SP)
BASE = os.path.join(SP, 'cputest040_all.hdf')       # cputest + integer corpus
VOL = 'CT040ALL'
LOG = VOL + ':cputest.log'

ap = argparse.ArgumentParser()
ap.add_argument('out', nargs='?', default=os.path.join(SP, 'cputest040_log.hdf'))
ap.add_argument('--groups', default='')
ap.add_argument('--flags', default='')
ap.add_argument('--only', default='', help='file of <group>/<insn> lines (e.g. board/run1_failed.txt): run just those')
ap.add_argument('--fpu', default='fpu', help='directory (under tests/cputest) holding the FPU groups: fpu (the real 040 model, default) or fpu_u (FPU_UNIMP=1: FPSP instructions as if in hardware, NOT a real 040)')
opt = ap.parse_args()
OUT = opt.out
ONLY = {g.strip().lower() for g in opt.groups.split(',') if g.strip()}
FLAGS = (' ' + opt.flags.strip()) if opt.flags.strip() else ''
PICK = {l.strip().lower() for l in open(opt.only) if l.strip()} if opt.only else set()

# run order: (runner group name, data dir, corpus root)
INT = os.path.join(CT, 'data040')
GROUPS = [('basic', '4_BASIC', INT)]
GROUPS += [(g.lower(), '4_' + g, os.path.join(CT, opt.fpu, g, 'data040'))
           for g in ('FPACK', 'FINT', 'FBASIC', 'FILLG')]
GROUPS += [(g.lower(), '4_' + g, INT)
           for g in ('AE', 'ODDSTK', 'ODDIRQ', 'ODDEXC', 'IRQ', 'EXTDST', 'EXTSRC', 'Default')]


def xdf(*args):
    r = subprocess.run([sys.executable, '-m', 'amitools.tools.xdftool'] + list(args),
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit('xdftool failed: %s\n%s%s' % (' '.join(args), r.stdout, r.stderr))
    return r.stdout


def insns(root, gdir):
    p = os.path.join(root, gdir)
    return sorted((d for d in os.listdir(p) if os.path.isdir(os.path.join(p, d))), key=str.lower)


def main():
    shutil.copyfile(BASE, OUT)
    on_hdf = set(l.split()[0] for l in xdf(OUT, 'list', 'data').splitlines() if l.startswith('  ') and not l.startswith('   '))
    run, skipped = [], []
    cmds = []
    for gname, gdir, root in GROUPS:
        if ONLY and gname not in ONLY:
            continue
        # an FPU group still being generated has a partial (last file torn) corpus
        runtxt = os.path.join(os.path.dirname(root), 'run.txt')
        # (gen_corpus.sh prints "== done" even after the generator was killed,
        # with "exited with status" before it)
        rt = open(runtxt).read() if os.path.exists(runtxt) else ''
        unfinished = root != INT and not ('== done' in rt and 'exited with status' not in rt)
        if unfinished or not os.path.isdir(os.path.join(root, gdir)):
            skipped.append(gdir)
            continue
        if gdir not in on_hdf:
            cmds += ['+', 'makedir', 'data/' + gdir]
            for f in ('lmem.dat', 'tmem.dat'):
                cmds += ['+', 'write', os.path.join(root, gdir, f), 'data/%s/%s' % (gdir, f)]
            for i in insns(root, gdir):
                cmds += ['+', 'makedir', 'data/%s/%s' % (gdir, i),
                         '+', 'write', os.path.join(root, gdir, i, '0000.daz'), 'data/%s/%s/0000.daz' % (gdir, i)]
        lst = insns(root, gdir)
        if PICK:
            lst = [i for i in lst if ('%s/%s' % (gname, i)).lower() in PICK]
            if not lst:
                continue
        run.append((gname, lst))

    total = sum(len(l) for _, l in run)
    s = ['; RunLog: every 68040 cputest instruction, one at a time, logged to %s' % LOG,
         '; Resumable: :st/<group>.<insn> marks an instruction as started.',
         '; A "=== g/i" line without "=== end g/i" in the log = that instruction crashed.',
         '; cputest options: -68040%s' % FLAGS,
         'FailAt 1000',
         'Stack 16384',
         'If NOT EXISTS %s' % LOG,
         '  Echo >>%s "=== RunLog start: %d instructions in %d groups"' % (LOG, total, len(run)),
         'Else',
         '  Echo >>%s "=== RunLog resumed (reboot or crash)"' % LOG,
         'EndIf']
    n = 0
    for gname, lst in run:
        for i in lst:
            n += 1
            tag = '%s/%s' % (gname, i)
            mark = '%s:st/%s.%s' % (VOL, gname, i)
            s += ['If NOT EXISTS %s' % mark,
                  '  Echo >%s ""' % mark,
                  '  Echo "[%d/%d] %s"' % (n, total, tag),
                  '  Echo >>%s "=== %s"' % (LOG, tag),
                  '  %s:cputest >>%s %s -68040%s' % (VOL, LOG, tag, FLAGS),
                  '  Echo >>%s "=== end %s"' % (LOG, tag),
                  'EndIf']
    s += ['Echo >>%s "=== RunLog finished"' % LOG,
          'Echo "*N=== RunLog finished. Log: %s ==="' % LOG]
    # the bare HDF has no C:, so the boot script is RunLog itself (shell built-ins
    # only: Echo, If, Stack, FailAt); :st/ is created here, not with MakeDir
    ss = ['; MinimigAGA 68040 cputest, full corpus, logged to %s (copy of :RunLog)' % LOG,
          'Echo "*N=== cputest: %d instructions, log %s. Resumes after a reboot. ==="' % (total, LOG),
          'Echo "Start over (from a Workbench shell): Delete %s:st/#? QUIET + Delete %s"' % (VOL, LOG)] + s

    tmp = os.path.join(SP, 'stage', 'runlog')
    os.makedirs(tmp, exist_ok=True)
    open(os.path.join(tmp, 'RunLog'), 'w').write('\n'.join(s) + '\n')
    open(os.path.join(tmp, 'startup-sequence'), 'w').write('\n'.join(ss) + '\n')
    cmds += ['+', 'makedir', 'st',
             '+', 'write', os.path.join(tmp, 'RunLog'), 'RunLog',
             '+', 'protect', 'RunLog', 'rweds',
             '+', 'delete', 's/startup-sequence',
             '+', 'write', os.path.join(tmp, 'startup-sequence'), 's/startup-sequence']
    xdf(OUT, *cmds[1:])
    print(xdf(OUT, 'info').strip())
    print('%s: %d instructions; groups: %s' % (OUT, total, ' '.join('%s(%d)' % (g, len(l)) for g, l in run)))
    if skipped:
        print('not generated yet, left out: ' + ' '.join(skipped))


if __name__ == '__main__':
    main()
