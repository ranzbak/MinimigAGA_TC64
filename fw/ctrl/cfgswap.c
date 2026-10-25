#include <string.h>

#include "cfgswap.h"
#include "swap.h"

/* The 32-bit fields of configTYPE, in struct order */
static const uint8_t cfg_long_offsets[] = {
	CFG_OFF_VERSION,
	CFG_OFF_KICKDIR,
	CFG_OFF_EXTROMDIR,
	CFG_OFF_HDFDIR,
	CFG_OFF_HDFDIR + 4,
	CFG_OFF_HDFDIR + 8,
	CFG_OFF_HDFDIR + 12,
};

int cfg_order(const uint8_t *buf, size_t len)
{
	uint32_t v;
	if (len < CFG_MIN_SIZE || len > CFG_SIZE)
		return CFG_BAD;
	if (memcmp(buf, CFG_ID, CFG_ID_LEN) != 0)
		return CFG_BAD;
	v = rd_le32(buf + CFG_OFF_VERSION);
	if (v >= 1 && v <= CFG_VERSION_MAX)
		return CFG_RV;
	v = rd_be32(buf + CFG_OFF_VERSION);
	if (v >= 1 && v <= CFG_VERSION_MAX)
		return CFG_BE;
	return CFG_BAD;
}

void cfg_swap(uint8_t *buf)
{
	size_t i;
	for (i = 0; i < sizeof cfg_long_offsets; i++) {
		uint8_t *p = buf + cfg_long_offsets[i];
		uint8_t t;
		t = p[0]; p[0] = p[3]; p[3] = t;
		t = p[1]; p[1] = p[2]; p[2] = t;
	}
}
