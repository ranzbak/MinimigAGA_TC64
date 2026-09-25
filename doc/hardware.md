# The emulated machine

What the bitstream on this branch contains, checked against the RTL
(`rtl/soc/minimig_openaars_top.v`, `rtl/soc/minimig_virtual_top.v`,
`rtl/soc/TG68K.vhd`, `rtl/minimig/`, `rtl/openaars/`). Items that the RTL shows
but that haven't been tried on the board are marked (unverified).

## The board

| Part | Where | Used for |
|---|---|---|
| Xilinx XC7A100T (xc7a100tfgg676-2) | QMTech core board | everything below |
| DDR3, 256 MB (MT41K128M16) | QMTech core board | one Zorro III fast RAM board (16 MB of it) |
| 16-bit SDRAM, 32 MB | OpenAARS IO board | chip, slow, Kickstart and most fast RAM (the simulation uses the AS4C16M16SA model) |
| ADV7511 | IO board | HDMI transmitter, set up over I2C by the OSD firmware |
| MAX9850 | IO board | headphone output, fed over I2S |
| PCF2123 | IO board | battery-backed real-time clock, over SPI |
| MCP23S17 | IO board | reads the two joystick ports, over SPI |
| micro SD slot | IO board | the SD card, in SPI mode |
| 2x PS/2 | IO board | keyboard and mouse |
| 2 buttons | IO board | reset, OSD |
| 5 LEDs | IO board | power, floppy, hard disk, disk activity, SD card access |
| 2 UARTs | IO board | UART0: the Amiga's serial port (with RTS/CTS); UART1: the OSD firmware's log, 115200 baud, transmit only |

Clocks: a 50 MHz crystal gives 113.4375 MHz (SDRAM and system), 28.36 MHz
(the Amiga chipset), 37.8125 MHz (the CPU), 148.5 MHz (HDMI) and 100 MHz
(DDR3).

## CPU: a pipelined MC68040

The CPU is [AP68040-pipelined](https://github.com/ranzbak/AP68040-pipelined)
(`lib/AP68040-pipelined`), a 68040-compatible core with the real chip's six
stages (fetch, decode, address calculation, operand fetch, execute,
write-back). In this build:

- **Clock:** its own 37.8125 MHz clock domain, a third of the 113.4375 MHz
  system clock.
- **MMU:** the 68040 MMU (page tables, translation caches). It's what
  `mmu.library`, MuForce or Enforcer use.
- **FPU:** the instructions the 68040 has in hardware. The others (FSIN,
  FETOX, packed decimal and so on) trap as on a real 68040 and need an FPSP
  such as MMULib's `68040.library`.
- **Caches:** 4 KB instruction and 4 KB data, 4-way, 16-byte lines, as on the
  68040. Cache hits are answered without going to memory (separate instruction
  and data read paths). Stores to cacheable memory are posted. Writes by the
  chipset's DMA are snooped, so the data cache sees them.
- **Cacheable memory:** the fast RAM boards, and chip RAM when Turbo chip RAM
  is on.

The OSD's Chipset page shows `CPU : 68040/FPU/MMU`. That line is read from
the bitstream (`CORE_CAPS` in `minimig_virtual_top.v`), not set: `/FPU` and
`/MMU` appear when the image was built with them (the shipping build has
both). It can't be switched to another CPU.

**Turbo** (Chipset page):

- **CHIPRAM:** the CPU reads and writes chip RAM directly in the SDRAM
  instead of over the 7 MHz chipset bus. Only with the AGA chipset and 2 MB
  of chip RAM.
- **KICK:** Kickstart is read from its SDRAM copy at full speed. Only with the
  AGA chipset.
- **BOTH:** the two together.

## Memory map

| Address | Size | What |
|---|---|---|
| `$000000-$1FFFFF` | 0.5-2 MB | chip RAM |
| `$200000-$9FFFFF` | 2, 4 or 8 MB | Zorro II fast RAM |
| `$A10000` | | HRTmon, when enabled |
| `$B80000-$B8FFFF` | | RTG and Akiko registers |
| `$BFD000`, `$BFE001` | | CIA-B, CIA-A |
| `$C00000-$D7FFFF` | 0.5-1.5 MB | slow RAM |
| `$DA0000-$DAFFFF` | | IDE (A600/A1200-style Gayle) |
| `$DC0000-$DCFFFF` | | real-time clock (Oki MSM6242-compatible) |
| `$DE1000-$DE1FFF` | | Gayle registers |
| `$DFF000` | | custom chip registers |
| `$E00000-$E7FFFF` | 512 KB | first half of a 1 MB Kickstart, or the extended ROM |
| `$E90000` (assigned by AmigaOS) | 64 KB | Toccata sound card, Zorro II |
| `$EC0000-$EFFFFF` | | audio buffer of the extra audio channel |
| `$F80000-$FFFFFF` | 512 KB | Kickstart |
| `$40000000-$40FFFFFF` | 16 MB | Zorro III board 1, on the SDRAM |
| assigned by AmigaOS (`$41000000` in simulation) | 16 MB | Zorro III board 3, on the DDR3 |

The Zorro boards are autoconfig boards. The OS assigns their addresses, and
the core decodes the DDR3 board and the Toccata card at whatever address the
OS gave them. Zorro III board 2 (a second 32 MB) exists only on 64 MB
platforms, not on this board.

Which boards are offered (OSD Memory page):

| FAST | Boards: all | Boards: DDR3 only |
|---|---|---|
| none | none | DDR3 board, Toccata |
| 2 MB / 4 MB | Zorro II 2/4 MB | DDR3 board, Toccata |
| Maximum | Zorro II 8 MB, Zorro III board 1, DDR3 board, Toccata | DDR3 board, Toccata |

The Zorro III boards and the Toccata card in the "Maximum, all" cell need the
saved configuration's CPU field to say 68020 (`cpu_config[1]`, the
`m68020` input of `minimig_autoconfig.v`). The OSD can't set it on this build.
Without it, "Maximum, all" gives only the 8 MB Zorro II board. This is what
`sim/autoconfig` shows; not confirmed on the board (unverified).

