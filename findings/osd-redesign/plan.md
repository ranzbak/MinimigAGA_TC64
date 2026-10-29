# OSD redesign: implementation plan

Branch `5.0-040-56mhz`, head 7dd35aa2. Reference build: `build/stage_sdc_7dd35aa2_ship` (utilization.rpt, timing_summary.rpt, util_hier.rpt). All paths below are relative to the repository root.

Written 2026-10-26 (Fable plan agent). Requirements: doc/backlog.md "OSD redesign" (2026-10-17) and scaler item 7a; Paul 2026-10-26: drop the scroll text, keep About and Supporters with an animated background each, answer whether small icons fit.

## 1. Current state

### 1.1 OSD RTL datapath (`rtl/minimig/userio_osd.v`)

- Buffer: `reg [7:0] osdbuf [0:2047]` (:76), a 1-bpp **bitmap**, not a character buffer. Each byte is one pixel column of 8 vertical pixels; read address `{vpos[5:3], horbeam_osd}` (:231) = 8 text lines of 256 columns. The pixel is `vena & bufout[vpos[2:0]]` (:212). There is no font in RTL: the firmware renders glyphs from `fw/ctrl/charrom.h` (8x8, column-major, LSB top) and sends 8 bytes per character (`osd.c` :359-500 `OsdWriteOffset`).
- Window: fixed, `hframe` = 256 OSD pixels from horbeam_osdclk 448 (:164), `vframe` from verbeam bits (:176), output at clk/2 unless `varbeamen` (:161). RTG shifts the horizontal counter by 220 (:134).
- No scroll, highlight or colour hardware: the `highlight`/`invert` logic is commented out (:83, :199-205, :507-515). Colour is applied outside: `amber.v` :395-397 (`OSD_R/G/B` = 0xF0 white on video dimmed >>2 with blue tint) and, for the openaars build (`MINIMIG_TOPLEVEL_DITHER` -> `MINIMIG_TOPLEVEL_OSD`, amber.v :378-380), in `rtl/soc/minimig_virtual_top.v` :559-574 (`osd_window ? {osd_r, red_reg[7:2]} : red_reg`).
- Where it mixes: amber at 28 MHz (`minimig.v` AMBER1, :103-104 of the instantiation block), i.e. `vga_r/g/b` already carry the OSD when they enter `pal_to_ddr` (`rtl/soc/minimig_openaars_top.v` :521-550). From there the OSD pixels go through `crt_beamh` (clk_114, pal_to_ddr.sv :356), the 16-line ring of `pal_to_hd_upsample` (clk_114 write / clk_148 read, :385-428, horizontal resampling 1685/1980 samples per line), `crt_post` (clk_148, :324-349, CRT_LAT 9 + LIN_LAT 3) and `signal_generator` (:431-460) into `adv_ddr` (:464-497). That is backlog item 7a: beam, scanlines, bloom and mask apply to the OSD, and glyph columns are resampled non-integer.
- SPI: slave `userio_osd_spi.v`, command byte[7:2] decoded at :316-338; data byte counter `dat_cnt` saturates at 4 (:352-360). OSD write = `SPI_OSD_BUFFER_ADR` 0x0C: three zero bytes, the line number in data byte 3 (`wraddr <= {wrdat[2:0], 8'b0}` :500), then a byte stream (`wren` :493). Version reply `SPI_VERSION_ADR` 0x88: bytes 0-3 version, 4 = magic 0xA4, 5 = capability byte, 6-9 input diagnostic, 10-15 return `MINION_VER` (:668-682). **All 8 capability bits are assigned** (CORE_CAPS bits 0-3, 0x10 KEYQ, 0x20 TEMP, 0x40 INDIAG, 0x80 IDE2: `fw/ctrl/fpga.h` :27-33), so a new feature needs a new reply byte, not a bit.
- Free command codes (byte values with bits 1:0 = 0): 0x2C, 0x3C, 0x4C, 0x5C, 0x6C, 0x7C, 0xA8 ...; used: 0x08 0x18 0x28 0x04 0x14 0x24 0x34 0x44 0x54 0x58 0x64 0x0C 0x1C 0x88 0x98 0x9C.
- Keys: `osd_ctrl` (Amiga raw keys) plus the key queue (:702-736). Joystick 2 maps to KEY_MENU/ENTER/UP/DOWN/LEFT/RIGHT in `userio.v` :319-340 (the PGUP/PGDOWN diagonal branches at :333-336 are unreachable: the single-direction tests above them match first).
- Cost today (util_hier.rpt): `userio_osd` 198 LUT, 183 FF, 1 RAMB18; `amber` 248 LUT, 2 RAMB36; `pal_to_ddr` 1,582 LUT, 2,302 FF, 39 RAMB36 + 1 RAMB18, 22 DSP (ring 24 RAMB36, crt_post 13, beamh 2).

### 1.2 Firmware (`fw/ctrl`)

