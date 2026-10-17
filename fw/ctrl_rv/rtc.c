#include <stdio.h>

#include "hardware.h"
#include "version.h"
#include "rtc.h"

void HandleRTC()
{
	static int c=0;
	if((c++&8191)==0) /* No need to update this every loop */
	{
		int t1,t2,t3;
		// Communicate with RTC chip over SPI
		SPI_slow();
		EnableRTC();
		SPI(0x92);	/* Read, Subaddress 001, start reading at register 0000 */

		t1=SPI(0xff); /* Seconds */
		t2=SPI(0xff); /* Minutes */
		HW_RTC(0x0c)=t1 | (t2 << 8);

		t1=SPI(0xff); /* Hours */
		t2=SPI(0xff); /* Day */
		HW_RTC(0x08)=t1 | (t2 << 8);

		t3=SPI(0xff); /* Weekday */

		t1=SPI(0xff); /* Month */
		t2=SPI(0xff); /* Year */
		HW_RTC(0x04)=t1 | (t2 << 8);

		HW_RTC(0x00)=0x4000 | t3; /* Flags + weekday */
		DisableRTC();
		SPI_fast();
	}
}

