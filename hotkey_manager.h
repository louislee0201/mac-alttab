#ifndef HOTKEY_MANAGER_H
#define HOTKEY_MANAGER_H

#include <stdbool.h>

void initApp(void);
void registerHotkey();
void unregisterHotkey();
void runEventLoopWithSetup(void);
bool isOptionKeyPressed();

#endif
