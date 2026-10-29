#ifndef MENU_H
#define MENU_H

#include "fdd.h" // for adfTYPE definition

// menu.c: the OSD's entry points (the menu is ui.c on the text layer)

void InsertFloppy(adfTYPE *drive);  // menu_model.c
void HandleUI(void);
void ShowError();
void DebugMessage(char *message);
void _showdebugmessages();
// The Ctrl-Alt-F12 debug page on the OSD text layer (osd2_caps): on draws it
// and switches the 64 x 20 window on, off switches it off if it was on.
void debug2_show(int on);
void SanityCheck();

#endif