- `osd.c`: SPI renderer (`OsdWrite`, `OsdWriteOffset`, `OSD_PrintText` pixel-offset print, `OsdDrawLogo`, `OsdWriteDoubleSize`), title side-stripe (`OsdSetTitle` :298-356 rotates the title into the 22-column left stripe), stars/fireworks on an 8x256 `framebuffer` (:104-266), scroller (`ScrollText` :1073-1121), key input (`OsdGetCtrl` :1016-1061, queue drain :984-1013, auto-repeat). Config commands `ConfigVideo` etc. :853-952.
- `menu.c` (3,075 lines): one `HandleUI()` state machine (:400-2733), `menustate` pairs (`*1` draws, `*2` handles input), `menumask` selectable rows, `menusub` cursor. Key decode :451-603 (modifiers kept in statics; shortcuts Ctrl-Alt-KP+/-, Shift-KP+/-, Shift-KP., Ctrl-Alt-KP0, Ctrl-Alt-F12). Help ticker :605-631 (`helpstate`, `OsdWriteOffset(7, STD_EXIT ..)` slide, then `ScrollText(7, helptext)`); `helptexts[]` :118-131 (3,222 characters of rodata). Pages: MAIN (floppies, CD, settings links) :693-856, FLOPPY :858-912, MAIN2_1 settings hub :933-997, MISC (reset/reboot/about/supporters) :999-1069, ABOUT :1071-1118, SUPPORTERS :1120-1160, LOAD/SAVE config :1162-1235, :1481-1550, FILE_SELECT :1240-1400 (+ `PrintDirectory` :2828-2908, 8 entries = `MAXDIRENTRIES` in `fat.h` :6), CONFIRM :1405-1438, CHIPSET :1555-1735, MEMORY :1740-1903, HARDFILE 1-4 :1913-2037, HARDFILE_SELECTED/EXIT/CHANGED :2042-2176, SYNTHRDB warnings :2178-2218, VIDEO :2223-2339, VIDEO3 (Hpos/Vpos) :2344-2423, HDMI (clock delay, chip readback, INT counters) :2431-2512, AUDIO :2517-2592, ROMFILE :2597-2654, ERROR :2659-2712, INFO :2717-2724. Debug page `_showdebugmessages` :153-162 (8 x 32).
- Host CPU: VexRiscv RV32IMC on CLK_114 (113.4 MHz; `minimig_virtual_top.v` :1426-1429). SPI to the OSD at speed 1 = 18.9 MHz sck (`spi_sck` 52.9 ns, timing_summary clocks; `cfide.vhd` :685-714): 423 ns per byte on the wire, ~60-70 CPU cycles per `SPI()` round trip, so ~2.3 KB/ms. The OSD takes one byte per clk7 period (141 ns), not the limit.
- Firmware image: `RV32OSDB.BIN` 103 KB (text 89 KB, data 3.5 KB, bss 59 KB; README :120). Limit: image end < 0x70000 (`arch/firmware.ld` :23, :73): 450 KB available. Stack: 0x1400-0x2000 (3 KB) in the boot BRAM, high water 0x1950 = 1,712 B used, 1,360 B spare (`stackcheck.h`, README :383). `make -C fw/ctrl check` gates (a)-(j), `make stack`.
- Lock-step: trailer `'S','D','C','V',0,0,SDC_VERSION` (`sdctrailer.c`, `sdc.h` :76 = 0x5D02); `fw/ctrl_boot/lockstep.c` requires bytes 4-5 == 0 and the version == the SD peripheral's VERSION register. The boot ROM paints "FIRMWARE MISMATCH" into the **legacy** bitmap buffer (`lockstep.c` osd_mismatch, 2,048 bytes after command 0x0C).
- Host tests: `fw/ctrl/test/` (mock_hw captures `hosttest_spi`/`hosttest_cs`; `make -C fw/ctrl/test`, `mutants.sh`). Benches: `sim/osd_keyq/run.sh` (iverilog, mutant modes), `sim/hdmi_upsample/` (`tb_osd_video.v` SPI bench of userio_osd, `tb_crt_frame.v` + `crt_run.sh` legs, golden frames, Python models), `tools/vivado/ooc_hostcpu/` (OOC synth flow pattern).

## 2. Resource budget (xc7a100t, stage_sdc_7dd35aa2_ship)

| Resource | Used | Available | Free |
|---|---|---|---|
| Slice LUTs | 47,585 (75.1 %) | 63,400 | 15,815 (but **slices 13,990/15,850 = 88.3 %**: placement is the real limit, keep additions small) |
| Flip-flops | 28,140 (22.2 %) | 126,800 | 98,660 |
| BRAM tiles | 103 (83 RAMB36 + 40 RAMB18) | 135 | 32 tiles (= 32 RAMB36 or 64 RAMB18) |
| DSP48 | 50 | 240 | 190 |

Timing (same build): clk_148 intra WNS **+0.447 ns** (tight), clk_114 +0.363, clk_38 +1.294, dll_28 +14.77; dll_28/clk_114 -> clk_148 covered by `set_max_delay -datapath_only 6.734` (`fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc` :52), WNS +0.851. The one failing group (-0.487 ns, 16 endpoints) is the SDRAM DQ input path clk_gen_sdram -> clk_114 (failing.rpt), pre-existing and unrelated.

| Option | BRAM | LUT | FF | Domain / timing | Picture |
|---|---|---|---|---|---|
| A. Keep mix point in amber, enlarge bitmap to 16x64 chars (8 KB) + attribute bits | +1 RAMB36 for 8 KB bitmap, +1 RAMB18 for 1 KB attributes (per char) | ~+100 | ~+50 | dll_28 (14 ns slack) | Still resampled 1685/1980 per line (uneven glyph columns), still through beam/scanlines/bloom/mask. Does not fix 7a. |
| B. OSD flag through the HDMI chain (24 -> 25 bits) and bypass at the end of crt_post | +1 RAMB36 (32K x 1 ring plane) | ~+200 (flag shift registers through crt_beamh, upsampler, crt_post latency 12, bypass mux) | ~+100 | adds logic and a mux in **clk_148 (0.447 ns)** | 1-bpp, monochrome, no attributes, horizontal resampling remains; only the filters are bypassed. Every scaler mode change must keep the flag aligned (CRT_LAT, LIN_LAT, ring16). |
| **C. Native 720p text layer after crt_post (recommended)** | +2 RAMB36 (cell RAM 2048 x 18, font RAM 4096 x 8); Phase 6 removes the legacy bitmap: -1 RAMB18 | ~+400-500 (counters, two RAM fetch stages, 16:1 palette mux x 26 bits, blend) | ~+1,000 (palette staging + live 2 x 16 x 26, config, pipeline, 6-pixel delay line) | clk_148, fully registered, one LUT level per stage; the 74.25 MHz pixel enable gives 2 clocks per pixel | Pixel-exact glyphs at 720p, independent of PAL/NTSC/RTG/15-31 kHz, no CRT filtering, colour attributes, window anywhere on the 1280x720 raster. |

Recommendation: **C**. It is the only option that solves 7a and the layout wish together, and its cost (2 of 32 free BRAM tiles, ~130 slices) is the smallest relative to what it gives. Option B is almost as expensive and keeps the cramped resampled text; option A is cheap but keeps the smear. Risk to manage: clk_148 slack. Mitigation: every stage registered, the compositor sits on the pixel enable, OOC timing check before integration (Phase 1).

Firmware headroom: 347 KB of image space, so a 4 KB 8x16 font, 2.5 KB shadow text buffer (bss) and a few KB of tables are nothing. The stack is the constraint (1,360 B spare): the new engine must keep every frame small (`make stack`, gate: no frame > 512 B) and keep screen buffers in bss.

## 3. Decisions

