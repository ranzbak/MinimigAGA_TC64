#ifndef UART_H
#define UART_H

/* Hardware registers for a supporting UART to the ZPUFlex project. */

#define UARTBASE 0xfffffff0
#define HW_UART(x) *(volatile unsigned char *)(UARTBASE+x)

/* Write-only.  cfide acks a UART write only when its transmitter is free (the
   write stalls while a character shifts out), so no ready poll is needed; a
   UART read is never acked at all (cfide's support state machine handles UART
   writes only) and would hang the CPU.  There is no TX-ready bit. */
#define REG_UART 0x00

int putchar(int c);
int puts(const char *msg);

#endif

