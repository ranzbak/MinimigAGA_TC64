/* t_sdc_regs: the SD card peripheral (rtl/host/sdcard_spi.v) through cfide's
 * ext_* port (0xFFFFFF00..2C, the windows 0-2; Task 8).  The bench wires an
 * sdcard_spi to the port (no card: sd_cd_n high, MISO high) and its irq to
 * cfide irq_src(4).  Every read must return the value of its own access, not
 * the previous one's: reads of registers with different values alternate,
 * back to back.  The bench counts the ext strobes (one per access, in its
 * first cycle) and checks the CS pin at the end (final_checks).
 *   1      VERSION = 0x5D02
 *   2-4    STATUS 0 (idle, no card), CFG 0x00FF and TIMEOUT 0 after reset
 *   5-7    CFG := 0x0102, read back; VERSION again; CFG again
 *   8-9    TIMEOUT := 0x1234, IRQEN := 0x001F, read back
 *   10-14  five reads back to back: CFG, VERSION, TIMEOUT, IRQEN, CFG
 *   15-16  RXLVL 0, TXLVL 0
 *   17-18  IRQEN := 1 (op done), IRQACK all: IRQPEND bit 0 clear and
 *          cfide IRQ_RAW bit 4 clear
 *   19-20  CMD RX_FLUSH (done at once): IRQPEND bit 0, then IRQ_RAW bit 4
 *          (polled: the 2-FF clk_28 synchroniser)
 *   21     IRQACK 1: IRQ_RAW bit 4 clear again (polled)
 *   22     VERSION once more
 * Exit code: 0 or the failing check. */
#include "hb.h"
#include "check.h"

    .text
    .globl main
main:
    li      s0, 0
    lhu     t0, HB_SDC_VERSION_OFS(zero);  CHECK t0, HB_SDC_VERSION      /* 1 */
    lhu     t0, HB_SDC_CMD_OFS(zero);      CHECK t0, 0x0000              /* 2 */
    lhu     t0, HB_SDC_CFG_OFS(zero);      CHECK t0, 0x00FF              /* 3 */
    lhu     t0, HB_SDC_TIMEOUT_OFS(zero);  CHECK t0, 0x0000              /* 4 */
    li      t0, 0x0102
    sh      t0, HB_SDC_CFG_OFS(zero)
    lhu     t0, HB_SDC_CFG_OFS(zero);      CHECK t0, 0x0102              /* 5 */
    lhu     t0, HB_SDC_VERSION_OFS(zero);  CHECK t0, HB_SDC_VERSION      /* 6 */
    lhu     t0, HB_SDC_CFG_OFS(zero);      CHECK t0, 0x0102              /* 7 */
    li      t0, 0x1234
    sh      t0, HB_SDC_TIMEOUT_OFS(zero)
    li      t0, 0x001F
    sh      t0, HB_SDC_IRQEN_OFS(zero)
    lhu     t0, HB_SDC_TIMEOUT_OFS(zero);  CHECK t0, 0x1234              /* 8 */
    lhu     t0, HB_SDC_IRQEN_OFS(zero);    CHECK t0, 0x001F              /* 9 */
    /* back to back: no instruction between the loads */
    lhu     t1, HB_SDC_CFG_OFS(zero)
    lhu     t2, HB_SDC_VERSION_OFS(zero)
    lhu     t3, HB_SDC_TIMEOUT_OFS(zero)
    lhu     t4, HB_SDC_IRQEN_OFS(zero)
    lhu     t5, HB_SDC_CFG_OFS(zero)
    CHECK   t1, 0x0102                                                   /* 10 */
    CHECK   t2, HB_SDC_VERSION                                           /* 11 */
    CHECK   t3, 0x1234                                                   /* 12 */
    CHECK   t4, 0x001F                                                   /* 13 */
    CHECK   t5, 0x0102                                                   /* 14 */
    lhu     t0, HB_SDC_RXLVL_OFS(zero);    CHECK t0, 0                   /* 15 */
    lhu     t0, HB_SDC_TXLVL_OFS(zero);    CHECK t0, 0                   /* 16 */
    /* the interrupt: op done only */
    li      t0, 0x0001
    sh      t0, HB_SDC_IRQEN_OFS(zero)
    li      t0, 0x001F
    sh      t0, HB_SDC_IRQ_OFS(zero)
    lhu     t0, HB_SDC_IRQ_OFS(zero)
    andi    t0, t0, 1;                     CHECK t0, 0                   /* 17 */
    li      t1, 16                          /* the irq falls through the 2-FF sync */
1:  lhu     t0, HB_IRQ_RAW_OFS(zero)
    andi    t0, t0, HB_SDC_IRQ_BIT
    beqz    t0, 2f
    addi    t1, t1, -1
    bnez    t1, 1b
2:  CHECK   t0, 0                                                        /* 18 */
    li      t0, 8                           /* RX_FLUSH: done at once */
    sh      t0, HB_SDC_CMD_OFS(zero)
    lhu     t0, HB_SDC_IRQ_OFS(zero)
    andi    t0, t0, 1;                     CHECK t0, 1                   /* 19 */
    li      t1, 16
1:  lhu     t0, HB_IRQ_RAW_OFS(zero)
    andi    t0, t0, HB_SDC_IRQ_BIT
    bnez    t0, 2f
    addi    t1, t1, -1
    bnez    t1, 1b
2:  CHECK   t0, HB_SDC_IRQ_BIT                                           /* 20 */
    li      t0, 0x0001
    sh      t0, HB_SDC_IRQ_OFS(zero)
    li      t1, 16
1:  lhu     t0, HB_IRQ_RAW_OFS(zero)
    andi    t0, t0, HB_SDC_IRQ_BIT
    beqz    t0, 2f
    addi    t1, t1, -1
    bnez    t1, 1b
2:  CHECK   t0, 0                                                        /* 21 */
    lhu     t0, HB_SDC_VERSION_OFS(zero);  CHECK t0, HB_SDC_VERSION      /* 22 */
    li      a0, 0
    ret
fail:
    mv      a0, s0
    ret
