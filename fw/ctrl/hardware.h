//#define MCLK 48000000
//#define FWS 1 // Flash wait states
//
//#define DISKLED    AT91C_PIO_PA10
//#define MMC_CLKEN  AT91C_PIO_PA24
//#define MMC_SEL    AT91C_PIO_PA27
//#define DIN AT91C_PIO_PA20
//#define CCLK AT91C_PIO_PA4
//#define PROG_B AT91C_PIO_PA9
//#define INIT_B AT91C_PIO_PA7
//#define DONE AT91C_PIO_PA8
//#define FPGA0 AT91C_PIO_PA26
//#define FPGA1 AT91C_PIO_PA25
//#define FPGA2 AT91C_PIO_PA15
//#define BUTTON AT91C_PIO_PA28

#ifndef HARDWARE_H
#define HARDWARE_H

/* I/O map (plan 5.3): every register at offset 0 of its 16-byte window,
   CPU addresses 0xFFFFFFx0, so each access compiles to a zero-based
   lw/sh/sb with a small negative offset. */

#include "i2c.h"
#include "spi.h"
#include "uart.h"

/* 0x680000 is 0xe80000 in Amiga space */
#define HOSTMAP_ADDR 0x680000

#define DISKLED_ON // *AT91C_PIOA_SODR = DISKLED;
#define DISKLED_OFF // *AT91C_PIOA_CODR = DISKLED;

#define AUDIO (*(volatile unsigned char *)0xFFFFFFB0)
#define AUDIOF_CLEAR 2
#define AUDIOF_ENA 1
#define AUDIOF_AMIGA 2

/* AUDIO_BUFFER at host address 0x70000, is 0xef0000 in Amiga space */
#define AUDIO_BUFFER 0x70000
/* We have two alternating buffers of this size */
#define AUDIO_BUFFER_SIZE 0x8000

#define HW_SPI(x) (*(volatile unsigned char *)(0xFFFFFFE0+(x)))
#define HW_SPI_CS 4
#define HW_SPI_DATA 0
#define HW_SPI_SPEED 8

/* UART TX: write only (cfide never acks a read of 0xFFFFFFF0) */
#define UART_TX (*(volatile unsigned char *)0xFFFFFFF0)
#define RS232(x) (UART_TX=(x))

#define TIMER (*(volatile unsigned short *)0xFFFFFFD0)

// FPGA die temperature: the XADC's raw 12-bit reading, see rtl/soc/fpga_temp.v.
// Only decoded when CORE_CAPS_TEMP is set -- on a core without it this address
// reads the platform register instead, so check the capability before using it.
#define FPGA_TEMP_RAW (*(volatile unsigned short *)0xFFFFFF40)
#define SPIN {int v=TIMER; (void)v;}	// Waste a few cycles to let the FPGA catch up

// Track write (fdd.c FindSync / GetHeader / GetData): the time paula_floppy's
// write FIFO needs between two FIFO words the firmware reads.  paula loads a
// word's SPI transmit register (fifo_out) at the word's first sck edge, but
// pops the word before it only after that word has gone through its rx_flag
// synchroniser, the FIFO pointer and the FIFO's registered output: about 56
// to 64 clk_114 after the word's last edge.  A word started sooner sends the
// previous word again (sim/l3 fdd_wr run p4t14w: "Second sync word
// missing...", nothing written; findings/osd-riscv/phase4.md, Task 14).
// (A slow enough CPU would not need it.)  WRFIFO_GAP is a counted loop of
// WRFIFO_GAP_READS discarded TIMER reads, 16 SPINs under another name: each
// read is a cfide access acknowledged at a clk_28 edge, so the gap has a
// floor in clk_28 cycles whatever the CPU's speed (not an empty loop whose
// length follows the CPU).  The one listed exception to "No new count-based
// delays" (README "Differences", "Delay sites"); test/Makefile wrfifo.ok
// allows a discarded TIMER read only in SPIN and here.
#define WRFIFO_GAP_READS 16
#define WRFIFO_GAP {int i_; for (i_ = 0; i_ < WRFIFO_GAP_READS; i_++) {int v_=TIMER; (void)v_;}}

