#ifndef FPGA_H
#define FPGA_H

#include "rafile.h"

void ShiftFpga(unsigned char data);
unsigned char ConfigureFpga(void);
void SendFileV2(RAFile* file, unsigned char* key, int keysize, int address, int size);
void SendFile(RAFile *file);
void SendFileEncrypted(RAFile *file,unsigned char *key,int keysize);
char BootPrint(const char *text);
char PrepareBootUpload(unsigned char base, unsigned char size);
void BootExit(void);
void ClearMemory(unsigned long base, unsigned long size);
unsigned char GetFPGAStatus(void);
void fpga_init();

#endif

