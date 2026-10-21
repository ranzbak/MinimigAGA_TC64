#include <stdio.h>
#include <string.h>

#include "hardware.h"
#include "audio.h"
#include "rafile.h"

#include "drivesounds.h"
#include "cdaudio.h"
#include "swap.h"

extern char __bss_end;

struct drivesound
{
	enum DriveSound_Type type;
	short *base;
	int length;
	int active;
	int chain;
	int cursor;
};

struct dsevent
{
	enum DriveSound_Type type;
	int timestamp;
};

#define DSEVENTBUFFER_SIZE 16

struct dseventbuffer
{
	volatile int in;
	volatile int out;
	int	loaded;
	int timestamp;
	int	cursor;
	int silence;
	int active;
	int playing;
	int enabled;
	struct dsevent events[DSEVENTBUFFER_SIZE];
	struct drivesound sounds[DRIVESOUND_COUNT];
};

struct dseventbuffer drivesounds;


void drivesounds_enable(int type)
{
	drivesounds.enabled|=type;
}

void drivesounds_disable(int type)
{
	drivesounds.enabled&=~type;
	if(!drivesounds.enabled && !cda_busy())	/* not the CD audio player's stream */
		audio_stop();
}

/* The CD audio player takes the ring (findings/cdrom/plan.md 13.1): drop
   what was playing and queued, without touching the AUDIO register. */
void drivesounds_yield()
{
	drivesounds.active=0;
	drivesounds.playing=0;
	drivesounds.out=drivesounds.in;
}


void drivesounds_queueevent(enum DriveSound_Type type)
{
	if(drivesounds.enabled)
	{
		if(!drivesounds.active)
			drivesounds_start();
		drivesounds.events[drivesounds.in].type=type;
		drivesounds.events[drivesounds.in].timestamp=TIMER; /* Add some jitter */
		drivesounds.in=(drivesounds.in+1)&(DSEVENTBUFFER_SIZE-1);
	}
}


void drivesounds_stop()
{
	audio_stop();
	drivesounds.active=0;
	drivesounds.playing=0;
}


void drivesounds_start()
{
	if(drivesounds.enabled)
	{
		drivesounds.active=1;
		drivesounds.silence=0;
		drivesounds.timestamp=TIMER;
		drivesounds.cursor=0;
		drivesounds.playing=0;
	}
}


struct dsevent *drivesounds_nextevent()
{
	struct dsevent *result=0;
	if(drivesounds.in!=drivesounds.out)
		result=&drivesounds.events[drivesounds.out++];
	drivesounds.out&=(DSEVENTBUFFER_SIZE-1);

//	if(result)
//		printf("Found event %d at time %d\n",result->type,result->timestamp);
	return(result);
}


void drivesounds_finishsound(int i)
{
	drivesounds.sounds[i].active=0;
	drivesounds.sounds[i].cursor=0;
	i=drivesounds.sounds[i].chain;
	if(i)
	{
//						printf("chained with sound %d\n",drivesounds.sounds[i].chain);
		drivesounds.sounds[i].active=1;
		drivesounds.sounds[i].cursor=0;
	}
}


