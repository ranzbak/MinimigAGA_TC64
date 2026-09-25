# fw-fixes: 832 firmware for the mouse-button / OSD-at-boot investigation (2026-09-24)

Every binary here keeps `0xBA, 0xA0` in `fw/ctrl_832/adv7511.c` (the ADV7511
clock-delay value validated on the board, same as `fw-ba-sweep/832OSDAD_BAA0.bin`).
Built in a scratch copy of Paul's checkout (`e2-t4` working tree, sources identical
to HEAD `0965c8a` apart from the generated `version.h`), never in the checkout itself.
Copy to the SD card as `832OSDAD.BIN`.

## 832OSDAD_BAA0_INDIAG.bin  (md5 25cd69cdacf12573fa08867ffc5397a4)

`832OSDAD_BAA0.bin` plus a DIAGNOSTIC line; nothing else changes behaviour.
Source diff against the checkout: `832OSDAD_BAA0_INDIAG.diff` (adv7511.c, fpga.c,
fpga.h, menu.c, osd.c).

* The firmware records WHY the OSD opened the first time after boot:
  `k` = a KEY_MENU event out of the core's key queue, `b` = the board's menu
  button, `e` = an error dialog (code = ErrorMask), `-` = it has not opened yet;
  plus the key code and which HandleUI call since boot it happened on
  (`@1`/`@2` = within the first two passes of the main loop, i.e. something that
  was already queued at boot).
* Shown on line 7 of the **Chipset** menu (the empty line above "back"):
  * on a core WITHOUT the diagnostic (e.g. `stage_ap040_pipe_m14c_fpu`):
    `first open k69@2` style -- works with the current bitstream, card swap only;
  * on `stage_ap040_pipe_m14c_indiag` (capability bit 0x40): `AABB CCDD k69@2`,
    where AA..DD are bytes 6-9 of OSD_CMD_VERSION (see below).

### Reading AABB CCDD (bitstream stage_ap040_pipe_m14c_indiag only)

Bit 7 first.  AA and BB are live, CC and DD are "seen at least once since the
Chipset page was last drawn" (drawing the page clears them, so the FIRST draw
after closing the OSD for a while is the one that counts).

| byte | bits (7..0) |
|------|-------------|
| AA live | `_fire0` (CIA-A PRA bit 6, 0 = LMB down), `potcap1` (POTGOR bit 10, 0 = RMB down), `_mleft0`, `_mright0` (PS/2 mouse, 0 = down), `_lmb`, `_rmb` (keyboard emulation), `joy1enable`, `key_disable` |
| BB live | `cd32pad`, `joy2enable`, then JOYA raw bits 5..0 = fire2, fire, up, down, left, right (1 = idle) |
| CC sticky | `fire0_phantom` (CIA-A saw LMB down that no mouse/keyboard held), `pot_phantom` (same for RMB/POTGOR), then JOYA bits 5..0 that were LOW |
| DD sticky | `joy_menu` (joystick port 2 produced KEY_MENU), `fire0_lost` (mouse held LMB, CIA-A did not see it), then JOYB bits 5..0 that were LOW |

Healthy, idle, OSD open: `AA` = `fd` (key_disable=1), `BB` = `3f`, `CC DD` = `0000`.

## The matching bitstream

`MinimigAGA_TC64-pipelined/build/stage_ap040_pipe_m14c_indiag/minimig_openaars_top.bit`
(md5 354395539d05beff872f7fd979947f53): pipelined-integration 7abe7c3 + the four
uncommitted worktree files (video fix etc., see source.txt/source.diff there),
AP68040-pipelined 9efe490, MMU=1 FPU=1, no ILA.  Same as m14c_fpu plus:
* 1e3e009 -- MCP23S17 joystick expander: MISO sampled 4 clocks after SCK falls
  instead of 1 (CLKS_PER_HALF_BIT 3 -> 6);
* 7abe7c3 -- the input-path diagnostic above.
NOT included: 19a39f1 (PS/2 mouse wheel init fix), committed after synthesis.
Timing: clk_38 +0.449, clk_114 +0.627, clk_148 +0.553, clk_ddr100 +0.006, only the
known 16 clk_gen_sdram -> clk_114 endpoints fail (-0.470).  Pad registers: 16 of
my_pal_to_ddr/myadr_ddr/*_out_reg* in OLOGIC; the only one in fabric is the
internal hsync_out_reg (its replica drives the pin), as expected.

## 832OSDAD_HDMISLIDER.bin  (md5 017594feb7f12fd0ed00c88ec890a8c1, 2026-09-25)

MEMRESET plus an **HDMI** settings page (Settings, between "Video Pos" and
"Chipset"): "Clock delay +/-" steps the ADV7511 register 0xBA delay from
-1.2 to +1.6 ns in 0.4 ns steps, live, with a bar.  Default +0.8 ns (0xA0).
Stored in the config file's former padding byte (`config.hdmi_clkdelay`,
0 = default), so the file stays 212 bytes and older firmware still loads it.
Applied at boot, on Load config, and after every hot-plug re-init.
Source: uncommitted in the integration worktree (5.0-040-pipelined):
adv7511.c/.h, config.c/.h, menu.c/.h.

## 832OSDAD_HDMISLIDER2.bin  (md5 0d666fec6a3a250a8f1494c420c6c156, 2026-09-25)

HDMISLIDER plus a live read-back on the HDMI page, line 5:
`Chip 0xBA: xx  set: yy` -- what the ADV7511 really holds vs what the firmware wrote.
Reason: Paul saw no picture change when stepping. The RTL has its own I2C master on
the same bus (rtl/openaars/adv7511/i2c_sender.vhd, wired-AND with the 832's, no
arbitration); its table writes 0xBA = 0x00 (-1.2 ns) at reset and re-sends the WHOLE
table on every edge of dv_int -- and the firmware's hot-plug poll clears the
interrupt flags (0x96) several times a second.  xx != yy means the RTL overwrote it.

## 832OSDAD_HDMISLIDER3.bin  (md5 ea56c65503f98ed2844dc6dbf2e2a032, 2026-09-25)

HDMISLIDER2 with the default moved to **-1.2 ns (0xBA = 0x00)**: Paul stepped the
slider on the board and -1.2 ns is the one glitch-free value (the light yellows
sparkle at the others). Same value as the RTL table in i2c_sender.vhd.
