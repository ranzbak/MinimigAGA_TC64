/*
 * CD disc model and CUE sheet parser -- see cue.h and
 * findings/cdrom/plan.md 13.4.
 *
 * No library call but memset, no malloc, nothing big on the stack.
 */

#include <string.h>
#include "cue.h"

static const char *const cue_text[] = {
	"ok", "syntax", "unknown cmd", "line too long", "file type", "track mode",
	"too many", "track order", "bad INDEX", "PREGAP+INDEX0", "2nd session",
	"file missing", "WAV format", "sector sizes", "past file end", "no tracks",
	"read error"
};

uint32_t cue_sector_size(int32_t type)
{
	return type == CD_DATA2048 ? 2048 : 2352;
}

static int32_t fail_at(struct cue_parser *p, int32_t e, int32_t line)
{
	p->error = e;
	p->error_line = line;
	return e;
}

static int32_t fail(struct cue_parser *p, int32_t e)
{
	return fail_at(p, e, p->line);
}

/* Keyword match, any case. */
static int32_t kw(const char *s, const char *k)
{
	int32_t i = 0;
	for (;;) {
		char c = s[i], w = k[i];
		if (!w)
			return c == 0;
		if (c >= 'a' && c <= 'z')
			c = (char)(c - 32);
		if (c != w)
			return 0;
		i++;
	}
}

/* Decimal, 1 to 6 digits, up to the end of s. */
static int32_t num(const char *s, int32_t *v)
{
	int32_t n = 0, i = 0;
	while (s[i] >= '0' && s[i] <= '9') {
		if (i == 6)
			return 0;
		n = n * 10 + (s[i] - '0');
		i++;
	}
	if (!i || s[i])
		return 0;
	*v = n;
	return 1;
}

/* Index of the next ':' in s (cut there), -1 if none. */
static int32_t cut_colon(char *s)
{
	int32_t i = 0;
	while (s[i]) {
		if (s[i] == ':') {
			s[i] = 0;
			return i;
		}
		i++;
	}
	return -1;
}

/* mm:ss:ff -> sectors (75 per second). */
static int32_t msf(char *s, int32_t *v)
{
	int32_t m, sec, f, a, b;
	a = cut_colon(s);
	if (a < 0)
		return 0;
	b = cut_colon(s + a + 1);
	if (b < 0)
		return 0;
	if (!num(s, &m) || !num(s + a + 1, &sec) || !num(s + a + b + 2, &f) || sec > 59 || f > 74)
		return 0;
	*v = (m * 60 + sec) * 75 + f;
	return 1;
}

void cue_begin(struct cue_parser *p, struct cd_disc *d, cue_open_fn open, void *ctx)
{
	memset(p, 0, sizeof(*p));
	memset(d, 0, sizeof(*d));
	p->disc = d;
	p->open = open;
	p->ctx = ctx;
	p->line = 1;
	p->cur_file = -1;
}

static int32_t do_file(struct cue_parser *p, char **tok, int32_t n)
{
	struct cd_disc *d = p->disc;
	struct cd_file *f;
	int32_t wave, r;
	if (n != 3)
		return fail(p, CUE_E_SYNTAX);
	if (kw(tok[2], "BINARY"))
		wave = 0;
	else if (kw(tok[2], "WAVE"))
		wave = 1;
	else
		return fail(p, CUE_E_FILETYPE);
	if (d->files >= CD_MAX_FILES)
		return fail(p, CUE_E_TOOMANY);
	f = &d->file[d->files];
	memset(f, 0, sizeof(*f));
	f->wave = (uint8_t)wave;
	r = p->open(p->ctx, tok[1], f);
	if (r != CUE_OK)
		return fail(p, r);
	p->cur_file = d->files;
	d->files++;
	return CUE_OK;
}

