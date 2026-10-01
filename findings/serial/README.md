# Amiga serial port at ~112 baud on the AP040 images

Status 2026-10-01: cause narrowed down, not fixed.

## Symptom

With the AP040 images (cu9 and later) `Echo hello >SER:` comes out at about
112 baud whatever Serial Prefs says (38400 was set). The 020 core ran the same
setup up to 56k6. Measured with a per-byte timestamp capture on the board's
CP2105 (second port, ttyUSB1): one zero byte per falling edge, 17.83 ms apart
for `UUUU`, so one bit is about 8.9 ms (SERPER around $7B6E).

## What is established

* Paula latches SERPER on every 7 MHz enable while `reg_address == $032`,
  without a write strobe (`rtl/minimig/paula_uart.v`). Agnus puts the CPU
  address on the register bus for reads too (`agnus.v` `reg_address_cpu`), and
  Gary gives the chips `$FFFF` or the CPU's write data on a read (`gary.v:117`).
  That is how the real chipset behaves: the custom chips have no R/W line, so a
  read of a write-only register writes whatever is on the bus.
* `amiga_sw/SerTest` on the board (bare boot, stage_cf1): SERPER written
  directly works (line A), the CPU computes 368/92/30 correctly (B, and F:
  serial.device 3.1.4's own instruction sequence), and ONE read of $DFF032
  makes the next line come out at the slow rate (C). D (POTGO write) is fine.
* sim/ddr3_cpu: the core writes SERPER cleanly in every addressing form
  (`serper_ddr3.asm`, probe `serprobe_ddr3.sv`), and serial.device 3.1.4's
  SetParams code, incbin'd byte for byte (`sdsetpar_ddr3.asm`), writes
  $0170/$005C/$001E with no read of $DFF032.

So something else, running under AmigaOS on the AP040, reads $DFF032 -- the
020 core never did. A spurious read of a custom register is a correctness bug
in its own right (a strobe register such as COPJMP would act on it).

## Next step

`build/stage_cf1i` is stage_cf1 with the CPU ILA. `tools/vivado/ila_cpu040_capture.tcl`
mode `serper` triggers on a chipset READ at $xxDFF032 and keeps the 3584 bus
cycles before it (PC, address, opcode):

    vivado -mode batch -source tools/vivado/ila_cpu040_capture.tcl \
           -tclargs build/stage_cf1i serper.csv 20 1 serper

then boot Workbench and `Echo hello >SER:`.

## Files

    serper_ddr3.asm     SERPER/SERDAT writes in every form, with serprobe_ddr3.sv
    spcalc_ddr3.asm     serial.device's SERPER arithmetic, store and read-back
    sdsetpar_ddr3.asm   serial.device 3.1.4's routine itself; needs serial314.code
    serprobe_ddr3.sv    every chipset cycle in $DFF000-$DFF1FF and the core's own

`serial314.code` is Commodore's code and is not in the repository: extract
`devs/serial.device` from the Workbench 3.1.4 ADF and strip the 32-byte hunk
header (`xdftool Workbench3_1_4.adf read devs/serial.device sd; dd if=sd
of=serial314.code bs=1 skip=32 count=$((0x147c))`).

Run any of them with findings/ap040-pipelined/tests/perf/run_ddr3_prog.sh
(`PROBE=findings/serial/serprobe_ddr3.sv PROBE_TOP=serprobe_ddr3`).
