# WHDLoad and software compatibility notes

Titles that need something non-default on this machine, and why. The point of
this file is to stop a configuration quirk being investigated twice as a core
bug.

Standing rule before adding anything here: a title that misbehaves is not
evidence against the core until it has been retried with **Turbo off** (chip
and kick). An AP68040 with Turbo reaches chip RAM without waiting for the
Amiga's bus slots, so CPU-to-chipset timing is nowhere near what software of
this era assumes. See `findings/aga-chipset/2026-09-19-demo-fix-port.md`.

## Trolls AGA -- needs the `NOEXPCHIP` tooltype

**Symptom.** WHDLoad 18.3 reports `Exception "Access Fault" ($7008)`,
`PC = $29BD0`, `Word Read from $41D44A6` (and `$41D442A` on a second run).
Triggered by moving vertically above the playfield.

**Fix, from EAB:** add the WHDLoad tooltype **`NOEXPCHIP`** to the game's icon
(select the icon, Right-Amiga+I, add it to Tool Types, Save). Confirmed working
by the poster with no graphics glitches. `NOCACHE` also masks it but costs
speed and treats a symptom. Do not put either in `S:WHDLoad.prefs` -- chip
expansion is wanted for plenty of other titles.

**What was actually happening.** Two crashes, same PC, addresses 124 bytes
apart -- one code path computing a pointer from an index that varies with
player position. Masking to 24 bits:

    $041D44A6 & $00FFFFFF = $1D44A6    (1,918,630)
    $041D442A & $00FFFFFF = $1D442A    (1,918,506)

Both land inside 2 MB of chip RAM, and the difference from the unmasked value
is exactly `$04000000` -- bit 26. An A1200's 68EC020 has a 24-bit address bus,
so bit 26 does not exist: the read wraps into chip RAM, returns a garbage tile,
and nothing happens. Our AP68040 has a full 32-bit bus, so the address is real.

**Why the MMU faulted, not the bus.** This design never raises a bus error --
undecoded 32-bit space is auto-completed with `$FFFF`
(`rtl/soc/TG68K.vhd:1135`). So the access fault can only have come from the
68040's own table walk finding `$04xxxxxx` invalid. Without an MMU the read
would have returned `$FFFF` and the game would have carried on as it does on
real hardware. An `ENVARC:MMU-Configuration` line marking that region Valid
would therefore also suppress the fault -- but `NOEXPCHIP` is the better fix,
because it stops the bad access being generated at all.

**The distinction worth keeping.** The MECHANISM is the 24-bit wrap above. The
TRIGGER is WHDLoad's chip-RAM expansion, which changes where the game's buffers
land and pushes the index up into `$04xxxxxx`. Working out the mechanism did
not predict the fix; the tooltype did. Worth remembering next time a neat
explanation feels like a solution.

**Not a core fault.** The CPU faulted exactly where it should. A CPU that
silently truncated to 24 bits would have hidden this, and would hide real bugs
with it.

Aside from the same thread: the CD32 version under WinUAE adds CD music during
play, if the goal is to enjoy the game rather than to test the machine.
