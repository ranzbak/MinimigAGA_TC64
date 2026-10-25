# SD card path: baseline measurements (today's SPI path)

Plan Task 3, measured 2026-10-24 on the QMTech XC7A100T board.  Bitstream: the
board's shipping image.  Firmware: `sdio` b8a6865c (Task 1 counters, Task 2
about-screen timer, Task 1b report every 5.8 s regardless of DebugMode), build
`2026-10-24-14-19`.  UART log: `baseline-logs/ttyUSB0.log` (115200 8N1,
timestamps from the capture PC); Paul's run marks: `baseline-logs/marks.txt`.

## How

- DebugMode **off** for all runs.  A first try in DebugMode (14:06-14:08 in the
  log) showed why: DebugMode keeps the OSD open and redraws its 8 debug lines on
  every main-loop pass, and adds a `sprintf` + debug line per read command
  (`hdd.c:499`).  Idle loop rate fell from ~17,000 to ~640 passes/s.
- The firmware prints cumulative counters every 1001 TIMER counts (5,809 ms).
  A run's figures are the difference between the report before it and the
  first report after the counters stop changing.
- Each run copied the same small-files set (about 1.2 MB written, ~2,500
  sectors each way) from the card's FAT side into the HDF on the same card.
  Wall time per run was not stopwatched; the 5.8 s reports bound it at roughly
  20-35 s.  The reference for the end result stays Paul's original figure:
  **~500 MB of small files in ~1 hour (~140 KB/s)**.

## Results

| | Copy 1, OSD closed | Copy 2, menu open | Copy 3, about screen |
| --- | --- | --- | --- |
| Write commands / sectors | 95 / 2,512 | 98 / 2,519 | 82 / 2,471 |
| Write histogram 1 / 2 / 3-4 / 5-8 / 9-16 / 17-64 / 65-256 | 4 / 26 / 2 / 0 / 0 / **63** / 0 | 3 / 30 / 2 / 0 / 0 / **63** / 0 | 3 / 15 / 2 / 0 / 0 / **62** / 0 |
| Read commands / sectors | 129 / 2,547 | 100 / 2,431 | 98 / 2,427 |
| Read histogram 1 / 2 / 3-4 / 5-8 / 9-16 / 17-64 / 65-256 | 2 / 28 / 2 / 3 / 34 / 60 / 0 | 2 / 2 / 2 / 3 / 32 / 59 / 0 | 2 / 0 / 2 / 3 / 32 / 59 / 0 |
| Card-busy polls (per written block) | 3,303,625 (1,315) | 2,181,782 (866) | 3,260,668 (1,320) |
| Card busy, lower bound (polls x 0.423 us, one SPI byte at 18.9 MHz) | >= 1.40 s | >= 0.92 s | >= 1.38 s |
| Amiga polls (waiting for Gayle's FIFO) | 67,050 | 65,847 | 55,846 |
| Loop passes per 5.8 s during the run | 101,813 / 76,168 / **4,199** / 73,519 / 102,310 | 53,187 / **22,718** / 86,991 / 102,557 | 54,927 / **2,045** / 75,701 |

Idle main-loop rate for comparison (passes per 5,809 ms): OSD closed ~99,900,
menu open ~101,000, about screen ~80,200.

## What it says

1. **Writes are not single-sector bound.** About two thirds of the write
   commands are 17-64 sectors and carry almost all written data; the rest are
   mostly 2-sector filesystem writes; single sectors are rare.  Design 9.1
   feared per-command latency would dominate; for this set it does not.
   CMD25 runs plus no CPU spinning on card busy act on most of the data, so
   the 10-minute target is plausible on the command-shape side.
2. **The CPU spins on card busy for every written block**: 870-1,320 polls,
   at least 0.4-0.55 ms per block, at least ~1-1.4 s per 1.2 MB copy.  This is
   CPU time lost to the UI, not only disk time.
3. **The main loop starves during copies.**  The worst 5.8 s windows have
   2,045-4,199 passes (1.4-2.8 ms per pass) against ~100,000 idle (~0.06 ms):
   a 25-50x slowdown.  This is the sluggish OSD Paul sees.  The interrupt-driven
   peripheral (design 5.2) targets exactly this.
4. **The CPU also spins on the Amiga**: 56,000-67,000 Gayle-FIFO polls per
   copy (`hdd.c` `GetFPGAStatus` loops).  Task 11 turns these into main-loop
   states.
5. Menu or about screen open changes little in the copy itself (similar
   counts); the about screen lowers the idle loop rate by ~20 % even with the
   17 ms redraw timer.

## Side effects of the measurement firmware

- Each report holds the CPU ~26 ms on the UART (no TX FIFO in `cfide`, ~87 us
  per byte), every 5.8 s: ~0.45 % of the time.  Drop or gate the report before
  this firmware ships.

## Gate

Shown to Paul 2026-10-24; Paul: the data is sufficient, proceed to Phase B
(Task 4).