/* srcs/srcs2/srcs3 are only read when the matching src pointer is set, which also sets them: a false positive, not a bug */
/* Byte order: the samples are native (drivesounds_init converts them), and
   each frame goes into the ring as the audio hardware takes it: the low 16
   bits of the sum, little-endian, twice (lo hi lo hi).  The long is stored
   little-endian and needs no swap (the big-endian firmware before swapped
   the bytes of the sum and stored the long big-endian).  The & 0xffff keeps
   a negative sum's sign out of the upper half (-1 * 0x10001 = 0xfffeffff).
   Unsigned: the sums wrap. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
void drivesounds_render(int timestamp)
{
	int samples;
	int *buf=(int *)AUDIO_BUFFER;
	short *src,*src2,*src3;
	int srcs,srcs2,srcs3;
	int i;
	int b1 __attribute__((unused)), b2 __attribute__((unused)); // only ever assigned (a leftover)

	if(!drivesounds.loaded)
	{
		drivesounds.timestamp=timestamp;
		return;
	}

	samples=(timestamp-drivesounds.timestamp);
	if(samples<0)
		samples+=65536;
	if(samples>127)
		samples=127;
	samples*=256;

//	printf("Rendering %d samples\n",samples);

	while(samples)
	{
		int span=samples;

		src=src2=src3=0;

		for(i=0;i<DRIVESOUND_COUNT;++i)
		{
			if(drivesounds.sounds[i].active)
			{
				src=drivesounds.sounds[i].base;
				src+=drivesounds.sounds[i].cursor;
				srcs=i;
				++i;
				break;
			}
		}
		for(;i<DRIVESOUND_COUNT;++i)
		{
			if(drivesounds.sounds[i].active)
			{
				src2=drivesounds.sounds[i].base;
				src2+=drivesounds.sounds[i].cursor;
				srcs2=i;
				++i;
				break;
			}
		}
		for(;i<DRIVESOUND_COUNT;++i)
		{
			if(drivesounds.sounds[i].active)
			{
				src3=drivesounds.sounds[i].base;
				src3+=drivesounds.sounds[i].cursor;
				srcs3=i;
				++i;
				break;
			}
		}
		for(;i<DRIVESOUND_COUNT;++i)
		{
			drivesounds.sounds[i].active=0;
		}

		if(((AUDIO_BUFFER_SIZE-drivesounds.cursor)>>1)<span)
			span=(AUDIO_BUFFER_SIZE-drivesounds.cursor)>>1;
		if(src && ((drivesounds.sounds[srcs].length-drivesounds.sounds[srcs].cursor)<span))
			span=drivesounds.sounds[srcs].length-drivesounds.sounds[srcs].cursor;
		if(src2 && ((drivesounds.sounds[srcs2].length-drivesounds.sounds[srcs2].cursor)<span))
			span=drivesounds.sounds[srcs2].length-drivesounds.sounds[srcs2].cursor;
		if(src3 && ((drivesounds.sounds[srcs3].length-drivesounds.sounds[srcs3].cursor)<span))
			span=drivesounds.sounds[srcs3].length-drivesounds.sounds[srcs3].cursor;

		buf=(int *)AUDIO_BUFFER;
		buf+=drivesounds.cursor>>1;
		b1=drivesounds.cursor&0x4000;
		drivesounds.cursor+=2*span;
		drivesounds.cursor&=(AUDIO_BUFFER_SIZE)-1;
		b2=drivesounds.cursor&0x4000;

 		samples-=span;

		if(src3)
		{
			drivesounds.silence=0;
			drivesounds.sounds[srcs].cursor+=span;
			drivesounds.sounds[srcs2].cursor+=span;
			drivesounds.sounds[srcs3].cursor+=span;
			if(!(AUDIO&AUDIOF_AMIGA))
			{
				while(span--)
				{
					unsigned int c=*src++;
					c+=*src2++;
					c+=*src3++;
					c=(c&0xffff)*0x10001;
					*buf++=c;
				}
			}
			if(drivesounds.sounds[srcs].cursor>=drivesounds.sounds[srcs].length)
				drivesounds_finishsound(srcs);
			if(drivesounds.sounds[srcs2].cursor>=drivesounds.sounds[srcs2].length)
				drivesounds_finishsound(srcs2);
			if(drivesounds.sounds[srcs3].cursor>=drivesounds.sounds[srcs3].length)
				drivesounds_finishsound(srcs3);
		}
		else if(src2)
		{
			drivesounds.silence=0;
			drivesounds.sounds[srcs].cursor+=span;
			drivesounds.sounds[srcs2].cursor+=span;
			if(!(AUDIO&AUDIOF_AMIGA))
			{
				while(span--)
				{
					unsigned int c=*src++;
					c+=*src2++;
					c=(c&0xffff)*0x10001;
					*buf++=c;
				}
			}
			if(drivesounds.sounds[srcs].cursor>=drivesounds.sounds[srcs].length)
				drivesounds_finishsound(srcs);
			if(drivesounds.sounds[srcs2].cursor>=drivesounds.sounds[srcs2].length)
				drivesounds_finishsound(srcs2);
		}
		else if(src)
		{
			drivesounds.silence=0;
			drivesounds.sounds[srcs].cursor+=span;
			if(!(AUDIO&AUDIOF_AMIGA))
			{
				while(span--)
				{
					unsigned int c=*src++;
					c=(c&0xffff)*0x10001;
					*buf++=c;
				}
			}
			if(drivesounds.sounds[srcs].cursor>=drivesounds.sounds[srcs].length)
				drivesounds_finishsound(srcs);
		}
		else if(span)
		{
			drivesounds.silence+=span;
			if(!(AUDIO&AUDIOF_AMIGA))
			{
				while(span--)
					*buf++=0;
			}
		}
	}

	if(drivesounds.silence>=AUDIO_BUFFER_SIZE)
		drivesounds_stop();
	else if(drivesounds.active && !drivesounds.playing && drivesounds.cursor&0x4000)
		audio_start();	// Start playing audio once the first buffer is full...

	drivesounds.timestamp=timestamp;
}
#pragma GCC diagnostic pop


int countstep(enum DriveSound_Type type)
{
	int count=0;
	int step;
	for(step=0;step<4;++step)
	{
		if(drivesounds.sounds[type+step].active)
		{
			++count;
		}
	}
	return(count);
}


/* Pick a step sound at random, while keeping no more than "maxactive" other step sounds playing. */