#if 1
#define EnableCard()  HW_SPI(HW_SPI_CS)=0x02
#define DisableCard() HW_SPI(HW_SPI_CS)=0x03
#define EnableFpga()  HW_SPI(HW_SPI_CS)=0x10
#define DisableFpga() HW_SPI(HW_SPI_CS)=0x11
#define EnableOsd()   HW_SPI(HW_SPI_CS)=0x20
#define DisableOsd()  HW_SPI(HW_SPI_CS)=0x21
#define EnableDMode() HW_SPI(HW_SPI_CS)=0x40
#define DisableDMode() HW_SPI(HW_SPI_CS)=0x41
#define EnableRTC()   HW_SPI(HW_SPI_CS)=0x80
#define DisableRTC()   HW_SPI(HW_SPI_CS)=0x81
#endif

#define SPI_slow()  HW_SPI(HW_SPI_SPEED)=0x3f
#define SPI_fast()  HW_SPI(HW_SPI_SPEED)=0x1

// Yuk.  The following monstrosity does a dummy read from the timer register, writes, then reads from
// the SPI register.  Doing it this way works around a timing issue with ADF writing when GCC optimisation is turned on.
//#define SPI(x) (*(volatile unsigned short *)0xDEE010,*(volatile unsigned char *)0xda4000=x,*(volatile unsigned char *)0xda4000)

#define SPI(x) (HW_SPI(HW_SPI_DATA)=x,HW_SPI(HW_SPI_DATA))
// A reply byte from the OSD (userio_osd.v loads it on its clk7_en grid, after
// the previous byte): read back-to-back, the CPU can catch the PREVIOUS byte.
// Measured on the board 2026-10-14 (stage_scaler): the version reply read
// with SPI(0xff) gave 00 01 0A 0A A4 A4, with four SPINs before each byte
// 01 1A 0A 02 A4 7D every time -- the stale magic byte is what brought the
// 68020 CPU menu back on a 68040 core.
// The RV firmware (Phase 4) waits instead for HOST_REQ's OSD_RDY before each
// reply byte, at most 2 TIMER counts (hardware.c); every wait that ran out is
// counted in osd_rdy_timeouts (printed with the stack high water in DebugMode).
unsigned char SPI_reply(void);
extern unsigned long osd_rdy_timeouts;
#define RDSPI  HW_SPI(HW_SPI_DATA)

// HOST_REQ (cfide, read only; audio window offset 4).  Bit 0 OSD_RDY: 1 when
// userio_osd has taken every byte cfide sent with the OSD selected, i.e. a
// reply byte read now is the current one.  Bits 15..1 read 0 (reserved).
// Needs a core with the Phase 4 RTL: an older cfide returns its audio status
// here (bit 0 = audio_buf), so SPI_reply() waits its full bound or not at all.
#define HOST_REQ (*(volatile unsigned short *)0xFFFFFFB4)
#define HOST_REQ_OSD_RDY 0x0001

// A 16-bit register for platform-specific config.
// On read:
//   Bit 0 -> menu button
//   Bit 1 -> 32meg supported
//   Bit 8 -> Reconfig supportred 

#define PLATFORM (*(volatile unsigned short *)0xFFFFFFC0)
#define PLATFORM_MENUBUTTON 0
#define PLATFORM_32MEG 1
#define PLATFORM_SPIRTC 2
#define PLATFORM_RECONFIG 8

// On write:
//   Bit 0 -> Scandoubler enable
//   Bit 8 -> Reconfig, if supported.


#define PLATFORM_SCANDOUBLER 0

// Write to this register to reconfigure the FPGA on devices which support such operations.
#define RECONFIGURE (*(volatile unsigned short *)0xDEE016)

#define RAMFUNC  // Used by ARM

