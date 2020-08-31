#ifndef DRIVESOUNDS_H
#define DRIVESOUNDS_H

enum DriveSound_Type {
	DRIVESOUND_INSERT=0,DRIVESOUND_EJECT,DRIVESOUND_MOTORSTART,DRIVESOUND_MOTORLOOP,DRIVESOUND_MOTORSTOP,
	DRIVESOUND_STEP,DRIVESOUND_STEP2,DRIVESOUND_STEP3,DRIVESOUND_STEP4
};
#define DRIVESOUND_COUNT 9

void drivesounds_queueevent(enum DriveSound_Type type);
void drivesounds_stop();
void drivesounds_start();
int drivesounds_fill();
int drivesounds_init(const char *filename);

#endif

