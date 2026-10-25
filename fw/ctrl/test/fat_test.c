/* fat_test: the real fat.c over the real mmc.c on the card model of mock_hw.c.
 *   fat_test <image> <data dir> <out prefix> <16|32> <partition start LBA, 0 = no MBR>
 * Run by fat_check.sh (make -C fw/ctrl/test run-fat_test) on the three
 * images of fatimg.sh; the data dir holds the files those were made from
 * (gold/fatdata.py), the reference for every byte read here.
 *   - FindDrive(): FAT type, partition start/size against the MBR bytes of
 *     the image (read here byte by byte, not through fat.c), cluster size
 *   - <out prefix>.list: every directory of the tree through ScanDirectory
 *     (names, sizes, start clusters, long names); fat_check.sh compares it
 *     with mdir/mshowfat (gold/fatlist.py)
 *   - FileOpen + FileRead/FileNextSector, FileSeek, FileReadEx of BIG.BIN
 *     (300 KB, fragmented over a deleted file's clusters), byte for byte
 *   - a subdirectory walk with long names: FindDirectory, ChangeDirectory,
 *     FileOpen by long name, ValidateDirectory, FindDirectoryByCluster
 *   - HIGH.BIN by FileOpen + FileRead (on FAT32 its start cluster is above
 *     65535: HighCluster)
 *   - "Games Collection/Many Long Names", two clusters: FileOpen of DELTA by
 *     its long name (its entries are in the directory's second cluster,
 *     GetFATLink) and of S2.BIN, byte for byte
 *   - FileOpen of a name that does not exist: 0, "not found"
 *   - FileCreate + FileWrite x3 + UpdateEntry of NEWFILE.BIN (W3.BIN), read
 *     back through fat.c; its raw directory entry (create and access date,
 *     create time, start cluster, HighCluster: on FAT32 above 65535) against
 *     the FAT layout; the card is saved to <out prefix>.img for fsck.fat -n,
 *     mtype and mdir (the modify date and time) (fat_check.sh)
 * The firmware's printf goes through rvlibc.c and uart.c to the mock UART
 * (saved to <out prefix>.uart); this program reports with fprintf(stdout). */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "errors.h"
#include "hardware.h"
#include "mmc.h"
#include "sdproto.h"
#include "fat.h"
#include "mock_hw.h"

/* what fat.c and mmc.c need from the rest of the firmware */
int ErrorMask, ErrorFatal;
struct Error Errors[ERROR_MAX + 1];
char BootPrint(const char *text) { (void)text; return 0; }
void BootPrintEx(char *str) { (void)str; }

/* fat.c's globals that fat.h does not declare (menu.c declares DirEntry so) */
extern unsigned long boot_sector;
extern unsigned char fattype;
extern DIRENTRY DirEntry[MAXDIRENTRIES];
extern char DirEntryLFN[MAXDIRENTRIES][261];
extern unsigned char sort_table[MAXDIRENTRIES];
extern unsigned char nDirEntries;

static int fails;
static int cases;
static FILE *out;

static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
}

static int check(const char *what, unsigned long got, unsigned long want)
{
	cases++;
	if (got != want) {
		say("FAIL %s: got %lu (0x%lx), want %lu (0x%lx)\n", what, got, got, want, want);
		fails++;
		return 0;
	}
	say("ok   %s = %lu\n", what, got);
	return 1;
}

static int check_mem(const char *what, const unsigned char *got, const unsigned char *want, size_t n)
{
	cases++;
	for (size_t i = 0; i < n; i++)
		if (got[i] != want[i]) {
			say("FAIL %s: byte %zu is %02x, want %02x\n", what, i, got[i], want[i]);
			fails++;
			return 0;
		}
	say("ok   %s (%zu bytes)\n", what, n);
	return 1;
}

static unsigned char *slurp(const char *dir, const char *name, size_t *len)
{
	char path[1024];
	snprintf(path, sizeof path, "%s/%s", dir, name);
	FILE *f = fopen(path, "rb");
	if (!f) { say("FAIL cannot open %s\n", path); exit(1); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	unsigned char *p = malloc((size_t)n + 1);
	if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) { say("FAIL cannot read %s\n", path); exit(1); }
	fclose(f);
	*len = (size_t)n;
	return p;
}

