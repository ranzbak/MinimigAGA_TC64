/* sdc.c: driver of the SD card SPI peripheral (rtl/host/sdcard_spi.v); the
 * API and its rules are in sdc.h. */
#include <stdint.h>

#include "hardware.h"
#include "irq.h"
#include "sdc.h"

volatile unsigned sdc_events;
struct sdc_trace_ent sdc_trace[SDC_TRACE_N];
volatile unsigned sdc_trace_head;

/* one trace entry; called with interrupts off (the handler, or irq_save) */
static void trace_put(unsigned what, unsigned len, unsigned status, unsigned pend)
{
	struct sdc_trace_ent *e = &sdc_trace[sdc_trace_head & (SDC_TRACE_N - 1)];

	e->time = TIMER;
	e->what = what;
	e->len = len;
	e->status = status;
	e->irqpend = pend;
	sdc_trace_head = sdc_trace_head + 1;
}

/* IRQ_SDCARD (LEVEL): latch and acknowledge what is pending and enabled.  A
   call with nothing pending (the controller's synchroniser can call a LEVEL
   handler once more after its line dropped) does nothing. */
static void sdc_irq(void)
{
	unsigned en = SDC_R(SDC_IRQEN);
	unsigned raw = SDC_R(SDC_IRQPEND);
	unsigned p = raw & en;

	if (!p)
		return;
	/* the watermark bits stay set while their level holds: one shot */
	if (p & (SDC_IRQ_RXHI | SDC_IRQ_TXLO))
		SDC_W(SDC_IRQEN, en & ~(p & (SDC_IRQ_RXHI | SDC_IRQ_TXLO)));
	SDC_W(SDC_IRQACK, p);
	sdc_events = sdc_events | p;
	if (p & (SDC_IRQ_DONE | SDC_IRQ_ERR | SDC_IRQ_CD))
		trace_put(SDC_TR_EVENT, SDC_R(SDC_COUNT), SDC_R(SDC_STATUS), raw);
}

void sdc_init(void)
{
	unsigned long t;
	uint32_t s;

	SDC_W(SDC_IRQEN, 0);
	IrqSetHandler(IRQ_SDCARD, sdc_irq);
	IrqSetMode(IRQ_SDCARD, 1);
	/* stop whatever ran before (a second ColdBoot): an XFER / wait op ends
	   at the next byte boundary (36 us at the slowest SCK), a Gayle op at
	   once */
	SDC_W(SDC_CMD, SDC_OP_ABORT);
	t = GetTimer(2);
	while ((SDC_R(SDC_STATUS) & SDC_ST_BUSY) && !CheckTimer(t))
		;
	SDC_W(SDC_CFG, SDC_DIV_INIT);
	SDC_W(SDC_WMARK, 0);
	SDC_W(SDC_CMD, SDC_OP_RX_FLUSH);
	SDC_W(SDC_CMD, SDC_OP_TX_FLUSH);
	s = irq_save();
	SDC_W(SDC_IRQACK, SDC_IRQ_ALL);
	sdc_events = 0;
	SDC_W(SDC_IRQEN, SDC_IRQ_DONE | SDC_IRQ_ERR | SDC_IRQ_CD);
	irq_restore(s);
	IrqEnable(IRQ_SDCARD);
}

int sdc_start(unsigned cmd, unsigned len)
{
	unsigned op = cmd & 15, st, what;
	int rc = 0;
	uint32_t s = irq_save();

	st = SDC_R(SDC_STATUS);
	if (op != SDC_OP_ABORT && (st & SDC_ST_BUSY)) {
		rc = -1;
		what = SDC_TR_BUSY;
	} else {
		/* a fresh op: no DONE / ERR of an earlier one may stand for it */
		SDC_W(SDC_IRQACK, SDC_IRQ_DONE | SDC_IRQ_ERR);
		sdc_events = sdc_events & ~(SDC_IRQ_DONE | SDC_IRQ_ERR);
		if (op != SDC_OP_ABORT)
			SDC_W(SDC_LEN, len);
		SDC_W(SDC_CMD, cmd);
		what = SDC_TR_START;
		/* accepted ops clear STATUS 7:1, a refusal sets bit 6 */
		if (op != SDC_OP_ABORT && (SDC_R(SDC_STATUS) & SDC_ST_REFUSED)) {
			SDC_W(SDC_IRQACK, SDC_IRQ_ERR);   /* the refusal's own */
			rc = -1;
			what = SDC_TR_REFUSED;
		}
	}
	trace_put(what | (cmd & 0xFFF), len, st, 0);
	irq_restore(s);
	return rc;
}

int sdc_wait(unsigned mask)
{
	unsigned m = mask | SDC_IRQ_ERR | SDC_IRQ_CD, e;
	unsigned long t = GetTimer(SDC_WAIT_BOUND);

	while (!((e = sdc_events) & m)) {
		if (CheckTimer(t)) {
			sdc_start(SDC_OP_ABORT, 0);
			return 0;
		}
		SDC_IDLE();
	}
	return (int)(e & m);
}

void sdc_clear(unsigned mask)
{
	uint32_t s = irq_save();

	sdc_events = sdc_events & ~mask;
	irq_restore(s);
}

unsigned sdc_take(unsigned mask)
{
	uint32_t s = irq_save();
	unsigned e = sdc_events & mask;

	sdc_events = sdc_events & ~e;
	irq_restore(s);
	return e;
}

void sdc_arm(unsigned bits)
{
	uint32_t s = irq_save();

	SDC_W(SDC_IRQEN, SDC_R(SDC_IRQEN) | (bits & SDC_IRQ_ALL));
	irq_restore(s);
}

void sdc_push(const unsigned char *p, unsigned n)
{
	for (; n >= 2; n -= 2, p += 2)
		SDC_W(SDC_TXW, (unsigned short)((p[0] << 8) | p[1]));
	if (n)
		SDC_W(SDC_TXB, p[0]);
}

void sdc_pop(unsigned char *p, unsigned n)
{
	unsigned w;

	for (; n >= 2; n -= 2, p += 2) {
		w = SDC_R(SDC_RXW);
		p[0] = w >> 8;
		p[1] = w;
	}
	if (n)
		p[0] = SDC_R(SDC_RXB);
}

/* CFG read-modify-write while idle; the handler never writes CFG and only
   the firmware starts ops, so busy cannot rise between the check and the
   write (an op can only end there) */
static int cfg_set(unsigned keep, unsigned set)
{
	int rc = -1;
	uint32_t s = irq_save();

	if (!(SDC_R(SDC_STATUS) & SDC_ST_BUSY)) {
		SDC_W(SDC_CFG, (SDC_R(SDC_CFG) & keep) | set);
		rc = 0;
	}
	irq_restore(s);
	return rc;
}

int sdc_set_div(unsigned div)
{
	if (div < SDC_DIV_MIN)
		div = SDC_DIV_MIN;
	if (div > SDC_CFG_DIV)
		div = SDC_CFG_DIV;
	return cfg_set(SDC_CFG_CS, div);
}

int sdc_select(int on)
{
	return cfg_set(SDC_CFG_DIV, on ? SDC_CFG_CS : 0);
}

unsigned sdc_status(void)
{
	return SDC_R(SDC_STATUS);
}
