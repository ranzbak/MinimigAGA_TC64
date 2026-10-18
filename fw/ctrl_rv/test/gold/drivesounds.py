#!/usr/bin/env python3
"""drivesounds.py <dir> <drivesnd.bin>: the 832's drive sound ring, for drivesounds_test (Task 14).

The audio ring the 832 firmware fills (fw/ctrl_832/drivesounds.c) for a fixed
sequence of events, computed here from the file format and from the 832's
behaviour, stated below -- not from fw/ctrl_rv/drivesounds.c.

The file (sw/mkdrivesounds/mkdrivesounds.c writes it):
    "DRIVESND", then per sound a big-endian 32-bit id and a big-endian 32-bit
    byte size and that many bytes of signed 16-bit big-endian samples (the
    gain is applied there), then id 0 / size 0.  The 832 loads it in front of
    AUDIO_BUFFER (the ring), reads id and size as 32-bit longs and stops at
    size 0 or at an id >= 13; sound <id> starts after its header, length =
    size / 2 samples.

The ring: AUDIO_BUFFER, 0x8000 stereo frames of 4 bytes (64 KB).  The 832's
render arithmetic per frame: c = the sum of the active sources' samples (one
to three, int), c = ((c & 255) << 8) | ((c >> 8) & 255), then c * 0x10001
stored as a big-endian long.  The bytes in the ring are therefore, for the
low 16 bits of the sum: lo, hi, lo, hi (little-endian 16-bit, both channels).

The state machine (drivesounds_queueevent/_start/_fill/_render, pickstep,
countstep, finishsound), as the 832 executes it:
  - queueevent: only when enabled != 0; starts the player first when it is
    not active (active = 1, silence = 0, timestamp = TIMER, cursor = 0);
    queues (type, TIMER) in a 16-entry ring.
  - fill: if the CD audio player is busy, the queue is dropped and 0 returned.
    Else, when enabled and active: for each queued event in order: a
    MOTORSTART while MOTORSTOP plays cancels the stop (LOOP chains to itself,
    STOP off, LOOP on); render up to the event's time; the cursor of sound
    <type> = 0 (the event's own type, before any step pick); then
      MOTORSTART (floppy on): LOOP chains to LOOP; if LOOP is not playing,
                 START chains to LOOP and plays
      MOTORSTOP  (floppy on): LOOP chains to STOP
      STEP       (floppy on): STEP + pickstep(1) plays, no chain
      HDDSTEP    (hdd on, fewer than 3 HDD steps playing): HDDSTEP +
                 pickstep(2) plays, no chain
      others     (floppy on): the sound plays, no chain
    then render up to TIMER; return active.
  - pickstep(max, type): (its "count" is read before it is set; the scenarios
    keep the number of playing steps of the type <= max at every pick, where
    the result does not depend on that value: asserted here) step = TIMER & 3,
    then the next one that is not playing.
  - render(ts): not loaded: timestamp = ts only.  n = ts - timestamp (+65536
    when negative), at most 127, times 256 frames.  While n: the first three
    playing sounds by index are the sources, every playing sound after the
    third is switched off (cursor kept); span = n, at most the frames to the
    ring's end and each source's samples left; the ring cursor advances
    span frames (mod 0x8000 frames); n -= span.  With sources: silence = 0,
    each source's cursor += span, the frames written unless AUDIO bit 1 (the
    Amiga owns the ring) reads set, then each finished source (cursor >=
    length) stops, cursor 0, and its chain (if not 0) starts at 0.  Without:
    silence += span, zeros written (same AUDIO rule).  After the loop:
    silence >= 0x8000 frames: AUDIO = 2 (stop), active = 0; else, when
    active and the cursor is in the ring's second half: AUDIO = 1 (start).
    timestamp = ts.
  - init resets in, out, loaded, cursor, active, playing, enabled (not the
    sounds' state, not timestamp or silence).

The mock's AUDIO is one variable (a write is what the next read returns); on
the board a read is {Amiga owns, buffer half}, independent of the writes.  The
scenarios set the read value explicitly (op "audio") after every stop, and it
is asserted here that no render reads a value the firmware wrote.

Written into <dir>:
  SYNTH.BIN      a DRIVESND file of 13 short sounds of pseudo-random full-range
                 samples (sums of three wrap, negative sums), sizes multiples
                 of 8 bytes: it loads at an 8-byte aligned address, so a
                 32/64-bit header load is aligned there and the wrong value it
                 gives is reported by the test, not by the sanitizer
  ring_synth.bin, ring_real.bin   the ring after every "fill" op, 64 KB each
  dscases.h      the two cases: the op lists ({op, a, name, b, return value,
                 AUDIO}: the expected return value of the load and of each
                 fill, the AUDIO value after each fill), the lines each load
                 prints ("Audio file - length <n>", "Sound <id> length
                 <bytes>": the firmware's line without the address)
python3 -I, standard library only.
"""
import os
import struct
import sys

