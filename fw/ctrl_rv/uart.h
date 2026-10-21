#ifndef UART_H
#define UART_H

/* Hardware registers for a supporting UART to the ZPUFlex project. */

#ifdef __cplusplus
extern "C" {
#endif

/* Transmit only: UART_TX (hardware.h, 0xFFFFFFF0) is write only; the core
   never acknowledges a read of it.  There is no receive side. */

#ifndef DISABLE_UART_TX
int putchar(int c);
int puts(const char *msg);

#else
#define putchar(x) (x)
#define puts(x)
#endif

#ifdef __cplusplus
}
#endif

#endif