static int32_t do_track(struct cue_parser *p, char **tok, int32_t n)
{
	struct cd_disc *d = p->disc;
	struct cd_track *t;
	int32_t i = d->tracks, v, type;
	if (n != 3 || p->cur_file < 0 || !num(tok[1], &v))
		return fail(p, CUE_E_SYNTAX);
	if (i >= CD_MAX_TRACKS)
		return fail(p, CUE_E_TOOMANY);
	if (v != i + 1)
		return fail(p, CUE_E_ORDER);
	if (kw(tok[2], "MODE1/2048"))
		type = CD_DATA2048;
	else if (kw(tok[2], "MODE1/2352"))
		type = CD_DATA2352;
	else if (kw(tok[2], "AUDIO"))
		type = CD_AUDIO;
	else
		return fail(p, CUE_E_MODE);
	if (d->file[p->cur_file].wave && type != CD_AUDIO)
		return fail(p, CUE_E_MIXED);
	if (i && d->track[i - 1].file == p->cur_file &&
	    cue_sector_size(d->track[i - 1].type) != cue_sector_size(type))
		return fail(p, CUE_E_MIXED);
	t = &d->track[i];
	t->number = (uint8_t)v;
	t->type = (uint8_t)type;
	t->file = (uint8_t)p->cur_file;
	p->idx0[i] = -1;
	p->idx1[i] = -1;
	p->pregap[i] = 0;
	p->postgap[i] = 0;
	p->tline[i] = p->line;
	d->tracks++;
	return CUE_OK;
}

static int32_t do_index(struct cue_parser *p, char **tok, int32_t n)
{
	struct cd_disc *d = p->disc;
	int32_t t = d->tracks - 1, i, fr;
	if (n != 3 || t < 0 || !num(tok[1], &i) || !msf(tok[2], &fr))
		return fail(p, CUE_E_SYNTAX);
	if (d->track[t].file != p->cur_file)	/* INDEX in a later FILE than its TRACK */
		return fail(p, CUE_E_INDEX);
	if (i == 0) {
		if (p->idx0[t] >= 0 || p->idx1[t] >= 0)
			return fail(p, CUE_E_INDEX);
		if (p->pregap[t])
			return fail(p, CUE_E_GAP);
		p->idx0[t] = fr;
	} else if (i == 1) {
		if (p->idx1[t] >= 0 || (p->idx0[t] >= 0 && fr < p->idx0[t]))
			return fail(p, CUE_E_INDEX);
		p->idx1[t] = fr;
	} else {
		return fail(p, CUE_E_INDEX);
	}
	return CUE_OK;
}

static int32_t do_gap(struct cue_parser *p, char **tok, int32_t n, int32_t post)
{
	int32_t t = p->disc->tracks - 1, fr;
	if (n != 2 || t < 0 || !msf(tok[1], &fr))
		return fail(p, CUE_E_SYNTAX);
	if (post) {
		p->postgap[t] = fr;
	} else {
		if (p->idx0[t] >= 0)
			return fail(p, CUE_E_GAP);
		p->pregap[t] = fr;
	}
	return CUE_OK;
}

static int32_t is_blank(char c)
{
	return c == ' ' || c == '\t' || c == '\r';
}

static int32_t do_line(struct cue_parser *p)
{
	char *tok[5];
	char *b = p->buf;
	int32_t n = 0, i = 0, v;

	if (p->line == 1 && (uint8_t)b[0] == 0xEF && (uint8_t)b[1] == 0xBB && (uint8_t)b[2] == 0xBF)
		i = 3;	/* UTF-8 byte order mark */
	while (n < 5) {
		char c;
		while (is_blank(b[i]))
			i++;
		c = b[i];
		if (!c)
			break;
		if (c == '"') {
			i++;
			tok[n++] = b + i;
			while (b[i] != '"' && b[i])
				i++;
			if (!b[i])
				return fail(p, CUE_E_SYNTAX);
			b[i++] = 0;
		} else {
			tok[n++] = b + i;
			while (b[i] && !is_blank(b[i]))
				i++;
			if (b[i])
				b[i++] = 0;
		}
	}
	if (!n)
		return CUE_OK;
	if (kw(tok[0], "REM")) {
		if (n >= 3 && kw(tok[1], "SESSION")) {
			if (!num(tok[2], &v))
				return fail(p, CUE_E_SYNTAX);
			if (v > 1)
				return fail(p, CUE_E_SESSION);
		}
		return CUE_OK;
	}
	if (kw(tok[0], "CATALOG") || kw(tok[0], "TITLE") || kw(tok[0], "PERFORMER") ||
	    kw(tok[0], "SONGWRITER") || kw(tok[0], "FLAGS") || kw(tok[0], "ISRC") ||
	    kw(tok[0], "CDTEXTFILE"))
		return CUE_OK;
	if (kw(tok[0], "FILE"))
		return do_file(p, tok, n);
	if (kw(tok[0], "TRACK"))
		return do_track(p, tok, n);
	if (kw(tok[0], "INDEX"))
		return do_index(p, tok, n);
	if (kw(tok[0], "PREGAP"))
		return do_gap(p, tok, n, 0);
	if (kw(tok[0], "POSTGAP"))
		return do_gap(p, tok, n, 1);
	return fail(p, CUE_E_UNKNOWN);
}