#define SPI_RST_USR         0x1
#define SPI_RST_CPU         0x2
#define SPI_CPU_HLT         0x4

// 15kHz to HDMI Video position
#define VIDEOSCALE (*(volatile unsigned int *)0xFFFFFF50)
#define VIDEOSCALE_SET_POS (VIDEOSCALE)

//void USART_Init(unsigned long baudrate);
//void USART_Write(unsigned char c);
//
//void SPI_Init(void);
//unsigned char SPI(unsigned char outByte);
//void SPI_Wait4XferEnd(void);
//void EnableCard(void);
//void DisableCard(void);
//void EnableFpga(void);
//void DisableFpga(void);
//void EnableOsd(void);
//void DisableOsd(void);
unsigned long CheckButton(void);
void Timer_Init(void);
unsigned long GetTimer(unsigned long offset);
unsigned long CheckTimer(unsigned long t);
void WaitTimer(unsigned long time);
void ConfigMisc(unsigned short misc);
void Reconfigure();

/* Host tests (-DHOSTTEST, fw/ctrl/test/mock_hw.c): the register accesses
   the firmware makes through these macros go to a mock instead of to the
   addresses above, and AUDIO_BUFFER is the mock's RAM (the audio ring, with
   the room drivesounds_init loads into in front of it).  Not defined in the
   target build: the preprocessor drops this block and RV32OSDA.BIN is the
   same.  hwmap_test #undefs HOSTTEST to check the real expansions. */
#ifdef HOSTTEST
unsigned char hosttest_spi(unsigned char out);	/* SPI(x): write DATA, read DATA */
unsigned char hosttest_rdspi(void);		/* RDSPI: read DATA */
void hosttest_cs(unsigned v);			/* the CS register: Enable*()/Disable*() */
void hosttest_spi_speed(unsigned v);		/* the SPEED register: SPI_slow()/SPI_fast() */
unsigned short hosttest_timer(void);		/* TIMER read */
unsigned short hosttest_host_req(void);		/* HOST_REQ read */
volatile unsigned short *hosttest_platform(void);	/* PLATFORM, an lvalue */
volatile unsigned char *hosttest_audio(void);		/* AUDIO, an lvalue */
void hosttest_uart(int c);			/* RS232(x) */
unsigned char *hosttest_audio_buffer(void);	/* AUDIO_BUFFER: the mock's ring */

#undef SPI
#undef RDSPI
#undef EnableCard
#undef DisableCard
#undef EnableFpga
#undef DisableFpga
#undef EnableOsd
#undef DisableOsd
#undef EnableDMode
#undef DisableDMode
#undef EnableRTC
#undef DisableRTC
#undef SPI_slow
#undef SPI_fast
#undef TIMER
#undef HOST_REQ
#undef PLATFORM
#undef AUDIO
#undef RS232
#undef AUDIO_BUFFER
#define SPI(x)         hosttest_spi(x)
#define RDSPI          hosttest_rdspi()
#define EnableCard()   hosttest_cs(0x02)
#define DisableCard()  hosttest_cs(0x03)
#define EnableFpga()   hosttest_cs(0x10)
#define DisableFpga()  hosttest_cs(0x11)
#define EnableOsd()    hosttest_cs(0x20)
#define DisableOsd()   hosttest_cs(0x21)
#define EnableDMode()  hosttest_cs(0x40)
#define DisableDMode() hosttest_cs(0x41)
#define EnableRTC()    hosttest_cs(0x80)
#define DisableRTC()   hosttest_cs(0x81)
#define SPI_slow()     hosttest_spi_speed(0x3f)
#define SPI_fast()     hosttest_spi_speed(0x1)
#define TIMER          hosttest_timer()
#define HOST_REQ       hosttest_host_req()
#define PLATFORM       (*hosttest_platform())
#define AUDIO          (*hosttest_audio())
#define RS232(x)       hosttest_uart(x)
#define AUDIO_BUFFER   (hosttest_audio_buffer())
#endif /* HOSTTEST */

#endif /* HARDWARE_H */
