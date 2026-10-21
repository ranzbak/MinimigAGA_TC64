/* mock_selftest: the host-test mock (mock_hw.c) itself.
 *   mock_selftest <card.img>      card.img: a tools/sim/mkcard.sh image
 * Scripted replies per chip select, the spi.txt trace format, the timer, the
 * UART, the card image model by hand (CMD0/8/55+41/58/17/18/12/24) and under
 * the real mmc.c (MMC_Init, MMC_Read, MMC_ReadMultiple, MMC_Write). */
#include <stdio.h>
#include <string.h>

#include "errors.h"
#include "hardware.h"
#include "mmc.h"
#include "mock_hw.h"

/* what mmc.c's FatalError macro writes */
int ErrorMask, ErrorFatal;
struct Error Errors[ERROR_MAX + 1];

extern unsigned char CardType;	/* mmc.c */

static int fails;
static int cases;
static void check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		printf("FAIL %s: got %ld (0x%lx), want %ld (0x%lx)\n", what, got, (unsigned long)got, want, (unsigned long)want);
		fails++;
	} else
		printf("ok   %s = %ld\n", what, got);
}
static void check_str(const char *what, const char *got, const char *want)
{
	cases++;
	if (strcmp(got, want)) {
		printf("FAIL %s:\n--- got\n%s--- want\n%s---\n", what, got, want);
		fails++;
	} else
		printf("ok   %s\n", what);
}

static unsigned char cb_calls;
static unsigned char cb(void *ctx, unsigned char out)
{
	(void)ctx;
	cb_calls++;
	return (unsigned char)(out ^ 0xFF);
}

/* a card command by hand: returns R1 (after the model's NCR bytes) */
static unsigned char cmd(unsigned char c, unsigned arg)
{
	unsigned char r = 0xFF;
	SPI(0xFF);
	SPI(c);
	SPI(arg >> 24); SPI(arg >> 16); SPI(arg >> 8); SPI(arg);
	SPI(0x95);
	for (int i = 0; i < 16 && r == 0xFF; i++) r = SPI(0xFF);
	return r;
}

static void scripts_and_trace(void)
{
	static const unsigned char osd[] = { 0x11, 0x22, 0x33 };
	static const unsigned char fpga[] = { 0xAA, 0xBB };

	mock_reset();
	mock_script_bytes(0x20, osd, sizeof osd);
	mock_script_bytes(0x10, fpga, sizeof fpga);

	EnableOsd();
	check("OSD reply 1", SPI(0x01), 0x11);
	EnableFpga();			/* both lines selected: the higher line (OSD) answers */
	check("OSD and FPGA selected: the OSD queue", SPI(0x02), 0x22);
	DisableOsd();
	check("FPGA alone: its queue", SPI(0x03), 0xAA);
	EnableOsd();
	check("OSD third byte", SPI(0x04), 0x33);
	check("OSD queue empty: idle 0xFF", SPI(0x05), 0xFF);
	check("an underrun is counted", mock_underruns(0x20), 1);
	DisableOsd();
	check("the FPGA's second byte is still queued", mock_script_left(0x10), 1);
	check("FPGA reply 2", SPI(0x06), 0xBB);
	DisableFpga();
	SPI(0x77);		/* no select */
	check("RDSPI is the last byte received", RDSPI, 0xFF);

	check_str("trace = spi.txt format, one frame per run of constant cs",
		mock_trace(),
		"20 01 / 11\n"
		"30 02 / 22\n"
		"10 03 / aa\n"
		"30 04 05 / 33 ff\n"
		"10 06 / bb\n"
		"00 77 / ff\n");
	check("frames", mock_frames(), 6);

	mock_reset();
	EnableCard(); DisableCard();
	EnableRTC(); DisableRTC();
	check_str("an empty selected frame is written, an empty cs 00 frame is not",
		mock_trace(), "02 /\n80 /\n");

	/* callback */
	mock_reset();
	mock_script_fn(0x40, cb, NULL);
	EnableDMode();
	check("callback reply", SPI(0x0F), 0xF0);
	check("callback called once", cb_calls, 1);
	DisableDMode();

	/* idle byte */
	mock_script_idle(0x20, 0x5A);
	EnableOsd();
	check("changed idle byte", SPI(0), 0x5A);
	DisableOsd();

	/* speed */
	SPI_slow();
	check("SPI_slow", mock_spi_speed(), 0x3f);
	SPI_fast();
	check("SPI_fast", mock_spi_speed(), 0x01);

	/* the file form of the trace */
	mock_reset();
	EnableOsd(); SPI(0xAB); DisableOsd();
	check("trace file written", mock_trace_write("mock_trace.tmp"), 0);
	{
		char line[64] = "";
		FILE *f = fopen("mock_trace.tmp", "r");
		if (f) { if (!fgets(line, sizeof line, f)) line[0] = 0; fclose(f); }
		remove("mock_trace.tmp");
		check_str("trace file content", line, "20 ab / ff\n");
	}
}

/* the hooks of hardware.h send the Enable values hwmap_test asserts for the
   real macros: a select sets the line's bit and bit 0, a deselect clears them */
