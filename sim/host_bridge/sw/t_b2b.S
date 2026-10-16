/* t_b2b: back-to-back hw writes, no other instruction between them.
 * cfide's ack is a clk_28 register; the bridge's four-phase handshake
 * (hw_release) waits for it to fall before the next hw request.  Each block
 * runs twice: the first call fills the I-cache (4 KB), so the measured
 * second call has no line refill between the stores.  The bench checks at
 * STAMP 2-4 (tb_host_bridge.v, TEST=t_b2b):
 *   64 x sh PLATFORM 1,0,1,0,...  -> 64 scandoubler toggles, pin ends at 0
 *   64 x sh AUDIO    1,0,1,0,...  -> 64 audio_ena toggles, pin ends at 0
 *   32 x sb SPI CS   0x02,0x03,.. -> sd_cs FC,FF,FC,... (32 changes)
 * and every run: no hw access completes on a stale ack.  The program then
 * reads PLATFORM and AUDIO back (neither holds the written value: PLATFORM
 * reads platformdata, AUDIO {audio_amiga, audio_buf}; the pins are the
 * bench's).  Exit code: 0 or the failing check. */
#include "hb.h"
#include "check.h"

    .text
    .globl main
main:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    li      s0, 0
    li      t1, 1
    li      t2, HB_CS1_ON
    li      t3, HB_CS1_OFF
    call    b2b_platform            /* warm-up: I-cache */
    call    b2b_audio
    call    b2b_cs
    STAMP   1                       /* bench: pins at 0, CS off; arm */
    call    b2b_platform
    STAMP   2
    call    b2b_audio
    STAMP   3
    call    b2b_cs
    STAMP   4
    lhu     t0, HB_PLATFORM_OFS(zero);  CHECK t0, HB_PLATFORM_VAL      /* 1 */
    lhu     t0, HB_AUDIO_OFS(zero);     CHECK t0, 1                    /* 2 */
    li      a0, 0
    j       9f
fail:
    mv      a0, s0
9:  lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

    .balign 32
b2b_platform:
    .rept   32
    sh      t1, HB_PLATFORM_OFS(zero)
    sh      zero, HB_PLATFORM_OFS(zero)
    .endr
    ret

    .balign 32
b2b_audio:
    .rept   32
    sh      t1, HB_AUDIO_OFS(zero)
    sh      zero, HB_AUDIO_OFS(zero)
    .endr
    ret

    .balign 32
b2b_cs:
    .rept   16
    sb      t2, HB_SPI_CS_OFS(zero)
    sb      t3, HB_SPI_CS_OFS(zero)
    .endr
    ret