COUNT = 13
INSERT, EJECT, MSTART, MLOOP, MSTOP, STEP, STEP2, STEP3, STEP4, HDDSTEP = range(10)
FLOPPY, HDD = 1, 2
RING_BYTES = 0x10000

NAMES = ["INSERT", "EJECT", "MOTORSTART", "MOTORLOOP", "MOTORSTOP", "STEP", "STEP2",
         "STEP3", "STEP4", "HDDSTEP", "HDDSTEP2", "HDDSTEP3", "HDDSTEP4"]


def parse(data):
    """The sounds of a DRIVESND file: {id: [signed samples]} and the lines the
    load prints (its length, then id and byte size of each sound)."""
    assert data[:8] == b"DRIVESND", "bad signature"
    o = 8
    sounds, lines = {}, ["Audio file - length %d" % len(data)]
    while True:
        sid, size = struct.unpack(">ii", data[o:o + 8])
        o += 8
        if size == 0 or sid >= COUNT:
            break
        lines.append("Sound %d length %d" % (sid, size))
        sounds[sid] = list(struct.unpack(">%dh" % (size // 2), data[o:o + size // 2 * 2]))
        o += size
    return sounds, lines


def synth_file():
    """13 sounds; sizes multiples of 8 bytes.  Sound 0 is 64 KB: read as a
    native long its size would be 0x100 (LE) and the "next header" there is
    samples 128-131 = 0x4000 (an id >= 13 either way): the loop ends inside
    the file."""
    sizes = [0x10000, 2048, 1600, 2400, 1200, 800, 816, 832, 848, 400, 416, 432, 448]
    out = [b"DRIVESND"]
    x = 12345
    for sid, size in enumerate(sizes):
        out.append(struct.pack(">II", sid, size))
        smp = []
        for k in range(size // 2):
            x = (x * 1103515245 + 12345) & 0x7FFFFFFF
            v = (x >> 8) & 0xFFFF
            if k % 97 == 0:
                v = (0x7FFF, 0x8000, 0xFFFF, 0x0001)[(k // 97) % 4]
            smp.append(v - 0x10000 if v & 0x8000 else v)
        if sid == 0:
            smp[128:132] = [0x4000] * 4
        out.append(struct.pack(">%dh" % len(smp), *smp))
    out.append(struct.pack(">II", 0, 0))
    return b"".join(out)


class Sound:
    def __init__(self):
        self.samples, self.length, self.active, self.chain, self.cursor = None, 0, 0, 0, 0


class Player:
    """The 832's drive sound state (struct dseventbuffer) and the mock around it."""

    def __init__(self):
        self.inp = self.out = self.loaded = self.timestamp = self.cursor = 0
        self.silence = self.active = self.playing = self.enabled = 0
        self.events = [(0, 0)] * 16
        self.snd = [Sound() for _ in range(COUNT)]
        self.ring = bytearray(RING_BYTES)
        self.time = 0                 # the mock TIMER (step 0 during a case)
        self.audio = 0                # the mock AUDIO variable
        self.audio_by_fw = False      # its value was written by the firmware
        self.cda = 0
        self.cov = set()

    def timer(self):
        return self.time & 0xFFFF

    def audio_write(self, v):
        self.audio, self.audio_by_fw = v, True

    def audio_read(self):
        assert not (self.audio_by_fw and self.audio & 2), \
            "a render reads back the firmware's AUDIO write of %d (op audio missing)" % self.audio
        return self.audio

    def init(self, sounds):
        for i, s in enumerate(self.snd):
            assert not s.active, "sound %d still playing at init" % i
        self.inp = self.out = self.loaded = 0
        for i in range(COUNT):
            if i in sounds:
                self.snd[i].samples, self.snd[i].length = sounds[i], len(sounds[i])
        self.loaded = 1
        self.cursor = self.active = self.playing = self.enabled = 0

    def start(self):
        if self.enabled:
            self.active, self.silence, self.timestamp = 1, 0, self.timer()
            self.cursor = self.playing = 0

    def stop(self):
        self.audio_write(2)
        self.active = self.playing = 0
        self.cov.add("stop")

    def queue(self, t):
        if self.enabled:
            if not self.active:
                self.start()
            self.events[self.inp] = (t, self.timer())
            self.inp = (self.inp + 1) & 15

    def finish(self, i):
        s = self.snd[i]
        s.active, s.cursor = 0, 0
        c = s.chain
        if c:
            self.snd[c].active, self.snd[c].cursor = 1, 0
            self.cov.add("chain %s->%s" % (NAMES[i], NAMES[c]))

    def render(self, ts):
        if not self.loaded:
            self.timestamp = ts
            return
        n = ts - self.timestamp
        if n < 0:
            n += 65536
            self.cov.add("timer wrap")
        if n > 127:
            n = 127
            self.cov.add("127 ticks")
        n *= 256
        while n:
            span = n
            src = []
            for i in range(COUNT):
                if self.snd[i].active:
                    src.append(i)
                    if len(src) == 3:
                        for j in range(i + 1, COUNT):
                            if self.snd[j].active:
                                self.cov.add("fourth voice off")
                            self.snd[j].active = 0
                        break
            span = min(span, (0x8000 - self.cursor) >> 1)
            for i in src:
                span = min(span, self.snd[i].length - self.snd[i].cursor)
            assert span > 0
            frame = self.cursor >> 1
            self.cursor = (self.cursor + 2 * span) & 0x7FFF
            n -= span
            if src:
                self.silence = 0
                start = [self.snd[i].cursor for i in src]
                for i in src:
                    self.snd[i].cursor += span
                if not self.audio_read() & 2:
                    self.cov.add("%d sources" % len(src))
                    for k in range(span):
                        c = sum(self.snd[i].samples[start[m] + k] for m, i in enumerate(src))
                        lo, hi = c & 255, (c >> 8) & 255
                        self.ring[4 * (frame + k):4 * (frame + k) + 4] = bytes((lo, hi, lo, hi))
                else:
                    self.cov.add("Amiga owns the ring")
                for i in src:
                    if self.snd[i].cursor >= self.snd[i].length:
                        self.finish(i)
            else:
                self.silence += span
                if not self.audio_read() & 2:
                    self.cov.add("silence")
                    self.ring[4 * frame:4 * (frame + span)] = bytes(4 * span)
        if self.silence >= 0x8000:
            self.stop()
        elif self.active and not self.playing and self.cursor & 0x4000:
            self.audio_write(1)
            self.cov.add("audio start")
        self.timestamp = ts

    def countstep(self, t):
        return sum(1 for k in range(4) if self.snd[t + k].active)

    def pickstep(self, maxactive, t):
        assert self.countstep(t) <= maxactive, \
            "pickstep(%d, %s) with %d playing: depends on its uninitialised count" % (
                maxactive, NAMES[t], self.countstep(t))
        step = self.timer() & 3
        while self.snd[t + step].active:
            step = (step + 1) & 3
        return step

    def fill(self):
        if self.cda:
            self.out = self.inp
            self.cov.add("CD audio busy")
            return 0
        if self.enabled and self.active:
            while self.inp != self.out:
                t, ts = self.events[self.out]
                self.out = (self.out + 1) & 15
                if t == MSTART and self.snd[MSTOP].active:
                    self.snd[MLOOP].chain = MLOOP
                    self.snd[MSTOP].active = 0
                    self.snd[MLOOP].active = 1
                    self.cov.add("start cancels stop")
                self.render(ts)
                self.snd[t].cursor = 0
                fl = "on" if self.enabled & FLOPPY else "off"
                if t == MSTART:
                    self.cov.add("MOTORSTART floppy " + fl)
                    if self.enabled & FLOPPY:
                        self.snd[MLOOP].chain = MLOOP
                        if not self.snd[MLOOP].active:
                            self.snd[MSTART].chain = MLOOP
                            self.snd[MSTART].active = 1
                elif t == MSTOP:
                    self.cov.add("MOTORSTOP floppy " + fl)
                    if self.enabled & FLOPPY:
                        self.snd[MLOOP].chain = MSTOP
                elif t == STEP:
                    self.cov.add("STEP floppy " + fl)
                    if self.enabled & FLOPPY:
                        p = STEP + self.pickstep(1, STEP)
                        self.snd[p].active, self.snd[p].chain = 1, 0
                elif t == HDDSTEP:
                    if self.enabled & HDD and self.countstep(HDDSTEP) < 3:
                        p = HDDSTEP + self.pickstep(2, HDDSTEP)
                        self.snd[p].active, self.snd[p].chain = 1, 0
                        self.cov.add("HDDSTEP plays")
                    else:
                        self.cov.add("HDDSTEP dropped")
                else:
                    self.cov.add("default floppy " + fl)
                    if self.enabled & FLOPPY:
                        self.snd[t].active, self.snd[t].chain = 1, 0
            self.render(self.timer())
        return self.active


# The scenarios: (op, a, b).  init <name> <start time>; enable/disable <mask>;
# advance <ticks>; queue <type>; fill; audio <AUDIO read value>; cda <busy>.
def scenario_synth():
    return [
        ("init", "SYNTH   BIN", 100),
        ("enable", FLOPPY | HDD, 0),
        ("queue", INSERT, 0), ("fill", 0, 0),
        ("advance", 1, 0), ("queue", MSTART, 0), ("advance", 1, 0), ("queue", STEP, 0),
        ("advance", 1, 0), ("fill", 0, 0),
        ("advance", 3, 0), ("fill", 0, 0),
        ("queue", HDDSTEP, 0), ("queue", HDDSTEP, 0), ("queue", EJECT, 0),
        ("advance", 2, 0), ("fill", 0, 0),
        ("advance", 40, 0), ("fill", 0, 0),
        ("queue", MSTOP, 0), ("advance", 70, 0), ("fill", 0, 0),
        ("advance", 127, 0), ("fill", 0, 0),
        ("advance", 127, 0), ("fill", 0, 0),
        ("audio", 0, 0),
        ("advance", 10, 0), ("fill", 0, 0),
    ]


def scenario_real():
    return [
        ("init", "DRIVESNDBIN", 65450),
        ("enable", FLOPPY | HDD, 0),
        ("queue", INSERT, 0), ("fill", 0, 0),
        ("advance", 10, 0), ("fill", 0, 0),
        ("queue", MSTART, 0), ("advance", 5, 0), ("queue", STEP, 0), ("advance", 3, 0), ("fill", 0, 0),
        ("advance", 2, 0), ("queue", STEP, 0),
        ("queue", HDDSTEP, 0), ("queue", HDDSTEP, 0), ("queue", HDDSTEP, 0), ("queue", HDDSTEP, 0),
        ("advance", 2, 0), ("fill", 0, 0),
        ("advance", 60, 0), ("fill", 0, 0),
        ("advance", 20, 0), ("fill", 0, 0),
        ("advance", 200, 0), ("fill", 0, 0),
        ("queue", HDDSTEP, 0), ("advance", 3, 0), ("queue", HDDSTEP, 0), ("advance", 1, 0),
        ("queue", HDDSTEP, 0), ("advance", 1, 0), ("queue", HDDSTEP, 0), ("advance", 1, 0), ("fill", 0, 0),
        ("queue", MSTOP, 0), ("advance", 30, 0), ("fill", 0, 0),
        ("advance", 40, 0), ("fill", 0, 0),
        ("queue", MSTART, 0), ("advance", 10, 0), ("fill", 0, 0),
        ("queue", EJECT, 0), ("advance", 10, 0), ("fill", 0, 0),
        ("audio", 2, 0), ("advance", 10, 0), ("fill", 0, 0), ("audio", 0, 0),
        ("queue", STEP, 0), ("cda", 1, 0), ("advance", 5, 0), ("fill", 0, 0), ("cda", 0, 0),
        ("advance", 5, 0), ("fill", 0, 0),
        ("disable", FLOPPY, 0),
        ("queue", MSTOP, 0), ("queue", STEP, 0), ("queue", INSERT, 0), ("queue", MSTART, 0),
        ("queue", HDDSTEP, 0), ("advance", 8, 0), ("fill", 0, 0),
        ("advance", 30, 0), ("fill", 0, 0),
        ("enable", FLOPPY, 0), ("queue", MSTOP, 0), ("advance", 100, 0), ("fill", 0, 0),
        ("advance", 80, 0), ("fill", 0, 0),
        ("disable", FLOPPY, 0), ("queue", MSTART, 0), ("advance", 5, 0), ("fill", 0, 0),
        ("enable", FLOPPY, 0),
        ("advance", 127, 0), ("fill", 0, 0),
        ("advance", 127, 0), ("fill", 0, 0),
        ("advance", 127, 0), ("fill", 0, 0),
        ("audio", 0, 0),
        ("queue", INSERT, 0), ("advance", 10, 0), ("fill", 0, 0),
    ]


OPS = {"init": "DS_INIT", "enable": "DS_ENABLE", "disable": "DS_DISABLE", "advance": "DS_ADVANCE",
       "queue": "DS_QUEUE", "fill": "DS_FILL", "audio": "DS_AUDIO", "cda": "DS_CDA"}

# what each case must reach (the scenarios are written for these)
COVER_SYNTH = {"1 sources", "2 sources", "3 sources", "fourth voice off", "chain MOTORSTART->MOTORLOOP",
               "chain MOTORLOOP->MOTORSTOP", "silence", "stop", "audio start"}
COVER_REAL = {"1 sources", "2 sources", "3 sources", "fourth voice off", "silence", "stop",
              "audio start", "timer wrap", "127 ticks", "chain MOTORSTART->MOTORLOOP",
              "chain MOTORLOOP->MOTORLOOP", "chain MOTORLOOP->MOTORSTOP", "start cancels stop",
              "Amiga owns the ring", "CD audio busy", "HDDSTEP plays", "HDDSTEP dropped",
              "MOTORSTART floppy on", "MOTORSTART floppy off", "MOTORSTOP floppy on",
              "MOTORSTOP floppy off", "STEP floppy on", "STEP floppy off",
              "default floppy on", "default floppy off"}


def run(p, name, ops, files, d):
    rows, snaps = [], []
    for op, a, b in ops:
        want_ret = want_audio = 0
        if op == "init":
            sounds, lines = files[a]
            p.init(sounds)
            p.time = b
            want_ret = 1 if sounds else 0
            arg, cname = 0, '"%s"' % a
        else:
            arg, cname = a, "NULL"
            if op == "enable":
                p.enabled |= a
            elif op == "disable":
                p.enabled &= ~a
                assert p.enabled, "drivesounds_disable to 0 (audio_stop) is not in the scenarios"
            elif op == "advance":
                p.time += a
            elif op == "queue":
                p.queue(a)
            elif op == "audio":
                p.audio, p.audio_by_fw = a, False
            elif op == "cda":
                p.cda = a
            elif op == "fill":
                want_ret = p.fill()
                want_audio = p.audio
                snaps.append(bytes(p.ring))
        rows.append("\t{ %s, %d, %s, %d, %d, %d },\n" % (OPS[op], arg, cname, b, want_ret, want_audio))
    with open(os.path.join(d, "ring_%s.bin" % name), "wb") as f:
        f.write(b"".join(snaps))
    return rows, len(snaps)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: drivesounds.py <dir> <drivesnd.bin>")
    d, real = sys.argv[1], sys.argv[2]
    os.makedirs(d, exist_ok=True)
    synth = synth_file()
    with open(os.path.join(d, "SYNTH.BIN"), "wb") as f:
        f.write(synth)
    with open(real, "rb") as f:
        files = {"SYNTH   BIN": parse(synth), "DRIVESNDBIN": parse(f.read())}
    p = Player()
    out = ["/* generated by gold/drivesounds.py: the 832's drive sound ring */\n"]
    for name, ops, cover in (("synth", scenario_synth(), COVER_SYNTH), ("real", scenario_real(), COVER_REAL)):
        p.cov = set()
        rows, nsnap = run(p, name, ops, files, d)
        missing = cover - p.cov
        assert not missing, "%s: the scenario does not reach %s" % (name, sorted(missing))
        out.append("static const struct ds_op ds_ops_%s[] = {\n%s};\n" % (name, "".join(rows)))
        out.append("#define DS_SNAPS_%s %d\n" % (name.upper(), nsnap))
        lines = files[ops[0][1]][1]
        out.append("static const char ds_lines_%s[] =\n%s;\n"
                   % (name, "\n".join('\t"%s\\n"' % l for l in lines)))
    with open(os.path.join(d, "dscases.h"), "w") as f:
        f.write("".join(out))


if __name__ == "__main__":
    main()