### 3.1 Render point and clock domain
A new module `osd_text` (vendor-neutral Verilog, `rtl/openaars/adv7511/osd_text.v`, generic enough for any 720p top) instantiated in `pal_to_ddr.sv` between `hd_gen` and `myadr_ddr`. It runs on `clk_148` with the generator's pixel enable (`signal_generator.sv` r_vid_enable, every other clock), takes the generator's x/y (hz_count/vt_count one pixel ahead of r_x/r_y, :131-146), and composes over `w_o_r/g/b`. The video and syncs pass through a fixed delay line (the module's latency, 3 pixel clocks) so `adv_ddr` sees unchanged relative timing. Write side (SPI decode) stays in `userio_osd.v` (dll_28); the RAMs are true dual-port with two clocks (write port dll_28, read port clk_148), inferred, no primitives. Configuration and palette cross dll_28 -> clk_148 as **staging registers + a commit toggle**, copied to live registers at the generator's frame pulse (`o_frame`) -- the pattern of `r_crt_cfg` (pal_to_ddr.sv :262-282) and the VPOS toggle (wizard.xdc :60-62); the existing `set_max_delay -datapath_only` constraints cover it, no new XDC. The old bitmap path stays as a parameter `OSD_LEGACY` (default 1 for the non-openaars tops; the openaars top sets 0 in Phase 6).

### 3.2 Text grid, cell size, scale
- Cell RAM 2048 cells, stride 64 (address = row << 6 | col): 64 columns x 32 rows addressable; the window shows `cols` x `rows` of them from cell (0,0). Rows beyond the window are off-screen scratch (e.g. a prepared dialog).
- Glyph 8 x 16 pixels, drawn at scale 1 (8x16) or 2 (16x32), a config bit. At scale 2 a 64 x 20 window is 1024 x 640 pixels, centred at x0 = 128, y0 = 40: the AmiCube proportions on 720p. Scale 1 gives 512 x 320 for a small overlay (info toasts). Recommend scale 2, 64 x 20 (rows: tab bar, separator, 15 items, separator, status). Max rows at scale 2: 22 (704 lines).
- Window geometry: x0, y0 in 8-pixel units (8-bit each), cols (1..64), rows (1..32), enable, scale. One window; panels are drawn with cells.

### 3.3 Font source
Firmware-owned. `fw/ctrl/font8x16.h` (256 glyphs x 16 bytes = 4 KB rodata, row-major, bit 7 = left pixel): first version generated from `charrom.h` doubled vertically (keeps the padlock 0x17, note 0x19, arrows 0x10-0x16 used by menu.c :719, :762, :767), later a proper 8x16 face (GPL-compatible, e.g. a public-domain VGA 8x16). A script `fw/ctrl/tools/mkfontmem.py` writes `rtl/openaars/adv7511/osd_font.mem` from the same header; the RTL font RAM is initialised from it (`$readmemh`, vendor-neutral), so the layer works before any upload (boot ROM message, Phase 6) and the firmware uploads only the glyphs it redefines (icons, logo, effect glyphs). Glyph map: 0x00-0x1F symbols/box drawing, 0x20-0x7F ASCII, 0x80-0xBF free for the logo (87 glyphs, see 3.9), 0xC0-0xFF icons/effects.

### 3.4 Attribute format (8 bits per cell)
`attr[3:0]` = foreground palette index, `attr[7:4]` = background palette index. No blink/underline bits (box glyphs and colours do the job). Multi-colour glyphs, if wanted later (3.10), are selected by glyph code range, not by attribute bits, so the 2-byte cell format never changes.

### 3.5 Palette
16 entries x {mode[1:0], r[7:0], g[7:0], b[7:0]}. mode 0 = opaque; 1 = video dimmed (video >> 1); 2 = video unchanged (transparent); 3 = 50/50 blend of entry colour and video (tinted panel). A cell with bg index whose mode is 1/2/3 shows the Amiga picture through: the "background layer under transparent text" comes free. Outside the window: video untouched (no global dim; the firmware draws a dim border row/column if wanted).
Colour scheme (recommendation, firmware data, trivially changed): 0 dim-video (mode 1) for the outer frame; 1 panel 0x1A2434; 2 text 0xC8CCD0; 3 white; 4 tab bar 0x101820; 5 active tab 0xF0A030 (Amiga-ish amber); 6 highlight bar 0x3060C0; 7 highlight text white; 8 value 0x60D0E0; 9 greyed 0x707880; 10 warning 0xE04040; 11 ok 0x40C060; 12 border 0x506070; 13 status bar 0x202830; 14 help panel 0x141C28; 15 black. Alternative: the Workbench 3 four (grey 0xAAAAAA, black, white, blue 0x6688BB) plus amber -- Paul's pick; both fit 16 entries.

### 3.6 Help panel and status line
Firmware-drawn cells. Layout at 64 x 20: row 0 tab bar (5 tabs, active tab in palette 5, the rest 4; F-key hint), row 1 separator (box glyphs), rows 2-17 item list cols 0-39 (label left-aligned, value from col 22, `<`/`>` marks on the focused value item), help panel cols 41-63 (item help text word-wrapped by the firmware at draw time, 22 chars wide, up to 16 lines; also chip readbacks like the HDMI 0xBA register and INT counters for the item under the cursor), row 18 separator, row 19 status line (left: core version / die temperature when `CORE_CAPS_TEMP`; right: key hints "Enter select  Left/Right change  F1-F5 tabs  Esc close"; toasts such as "TURBO", "vol 23 ########", "Refreshing ADV7511" replace it for 1 s). Modal dialogs (confirm, warnings, error page) are a centred box over rows 4-15.

### 3.7 Drop the scroll text (Paul, 2026-10-26)
What exists: the bottom-row help ticker (`menu.c` :605-631 with `helpstate`, `helptext_timer`, `helptexts[]` :118-131, `ScrollText`/`ScrollReset`/`OSD_PrintText` in `osd.c` :268-273, :690-767, :1073-1121, the `offset` parameter of `OsdWriteOffset`), the file-selector long-name scroller (`ScrollLongName` :2735-2759, called :1251), and the credits scrollers on About/Supporters (:1112, :1154). RTL: **none** -- there is no scroll hardware (the invert/highlight remains are comments), and no SPI command is scroll-specific; nothing to remove in RTL. Firmware freed: ~3.2 KB rodata (`helptexts`, measured 3,222 characters) + two credit strings (~0.9 KB) + ~1.0-1.5 KB code (`ScrollText`, `OSD_PrintText`, `ScrollLongName`, the ticker state machine): about 5 KB of 103 KB, exact figure from `make -C fw/ctrl size` before/after (Phase 0 done criterion). The help texts come back as per-item help in the right panel (shortened), the credits as static lines on the About page (20 rows give room).

**Long file names (Paul, 2026-10-26):** the file selector keeps a scroller, for the selected entry only. When the cursor lands on an entry whose name is wider than the name field, the name shows from its start for 500 ms, then scrolls left one cell per step (~8 cells/s, firmware timer) until its last character is at the field's right edge, holds there 1 s, jumps back to the start, and repeats while the entry stays selected. Moving the cursor resets the entry to its start. Unselected long names are cut at the field width with "~". Cell steps only, no RTL: a smooth pixel scroll would need a per-row fine-offset register in `osd_text` (clk_148), not worth the slack. Cost: one row of char-only writes (~70 SPI bytes) per step. Phase 0 therefore keeps `ScrollLongName` in the legacy engine; the new engine's version is written in Phase 3 (`ui.c` file selector, driven by `ui_tick()`).

### 3.8 About and Supporters pages (Paul, 2026-10-26)
Both kept, each with an animated background driven through the cell/attribute buffer and the palette; **no RTL beyond the base design** (palette + transparent modes). Costs per frame on the VexRiscv (one `SPI()` ~65 cycles; frame = 2.27 M cycles at 50 Hz, 1.89 M at 60 Hz):

| Effect | Per-frame SPI bytes | CPU cycles | Share of a 50 Hz frame | RTL |
|---|---|---|---|---|
| Palette cycling (16 entries, 64 B + 2 B cmd) | 66 | ~4.5 k | 0.2 % | none |
| Copper bars: one bg index per row, palette rotated | 66 | ~4.5 k | 0.2 % | none (a per-row colour register would save nothing) |
| Starfield: 48 single-cell glyph stars, erase + draw (char-only writes, 4 B header + 1 B each) | ~480 | ~32 k | 1.4 % | none |
| Plasma: 16 static dither glyphs, attr field precomputed once (1,280 B, 0.6 ms, once), palette cycled per frame | 66 | ~4.5 k | 0.2 % | none |
| Sine colour wave over 12 text rows (attr-only rewrite, 64 B + 4 B per row) | ~820 | ~55 k | 2.4 % | none |
| Glyph plasma (redefine 16 glyphs = 256 B per frame) | ~260 | ~17 k | 0.8 % | none |
| Full cell buffer rewrite (reference, 64x20 pairs) | ~2,570 | ~170 k | 7.5 % | -- |

Picks: **About** = starfield (4 star glyphs at sub-cell dot positions, 48 stars, char-only writes) behind the logo (logo converted once to 8x16 glyphs, 3.9) with copper-bar palette cycling on the title row; credits as static text. **Supporters** = palette-cycled plasma (static dither-glyph field, 12 cycled entries) under the names in three columns, names fading in by a palette ramp. Both under 2 % of a frame; the existing About page already pushes 1.5 KB per 17 ms through the old path, so the main loop's disk service is not worse off. Optional RTL extras (not planned): per-row palette offset register (~10 LUT + 32 x 4 bits) -- unnecessary since bg attributes already give a colour per row; a hardware palette-cycle counter -- unnecessary at 66 bytes per frame.

### 3.9 Logo
`fw/ctrl/logo.h` is 5 rows x 227 columns of column-major bitmap (40 px tall). Converted at build time (same script as the font) into 29 x 3 = 87 glyphs (0x80-0xD6), loaded once when the page opens (1,392 B + headers, ~0.7 ms). Zero RTL.

### 3.10 Icons (Paul's question): yes, there is room
- **Recommended now: 1-bpp icon glyphs in the font RAM, zero RTL.** A 16x16-pixel icon (32x32 on screen at scale 2) is 2 glyphs side by side in one row (2x1 cells); 16x32 is 2x2 cells. Each cell has its own fg/bg colour, so a floppy icon can be a grey body cell plus a coloured label cell. 12 icons (df0-3, CD, HDD, CPU, chipset, memory, monitor, speaker, settings) x 2 = 24 glyphs, well inside 0xC0-0xFF (64 glyphs). Tabs: icon + name (e.g. `[icon] Storage`) fits in 64 columns; the item list: icon in cols 1-2, label from col 4.
- Optional later (Phase 8): a **2-bpp glyph range** 0xE0-0xFF: in those codes each glyph row's 8 bits are 4 pixel pairs, colour = palette[(bg & 0xC) + pair] (4 colours from an aligned palette block), pixels double width. Cost ~40 LUT, 0 BRAM, no attribute change; a 16-pixel-wide 4-colour icon is then 4 cells per row. Gives shaded icons.
- Not recommended: a sprite/icon RAM (16 icons x 16x16x4 bpp = 1 RAMB18 + a second fetch path and an icon index per cell: ~200 LUT and an attribute bit) -- more RTL in the tight domain for little over the glyph route.

### 3.11 Key mapping
Keyboard and joystick already yield KEY_UP/DOWN/LEFT/RIGHT/ENTER/MENU (`userio.v` :319-340, `menu.c` :571-603). New engine: F1-F5 = tabs 1-5; PgUp/PgDn = previous/next tab; Left/Right = previous/next tab when the cursor is on the tab bar, otherwise decrement/increment the focused value; Enter/Space = activate (cycle value / open file selector / run action), so a joystick (no F keys) reaches the tabs with Up past the first item onto the tab bar, then Left/Right; Esc/F12/menu button = close (or back out of a dialog); Backspace in the file selector = parent directory, Home = root (as today). The modifier shortcuts of :453-570 are kept unchanged.

### 3.12 Lock-step between RTL and firmware
- RTL reports the text layer in VERSION reply bytes 10-13: 10 = magic 0xB5 (an old core returns MINION_VER there, a day number <= 31, never 0xB5), 11 = OSD2 version (1), 12 = columns (64), 13 = rows (32). The firmware reads them in `fpga.c` after byte 5 (`SPI_reply()` per byte) and sets `osd2_caps`.
- Phases 1-5: the firmware keeps the legacy engine; on a core without 0xB5 it behaves exactly as today, on a core with it the new engine runs. Any firmware boots on any core.
- Phase 6 (legacy engine deleted): the trailer's reserved bytes 4-5 become `OSD2_REQUIRED` (0 = none). The boot ROM (`fw/ctrl_boot/lockstep.c`) compares it with the core's byte 11 and refuses a mismatch with the same message, now written into the cell RAM (it needs no font upload because the RTL font RAM is initialised). An old boot ROM still refuses a new-format trailer (bytes 4-5 != 0), an old firmware (bytes 4-5 == 0) still boots on a new ROM when the SDC version matches. `test/lockstep_test.c` gets the new cases.

### 3.13 Lores/Hires Filter removed (Paul, 2026-10-26)
"I don't see the value now we have CRT emulation." Both items go, firmware and RTL:
- On openaars amber's interpolation filters never run (`minimig.v` :874 `dblscan(_15khz && !varbeamen && !crt_any)`: any filter setting turns the scandoubler off, and amber filters only work scandoubled). The bits only drive `pal_to_ddr.sv` :302-317: `r_ctl_hblur` (crt_post H blur [1 6 1]/8 or [1 2 1]/4) and `r_ctl_vb` (vertical blend, already off under Scaling Sharp/Area).
- RTL: drop `lr_filter`/`hr_filter` from `crt_cfg` and `crt_any`; tie `i_hblur` and `i_vblend` to 0; `crt_post` `HAS_HBLUR = 0`. `HAS_VBLEND = 0` (3 DSP and the next-line multiply in clk_148 -- slack for `osd_text`) **only if** the scanline/kernel weight ROM (`wrom` {hz60, vblend, scan, phase}) and the Area kernel never use w1 with vblend = 0; the bench decides (all non-filter `crt_run.sh` legs bit-identical with HAS_VBLEND = 0, else keep 1). Amber's filter logic (amber.v :125, :195 and the interpolators) removed; the other tops may break (Paul's QMTech-only rule).
- Bloom: its help says "needs scanlines or a vertical filter"; after this it needs scanlines (or Beam width, check). Help text and the item's `avail()` follow.
- Config: `config.filter` bytes stay in the 212-byte struct (old files still load), ignored and written as 0. `ConfigVideo` sends 0 for the filter bits (or the SPI field is dropped with the RTL, same commit).
- Benches: the filter legs in `sim/hdmi_upsample/crt_run.sh` (`dim_hv`, `bloom_hv`, the hblur unit steps :222-223) are deleted or re-based; every other golden leg must stay bit-identical.