static int32_t end_line(struct cue_parser *p)
{
	int32_t r = CUE_OK;
	if (p->overflow)
		r = fail(p, CUE_E_LINE);
	else {
		p->buf[p->len] = 0;
		r = do_line(p);
	}
	p->len = 0;
	p->overflow = 0;
	p->line++;
	return r;
}

int32_t cue_feed(struct cue_parser *p, const char *text, uint32_t len)
{
	uint32_t i;
	for (i = 0; i < len && p->error == CUE_OK; i++) {
		char c = text[i];
		if (c == '\n')
			end_line(p);
		else if (p->len < CUE_LINE_MAX)
			p->buf[p->len++] = c;
		else
			p->overflow = 1;
	}
	return p->error;
}

/* Sectors of a file: a partial last sector counts for audio (padded with
   silence), not for data (12.2: the ISO's tail is ignored). */
static uint32_t file_sectors(const struct cd_disc *d, int32_t file)
{
	int32_t i, type = CD_DATA2048;
	uint32_t bytes = d->file[file].data_bytes, size;
	for (i = 0; i < d->tracks; i++)
		if (d->track[i].file == file)
			type = d->track[i].type;
	size = cue_sector_size(type);
	return bytes / size + ((type == CD_AUDIO && bytes % size) ? 1 : 0);
}

static int32_t layout(struct cue_parser *p)
{
	struct cd_disc *d = p->disc;
	int32_t i, base = 0, end = 0;

	if (!d->tracks)
		return fail_at(p, CUE_E_EMPTY, 0);
	for (i = 0; i < d->tracks; i++) {
		struct cd_track *t = &d->track[i];
		int32_t first = i == 0 || d->track[i - 1].file != t->file;
		int32_t last = i + 1 == d->tracks || d->track[i + 1].file != t->file;
		int32_t fsec = (int32_t)file_sectors(d, t->file);
		int32_t i1 = p->idx1[i];

		if (i1 < 0)
			return fail_at(p, CUE_E_INDEX, p->tline[i]);
		if (first) {
			base = i == 0 ? -i1 : end + p->pregap[i];	/* track 1 INDEX 01 is LBA 0 */
		} else {
			if (i1 <= p->idx1[i - 1] || (p->idx0[i] >= 0 && p->idx0[i] < p->idx1[i - 1]))
				return fail_at(p, CUE_E_INDEX, p->tline[i]);
			base += p->postgap[i - 1] + p->pregap[i];
		}
		if (i1 >= fsec)
			return fail_at(p, CUE_E_END, p->tline[i]);
		t->lba = (uint32_t)(base + i1);
		t->file_offset = d->file[t->file].data_offset + (uint32_t)i1 * cue_sector_size(t->type);
		t->pregap_silent = 0;
		if (i == 0)
			t->pregap_lba = 0;
		else if (p->pregap[i]) {
			t->pregap_lba = t->lba - (uint32_t)p->pregap[i];
			t->pregap_silent = 1;
		} else if (p->idx0[i] >= 0)
			t->pregap_lba = (uint32_t)(base + p->idx0[i]);
		else if (first)
			t->pregap_lba = (uint32_t)base;	/* file bytes before INDEX 01: an implicit INDEX 00 at 0 */
		else
			t->pregap_lba = t->lba;
		t->sectors = (uint32_t)(last ? fsec - i1 : p->idx1[i + 1] - i1);
		if (last)
			end = base + fsec + p->postgap[i];
	}
	d->leadout = (uint32_t)end;
	return CUE_OK;
}

int32_t cue_end(struct cue_parser *p)
{
	if (p->error == CUE_OK && (p->len || p->overflow))
		end_line(p);	/* no newline after the last line */
	if (p->error != CUE_OK)
		return p->error;
	return layout(p);
}

