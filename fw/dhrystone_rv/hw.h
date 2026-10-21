/* Dhrystone for the RISC-V host CPU: time, output, simulator hooks.
 *
 * -DL1         simulation build (sim/rv_l1 and sim/host_bridge): the run is
 *              NUMBER_OF_RUNS = 100 and measured by the bench's TIME stamps
 *              (0xFFFFFF00, "=== TIME <tag> cycle <n>"); DONE (0xFFFFFF04)
 *              ends the run, 0 = every result check passed.
 * board build  cfide TIMER (0xFFFFFFD0) for the time, NUMBER_OF_RUNS 200000
 *              (-DNUMBER_OF_RUNS=n overrides either default).
 * Both: characters out through the cfide UART (0xFFFFFFF0), byte writes
 * without a TX-ready poll (cfide holds the write until the transmitter is
 * free; it has no TX-ready bit to read, see hw.c).
 */
#ifndef HW_H
#define HW_H

#ifndef NUMBER_OF_RUNS
#ifdef L1
#define NUMBER_OF_RUNS 100
#else
#define NUMBER_OF_RUNS 200000
#endif
#endif

#define HW_STAMP_ADDR 0xFFFFFF00u    /* sim only: TIME stamp (W)          */
#define HW_DONE_ADDR  0xFFFFFF04u    /* sim only: DONE, exit code (W)     */
#define HW_TIMER_ADDR 0xFFFFFFD0u    /* cfide TIMER, 16-bit R             */
#define HW_UART_ADDR  0xFFFFFFF0u    /* cfide UART: 8-bit W (held until the transmitter is free) */

/* One TIMER count = 256 ticks of cfide's tick_in, which minimig_virtual_top
   drives every 643 clk_28 (28.359375 MHz): 256 * 643 / 28.359375 MHz = 5804.4 us. */
#define HW_TIMER_US 5804

#ifdef L1
#define hw_stamp(tag)   (*(volatile unsigned int *)HW_STAMP_ADDR = (tag))
#define hw_ms()         0L
#define hw_finish(code) (*(volatile unsigned int *)HW_DONE_ADDR = (code))
#else
#define hw_stamp(tag)   ((void)0)
long hw_ms(void);
#define hw_finish(code) ((void)0)
#endif

int printf(const char *fmt, ...);

#endif
