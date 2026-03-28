#ifndef UI_WINDOW_H
#define UI_WINDOW_H

void showSwitcherUI(const char** appNames, const char** titles, int count, int selectedIndex, int* windowIDs);
void hideSwitcherUI();
void updateSelection(int newIndex);
void promptLaunchAtLogin(void);
void prefetchSnapshots(const char** appNames, const char** titles, int count, int* windowIDs);

#endif