/* count is read before it is ever set: found by -Wextra, left as is (README, "Found by -Wextra", drivesounds.c pickstep) */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wuninitialized"
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
int pickstep(int maxactive,enum DriveSound_Type type)
{
	int bestcursor=0;
	int best=0;
	int count;
	int step;
	while(count>maxactive)
	{
		best=0;
		bestcursor=0;
		count=0;
		for(step=0;step<4;++step)
		{
			if(drivesounds.sounds[type+step].active)
			{
				++count;
				if(drivesounds.sounds[type+step].cursor>=bestcursor)
				{
					best=step;	
					bestcursor=drivesounds.sounds[type+step].cursor;
				}
			}
		}
		if(count>maxactive)
		{
			drivesounds.sounds[type+best].active=0;
			drivesounds.sounds[type+best].cursor=0;
		}
	}
	step=TIMER&3;
	while(drivesounds.sounds[type+step].active)
		step=(step+1)&3;
	return(step);
}
#pragma GCC diagnostic pop


int drivesounds_fill()
{
	struct dsevent *dse;
	if(cda_busy())	/* CD audio playing or paused: the drive sounds are silent (13.1) */
	{
		drivesounds.out=drivesounds.in;
		return(0);
	}
	if(drivesounds.enabled && drivesounds.active)
	{
		while((dse=drivesounds_nextevent()))
		{
			/* If we're about to start the motor but a stop is in progress, cancel both the stop and start, and go straight to loop. */
			if(dse->type==DRIVESOUND_MOTORSTART && drivesounds.sounds[DRIVESOUND_MOTORSTOP].active)
			{
				drivesounds.sounds[DRIVESOUND_MOTORLOOP].chain=DRIVESOUND_MOTORLOOP;
				drivesounds.sounds[DRIVESOUND_MOTORSTOP].active=0;
				drivesounds.sounds[DRIVESOUND_MOTORLOOP].active=1;
			}

			drivesounds_render(dse->timestamp);
			drivesounds.sounds[dse->type].cursor=0;
			switch(dse->type)
			{
				case DRIVESOUND_MOTORSTART:
					if ((drivesounds.enabled & DRIVESOUNDS_FLOPPY))
					{
						drivesounds.sounds[DRIVESOUND_MOTORLOOP].chain=DRIVESOUND_MOTORLOOP;
						if(!drivesounds.sounds[DRIVESOUND_MOTORLOOP].active)
						{
							drivesounds.sounds[DRIVESOUND_MOTORSTART].chain=DRIVESOUND_MOTORLOOP;
							drivesounds.sounds[DRIVESOUND_MOTORSTART].active=1;
						}
					}
					break;
				case DRIVESOUND_MOTORSTOP:
					if ((drivesounds.enabled & DRIVESOUNDS_FLOPPY))
					{
						drivesounds.sounds[DRIVESOUND_MOTORLOOP].chain=DRIVESOUND_MOTORSTOP;
					}
					break;
				case DRIVESOUND_STEP:
					if ((drivesounds.enabled & DRIVESOUNDS_FLOPPY))
					{
						dse->type=DRIVESOUND_STEP+pickstep(1,DRIVESOUND_STEP);	/* Pick a step sound at "random" */
						drivesounds.sounds[dse->type].active=1;
						drivesounds.sounds[dse->type].chain=0;
					}
					break;
				case DRIVESOUND_HDDSTEP:
					if((drivesounds.enabled & DRIVESOUNDS_HDD) && countstep(DRIVESOUND_HDDSTEP)<3)
					{
						dse->type=DRIVESOUND_HDDSTEP+pickstep(2,DRIVESOUND_HDDSTEP);	/* Pick a step sound at "random" */
						drivesounds.sounds[dse->type].active=1;
						drivesounds.sounds[dse->type].chain=0;
					}
					break;
				default:
					if ((drivesounds.enabled & DRIVESOUNDS_FLOPPY))
					{
						drivesounds.sounds[dse->type].active=1;
						drivesounds.sounds[dse->type].chain=0;
					}
					break;
			}
		}
		//	printf("Rendering remainder\n");
		drivesounds_render(TIMER);
	}
	return(drivesounds.active);
}


