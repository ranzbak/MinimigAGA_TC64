#ifndef DISKSTAT_H
#define DISKSTAT_H

/* Disk statistics for the SD baseline (findings/sdcard-engine, design 5.3):
   counted always, printed on the UART every DISKSTAT_PERIOD TIMER counts
   while DebugMode is on (main.c).  The totals are cumulative since power-on
   (differences of two reports give a copy's numbers); the loop passes are
   per report period. */

#define DISKSTAT_PERIOD 1000	// TIMER counts between two reports (5.804 s)

/* sectors per ATA command, [write][bucket]; buckets 1, 2, 3-4, 5-8, 9-16,
   17-64, 65-256 sectors */
#define DISKSTAT_BUCKETS 7
extern unsigned diskstat_hist[2][DISKSTAT_BUCKETS];

/* one ATA READ/WRITE (MULTIPLE) command of `sectors` sectors */
void diskstat_cmd(int write, unsigned sectors);
/* card-busy polls after one written block (each poll is one SPI byte) */
void diskstat_busy_polls(unsigned n);
/* GetFPGAStatus() polls of one wait for Gayle's sector FIFO */
void diskstat_amiga_polls(unsigned n);
/* once per main-loop pass */
void diskstat_loop_pass(void);
/* start a new report period now (DebugMode switched on) */
void diskstat_period_start(void);
/* print the totals and the period's loop passes and TIMER counts; starts the
   next period */
void diskstat_report(void);

#endif
