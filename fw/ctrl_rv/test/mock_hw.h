/* mock_hw: the host-test model of the OSD CPU's hardware (SPI, TIMER, UART,
 * PLATFORM, AUDIO) behind the -DHOSTTEST hooks of ../hardware.h.
 *
 *  - SPI trace: every frame (a run of constant chip-select register) with the
 *    bytes out and the bytes in, in the normalised spi.txt format of the L2
 *    bench (sim/host_bridge/tb_host_bridge.v +SPI_LOG, read by spitrace.py):
 *        <cs> <out bytes> / <in bytes>        hex, lowercase, no timestamps
 *    <cs> is the Enable value of the selected line (20 OSD, 10 FPGA, 02 card,
 *    40 DMode, 80 RTC, 00 none; the register model is cfide's: Enable sets
 *    the line's bit and bit 0, Disable clears them, the trace shows the
 *    register without bit 0).  A frame with cs 00 and no bytes is not written.
 *  - MISO per chip select: a queue of reply bytes, or a callback; nothing
 *    scripted gives the idle byte (0xFF).  Card (cs 02): the card image model.
 *  - Direct mode (DMode, 0x40, with the card selected): one SPI write clocks
 *    512 bytes out of the card with MOSI high, as cfide does (shiftcnt
 *    "10111111111111": 4096 clocks); the trace shows them under cs 42.
 *  - TIMER: a counter, advanced by hosttest_advance(), by `step` on every
 *    read, so that a CheckTimer() loop ends, and (mock_timer_spi_rate) by 1
 *    every n SPI bytes: time that passes with the bytes on the wire.
 *  - UART: the bytes of RS232(), kept as text.
 */
#ifndef MOCK_HW_H
#define MOCK_HW_H

#include <stddef.h>

/* everything back to power-on: trace, scripts, card (unloaded), timer 0 with
   step 1, UART empty, PLATFORM/AUDIO 0 */
void mock_reset(void);

/* ---- SPI trace ---- */
const char *mock_trace(void);               /* the open frame is closed first */
int mock_trace_write(const char *path);     /* 0 = ok */
int mock_frames(void);                      /* frames in the trace so far */
unsigned mock_cs(void);                     /* the CS register (cfide's scs) */
unsigned mock_spi_speed(void);              /* last SPEED write, 0 = none */
/* every SPEED write with the card commands parsed before it, one line each:
   "3f after 0 commands" */
const char *mock_spi_speed_log(void);

/* ---- scripted MISO ---- */
/* cs = the Enable value: 0x10 FPGA, 0x20 OSD, 0x40 DMode, 0x80 RTC, 0x00 no select */
void mock_script_bytes(unsigned cs, const unsigned char *b, size_t n);
typedef unsigned char (*mock_miso_fn)(void *ctx, unsigned char out);
void mock_script_fn(unsigned cs, mock_miso_fn fn, void *ctx);
void mock_script_idle(unsigned cs, unsigned char idle);   /* queue empty: this byte */
unsigned mock_script_left(unsigned cs);     /* queued bytes not yet read */
unsigned mock_underruns(unsigned cs);       /* reads that found the queue empty */
/* direct-mode transfers so far (512 card bytes each, into the FPGA): a
   callback's view of what reached the Gayle FIFO outside its own frames */
unsigned mock_dmode_blocks(void);

/* ---- SD card image model (sim/common/sd_spi_model.v) ---- */
/* sectors 0: 65536 or the image if larger (rounded up to 1024) */
int mock_card_load(const char *path, unsigned sectors);   /* 0 = ok */
int mock_card_save(const char *path);
const unsigned char *mock_card_sector(unsigned lba);      /* NULL beyond the card */
/* model defaults 4 8 1 2.  token_dly < 0: no data token ever (reads, CSD:
   0xFF until the card is deselected); busy < 0: busy (0x00) without end after
   a write or CMD12, until deselect or CMD0 (not in sd_spi_model.v: the timeout
   cases of mmc_test) */
void mock_card_params(int token_dly, int busy, int ncr, int init_polls);
unsigned mock_card_commands(void);          /* commands the card has parsed */
/* one line per command, as sd_spi_model.v's +SD_LOG=1 lines without the time
   and cs fields: "CMD0 arg=00000000", "ACMD41 arg=40000000" (A = after CMD55) */
const char *mock_card_log(void);

/* ---- TIMER ---- */
void hosttest_advance(unsigned n);
void mock_timer_step(unsigned n);           /* added after every read, default 1 */
void mock_timer_spi_rate(unsigned n);       /* +1 every n SPI bytes, 0 = off (default) */
unsigned mock_timer_reads(void);

/* ---- UART, PLATFORM, AUDIO ---- */
const char *mock_uart(void);
size_t mock_uart_len(void);
void mock_uart_clear(void);
void mock_platform_set(unsigned short v);
void mock_audio_set(unsigned char v);

#endif
