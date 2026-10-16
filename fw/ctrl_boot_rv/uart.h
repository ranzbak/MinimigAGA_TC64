#ifndef UART_H
#define UART_H

/* Hardware registers for a supporting UART to the ZPUFlex project. */

#define UARTBASE 0xfffffff0
#define HW_UART(x) *(volatile unsigned char *)(UARTBASE+x)

#define REG_UART 0x00
#define REG_UART_RXINT 9
#define REG_UART_TXREADY 8

int putchar(int c);
int puts(const char *msg);

#endif