static unsigned long le32_at(const unsigned char *b)
{
	return b[0] | (unsigned long)b[1] << 8 | (unsigned long)b[2] << 16 | (unsigned long)b[3] << 24;
}

/* ---- FindDrive ---------------------------------------------------------- */
static void find_drive(const char *img, int type, unsigned long start)
{
	unsigned char raw[512], bpb[512];
	FILE *f = fopen(img, "rb");
	if (!f || fread(raw, 1, 512, f) != 512 || fseek(f, (long)start * 512, SEEK_SET)
	    || fread(bpb, 1, 512, f) != 512) { say("FAIL cannot read %s\n", img); exit(1); }
	fclose(f);

	check("FindDrive()", FindDrive(), 1);
	check("FAT type", fattype, (unsigned long)type);
	check("fat32 flag", fat32, type == 32);
	check("boot sector (partition start)", boot_sector, start);
	check("FindDrive sets no error", (unsigned long)ErrorMask, 0);
	if (start) {
		check("MBR: partitions found", (unsigned long)partitioncount, 1);
		check("MBR: partitions[0].startlba == MBR bytes 454..457", partitions[0].startlba, le32_at(raw + 454));
		check("MBR: partitions[0].sectors == MBR bytes 458..461", partitions[0].sectors, le32_at(raw + 458));
	} else {
		check("superfloppy: no partition table read", (unsigned long)partitioncount, 0);
	}
	check("cluster size == BPB byte 13", cluster_size, bpb[13]);
	/* FileCreate allocates one cluster: the 3-sector file needs >= 4 sectors per cluster */
	if (!check("cluster size >= 4 sectors (one cluster holds NEWFILE.BIN)", cluster_size >= 4, 1))
		exit(1);
}

/* ---- the listing: every directory through ScanDirectory ----------------- */
static void list_dir(unsigned long cluster, const char *path, int depth)
{
	DIRENTRY ents[MAXDIRENTRIES];
	char lfns[MAXDIRENTRIES][261];
	int n;

	ChangeDirectory(cluster);
	ScanDirectory(SCAN_INIT, "*", SCAN_DIR | SCAN_LFN);
	n = nDirEntries;
	/* a full table may have cut the directory short */
	char what[400];
	snprintf(what, sizeof what, "directory \"%s\" fits the %d-entry table", path, MAXDIRENTRIES);
	check(what, n < MAXDIRENTRIES, 1);
	for (int i = 0; i < n; i++) {
		ents[i] = DirEntry[sort_table[i]];
		memcpy(lfns[i], DirEntryLFN[sort_table[i]], sizeof lfns[i]);
	}
	for (int i = 0; i < n; i++) {
		const DIRENTRY *e = &ents[i];
		if (!memcmp(e->Name, "..         ", 11))
			continue;
		int isdir = (e->Attributes & ATTR_DIRECTORY) != 0;
		/* the start cluster as menu.c forms it from a DirEntry */
		unsigned long start = e->StartCluster + (fat32 ? (e->HighCluster & 0x0FFF) << 16 : 0);
		fprintf(out, "%s|%c|%.8s%.3s|%lu|%lu|%s\n", path, isdir ? 'D' : 'F', (const char *)e->Name,
			(const char *)e->Extension, (unsigned long)e->FileSize, start, lfns[i]);
		if (isdir && depth < 4) {
			char sub[400];
			if (lfns[i][0])
				snprintf(sub, sizeof sub, "%s/%s", path, lfns[i]);
			else {
				int l = 8;
				while (l > 0 && e->Name[l - 1] == ' ') l--;
				snprintf(sub, sizeof sub, "%s/%.*s", path, l, (const char *)e->Name);
			}
			list_dir(start, sub, depth + 1);
		}
	}
}