#define HOOK_CS(en, dis, line) do { \
	mock_reset(); \
	en(); check(#en " selects the line", mock_cs(), (line) | 1); \
	dis(); check(#dis " deselects", mock_cs(), 0); } while (0)

static void hook_cs_values(void)
{
	HOOK_CS(EnableCard, DisableCard, 0x02);
	HOOK_CS(EnableFpga, DisableFpga, 0x10);
	HOOK_CS(EnableOsd, DisableOsd, 0x20);
	HOOK_CS(EnableDMode, DisableDMode, 0x40);
	HOOK_CS(EnableRTC, DisableRTC, 0x80);
}

static void timer_uart_platform(void)
{
	mock_reset();
	check("TIMER reads 0, then advances by the step", TIMER, 0);
	check("TIMER 1", TIMER, 1);
	hosttest_advance(100);
	check("hosttest_advance", TIMER, 102);
	mock_timer_step(0);
	check("step 0 holds", TIMER, 103);
	check("step 0 holds (2)", TIMER, 103);
	mock_timer_step(1);

	/* a timeout loop over CheckTimer ends: the firmware's own hardware.c */
	{
		unsigned long t = GetTimer(10);
		unsigned n = 0;
		while (!CheckTimer(t) && n < 1000) n++;
		check("a CheckTimer loop terminates (iterations < 1000)", n < 1000, 1);
		check("... after about 10 counts", n >= 8 && n <= 12, 1);
		n = 0;
		mock_timer_step(0);
		t = GetTimer(10);
		while (!CheckTimer(t) && n < 1000) { n++; if (n % 100 == 0) hosttest_advance(50); }
		check("a frozen timer ends by hosttest_advance", n < 1000, 1);
	}
	mock_timer_step(1);
	check("WaitTimer returns", (WaitTimer(5), 1), 1);

	/* UART */
	putchar('o'); putchar('k');
	puts("!");
	RS232(0x80);
	check("UART bytes", (long)mock_uart_len(), 4);
	check("UART text", memcmp(mock_uart(), "ok!\x80", 4), 0);
	mock_uart_clear();
	check("UART cleared", (long)mock_uart_len(), 0);

	/* PLATFORM, AUDIO */
	mock_platform_set(1 << PLATFORM_MENUBUTTON);
	check("CheckButton with the button bit set (not pressed)", CheckButton(), 0);
	mock_platform_set(0);
	check("CheckButton with the bit clear (pressed)", CheckButton(), 1);
	ConfigMisc(0x1234);
	check("ConfigMisc writes PLATFORM", PLATFORM, 0x1234);
	AUDIO = AUDIOF_ENA;
	check("AUDIO write", AUDIO, AUDIOF_ENA);
}

static void card_by_hand(const char *img)
{
	unsigned char blk[512];
	int tok;

	mock_reset();
	check("card image loads", mock_card_load(img, 0), 0);
	check("card sector 0 holds 0x55AA at 510", mock_card_sector(0)[510] << 8 | mock_card_sector(0)[511], 0x55AA);

	EnableCard();
	for (int i = 0; i < 10; i++) SPI(0xFF);
	/* CMD0 by hand: ncr = 1 filler byte, then R1 */
	SPI(0xFF); SPI(0x40); SPI(0); SPI(0); SPI(0); SPI(0); SPI(0x95);
	check("one 0xFF before R1 (NCR)", SPI(0xFF), 0xFF);
	check("CMD0 R1 = idle", SPI(0xFF), 0x01);
	check("CMD0 -> idle", cmd(0x40, 0), 0x01);
	check("CMD8 -> idle", cmd(0x48, 0x1AA), 0x01);
	{ unsigned char r7[4]; for (int i = 0; i < 4; i++) r7[i] = SPI(0xFF);
	  check("R7 echoes 01 AA", r7[2] << 8 | r7[3], 0x01AA); }
	{
		int polls = 0;
		unsigned char r;
		do {
			check("CMD55", cmd(0x77, 0) <= 1, 1);
			r = cmd(0x69, 1u << 30);
			polls++;
		} while (r == 0x01 && polls < 10);
		check("ACMD41 answers idle twice, then ready", polls, 3);
		check("ACMD41 ready", r, 0x00);
	}
	check("CMD58 OCR: ready, CCS", cmd(0x7A, 0) == 0x00 && SPI(0xFF) == 0xC0, 1);
	for (int i = 0; i < 3; i++) SPI(0xFF);

	/* CMD17, sector 0 */
	check("CMD17 R1", cmd(0x51, 0), 0x00);
	tok = 0;
	for (int i = 0; i < 20; i++) { if (SPI(0xFF) == 0xFE) { tok = 1; break; } }
	check("data token 0xFE", tok, 1);
	for (int i = 0; i < 512; i++) blk[i] = SPI(0xFF);
	SPI(0xFF); SPI(0xFF);
	check("sector 0 byte 510", blk[510], 0x55);
	check("sector 0 byte 511", blk[511], 0xAA);
	check("sector 0 = the image", memcmp(blk, mock_card_sector(0), 512), 0);
	check("after the block the bus idles", SPI(0xFF), 0xFF);

	/* CMD17 beyond the card */
	check("CMD17 past the end: parameter error", cmd(0x51, 0x7FFFFFFF), 0x40);

	/* CMD24 (three blocks, byte 0 never 0), then read back */
	for (unsigned lba = 5000; lba < 5003; lba++) {
		unsigned char r = cmd(0x58, lba);
		check("CMD24 R1", r, 0x00);
		SPI(0xFF); SPI(0xFE);
		for (int i = 0; i < 512; i++) SPI((unsigned char)(i * 7 + 3 + (lba - 5000)));
		SPI(0xFF); SPI(0xFF);
		check("data response 0x05", SPI(0xFF), 0x05);
		for (int i = 0; i < 8; i++) check("busy byte 0x00", SPI(0xFF), 0x00);
		check("not busy", SPI(0xFF), 0xFF);
		check("the card memory holds the block", mock_card_sector(lba)[511], (unsigned char)(511 * 7 + 3 + (lba - 5000)));
	}
	/* CMD18 two blocks, CMD12 */
	{
		int starts = 0, i;
		unsigned char got[2][512];
		check("CMD18 R1", cmd(0x52, 5000), 0x00);
		for (i = 0; i < 2 * 520 + 10 && starts < 2; i++) {
			if (SPI(0xFF) == 0xFE) {
				for (int k = 0; k < 512; k++) got[starts][k] = SPI(0xFF);
				SPI(0xFF); SPI(0xFF);
				starts++;
			}
		}
		check("CMD18 streams a second block", starts, 2);
		check("block 1 of the stream", memcmp(got[0], mock_card_sector(5000), 512), 0);
		check("block 2 of the stream", memcmp(got[1], mock_card_sector(5001), 512), 0);
		SPI(0x4C); SPI(0); SPI(0); SPI(0); SPI(0); SPI(0); SPI(0xFF);
		{ unsigned char r = 0xFF; for (i = 0; i < 16 && r == 0xFF; i++) r = SPI(0xFF);
		  check("CMD12 drops the stream: R1 comes next", r, 0x00); }
	}
	DisableCard();
	check("the card model parsed commands", mock_card_commands() >= 10, 1);

	/* CS rising aborts a read: the next select starts clean */
	EnableCard();
	cmd(0x51, 0);
	DisableCard();
	EnableCard();
	check("after re-select the card is quiet", SPI(0xFF), 0xFF);
	DisableCard();
}

static void card_under_mmc(const char *img)
{
	unsigned char buf[2048], ref[2048];

	mock_reset();
	check("card image loads", mock_card_load(img, 0), 0);
	CardType = 0;
	check("MMC_Init returns the card type, SDHC", MMC_Init(), CARDTYPE_SDHC);
	check("CardType", CardType, CARDTYPE_SDHC);
	check("the SPI ran slow, then fast", mock_spi_speed(), 0x01);

	check("MMC_Read lba 0", MMC_Read(0, buf), 1);
	check("MMC_Read 0x55AA", buf[510] << 8 | buf[511], 0x55AA);
	check("MMC_Read == image", memcmp(buf, mock_card_sector(0), 512), 0);

	check("MMC_Read lba 2048 (the partition)", MMC_Read(2048, buf), 1);
	check("... == image", memcmp(buf, mock_card_sector(2048), 512), 0);
	check("... a FAT boot sector: jump", buf[0] == 0xEB || buf[0] == 0xE9, 1);

	check("MMC_ReadMultiple lba 2048 x 4", MMC_ReadMultiple(2048, buf, 4), 1);
	for (int i = 0; i < 4; i++) memcpy(ref + 512 * i, mock_card_sector(2048 + i), 512);
	check("... == image", memcmp(buf, ref, 2048), 0);

	for (int i = 0; i < 512; i++) buf[i] = (unsigned char)(i ^ 0x5A);
	check("MMC_Write lba 6000", MMC_Write(6000, buf), 1);
	check("... in the card memory", memcmp(mock_card_sector(6000), buf, 512), 0);
	memset(buf, 0, 512);
	check("MMC_Read back", MMC_Read(6000, buf), 1);
	check("... equal", buf[100], (unsigned char)(100 ^ 0x5A));
	check("no fatal error", ErrorFatal, 0);
}

int main(int argc, char **argv)
{
	if (argc < 2) { printf("usage: mock_selftest <card.img>\n"); return 2; }
	/* a section that fails ends the run: the later ones (MMC_Init waits on
	   the timer) may not terminate over a broken mock */
	scripts_and_trace();
	if (!fails) hook_cs_values();
	if (!fails) timer_uart_platform();
	if (!fails) card_by_hand(argv[1]);
	if (!fails) card_under_mmc(argv[1]);
	printf("\n%d cases: %d failed\n", cases, fails);
	if (fails) { printf("mock_selftest FAIL\n"); return 1; }
	printf("mock_selftest PASS\n");
	return 0;
}