void cue_message(const struct cue_parser *p, char *buf)
{
	const char *t = cue_text[(p->error >= 0 && p->error <= CUE_E_READ) ? p->error : CUE_E_SYNTAX];
	char digits[8];
	int32_t n = 0, v = p->error_line, k = 0, i = 0;
	if (v > 0) {
		buf[0] = 'l';
		buf[1] = 'i';
		buf[2] = 'n';
		buf[3] = 'e';
		buf[4] = ' ';
		n = 5;
		if (v > 9999)
			v = 9999;
		while (v) {
			digits[k++] = (char)('0' + v % 10);
			v /= 10;
		}
		while (k)
			buf[n++] = digits[--k];
		buf[n++] = ':';
		buf[n++] = ' ';
	}
	while (t[i] && n != 23)
		buf[n++] = t[i++];
	buf[n] = 0;
}

void cue_single(struct cd_disc *d, const char *shortname, uint32_t bytes)
{
	int32_t i;
	memset(d, 0, sizeof(*d));
	for (i = 0; i < 11 && shortname[i]; i++)
		d->file[0].shortname[i] = shortname[i];
	d->file[0].data_bytes = bytes;
	d->files = 1;
	d->track[0].number = 1;
	d->track[0].type = CD_DATA2048;
	d->track[0].sectors = bytes / 2048;
	d->tracks = 1;
	d->leadout = bytes / 2048;
}

static uint32_t le16(const uint8_t *b)
{
	return (uint32_t)b[0] | ((uint32_t)b[1] << 8);
}

static uint32_t le32(const uint8_t *b)
{
	return le16(b) | (le16(b + 2) << 16);
}

static int32_t id4(const uint8_t *b, const char *id)
{
	return b[0] == (uint8_t)id[0] && b[1] == (uint8_t)id[1] && b[2] == (uint8_t)id[2] && b[3] == (uint8_t)id[3];
}

int32_t cue_wav(cue_read_fn read, void *ctx, uint32_t size, struct cd_file *f)
{
	uint8_t h[16];
	uint32_t pos = 12, len;
	int32_t fmt = 0;
	if (size < 12 || !read(ctx, 0, h, 12) || !id4(h, "RIFF") || !id4(h + 8, "WAVE"))
		return CUE_E_WAV;
	while (size - pos >= 8) {
		if (!read(ctx, pos, h, 8))
			return CUE_E_WAV;
		len = le32(h + 4);
		if (id4(h, "fmt ")) {
			if (len < 16 || size - pos - 8 < 16 || !read(ctx, pos + 8, h, 16))
				return CUE_E_WAV;
			if (le16(h) != 1 || le16(h + 2) != 2 || le32(h + 4) != 44100 ||
			    le16(h + 12) != 4 || le16(h + 14) != 16)
				return CUE_E_WAV;
			fmt = 1;
		} else if (id4(h, "data")) {
			if (!fmt)
				return CUE_E_WAV;
			f->data_offset = pos + 8;
			f->data_bytes = len < size - pos - 8 ? len : size - pos - 8;
			return CUE_OK;
		}
		if (len > size - pos - 8)
			break;
		pos += 8 + len + (len & 1);
		if (pos > size)
			break;
	}
	return CUE_E_WAV;
}

int32_t cue_locate(const struct cd_disc *d, uint32_t lba, struct cue_loc *loc)
{
	int32_t i;
	const struct cd_track *t;
	uint32_t end, size;
	if (lba >= d->leadout || !d->tracks)
		return 0;
	i = d->tracks - 1;
	while (i != 0 && d->track[i].pregap_lba > lba)
		i--;
	t = &d->track[i];
	end = i + 1 < d->tracks ? d->track[i + 1].pregap_lba : d->leadout;
	size = cue_sector_size(t->type);
	loc->track = i;
	loc->file = t->file;
	loc->silent = 0;
	loc->offset = 0;
	if (lba < t->lba) {
		loc->index = 0;
		loc->run = t->lba - lba;
		if (t->pregap_silent)
			loc->silent = 1;
		else
			loc->offset = t->file_offset - (t->lba - lba) * size;
	} else {
		loc->index = 1;
		if (lba - t->lba < t->sectors) {
			uint32_t stop = t->lba + t->sectors;
			loc->offset = t->file_offset + (lba - t->lba) * size;
			loc->run = (stop < end ? stop : end) - lba;
		} else {
			loc->silent = 1;	/* POSTGAP */
			loc->run = end - lba;
		}
	}
	return 1;
}
