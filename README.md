# Minimig AGA with a pipelined 68040, for OpenAARS

An Amiga in an FPGA: the Minimig AGA chipset with a pipelined MC68040 CPU
(MMU and FPU included), for the [OpenAARS](https://github.com/ranzbak/qmtech_minimig)
IO board version 5.0 with the QMTech "Xilinx FPGA Artix7 development board
XC7A100T DDR3" core board. This is the `5.0-040-pipelined` branch.

The IO board design is at
[github.com/ranzbak/qmtech_minimig](https://github.com/ranzbak/qmtech_minimig).
It's made in KiCad 5 and is free to use. The core board can be bought on eBay
or AliExpress.

**Only this board is built and maintained.** The other ports under `fpga/`
(MiST, Chameleon v1/v2, DE0-Nano, DE10-Lite, virtual) share RTL with this
build but don't build from this branch. Tag `d3_stable` is the last version
that builds them, with the TG68K CPU.

## What you get

- **CPU:** a pipelined MC68040 at 37.8 MHz with MMU, FPU (the 68040's hardware
  subset) and 4 KB instruction and data caches. The core is
  [AP68040-pipelined](https://github.com/ranzbak/AP68040-pipelined).
- **Chipset:** OCS, ECS or AGA, PAL or NTSC.
- **Memory:** up to 2 MB chip RAM, 1.5 MB slow RAM, 8 MB Zorro II fast RAM,
  and Zorro III fast RAM on the SDRAM and on the core board's DDR3.
- **Video:** HDMI at 1280x720, 50 or 60 Hz, scaled from the Amiga picture,
  plus a Picasso96 RTG screen.
- **Sound:** Paula, a Toccata-compatible Zorro II sound card, floppy drive
  sounds.
- **Storage:** hard disk images (HDF) and floppy images (ADF) on a FAT32 SD card.
- **Input:** PS/2 keyboard and mouse (scroll wheel supported), two joystick ports.
- **Also:** a battery-backed real-time clock, HRTmon, an on-screen menu (OSD).

Details and addresses: [doc/hardware.md](doc/hardware.md).

## Status (September 2026)

Experimental and still under test. Seen on the board so far:

- Kickstart 3.1.4 boots to Workbench.
- SysInfo reports about **0.83x** the speed of an A4000/040 at 25 MHz.
- The WinUAE cputest 68040 disk ran for 2 hours without an error, Frontier:
  Elite II ran all night, and AIBB's Beachball test (68020 code with the FPU)
  completes.
- **Open problem:** the AIBB FPU FLOPS test crashes.

The 68040 has no hardware for some FPU instructions (sine, logarithms and so
on). As on a real 68040, those need an FPU emulation library such as
`68040.library`. See [doc/workbench-setup.md](doc/workbench-setup.md).

## Quick start

1. Get the bitstream onto the board: build it ([doc/building.md](doc/building.md)),
   then load it over JTAG or write it to the board's flash with Vivado.
2. Prepare a FAT32 SD card with the OSD firmware `832OSDAD.BIN` and a Kickstart
   ROM: [doc/getting-started.md](doc/getting-started.md).
3. Boot, press **F12** for the menu, pick a hard disk image or a floppy.
4. For a Workbench with the FPU, MMU and RTG screen working:
   [doc/workbench-setup.md](doc/workbench-setup.md).

Something odd? Read [doc/troubleshooting.md](doc/troubleshooting.md) first:
several symptoms have a simple cause, such as a board that needs a power cycle.

## Documentation

| Document | For | What's in it |
|---|---|---|
| [doc/getting-started.md](doc/getting-started.md) | users | SD card, first boot, OSD keys and menus |
| [doc/workbench-setup.md](doc/workbench-setup.md) | users | Workbench HDF, 68040/FPU/MMU libraries, RTG, sound, clock, fast RAM |
| [doc/troubleshooting.md](doc/troubleshooting.md) | users | symptom, cause, fix |
| [doc/hardware.md](doc/hardware.md) | everyone | the emulated machine and its memory map |
| [doc/building.md](doc/building.md) | developers | toolchains, bitstream and firmware builds, JTAG, flash |
| [doc/simulation.md](doc/simulation.md) | developers | the test benches and how to run them |
| [doc/build-program-test.md](doc/build-program-test.md) | developers | the detailed build, program and hardware-test runbook |

## No warranty

This is experimental hardware description and firmware, provided as is,
without warranty of any kind. You use it at your own risk, including the risk
to your hardware and your data. See the license below and [LICENSE](LICENSE).

### Foreword

[minimig](http://en.wikipedia.org/wiki/Minimig) (short for Mini Amiga) is an open source re-implementation of an Amiga using a field-programmable gate array (FPGA). Original minimig author is Dennis van Weeren.

[Amiga](http://en.wikipedia.org/wiki/Amiga_500) was an amazing personal computer, announced around 1984, which - at the time - far surpassed any other personal computer on the market, with advanced graphic & sound capabilities, not to mention its great OS with preemptive multitasking capabilities.

This minimig variant has been upgraded with [AGA chipset](http://en.wikipedia.org/wiki/Amiga_Advanced_Graphics_Architecture) capabilites, which allows it to emulate the latest Amiga models ([Amiga 1200](http://en.wikipedia.org/wiki/Amiga_1200), [Amiga 4000](http://en.wikipedia.org/wiki/Amiga_4000) and (partially) [Amiga CD32](http://en.wikipedia.org/wiki/Amiga_CD32)). Ofcourse it also supports previous OCS/ECS Amigas like [Amiga 500](http://en.wikipedia.org/wiki/Amiga_500), [Amiga 600](http://en.wikipedia.org/wiki/Amiga_600) etc.

## Links & more info

Rok Krajnc's page [somuch.guru](http://somuch.guru/).

Further info about minimig can be found on the [Minimig Discussion Forum](http://www.minimig.net/).

The Turbo Chameleon 64 - [Individual Computers]http://wiki.icomp.de/wiki/Chameleon

MiST board support & other cores on the [MiST Project Page](https://github.com/mist-devel/mist-board/wiki)

## Credits

This project contains code written by:

- Jakub Bednarski
- Sascha Boing
- Tobias Gubener
- Till Harbaum
- Rok Krajnc
- Alastair M. Robinson
- Gyorgy Szombathelyi
- Dennis van Weeren

All code is copyright © 2005 - 2020 and the property of its respective authors.

### The 68040 CPU core

The CPU is [AP68040-pipelined](https://github.com/ranzbak/AP68040-pipelined)
(the `lib/AP68040-pipelined` submodule), a fork of
[AP68040](https://github.com/nonarkitten/AP68040):

- **Adam Polkosnik** wrote AP68040, the original sequential 68040 core with its
  MMU, FPU, caches and test benches, as part of
  [Minimig-AGA_MiSTer](https://github.com/apolkosnik/Minimig-AGA_MiSTer).
- **Renee Cousins (nonarkitten)** started the six-stage pipelined core.
- **Paul Honig** completed the pipelined core (the full integer ISA,
  exceptions, MMU, FPU, split read paths and timing closure) and its Minimig
  integration.

## License

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.

## Sources

This sourcecode is based on Rok's previous project ([minimig-de1](https://github.com/rkrajnc/minimig-de1)), and it continues from there. It was split into a new project to allow changes that would never fit in the FPGA on the DE1 board.

Original minimig sources from Dennis van Weeren with updates by Jakub Bednarski are published on [Google Code](http://code.google.com/p/minimig/).

Some minimig updates are published on the [Minimig Discussion Forum](http://www.minimig.net/), done by Sascha Boing.

ARM firmware updates and minimig-tc64 port changes by Christian Vogelsang ([minimig_tc64](https://github.com/cnvogelg/minimig_tc64)) and A.M. Robinson ([minimig_tc64](https://github.com/robinsonb5/minimig_tc64)).

MiST board & firmware by Till Harbaum ([MiST](https://code.google.com/p/mist-board/)).

TG68K.C core by Tobias Gubener.