int drivesounds_init(const char *filename)
{
	int result=0;
	char *buf=(char *)AUDIO_BUFFER;	/* Load the drivesounds immediately in front of the audio buffer */
	int maxsize=buf-&__bss_end;
	RAFile file;
	drivesounds.in=0;
	drivesounds.out=0;
	drivesounds.loaded=0;
	if(RAOpen(&file,filename))
	{
		int size=file.size;
		if(size<=maxsize)
		{
			printf("Audio file - length %d\n",(int)file.size);		
			buf-=file.size;
			RARead(&file,(unsigned char *)buf,file.size);
			/* The file is big-endian (sw/mkdrivesounds): the header longs
			   are read byte by byte (buf is at AUDIO_BUFFER - size, and
			   the sizes are even, not multiples of 4: misaligned longs),
			   and each sound's samples are made native here, once, in
			   place (the render loops read them as shorts).  That write is
			   bounded: an odd file length (an odd
			   halfword address: a trap) is refused; a sound with a negative
			   id, a negative or odd size or more bytes than are left before
			   AUDIO_BUFFER ends the list, as does a header with fewer than
			   8 bytes left. */
			if(file.size&1)
				printf("Bad length in DriveSounds file\n");
			else if(strncmp(buf,"DRIVESND",8)==0)
			{
				char *end=(char *)AUDIO_BUFFER;
				int id=0;
				buf+=8;
				id=rd_be32(buf);
				buf+=4;
				size=rd_be32(buf);
				buf+=4;
				while(size)
				{
					if(size && id>=0 && id<DRIVESOUND_COUNT)
					{
						int i;
						short *samples=(short *)buf;
						if(size<0 || (size&1) || size>end-buf)
						{
							printf("Bad sound in DriveSounds file\n");
							break;
						}
						printf("Sound %d at %X, length %d\n",id,(unsigned int)(uintptr_t)buf,size);
						drivesounds.sounds[id].base=samples;
						drivesounds.sounds[id].length=size/2; /* Size needs to be in 16-bit words */
						for(i=0;i<size/2;++i)
							samples[i]=(short)rd_be16(&samples[i]);
						buf+=size;
						result=1;
						if(end-buf<8)
							break;
						id=rd_be32(buf);
						buf+=4;
						size=rd_be32(buf);
						buf+=4;
					}
					else
					{
						size=0;
					}
				}
				drivesounds.loaded=1;
			}
			else
				printf("Bad signature in DriveSounds file\n");
		}
		else
			printf("Drive sounds file too large\n");
	}
	drivesounds.cursor=0;
	drivesounds.active=0;
	drivesounds.playing=0;
	drivesounds.enabled=0;
	return(result);
}


int drivesounds_loaded()
{
	return(drivesounds.loaded);
}

