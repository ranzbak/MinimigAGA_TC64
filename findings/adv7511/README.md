# PAL → HDMI (720p50 / 720p60) — findings and fix index

Scope: `rtl/openaars/adv7511/` — `pal_to_ddr.sv`, `pal_to_hd_upsample.v`,
`signal_generator.sv`, `adv_ddr.v`, `frame_freq.v` — plus
`fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc`.

Symptoms under investigation:

* Lines flicker on some input resolutions.
* Horizontal and vertical image position controls become unstable quickly.

Target output: **HDMI 720p @ 50 Hz or 60 Hz**, selected by the input signal.

---

## Fix index

Work them in this order. Each step removes noise that would otherwise mask the
next one.

| # | File | Finding | Effort | Symptom addressed |
|---|---|---|---|---|
| 1 | [fix-01-crossed-offset-ports.md](fix-01-crossed-offset-ports.md) | B1 | 1 line | V offset moves the picture horizontally |
| 2 | [fix-02-vertical-offset-missing.md](fix-02-vertical-offset-missing.md) | B1 | small | V offset does nothing at all |
| 3 | [fix-03-offset-cdc.md](fix-03-offset-cdc.md) | B3 | small | offset glitches while adjusting |
| 4 | [fix-04-read-address-underflow.md](fix-04-read-address-underflow.md) | B2 | small | H offset wraps into a live buffer |
| 5 | [fix-05-write-address-runaway.md](fix-05-write-address-runaway.md) | A1 | small | **primary flicker cause** |
| 6 | [fix-06-hcount-reset-genlock.md](fix-06-hcount-reset-genlock.md) | A2 | medium | **second flicker cause** |
| 7 | [fix-07-dds-increment.md](fix-07-dds-increment.md) | A3 | 1 line | wrong sample count per line |
| 8 | [fix-08-line-length-divider.md](fix-08-line-length-divider.md) | A4 | medium | width jumps, `dev=0` overrun |
| 9 | [fix-09-geometry-hres.md](fix-09-geometry-hres.md) | new | medium | `PAL_HD_H_RES` wrong on both instances |
| 10 | [fix-10-mode-detect-hysteresis.md](fix-10-mode-detect-hysteresis.md) | A6 | small | 50/60 Hz flips mid-frame |
| 11 | [fix-11-collapse-pipelines.md](fix-11-collapse-pipelines.md) | A6/C | medium | deletes the mux and the cross-wiring |
| 12 | [fix-12-interlace-multidriver.md](fix-12-interlace-multidriver.md) | A5 | medium | interlaced modes shimmer |
| 13 | [fix-13-housekeeping.md](fix-13-housekeeping.md) | C | small | latent bugs |
| — | [verification.md](verification.md) | — | — | how to prove each fix |
| — | [reference-timing.md](reference-timing.md) | — | — | clocks, modes, drift budget |

## Quick summary of the two flicker causes

**Fix 5** — the write address is never bounded to its 2048-word line buffer, and
writing is not stopped during vertical blanking. During vsync the write pointer
marches through several buffers that the read side is displaying at the top of
the frame. Vsync length differs per mode and per interlace field, so the
corruption pattern changes every frame.

**Fix 6** — `signal_generator` resets its **horizontal** counter on the source
vsync, at an arbitrary point in the HD line. That produces one runt line and one
extra HSYNC pulse per frame, and the frame length alternates between 751 and 752
HD lines.

## Quick summary of the offset instability

**Fix 1** — on the 50 Hz instance the vertical offset value is wired to the
horizontal offset port.

**Fix 2** — the vertical offset input is never referenced inside the upsampler;
vertical position is a hardcoded constant.

**Fix 3** — the offset buses cross from `clk_114` to `clk_148` with no
synchroniser, on a path that the constraints explicitly ignore.

**Fix 4** — the horizontal offset is subtracted from the buffer base with no
clamp, so past about 48 it reads out of the neighbouring buffer.
