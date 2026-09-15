# Minimig AGA

This version of the Minimig AGA core is specific for the [OpenAARS](https://github.com/ranzbak/qmtech_minimig) board.
The hardware design can be found at [https://github.com/ranzbak/qmtech_minimig](https://github.com/ranzbak/qmtech_minimig) the design is mode in KiCad 5 and is free to use.
The intended FPGA core board is the 'Xilinx FPGA Artix7 development board XC7A100T DDR3', which can be obtained from Ebay or AliExpress.

**Supported board.** Only the OpenAARS / QMTech XC7A100T build (`fpga/openaars`, `project_1`) is maintained. Since Stage E4a its CPU is the AP68040 (MC68040 with MMU and FPU) only. The other ports under `fpga/` (MiST, Chameleon v1/v2, DE0-Nano, DE10-Lite, virtual) share RTL with this build but no longer build from this branch; tag `d3_stable` is the last version that builds them, with the TG68K CPU.

### Foreword

[minimig](http://en.wikipedia.org/wiki/Minimig) (short for Mini Amiga) is an open source re-implementation of an Amiga using a field-programmable gate array (FPGA). Original minimig author is Dennis van Weeren.

[Amiga](http://en.wikipedia.org/wiki/Amiga_500) was an amazing personal computer, announced around 1984, which - at the time - far surpassed any other personal computer on the market, with advanced graphic & sound capabilities, not to mention its great OS with preemptive multitasking capabilities.

This minimig variant has been upgraded with [AGA chipset](http://en.wikipedia.org/wiki/Amiga_Advanced_Graphics_Architecture) capabilites, which allows it to emulate the latest Amiga models ([Amiga 1200](http://en.wikipedia.org/wiki/Amiga_1200), [Amiga 4000](http://en.wikipedia.org/wiki/Amiga_4000) and (partially) [Amiga CD32](http://en.wikipedia.org/wiki/Amiga_CD32)). Ofcourse it also supports previous OCS/ECS Amigas like [Amiga 500](http://en.wikipedia.org/wiki/Amiga_500), [Amiga 600](http://en.wikipedia.org/wiki/Amiga_600) etc.

## Core features supported

- chipset variants : OCS, ECS, AGA
- chipRAM : 0.5MB - 2.0MB
- slowRAM : 0.0MB - 1.5MB
- fastRAM : 0.0MB - 24MB
- CPU core : 68000, 68010, 68020
- kickstart : 1.2 - 3.1 (256kB, 512kB & 1MB kickstart ROMs currently supported)
- HRTmon with custom registers mirror
- floppy disks : 1-4 floppies (supports ADF floppy image format), with normal & turbo speeds
- hard disks : 1-2 hard disk images (supports whole disk images, partition images, using whole SD card and using SD card partition)
- video standard : PAL / NTSC
- supports normal & scandoubled video output (15kHz / 30kHz) - can be used with a monitor or a TV with a HDMI cable
- peripherals : real Amiga / C64 joysticks connected to C64 joystick ports, CDTV infra-red controllers, PS/2 keyboards,
  PS/2 mice, real Amiga mouse
- supports basic retargetable graphics (RTG) with a P96 driver
- has an implementation of the Akiko chunky to planar converter
- has an extra audio channel which can be used from the Amiga to play CD-quality WAV files, or used on some platforms to emulate floppy drive sounds.

## Usage

### Hardware

To use this Minimig core, you will at the minimum need an SD/SDHC card, formatted with the FAT32 filesystem, a PS/2 keyboard and a compatible monitor / TV. Joysticks & mouse can be emulated on the keyboard. You will probably want to attach a set of speakers of headphones, a real Amiga or PS/2 mouse and a real Amiga joystick.

### Software

To use the core, you will also need a Kickstart ROM image file, which you can obtain by copying Kickstart ROM IC from your actual Amiga, or by buying an [Amiga Forever](http://www.amigaforever.com/) software pack. The Kickstart image should be placed on the root of the SD card with the name KICK.ROM. Minimig also supports the [AROS](http://aros.sourceforge.net/) kickstart ROM replacement.

The Minimig can read any ADF floppy images you place on the SD card. I recommend at least Workbench 1.3 or 3.1 (AmigaOS), some of the Amigas great games (I recommend Ruff'n'Tumble) or some of the amazing demos from the vast Amiga demoscene (like State of the Art from Spaceballs).

The minimig can also use HDF harddisk images, which can be created with [WinUAE](http://www.winuae.net/).

### Recommended minimig config

- for ECS games / demos : CPU = 68000, Turbo=NONE, Chipset=ECS, chipRAM=0.5MB, slowRAM=0.5MB, Kickstart 1.3
- for AGA games / demos : CPU = 68020, Turbo=NONE, Chipset=AGA, chipRAM=2MB, slowRAM=0MB, fastRAM=24MB, Kickstart 3.1
  For Workbench usage, you can try turning TURBO=BOTH for a little speed increase.

### Controlling minimig

Keyboard special keys:

- F12 - OSD menu
- F11 - start monitor (HRTmon) if HRTmon is enabled in OSD menu (otherwise F11 is the Amiga HELP key)
- ScrollLock - toggle keyoard only / mouse / joystick 1 / joystick 2 emulation on the keyboard (direction keys + LCTRL)

### RTG settings

Because OpenAARS uses HDMI out and not VGA, the settings that will result in a flicker free image are limited.
Make sure the Picasso96 tools are installed, and use the tool 'Picasso96Mode' in 'Workbench->Prefs' to input the settings.

Here are the settings I found to work best on my display:
| Resolution | Depth | Width | Height | Clock | il | ds | or | Framesize | BorderSize | pos | syncsize | syncpol | freq |
| ---------- | ------- | ----- | ------ | ----- | --- | --- | ---- | --------- | ---------- | --- | -------- | ------- | ----- |
| 1024x768 | HiColor | 1024 | 768 | 56.72 | | | hor | 1279 | 8 | 0 | 64 | | 44kHz |
| | | | | | | | vert | 802 | 0 | 18 | 8 | | 55Hz |
| 800x600 | HiColor | 800 | 600 | 56.72 | | | hor | 1280 | 24 | 96 | 64 | | 44Khz |
| | | | | | | | vert | 768 | 0 | 0 | 6 | | 57Hz |
| 832x480 | 256Col | 832 | 480 | 28.36 | | | hor | 1012 | 0 | 55 | 64 | | 28kHz |
| | | | | | | | vert | 560 | 0 | 38 | 8 | | 50hz |
| 720x480 | HiColor | 720 | 480 | 28.36 | | | hor | 940 | 0 | 72 | 64 | | 30kHz |
| | | | | | | | vert | 588 | 0 | 98 | 8 | | 51hz |

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

## Building minimig-mist from sources

- checkout the source
- cd into the project directory
- Make sure vivado settings64.sh has been sourced into the shell `source <vivado home>/Vivado/2020.2/settings64.sh`
- run 'rebuild.sh'
- Open the project in Vivado, proceed with the build by pressing 'Generate bitstream'
- wait until the status in the top right corner indicates that the build is finished
- in 'PROGRAM AND DEBUG', unfold 'Open Hardware Manager'
- click 'Open Target' (Make sure the FPGA is connected via the programmer at this point)
- select 'auto connect'

## Building firmware

First build the compiler and patch it.
Luckily there is a Makefile making the process simpler.

```bash
cd EightThirtyTwo
make
<Some output>
cd ..
```

After that build the firmware itself.
The build process yields a file called: 832OSDAD.BIN
The 832OSDAD.BIN is copied to the micro sd card the Open AARS boots from.

```bash
cd fw/ctrl_832
make
cp 832OSDAD.bin <root of sd card>/832OSDAD.BIN
```

Files needed for the Open AARS to boot

| name          | description                                                  |
| ------------- | ------------------------------------------------------------ |
| 832OSDAD.BIN  | Firmware responsible for the On screen display               |
| kick.rom      | Default kickstart rom                                        |
| hrtmon.rom\*  | Hardware monitor rom                                         |
| rom.key\*\*   | If Amiga Forever rom files are used, this key file is needed |
| minimig.art\* | Spining ball logo at boot time                               |
| hardfile.hdf  | Harddisk image, can be created using UAE                     |

'\*' = Optional, '\*\*' = Only needed when Amiga forever kickstart roms are used

## Sources

This sourcecode is based on Rok's previous project ([minimig-de1](https://github.com/rkrajnc/minimig-de1)), and it continues from there. It was split into a new project to allow changes that would never fit in the FPGA on the DE1 board.

Original minimig sources from Dennis van Weeren with updates by Jakub Bednarski are published on [Google Code](http://code.google.com/p/minimig/).

Some minimig updates are published on the [Minimig Discussion Forum](http://www.minimig.net/), done by Sascha Boing.

ARM firmware updates and minimig-tc64 port changes by Christian Vogelsang ([minimig_tc64](https://github.com/cnvogelg/minimig_tc64)) and A.M. Robinson ([minimig_tc64](https://github.com/robinsonb5/minimig_tc64)).

MiST board & firmware by Till Harbaum ([MiST](https://code.google.com/p/mist-board/)).

TG68K.C core by Tobias Gubener.