/* ---- BIG.BIN: 300 KB, fragmented ----------------------------------------- */
static void read_big(const char *data)
{
	size_t len;
	unsigned char *ref = slurp(data, "BIG.BIN", &len);
	unsigned long nsec = (len + 511) / 512;
	unsigned char *all = calloc(nsec, 512);
	unsigned char sec[512];
	fileTYPE f;
	int ok = 1;

	ChangeDirectory(0);
	if (!check("FileOpen(\"BIG     BIN\")", FileOpen(&f, "BIG     BIN"), 1)) return;
	check("BIG.BIN size", f.size, len);

	/* sector by sector, the way the firmware streams a file */
	for (unsigned long s = 0; s < nsec && ok; s++) {
		size_t n = len - s * 512 < 512 ? len - s * 512 : 512;
		if (!FileRead(&f, sec) || memcmp(sec, ref + s * 512, n)) {
			say("FAIL FileRead of BIG.BIN sector %lu (cluster %lu)\n", s, f.cluster);
			ok = 0;
		} else if (s + 1 < nsec && !FileNextSector(&f)) {
			say("FAIL FileNextSector after sector %lu\n", s);
			ok = 0;
		}
	}
	cases++;
	if (ok) say("ok   FileRead/FileNextSector: all %lu sectors of BIG.BIN\n", nsec);
	else fails++;

	/* FileSeek backwards to the start, then FileReadEx one sector at a time
	   (hdd.c's use with a buffer).  FileReadEx does not advance pBuffer from
	   one cluster's MMC_ReadMultiple to the next (it never did): with a
	   buffer, nSize must stay within the cluster. */
	check("FileSeek(0, SEEK_SET)", FileSeek(&f, 0, SEEK_SET), 1);
	ok = 1;
	for (unsigned long s = 0; s < nsec && ok; s++)
		ok = FileReadEx(&f, all + s * 512, 1);
	check("FileReadEx(1 sector) over all sectors", ok, 1);
	check_mem("FileReadEx data == BIG.BIN", all, ref, len);
	/* several sectors in one call: one whole cluster (cluster 3 of the file) */
	memset(all, 0, cluster_size * 512);
	check("FileSeek(3 clusters)", FileSeek(&f, 3 * cluster_size, SEEK_SET), 1);
	check("FileReadEx(one cluster)", FileReadEx(&f, all, cluster_size), 1);
	check_mem("FileReadEx(one cluster) data == BIG.BIN", all, ref + 3 * cluster_size * 512, cluster_size * 512);
	/* the file's last cluster (findings/sdcard-engine Task 10 fix rounds 1
	   and 2): a read that ends at its end is good (the seek after it meets
	   the end of the chain); one block more fails; a seek past the end is
	   0 and leaves the pointer in the last cluster, where the next seek
	   still finds the right data */
	{
		unsigned long last = (nsec + cluster_size - 1) / cluster_size - 1;
		check("FileSeek(the last cluster)", FileSeek(&f, last * cluster_size, SEEK_SET), 1);
		check("FileReadEx(the whole last cluster): 1", FileReadEx(&f, all, cluster_size), 1);
		check_mem("... its data == BIG.BIN", all, ref + last * cluster_size * 512, len - last * cluster_size * 512);
		check("FileSeek(the last cluster) again", FileSeek(&f, last * cluster_size, SEEK_SET), 1);
		check("FileReadEx(the last cluster + 1 block): 0", FileReadEx(&f, all, cluster_size + 1), 0);
		check("FileSeek(past the end): 0", FileSeek(&f, (last + 1) * cluster_size, SEEK_SET), 0);
		check("... then FileSeek(the last sector) + FileRead", FileSeek(&f, nsec - 1, SEEK_SET) && FileRead(&f, sec), 1);
		check_mem("... == BIG.BIN's last sector", sec, ref + (nsec - 1) * 512, len - (nsec - 1) * 512);
	}
	/* a card error in FileReadEx's last seek (Task 10 fix round 3): the FAT
	   read after a chunk that ends a cluster fails (the FAT sector not in
	   fat_buffer, the card's CRC wrong 5 times: retries out): 0, MMCErr set
	   -- a caller going on would re-read the chunk */
	{
		extern unsigned long buffered_fat_index;
		check("FileSeek(cluster 2)", FileSeek(&f, 2 * cluster_size, SEEK_SET), 1);
		buffered_fat_index = -1;
		mock_card_error(MOCK_ERR_RDCRC, mock_card_blocks_read() + cluster_size + 1, 5);
		check("FileReadEx(cluster 2), its FAT read fails: 0", FileReadEx(&f, all, cluster_size), 0);
		check("... MMCErr a card error", MMCErr != SD_OK, 1);
		mock_card_error(MOCK_ERR_RDCRC, 0, 0);
		buffered_fat_index = -1;
		check("... then FileSeek(cluster 2) + FileReadEx again: 1", FileSeek(&f, 2 * cluster_size, SEEK_SET) &&
		      FileReadEx(&f, all, cluster_size), 1);
		check_mem("... the data", all, ref + 2 * cluster_size * 512, cluster_size * 512);
	}

	/* FileSeek forward over the fragment boundary and back within the file */
	static const unsigned long at[] = { 100, 3, 599, 40, 0 };
	for (unsigned i = 0; i < sizeof at / sizeof at[0]; i++) {
		char what[80];
		snprintf(what, sizeof what, "FileSeek(%lu) + FileRead == BIG.BIN sector %lu", at[i], at[i]);
		if (FileSeek(&f, at[i], SEEK_SET) && FileRead(&f, sec))
			check_mem(what, sec, ref + at[i] * 512, 512);
		else
			check(what, 0, 1);
	}
	free(all);
	free(ref);
}