## 4. RTL changes (minimal) and interface spec

### 4.1 `userio_osd.v` (dll_28): four commands, four reply bytes, one output bus
Command byte[7:2] codes (byte values):
- `0x2C SPI_TXT_WR`: d0 = mode (0 = char,attr pairs; 1 = chars only; 2 = attrs only), d1 = cell index[10:8], d2 = cell index[7:0], d3.. = data. Pairs: first byte latched, cell written on the second (both byte lanes); modes 1/2 write one lane per byte. Address increments per cell, wraps at 2048. (Follows the 0x0C pattern: enable set at `dat_cnt == 2`, stream from `dat_cnt == 3`; `dat_cnt` saturation at 4 is harmless as today.)
- `0x3C SPI_FONT_WR`: d0 = font byte address[11:8], d1 = [7:0], d2.. = bytes (glyph n row r at n*16 + r).
- `0x4C SPI_PAL_WR`: d0 = first entry (0..15), then 4 bytes per entry {mode in bits 7:6, r, g, b} into the **staging** palette (one byte at a time, 64 x 8-bit staging register, written in dll_28).
- `0x5C SPI_TXT_CFG`: exactly 5 data bytes: d0 = ctrl {bit0 enable, bit1 scale2, bits 7:2 reserved 0}, d1 = x0/8, d2 = y0/8, d3 = cols, d4 = rows; the 5th byte toggles `txt_commit`. (Own 3-bit byte counter like `ver_cnt`, since `dat_cnt` saturates at 4.)
- Version reply: `ver_cnt` 10 -> 8'hB5, 11 -> 8'd1, 12 -> 8'd64, 13 -> 8'd32 (:669-682).
- New output ports (all dll_28, registered): `txt_we` (1 clk pulse), `txt_lane[1:0]` (char/attr lanes), `txt_adr[10:0]`, `txt_dat[15:0]`; `font_we`, `font_adr[11:0]`, `font_dat[7:0]`; `pal_we`, `pal_adr[5:0]`, `pal_dat[7:0]`; `txt_cfg[39:0]` (staging), `txt_commit` (toggle). The firmware's rule: palette bytes and config before the commit; the live copy changes at one frame boundary.
- Transitional parameter `OSD_LEGACY` (default 1 during Phases 2-5, so every intermediate image still shows the old menu as a fallback): Phase 6 **deletes** the old OSD outright (Paul, 2026-10-26: "Drop the old OSD") -- `osdbuf`, the beam counters, the 0x0C path, the amber/minimig_virtual_top mix, and the parameter itself. No long-term switch; the unbuilt tops (mist/chameleon/de0/de10/virtual) are allowed to break (see memory: QMTech only), the last tag that builds their OSD gets named in the Phase 6 commit.
- Threaded up through `userio.v`, `minimig.v`, `minimig_virtual_top.v` to `minimig_openaars_top.v` (the way `osd_rx_seq` went in 35218e3c), into `pal_to_ddr` as inputs.

