#ifndef WINDOW_MANAGER_H
#define WINDOW_MANAGER_H

#include <stdbool.h>

typedef struct {
    char* title;
    char* appName;
    int windowID;
    int processID;
    bool isMinimized;
} WindowInfoC;

WindowInfoC* getWindowList(int* count);
void freeWindowList(WindowInfoC* windows, int count);
int activateWindow(int windowID, int processID);
void ensurePermissionsGranted(void);

#endif