/* ---- subdirectories with long names ------------------------------------- */
static void subdirs(const char *data)
{
	size_t len;
	unsigned char *ref = slurp(data, "DEEP.DAT", &len);
	unsigned char sec[512];
	fileTYPE f;

	ChangeDirectory(0);
	unsigned long games = FindDirectory(0, "GAMESC~1   ");
	check("FindDirectory(root, GAMESC~1) is a cluster", games >= 2, 1);
	ChangeDirectory(games);
	unsigned long level = FindDirectory(games, "ANOTHE~1   ");
	check("FindDirectory(Games Collection, ANOTHE~1) is a cluster", level >= 2, 1);
	check("FindDirectory(root, ANOTHE~1) finds nothing", FindDirectory(0, "ANOTHE~1   "), 0);
	ChangeDirectory(level);
	check("CurrentDirectory()", CurrentDirectory(), level);
	check("ValidateDirectory(Another Level), via \"..\"", ValidateDirectory(level), 1);
	check("ValidateDirectory(Games Collection)", ValidateDirectory(games), 1);
	check("FindDirectoryByCluster(Games Collection, Another Level)", FindDirectoryByCluster(games, level), 1);
	check("FindDirectoryByCluster(root, Another Level)", FindDirectoryByCluster(0, level), 0);

	ChangeDirectory(level);
	if (check("FileOpen(\"Deep File Name.dat\") by long name", FileOpen(&f, "Deep File Name.dat"), 1)) {
		check("Deep File Name.dat size", f.size, len);
		unsigned long nsec = (len + 511) / 512;
		int ok = 1;
		for (unsigned long s = 0; s < nsec && ok; s++) {
			size_t n = len - s * 512 < 512 ? len - s * 512 : 512;
			ok = FileRead(&f, sec) && !memcmp(sec, ref + s * 512, n) && (s + 1 == nsec || FileNextSector(&f));
		}
		check("Deep File Name.dat data == DEEP.DAT", ok, 1);
	}
	free(ref);
}

/* FileOpen(name) in the current directory, then the file byte for byte */
static void open_and_read(const char *data, const char *file, const char *name, unsigned long min_cluster)
{
	size_t len;
	unsigned char *ref = slurp(data, file, &len);
	unsigned char sec[512];
	char what[400];
	fileTYPE f;

	snprintf(what, sizeof what, "FileOpen(\"%s\")", name);
	if (check(what, FileOpen(&f, name), 1)) {
		snprintf(what, sizeof what, "%s size", file);
		check(what, f.size, len);
		snprintf(what, sizeof what, "%s start cluster >= %lu", file, min_cluster);
		check(what, f.start_cluster >= min_cluster, 1);
		unsigned long nsec = (len + 511) / 512;
		int ok = 1;
		for (unsigned long s = 0; s < nsec && ok; s++) {
			size_t n = len - s * 512 < 512 ? len - s * 512 : 512;
			ok = FileRead(&f, sec) && !memcmp(sec, ref + s * 512, n) && (s + 1 == nsec || FileNextSector(&f));
		}
		snprintf(what, sizeof what, "%s data", file);
		check(what, ok, 1);
	}
	free(ref);
}

