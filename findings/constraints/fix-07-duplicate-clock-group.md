# Fix 7 — Duplicated clock group, one of them matching nothing

**Severity: Low · File: `fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc:53-54`**

## Evidence

```tcl
set_clock_groups -name async_mycfide -asynchronous -group [get_clocks {clk_114, dll_28}] -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
set_clock_groups -name async_mycfide -asynchronous -group [get_clocks {clk_114 dll_28}] -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
```

Two problems in two lines:

**1. Line 53 has a comma inside the braces.** Tcl splits `{clk_114, dll_28}` into
the two words `clk_114,` and `dll_28`. `get_clocks` looks for a clock literally
named `clk_114,`, finds nothing, and emits a warning. So line 53 groups only
`dll_28` against the SPI clock.

**2. Both share `-name async_mycfide`.** Vivado treats the name as an identifier;
declaring two constraints with the same name means the second replaces the first
rather than adding to it. The behaviour is version-dependent and not something to
rely on.

Line 54 is the corrected version of line 53 and was presumably added without
deleting the original.

## Fix

Delete line 53. Keep line 54:

```tcl
set_clock_groups -name async_mycfide -asynchronous \
  -group [get_clocks {clk_114 dll_28}] \
  -group [get_clocks openaars_virtual_top/mycfide/sck_reg_n_0]
```

## Check for the same mistake elsewhere

A comma inside a `get_*` brace list is silent — it produces a warning in the log
and an empty match, not an error. Worth a sweep:

```bash
grep -n "get_clocks {[^}]*,\|get_ports {[^}]*,\|get_cells {[^}]*," \
  fpga/openaars/aars_v5.0/xc7a100t/*.xdc
```

And a sweep for duplicate constraint names:

```bash
grep -oh "\-name [a-zA-Z0-9_]*" fpga/openaars/aars_v5.0/xc7a100t/*.xdc | sort | uniq -d
```

## Verify

Search the synthesis and implementation logs for empty-match warnings after the
change:

```bash
grep -i "no objects matched\|CRITICAL WARNING.*get_clocks" \
  project_1/project_1.runs/*/runme.log
```
