# check_io.awk: static check of the I/O accesses in an objdump -d listing.
#   awk -v mode=b -f check_io.awk build/RV32OSDA.dis     (b) no load from the UART, 0xFFFFFFF0
#   awk -v mode=c -f check_io.awk build/RV32OSDA.dis     (c) I/O offsets multiple of 4
# Tracks, per function and in listing order, the constant held by a register
# after li / lui / addi / mv from a known register ("zero" is 0), so that
#   li a4,-112 ; lhu a5,0(a4)      and      lui a5,0xfffff ; lw a0,-16(a5)
# are seen like  lhu a5,-112(zero) .  Limits: straight-line tracking only (a
# register is forgotten when anything else writes it, at every call and after
# an unconditional jump, but not at other branch joins), so an address computed any other way, or held across
# a join, is not seen.  An access counts as I/O when its address is in
# -256..-1 (0xFFFFFF00..0xFFFFFFFF).
function v32(x) { x = x % 4294967296; if (x >= 2147483648) x -= 4294967296; if (x < -2147483648) x += 4294967296; return x }
function hex(s,   i, c, r) { r = 0; s = tolower(s); for (i = 3; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)) - 1; r = r * 16 + c } return r }
function num(s) { if (s ~ /^0x/) return hex(s); if (s ~ /^-0x/) return -hex(substr(s, 2)); return s + 0 }
function known(r) { return (r == "zero") || (r in val) }
function getv(r) { return (r == "zero") ? 0 : val[r] }
/^[0-9a-f]+ <.*>:/ { delete val; next }
{
	line = $0; sub(/#.*/, "", line)
	n = split(line, f, "\t"); if (n < 3) next
	op = f[3]; gsub(/ /, "", op)
	args = (n >= 4) ? f[4] : ""; gsub(/ /, "", args)
	if (op ~ /^(lb|lbu|lh|lhu|lw|sb|sh|sw)$/) {
		if (args ~ /^[a-z0-9]+,-?[0-9a-fx]+\([a-z0-9]+\)$/) {
			split(args, p, /[,()]/); off = num(p[2]); base = p[3]
			if (known(base)) {
				a = v32(getv(base) + off)
				if (a >= -256 && a <= -1) {
					io++; if (base == "zero") iozero++; else iotracked++
					if (mode == "b" && op ~ /^l/ && a >= -16 && a <= -13) { print; bad++ }
					if (mode == "c" && (-a) % 4 != 0) { print; bad++ }
				}
			}
			if (op ~ /^l/) delete val[p[1]]
		}
		next
	}
	# the instruction after an unconditional jump is reached only by a branch
	# from elsewhere (clang lays out such blocks): nothing is known there
	if (op ~ /^(j|jr|ret|mret)$/) { delete val; next }
	if (op ~ /^(b[a-z]*|nop|ecall|ebreak|fence|wfi)$/) next
	if (op ~ /^(jal|jalr|call|tail)$/) { delete val; next }
	split(args, p, ",")
	rd = p[1]
	if (op == "li") { val[rd] = v32(num(p[2])); next }
	if (op == "lui") { val[rd] = v32(num(p[2]) * 4096); next }
	if (op == "addi" && known(p[2])) { val[rd] = v32(getv(p[2]) + num(p[3])); next }
	if (op == "mv" && known(p[2])) { val[rd] = getv(p[2]); next }
	delete val[rd]
}
END {
	if (io == 0) { print "check_io: no I/O access found in the listing (empty or unparsable .dis?)"; exit 1 }
	if (bad) { printf "check (%s) FAIL: %d offending I/O accesses (%d I/O accesses seen: %d zero-based, %d through a tracked constant base)\n", mode, bad, io, iozero, iotracked; exit 1 }
	printf "check (%s) pass: %d I/O accesses seen (%d zero-based, %d through a tracked constant base)\n", mode, io, iozero, iotracked
}