/* the long name of <file> in lfn_names.txt (fatdata.py) */
static void long_name_of(const char *data, const char *file, char *out, size_t n)
{
	size_t len;
	char *t = (char *)slurp(data, "lfn_names.txt", &len);
	size_t fl = strlen(file);
	out[0] = 0;
	for (char *l = t; l < t + len; ) {
		char *e = memchr(l, '\n', (size_t)(t + len - l));
		if (!e) e = t + len;
		if ((size_t)(e - l) > fl && !memcmp(l, file, fl) && l[fl] == '|')
			snprintf(out, n, "%.*s", (int)(e - l - fl - 1), l + fl + 1);
		l = e + 1;
	}
	free(t);
	if (!out[0]) { say("FAIL no long name of %s in lfn_names.txt\n", file); exit(1); }
}

/* ---- HIGH.BIN, the two-cluster directory ---------------------------------- */
static void high_and_long(const char *data)
{
	char lfn[300];

	ChangeDirectory(0);
	/* FAT32: fatimg.sh put HIGH.BIN above cluster 65535 (HighCluster 1) */
	open_and_read(data, "HIGH.BIN", "HIGH    BIN", fat32 ? 0x10000 : 2);

	unsigned long games = FindDirectory(0, "GAMESC~1   ");
	ChangeDirectory(games);
	unsigned long many = FindDirectory(games, "MANYLO~1   ");
	check("FindDirectory(Games Collection, MANYLO~1) is a cluster", many >= 2, 1);
	ChangeDirectory(many);
	long_name_of(data, "DELTA.BIN", lfn, sizeof lfn);
	open_and_read(data, "DELTA.BIN", lfn, 2);	/* in the directory's second cluster */
	open_and_read(data, "S2.BIN", "S2      BIN", 2);
	ChangeDirectory(0);
}

/* ---- a name that does not exist ----------------------------------------- */
static void not_found(void)
{
	fileTYPE f;
	memset(&f, 0x5A, sizeof f);
	ChangeDirectory(0);
	mock_uart_clear();
	check("FileOpen(\"NOSUCH  CFG\")", FileOpen(&f, "NOSUCH  CFG"), 0);
	check("not found: the fileTYPE is cleared", f.size | f.start_cluster | (unsigned char)f.name[0], 0);
	check("not found: ERROR_FILESYSTEM set", (ErrorMask >> ERROR_FILESYSTEM) & 1, 1);
	check("not found: UART says so", strstr(mock_uart(), "file \"NOSUCH  CFG\" not found\r") != NULL, 1);
	ErrorMask = 0;
}

