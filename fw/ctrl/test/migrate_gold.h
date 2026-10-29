/* migrate_gold.h: migrate_test's record of one case's effect, one text
 * block per case in gold/migrate.txt (written by effect_write, read back by
 * effect_read):
 *   case <name>
 *   config <the 212 bytes of configTYPE, hex>
 *   spi <the Config* frames, as config_frames() writes them>
 *   calls <the call log>
 *   vpos <VIDEOSCALE> <VIDEOSCALE_RTG>      (hex)
 *   drives <drives> clkdelay <adv_clkdelay>
 *   df<i> <status> <tracks> <cluster_offset> <sector_offset> <track>
 *         <track_prev> <motor> <FNV-1a of cache[] as 32-bit words> <name, hex>
 * Every field a number or a string without a newline, so the -m32 and the
 * native build write the same file.  Included by migrate_test.c after its
 * struct effect. */
#ifndef MIGRATE_GOLD_H
#define MIGRATE_GOLD_H

static void hex_put(FILE *f, const void *p, size_t n)
{
	const unsigned char *b = p;
	while (n--)
		fprintf(f, "%02x", *b++);
}

static int hex_get(const char *s, void *p, size_t n)
{
	unsigned char *b = p;
	unsigned v;
	while (n--) {
		if (sscanf(s, "%2x", &v) != 1)
			return 0;
		*b++ = (unsigned char)v;
		s += 2;
	}
	return 1;
}

static unsigned long cache_hash(const adfTYPE *d)
{
	unsigned long h = 2166136261u;
	unsigned i;
	for (i = 0; i < MAX_TRACKS; i++)
		h = ((h ^ (d->cache[i] & 0xffffffffu)) * 16777619u) & 0xffffffffu;
	return h;
}

static void effect_write(FILE *f, const char *name, const struct effect *e)
{
	int i;
	fprintf(f, "case %s\nconfig ", name);
	hex_put(f, &e->config, sizeof e->config);
	fprintf(f, "\nspi %s\ncalls %s\nvpos %x %x\ndrives %u clkdelay %u\n",
	        e->spi, e->calls, e->vpos[0], e->vpos[1], e->drives, e->clkdelay);
	for (i = 0; i < 4; i++) {
		const adfTYPE *d = &e->df[i];
		fprintf(f, "df%d %u %u %lu %u %u %u %u %08lx ", i, d->status, d->tracks,
		        (unsigned long)d->cluster_offset, d->sector_offset, d->track, d->track_prev,
		        d->motor, cache_hash(d));
		hex_put(f, d->name, sizeof d->name);
		fputc('\n', f);
	}
}

/* the comparable part of a drive (what effect_write records) */
struct dfrec { unsigned status, tracks, sector_offset, track, track_prev, motor; unsigned long cluster_offset, hash; char name[22]; };
static void dfrec_of(const adfTYPE *d, struct dfrec *r)
{
	memset(r, 0, sizeof *r);
	r->status = d->status; r->tracks = d->tracks; r->sector_offset = d->sector_offset;
	r->track = d->track; r->track_prev = d->track_prev; r->motor = d->motor;
	r->cluster_offset = d->cluster_offset & 0xffffffffu; r->hash = cache_hash(d);
	memcpy(r->name, d->name, sizeof r->name);
}

/* the gold record of case `name` into e (its df[] as dfrec in dfs);
   0 = no such case or a malformed record */
static int effect_read(const char *path, const char *name, struct effect *e, struct dfrec dfs[4])
{
	static char line[16384];
	FILE *f = fopen(path, "r");
	int found = 0, n = 0;
	if (!f)
		return 0;
	memset(e, 0, sizeof *e);
	memset(dfs, 0, 4 * sizeof dfs[0]);
	while (fgets(line, sizeof line, f)) {
		size_t len = strlen(line);
		if (len && line[len - 1] == '\n')
			line[--len] = 0;
		if (!strncmp(line, "case ", 5)) {
			if (found)
				break;
			found = !strcmp(line + 5, name);
			continue;
		}
		if (!found)
			continue;
		if (!strncmp(line, "config ", 7)) {
			if (strlen(line + 7) != 2 * sizeof e->config || !hex_get(line + 7, &e->config, sizeof e->config))
				break;
			n++;
		} else if (!strncmp(line, "spi ", 4)) {
			snprintf(e->spi, sizeof e->spi, "%s", line + 4);
			n++;
		} else if (!strncmp(line, "calls ", 6)) {
			snprintf(e->calls, sizeof e->calls, "%s", line + 6);
			n++;
		} else if (!strncmp(line, "vpos ", 5)) {
			if (sscanf(line + 5, "%x %x", &e->vpos[0], &e->vpos[1]) != 2)
				break;
			n++;
		} else if (!strncmp(line, "drives ", 7)) {
			unsigned dr, cd;
			if (sscanf(line + 7, "%u clkdelay %u", &dr, &cd) != 2)
				break;
			e->drives = (unsigned char)dr;
			e->clkdelay = (unsigned char)cd;
			n++;
		} else if (!strncmp(line, "df", 2) && line[2] >= '0' && line[2] <= '3') {
			struct dfrec *r = &dfs[line[2] - '0'];
			int pos = 0;
			if (sscanf(line + 4, "%u %u %lu %u %u %u %u %lx %n", &r->status, &r->tracks, &r->cluster_offset,
			           &r->sector_offset, &r->track, &r->track_prev, &r->motor, &r->hash, &pos) != 8 ||
			    !hex_get(line + 4 + pos, r->name, sizeof r->name))
				break;
			n++;
		}
	}
	fclose(f);
	return found && n == 9;
}

#endif