### 4.2 `osd_text.v` (new, clk_148)
Ports: `clk` (clk_148), `i_pe` (pixel enable), `i_frame` (hd_gen o_frame), `i_x[11:0]`, `i_y[11:0]` (generator counters, next pixel), `i_r/g/b[7:0]`, `i_hs`, `i_vs`, `i_de`; write side `wclk` (dll_28) with the buses of 4.1; outputs `o_r/g/b`, `o_hs`, `o_vs`, `o_de` delayed by LAT = 3 pixel clocks.
- Cell RAM: `reg [15:0] cells [0:2047]` with two byte-lane writes on `wclk`, read on `clk` (registered output): one RAMB36.
- Font RAM: `reg [7:0] font [0:4095]`, `initial $readmemh("osd_font.mem")`, written on `wclk`, read on `clk`: one RAMB36.
- Live config and palette: copied from the synchronised staging values when the synchronised commit toggle changes and `i_frame` is seen (2-FF synchroniser on the toggle only; the staging bits are static by then).
- Pipeline per pixel enable: (0) window test, cell column/row from x - x0, y - y0 shifted by scale, running cell address (no multiplier), glyph column/line; (1) cell fetch (prefetch for the next cell while the current cell's pixels shift); (2) font fetch {char, line}; (3) bit select, fg/bg index, palette lookup (registered 16:1 mux); (4) blend by mode with the delayed video. Everything one LUT level per clk_148 stage; the delay line is 6 clocks of {24 rgb, hs, vs, de}.
- `pal_to_ddr.sv`: instantiate between `hd_gen` and `myadr_ddr` (inputs `w_o_*`, `w_hd_gen_hsync`, `w_hd_vsync`, `w_adv_de`; outputs into adv_ddr). Expose `hz_count`/`vt_count`-based x/y (add two ports to `signal_generator.sv`, next-pixel coordinates; `o_x/o_y` exist but are one register late).
- No Xilinx primitives and no Artix-7-specific items. If a build needs it, a `TXT_OUTREG` parameter (default 1) adds the BRAM output register stage (also generic Verilog); default on, since Vivado maps it to the RAMB's own register for timing.

### 4.3 Estimated cost of 4.1 + 4.2
+2 RAMB36, ~450 LUT (userio_osd +80 in dll_28; osd_text ~370 in clk_148), ~1,000 FF, 0 DSP. Phase 6: -1 RAMB18, -150 LUT.

## 5. Firmware architecture

New files in `fw/ctrl`:
- `osd2.c/.h` -- the driver. Shadow buffers `txt_chr[32][64]`, `txt_attr[32][64]` (bss, 4 KB), a dirty-row bitmap; `osd2_detect()` (VERSION bytes 10-13 -> `osd2_caps`); `osd2_put(row, col, text, attr)`, `osd2_fill(row, col, n, ch, attr)`, `osd2_box(r0,c0,r1,c1,attr)`, `osd2_attr(row,col,n,attr)` (attr-only); `osd2_flush()` (dirty rows -> 0x2C runs, pairs or one lane); `osd2_pal(i, mode, rgb)` + `osd2_commit(enable, scale, x0, y0, cols, rows)` (0x4C then 0x5C); `osd2_font(first, n, data)` (0x3C); `osd2_wrap(text, width, lines)` helper for the help panel. Each call is a few hundred bytes of code; all screen state lives in bss, never on the stack.
- `font8x16.h` (generated), `osd_icons.h` (icon glyphs), `osd_logo.h` (logo glyphs; generated from logo.h).
- `ui.c/.h` -- the engine. Data-driven tables:
  ```c
  struct ui_item { const char *label; uint8_t kind;        /* UI_TOGGLE, UI_CYCLE, UI_ACTION, UI_FILE, UI_INFO, UI_SEP */
                   uint8_t (*get)(void); void (*set)(uint8_t);   /* value model */
                   const char *const *values; uint8_t nvalues;
                   const char *help; uint8_t (*avail)(void);     /* 0 = greyed, not selectable */
                   uint8_t flags; uint8_t icon; };               /* UI_NEEDS_RESET, UI_LIVE ... */
  struct ui_tab  { const char *name; const struct ui_item *items; uint8_t n; uint8_t icon; };
  ```
  State: tab, cursor, focus (TABBAR / LIST / DIALOG / FILESEL), a one-level dialog (text lines, buttons, callback), the file selector (reuses `ScanDirectory`, `MAXDIRENTRIES` 8 -> 16 in `fat.h`; `DirEntryLFN` grows 2 KB bss), a toast (text + timer). `ui_draw_all()` on tab change/open, `ui_draw_item(i)` and `ui_draw_status()` incremental; `ui_key(c)` = today's decode (:451-603) plus the tab keys of 3.11; `ui_tick()` for timers and effects.
- `menu_model.c` -- the non-drawing logic lifted out of `menu.c`: `hdf_next_type`, `hdf_needs_reset`, `cd_*` helpers, the Config* calls per item, `InsertFloppy`, Kickstart reload sequence (:2627-2639), hardfile apply (:2141-2160), memory-changed reset prompt, config load/save; used by both engines during migration.
- Tab tables (`ui_tabs.c`), item by item from menu.c:
  - **Main**: df0-df3 (insert/eject; KP+/- add/remove drives; Backspace eject all), CD-ROM insert/eject (:739-773, :830-840), Load configuration (Default/1-4, greyed when absent :1167-1184), Save configuration, Reset, Reboot, Return to Chameleon (if `PLATFORM_RECONFIG`), About, Supporters.
  - **Storage**: Floppy drives, Floppy turbo, Floppy sounds (greyed unless `drivesounds_loaded()`), IDE on/off, Port 1 Master type / file, Port 1 Slave type / file, Port 2 Master/Slave type / file (if `CORE_CAPS_IDE2`), HDD sounds; leaving the tab with a change -> the reset dialog (:2095-2114).
  - **System**: Chipset (OCS-A500/A1000/ECS/AGA), Video standard PAL/NTSC, Chip RAM, Slow RAM, Fast RAM, Fast-RAM boards (all/DDR3 only), Kickstart ROM (file -> reload dialog), HRTmon, CD32 pad, Autofire, Volume (0-31, bar in the help panel); the die temperature/HDMI status line (:1590-1603) moves to the status row.
  - **Video**: Scanlines, Scaling, CRT mask, Bloom, Beam width, Hpos, Vpos (Left/Right step +-8 / +-VPOS_STEP), HDMI clock delay (chip readback and INT counters in the help panel), OSD scale (1x/2x) and OSD position (new items, config spare bytes).
  - **Acceleration**: CPU (68000/68010/020; fixed "68040/FPU/MMU" info line when `CORE_CPU_FIXED_040()`), Turbo (none/CHIPRAM/KICK/BOTH), Chip slots (Standard/Fast).
  - Dialogs: Reset/Reboot/Reconfigure confirm, Reload Kickstart, Memory changed, Hardfile changed, No partition table / No filesystem, Error page (left/right pages), Info toasts.
- Migration: `HandleUI()` becomes `if (osd2_caps) ui_handle(); else HandleUI_legacy();`. Phase by phase the tabs are filled; the legacy engine is untouched until Phase 6 deletes `HandleUI_legacy`, `OsdWrite*`, `OsdDrawLogo`, `OsdWriteDoubleSize`, the stars/fireworks framebuffer and `charrom.h` (the boot ROM has its own 17 glyphs).
- Host tests: `test/ui_test.c` with `mock_hw.c`: feeds key sequences into `ui_key()`, compares the shadow buffer against golden screens `test/gold/ui/*.txt` (64x20 text dumps; attributes as a second dump) and the captured SPI byte stream against the expected 0x2C/0x4C/0x5C runs; `test/osd2_test.c` for the driver (dirty rows, lane modes, wrap). Mutants in `mutants.sh` (e.g. a flush that skips dirty rows must fail).
- CPU budget: full redraw 2,570 B ~1.1-1.5 ms (7 %); cursor move 2 rows attr-only ~140 B ~60 us; palette commit ~30 us.

## 6. Phases (one implementation agent each)

### Phase 0 -- firmware cleanup: drop the scroll text
- Inputs: 3.7. Files: `fw/ctrl/menu.c` (:605-631, :1112, :1154, `helptexts`), `fw/ctrl/osd.c` (ScrollText, ScrollReset, OSD_PrintText and scroll statics only as far as `ScrollLongName` does not need them), `fw/ctrl/osd.h`, `fw/ctrl/menu.h`. Keep the file selector's `ScrollLongName` (:1251, :2735-2759): long names still scroll in the legacy engine.
- Done: builds with `-Werror`; `make -C fw/ctrl check` and `make -C fw/ctrl/test` pass; `make size` before/after recorded in the commit message; help ticker and credit scrollers gone (`helptexts` symbol absent in `nm`).
- Verify: host tests; board: open every page, no ticker on the bottom row, file selector long names still scroll, About/Supporters still animate; Esc/F12 close.

### Phase 1 -- `osd_text.v` standalone + bench + OOC
- Inputs: 4.2, 3.2-3.5. Files: new `rtl/openaars/adv7511/osd_text.v`, `osd_font.mem` (from `fw/ctrl/tools/mkfontmem.py` + `font8x16.h`, Phase 1 generates the doubled charrom), `sim/osd_text/` (`osd_text_tb.v`, `model.py`, `run.sh`), `tools/vivado/ooc_osd/` (copy of the `ooc_hostcpu` flow, clock 6.734 ns).
- Bench: instantiates `signal_generator.sv` + `osd_text`, loads cells/font/palette through the write ports (no SPI), captures one 720p frame of `o_r/g/b` at `o_de` to a PPM; `model.py` renders the same from the same cell/font/palette data; gate = byte-identical, including window edges, scale 1 and 2, all four palette modes, a window at x0 = 0 and at the right edge, rows 32. Second leg: layer disabled -> output bit-identical to the input and syncs delayed exactly LAT. Mutant: `+define+OSD_TEXT_MUTANT` that drops the prefetch must fail. iverilog (`-g2012`, as `sim/hdmi_upsample/run.sh`) is enough: ~3 M clocks per frame; use Verilator if a leg exceeds a few minutes.
- Done: bench green incl. mutant; OOC at 6.734 ns: WNS > 0.3 ns, <= 550 LUT, 2 RAMB36, 0 DSP; report in `findings/osd-redesign/phase1.md`.

### Phase 1b -- remove the Lores/Hires filters (RTL + legacy menu)
- Inputs: 3.13. Files: `rtl/minimig/minimig.v` (crt_cfg, crt_any), `rtl/minimig/amber.v`, `rtl/openaars/adv7511/pal_to_ddr.sv`, `crt_post.v` parameters, `sim/hdmi_upsample/crt_run.sh` + goldens, `fw/ctrl/menu.c` (Video page items :2234-2276, help text), `fw/ctrl/osd.c` `ConfigVideo`, `config.c` (filter bytes forced 0).
- Done: remaining `crt_run.sh` legs bit-identical; HAS_VBLEND decision recorded with the bench result; `make -C fw/ctrl check` + host tests green; full build: clk_148 WNS reported against 0.447 ns, LUT/DSP delta recorded.
- Board: Video page without the filter items; scanlines, mask, bloom, beam, Sharp/Area/Line rate look unchanged; old config file with filters set loads without effect.
- Runs before Phase 2 so `osd_text` gets the freed clk_148 slack.

### Phase 2 -- SPI decode, integration, full build, board smoke
- Inputs: 4.1, 3.12. Files: `rtl/minimig/userio_osd.v`, `userio.v`, `minimig.v`, `rtl/soc/minimig_virtual_top.v`, `minimig_openaars_top.v`, `rtl/openaars/adv7511/pal_to_ddr.sv`, `signal_generator.sv` (x/y ports), `sim/hdmi_upsample/tb_osd_text_spi.v` (after `tb_osd_video.v`), `crt_run.sh` new legs, `fw/ctrl/osd2.c/.h`, `fpga.c` (bytes 10-13), `menu.c` (debug page: Ctrl-Alt-F12 renders `_showdebugmessages` on the new layer when `osd2_caps`, otherwise as today).
- Benches: SPI bench: each command's bytes land where specified (cell lanes, font bytes, palette staging, cfg + commit toggle), VERSION bytes 10-13, an unknown command untouched, 0x0C still works; mutants (commit toggle never flips; lane swap). `crt_run.sh` legs `osd2off` (layer present, disabled: every existing golden leg bit-identical) and `osd2win` (window at a known place: the pin frame equals the Phase 1 model composited over the golden frame).
- Build: `tools/vivado/build_ap040.tcl` into `build/stage_osd2_<hash>`; done criteria: BRAM <= 105 tiles, LUT delta <= +600, clk_148 WNS >= 0.2 ns, no new failing group; `make -C fw/ctrl check`.
- Board checklist (Paul): old firmware on new core = today's OSD; new firmware: boot UART prints the OSD2 bytes; Ctrl-Alt-F12 shows the debug page in the new layer, crisp, with scanlines/mask/bloom on; the layer survives PAL/NTSC switch, RTG mode, 15/31 kHz; reset button clears it; disable leaves the picture untouched.

### Phase 3 -- engine core, Main + System tabs, host tests
- Inputs: section 5, 3.6, 3.11. Files: new `fw/ctrl/ui.c/.h`, `ui_tabs.c`, `menu_model.c/.h`, `fw/ctrl/Makefile`, `test/ui_test.c`, `test/osd2_test.c`, `test/Makefile`, `test/mutants.sh`, `test/gold/ui/`, `menu.c` (dispatcher, model code moved out, legacy untouched otherwise), `fat.h` (`MAXDIRENTRIES` 16), config spare byte for OSD scale/position.
- Done: on an OSD2 core the Main and System tabs work end to end (floppy insert via the 16-entry file selector with the selected-entry long-name scroll of 3.7, host-tested with a mock timer: start held 500 ms, cell steps, end held 1 s, restart, reset on cursor move, CD insert/eject, load/save config, reset/reboot dialogs, chipset/memory/kickstart with their reset prompts); other tabs show "coming in Phase 4" placeholders; `make stack`: no frame > 512 B; host tests + mutants green; `make check` green.
- Board: full session from power-on on the new engine; the same session on an old-core bitstream (legacy engine) to prove the fallback.

### Phase 4 -- Storage, Video, Acceleration tabs, dialogs, toasts, status line
- Files: `ui_tabs.c`, `menu_model.c`, `ui.c` (dialog/toast/help wrap), golden screens.
- Done: every item of section 5's map present (checklist against menu.c line refs), hardfile-changed and memory-changed flows identical in effect to the legacy ones (host test replays the same key sequences on both engines and compares the resulting `config` struct and Config* SPI stream -- the strongest migration check), Hpos/Vpos with Left/Right, HDMI clock delay with readback in the panel.
- Board: Paul's checklist per tab; CRT settings visible live while the OSD is open (the layer bypasses the filters).

### Phase 5 -- proper 8x16 font, icons (1-bpp), OSD scale/position items
- Files: `font8x16.h` (new face), `osd_icons.h`, `mkfontmem.py`, `ui_tabs.c` (icon column), Video tab items, `config.h` spare byte.
- Done: font renders every glyph menu.c uses (0x10-0x17 arrows/padlock, 0x19 note, box set); icons in tabs and items; scale 1x/2x and position saved with the config; `font8x16.h` and `osd_font.mem` from one source (`make check` gate (k): regenerate and diff).

### Phase 6 -- remove the legacy path, lock-step trailer, boot ROM message
- Files: `userio_osd.v` (old bitmap path and `OSD_LEGACY` deleted), `amber.v`/`minimig_virtual_top.v` (old OSD mix deleted), `userio_osd_spi.v` (0x0C decode removed), `fw/ctrl/menu.c` + `osd.c` (delete legacy engine/renderer, `charrom.h`, logo bitmap renderer), `fw/ctrl/sdctrailer.c`, `fw/ctrl_boot/lockstep.c/.h`, `fw/ctrl_boot/test/lockstep_test.c`, the boot ROM image + `OSDBoot_rv_ROM.vhd` (recipe in `fw/ctrl_boot/README.md`), `fw/ctrl/Makefile` check (h).
- Done: utilisation -1 RAMB18 / -150 LUT; `osd_keyq` bench still passes, `tb_osd_video` retired or rewritten for the text layer; lockstep host test covers {old fw, new fw} x {old ROM semantics, new ROM}; board: deliberately mismatched OSD2_REQUIRED shows "FIRMWARE MISMATCH" in the text layer and halts.

### Phase 7 -- About and Supporters effects, logo glyphs
- Inputs: 3.8, 3.9. Files: `ui_about.c` (starfield + copper palette), `ui_supporters.c` (plasma palette cycle), `osd_logo.h` + generator, `ui.c` tick hook.
- Done: measured cycles per frame via `TIMER` deltas printed on the UART in DebugMode: About < 50 k, Supporters < 10 k; floppy read during the About page unaffected (board: load an ADF while the page animates).

### Phase 8 (optional) -- 2-bpp icon glyph range
- Inputs: 3.10. Files: `osd_text.v`, Phase 1 bench + model, `osd_icons.h`. Done: ~40 LUT, bench pixel-exact, clk_148 slack unchanged within 0.05 ns.

## 7. Risks and open questions for Paul

1. **clk_148 slack (0.447 ns)**: a ~370-LUT addition in that domain. The OOC check in Phase 1 and the full-build gate in Phase 2 are the stop points; fallback is one more pipeline stage (LAT 4) -- the delay line absorbs it.
2. **adv_ddr row offset**: the scaler plan notes the pins show generator rows 15..734, not 0..719 (findings/scaler/plan.md, "Finding"). The Phase 1 model works in generator coordinates; Phase 2's `osd2win` leg measures the on-pin position, and the firmware's default y0 is set from that measurement. Open: whether to fix adv_ddr instead (separate backlog item).
3. **RAM collision**: a cell or glyph rewritten while being displayed gives one wrong pixel for one frame; palette/config are commit-latched so they never tear. Accept.
4. **Boot ROM size**: the Phase 6 mismatch painter in the cell RAM is smaller than today's 2,048-byte bitmap loop; `_end` 0x13D4 < 0x1400 must hold (`make check` (g)).
5. **Stack**: 1,360 B spare. The engine keeps buffers in bss; gate in Phase 3. If the help wrapper or `sprintf` paths need more, raise `STACK_FLOOR` only after checking the boot ROM `_end`.
6. **Open -- grid/scale**: 64 x 20 at scale 2 (1024 x 640) is the recommendation; the scale bit lets Paul compare 1x on the board before the final layout is frozen in Phase 3.
7. **Open -- colour scheme**: 3.5 proposes an AmiCube-like dark scheme; the Workbench-grey alternative is one palette table away.
8. **Open -- tab names and item placement**: Audio volume on System or Video? Load/Save on Main (proposed) or a sixth "Config" tab? The table format makes either a data change.
9. **Decided -- long file names** (Paul, 2026-10-26): selected entry holds its start 500 ms, then scrolls to the end (3.7).
10. **Decided -- old OSD** (Paul, 2026-10-26): dropped in Phase 6, no long-term `OSD_LEGACY` switch; the other tops may break.
11. **Joystick PGUP/PGDOWN branches in userio.v :333-336 are dead**; harmless, but worth a one-line note or removal when userio.v is touched in Phase 2.

### Critical files for implementation
- rtl/minimig/userio_osd.v
- rtl/openaars/adv7511/pal_to_ddr.sv
- rtl/openaars/adv7511/signal_generator.sv
- fw/ctrl/menu.c
- fw/ctrl/osd.c
