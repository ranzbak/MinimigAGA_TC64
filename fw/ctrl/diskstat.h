#ifndef DISKSTAT_H
#define DISKSTAT_H

/* Disk statistics for the SD baseline (findings/sdcard-engine, design 5.3):
   counted always, printed on the UART every DISKSTAT_PERIOD TIMER counts
   from boot when dbg_flags has DBG_DISKSTAT (main.c).  The totals are cumulative since
   power-on (differences of two reports give a copy's numbers); the loop
   passes are per report period. */

#define DISKSTAT_PERIOD 1000	// TIMER counts between two reports (5.804 s)

/* Run-time debug switches (findings/sdcard-engine ruling T11-R2), 0 =
   quiet: no UART output from the disk data path.  Set over the GDB tunnel
   (fw/ctrl/README.md "Debug flags"): (gdb) set var dbg_flags = 3 */
#define DBG_ATA      0x01	/* one UART line per ATA command (hdd.c) */
#define DBG_DISKSTAT 0x02	/* the disk report every DISKSTAT_PERIOD (main.c) */
extern volatile unsigned dbg_flags;

/* sectors per ATA command, [write][bucket]; buckets 1, 2, 3-4, 5-8, 9-16,
   17-64, 65-256 sectors */
#define DISKSTAT_BUCKETS 7
extern unsigned diskstat_hist[2][DISKSTAT_BUCKETS];

/* one ATA READ/WRITE (MULTIPLE) command of `sectors` sectors */
void diskstat_cmd(int write, unsigned sectors);
/* card-busy polls after one written block (each poll is one SPI byte) */
void diskstat_busy_polls(unsigned n);
/* status polls of one wait for Gayle's sector FIFO (the HDD data path: one
   per main-loop pass of the wait, findings/sdcard-engine Task 11a) */
void diskstat_amiga_polls(unsigned n);
/* once per main-loop pass */
void diskstat_loop_pass(void);
/* start a new report period now (once, before the main loop) */
void diskstat_period_start(void);
/* print the totals and the period's loop passes and TIMER counts; starts the
   next period */
void diskstat_report(void);

#endif