## Chipset and video

- **Chipset:** OCS (A500 or A1000 variant), ECS or AGA, PAL or NTSC.
- **HDMI:** the Amiga picture is scaled to 1280x720 and sent to the ADV7511.
  The output runs at 50 Hz when the Amiga's frame rate is under 53 Hz and at
  60 Hz otherwise, so PAL gives 720p50 and NTSC 720p60. The OSD firmware
  programs the ADV7511 over I2C, and does it again by itself when the display
  is plugged back in (Hot Plug Detect).
- **Video timing:** the ADV7511's clock delay (register `0xBA` = `0xA0`, set in
  `fw/ctrl_832/adv7511.c`) matches the centre-aligned output registers in
  `rtl/openaars/adv7511/adv_ddr.v`. The firmware and the bitstream have to
  come from the same version: an old firmware with a new bitstream (or the
  reverse) can give colour errors or a picture that drops out.
- **OSD video options:** blur filters for low and high resolution, scanlines
  (off, dim, black) for normal and interlaced modes, picture position.
- **RTG:** a Picasso96 display (`minimig.card`, `amiga_sw/rtg`). The frame
  buffer is in Zorro II fast RAM; 16-bit HiColor and 8-bit 256-colour modes.
  The Akiko chunky-to-planar converter is not built into this board's image
  (`havec2p` is 0 in `minimig_openaars_top.v`).

## Audio

- **Paula:** the four Amiga channels.
- **Toccata:** a Toccata-compatible Zorro II card, emulating the AD1848 codec's
  playback; recording is a stub.
- **Extra channel:** a 16-bit stereo channel fed from the `$EC0000` buffer,
  used for the floppy and hard disk sounds and by `amiga_sw/WavPlay`.
- **Output:** everything is mixed and sent as I2S to the MAX9850 headphone
  output. The firmware also sets up the ADV7511 for 48 kHz audio; whether HDMI
  carries sound depends on the board wiring (unverified).

## Input

- **PS/2 keyboard:** mapped to the Amiga keyboard. F12 and Scroll Lock open
  the OSD, Ctrl + Pause enters HRTmon. Num Lock turns on a keyboard joystick
  on port 2 (cursor keys, Ctrl and Left Alt for the buttons). The keyboard
  mouse emulation of older Minimig versions was removed (commit 1243760).
- **PS/2 mouse:** three buttons and, for an IntelliMouse-compatible mouse, the
  scroll wheel (read by `amiga_sw/WheelDriver`).
- **Joystick ports:** two DB9 ports, read through the MCP23S17 (directions and
  two buttons each). Port 1 switches between mouse and joystick by itself; an
  Amiga mouse on port 1 is decoded by the RTL (unverified on the board).
- **CD32 pad** (Chipset page): the Amiga sees a CD32 pad on the joystick
  ports. The MCP23S17 reads only six lines per port, so the CD32's extra
  buttons can't be pressed (unverified).
- **Autofire** on joystick port 2 (Ctrl + Left Alt + keypad 0).
- While the OSD is open, the Amiga gets no keys and no mouse buttons.

## Storage

- **SD card:** FAT32, read and written by the OSD firmware.
- **Hard disks:** an A600/A1200-style IDE interface with a master and a slave.
  Each can be an HDF with a partition table, a single-partition HDF (the
  firmware adds a partition table on the fly), the whole SD card, or one of
  its partitions 1-4.
- **Floppies:** one to four drives, ADF images, with an optional turbo mode.

## Real-time clock

The PCF2123 is presented to the Amiga as an Oki MSM6242-compatible clock at
`$DC0000`, which AmigaOS supports out of the box. Setting the clock writes
through to the PCF2123.

## The OSD and its controller

A small soft CPU (EightThirtyTwo, "832") runs the OSD firmware. A boot loader
in the bitstream (`fw/ctrl_boot_832`) loads `832OSDAD.BIN` from the SD card.
The firmware (`fw/ctrl_832`) draws the OSD, loads Kickstart and settings,
serves the floppy and hard disk images, sets up the HDMI chip, plays the drive
sounds, and prints a log on UART1. It releases the 68040 only after a
Kickstart has loaded.
