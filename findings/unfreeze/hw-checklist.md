# Free-running core: board checklist (Paul)

Image under test: `build/stage_unfreeze_on` (md5 079c8545f7b858f597da16d414fd68e8), loaded over JTAG.
Baseline for the A/B: `build/stage_chip32_on` (md5 2d4bfb4f...), the same design with the core frozen.

Same SD card, same OSD settings (FAST Maximum, Boards all, Turbo chip and Turbo kick OFF) and the same
Startup-Sequence for both images (`C:DDR3First` in both or in neither). Power-cycle the board before each
image's first boot; after a JTAG load with no HDMI, a power cycle is also the first remedy.

| # | check | stage_unfreeze_on | stage_chip32_on |
|---|---|---|---|
| 1 | cold boot to Workbench | | |
| 2 | SysInfo SPEED, run 1 / 2 / 3 | | (0.83x before) |
| 3 | cputest `ct040_01_B-01` | | |
| 4 | OSD reset while SysInfo SPEED runs: back to Workbench? | | |
| 5 | demanding demo set (Turbo off): solid? | | |
| 6 | RTG screen after a cold start | | |
| 7 | idle 10 minutes: no freeze, HDMI still up | | |

Sim prediction for SPEED: the SoC bench's loop is 1.16x faster (CPI 2.672 -> 2.300), so roughly 0.83x -> 0.95x
if the board follows the bench as it did for M14. A difference well outside that says the bench and the board
disagree somewhere; say so before reading anything else into it.