/* ---- FileCreate + FileWrite + UpdateEntry ------------------------------- */
static void create_file(const char *data)
{
	size_t len;
	unsigned char *w3 = slurp(data, "W3.BIN", &len);
	unsigned char sec[512];
	fileTYPE f;

	if (!check("W3.BIN is 3 sectors", len, 1536)) exit(1);
	ChangeDirectory(0);
	memset(&f, 0, sizeof f);
	memcpy(f.name, "NEWFILE BIN", 11);
	f.attributes = 0;
	f.size = 512;			/* like SaveConfiguration: one sector at first */
	if (!check("FileCreate(root, NEWFILE BIN)", FileCreate(0, &f), 1)) return;
	for (int s = 0; s < 3; s++) {
		char what[64];
		snprintf(what, sizeof what, "FileWrite sector %d", s);
		check(what, FileWrite(&f, w3 + s * 512), 1);
		if (s < 2) check("FileNextSector", FileNextSector(&f), 1);
	}
	f.size = 1536;
	check("UpdateEntry(size 1536)", UpdateEntry(&f), 1);
	/* FAT32: every cluster below 65536 is taken (fatimg.sh's filler) */
	if (fat32) check("FAT32: NEWFILE.BIN starts above cluster 65535", f.start_cluster > 0xFFFF, 1);

	/* its directory entry as bytes on the card, against the FAT layout: the
	   firmware stamps 2009-09-01 00:00:00 (fat.c FileCreate).  ModifyDate and
	   ModifyTime are what mdir shows: fat_check.sh compares those */
	const unsigned char *e = NULL;
	for (unsigned lba = 0; !e && mock_card_sector(lba); lba++) {
		const unsigned char *sp = mock_card_sector(lba);
		for (int k = 0; k < 16 && !e; k++)
			if (!memcmp(sp + 32 * k, "NEWFILE BIN", 11) && sp[32 * k + 11] != 0x0F) e = sp + 32 * k;
	}
	if (check("NEWFILE.BIN's directory entry on the card", e != NULL, 1)) {
		unsigned date = ((2009 - 1980) << 9) | (9 << 5) | 1;	/* FAT date: years since 1980, month, day */
		check("entry CreateTime (bytes 14-15)", e[14] | e[15] << 8, 0);
		check("entry CreateDate (bytes 16-17) 2009-09-01", e[16] | e[17] << 8, date);
		check("entry AccessDate (bytes 18-19)", e[18] | e[19] << 8, date);
		check("entry HighCluster (bytes 20-21)", e[20] | e[21] << 8, f.start_cluster >> 16);
		check("entry StartCluster (bytes 26-27)", e[26] | e[27] << 8, f.start_cluster & 0xFFFF);
		check("entry FileSize (bytes 28-31)", le32_at(e + 28), 1536);
	}

	fileTYPE g;
	if (check("FileOpen(\"NEWFILE BIN\") after the write", FileOpen(&g, "NEWFILE BIN"), 1)) {
		check("NEWFILE.BIN size", g.size, 1536);
		check("NEWFILE.BIN start cluster", g.start_cluster, f.start_cluster);
		for (int s = 0; s < 3; s++) {
			char what[64];
			snprintf(what, sizeof what, "NEWFILE.BIN sector %d read back", s);
			if (FileRead(&g, sec)) check_mem(what, sec, w3 + s * 512, 512);
			else check(what, 0, 1);
			if (s < 2) FileNextSector(&g);
		}
	}
	free(w3);
}

int main(int argc, char **argv)
{
	if (argc != 6) {
		say("usage: fat_test <image> <data dir> <out prefix> <16|32> <partition start LBA>\n");
		return 2;
	}
	const char *img = argv[1], *data = argv[2], *pre = argv[3];
	int type = atoi(argv[4]);
	unsigned long start = strtoul(argv[5], NULL, 0);
	char path[1024];
	struct stat st;

	mock_reset();
	if (stat(img, &st) || st.st_size % 512) { say("FAIL %s: no image of whole sectors\n", img); return 1; }
	if (!check("card image loads", mock_card_load(img, (unsigned)(st.st_size / 512)), 0)) return 1;
	if (!check("MMC_Init: SDHC", MMC_Init(), CARDTYPE_SDHC)) return 1;

	find_drive(img, type, start);
	if (!fails) {
		snprintf(path, sizeof path, "%s.list", pre);
		out = fopen(path, "w");
		if (!out) { say("FAIL cannot write %s\n", path); return 1; }
		list_dir(0, "", 0);
		fclose(out);
		read_big(data);
		subdirs(data);
		high_and_long(data);
		not_found();
		create_file(data);
		snprintf(path, sizeof path, "%s.img", pre);
		check("card saved", mock_card_save(path), 0);
	}
	snprintf(path, sizeof path, "%s.uart", pre);
	FILE *u = fopen(path, "wb");
	if (u) { fwrite(mock_uart(), 1, mock_uart_len(), u); fclose(u); }

	say("\n%d cases: %d failed\n", cases, fails);
	if (fails) { say("fat_test FAIL\n"); return 1; }
	say("fat_test PASS\n");
	return 0;
}
