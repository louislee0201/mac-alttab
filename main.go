package main

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Cocoa -framework Carbon -framework ApplicationServices -framework QuartzCore -framework CoreGraphics -framework ScreenCaptureKit
#include <stdlib.h>
#include "window_manager.h"
#include "hotkey_manager.h"
#include "ui_window.h"
*/
import "C"
import (
	"runtime"
	"sync"
	"time"
	"unsafe"
)

type WindowInfo struct {
	Title       string
	AppName     string
	WindowID    int
	ProcessID   int
	IsMinimized bool
}

type AppSwitcher struct {
	windows      []WindowInfo
	currentIndex int
	visible      bool
	mu           sync.Mutex
}

var switcher *AppSwitcher

func init() {
	runtime.LockOSThread()
}

func main() {
	switcher = &AppSwitcher{}

	C.initApp()
	C.runEventLoopWithSetup()
}

//export onAppReady
func onAppReady() {
	C.ensurePermissionsGranted()
	C.registerHotkey()
	C.promptLaunchAtLogin()
	// 后台预抓所有窗口截图，填充缓存
	go func() {
		time.Sleep(1 * time.Second) // 等权限和 ScreenCaptureKit 就绪
		switcher.mu.Lock()
		switcher.loadWindows()
		wins := switcher.windows
		switcher.mu.Unlock()
		if len(wins) == 0 {
			return
		}
		count := len(wins)
		appNames := make([]*C.char, count)
		titles := make([]*C.char, count)
		windowIDs := make([]C.int, count)
		for i, w := range wins {
			appNames[i] = C.CString(w.AppName)
			titles[i] = C.CString(w.Title)
			windowIDs[i] = C.int(w.WindowID)
		}
		C.prefetchSnapshots(&appNames[0], &titles[0], C.int(count), &windowIDs[0])
		for i := 0; i < count; i++ {
			C.free(unsafe.Pointer(appNames[i]))
			C.free(unsafe.Pointer(titles[i]))
		}
	}()
}

//export onHotkeyPressed
func onHotkeyPressed() {
	go handleHotkey()
}

//export onWindowClicked
func onWindowClicked(index int) {
	go handleWindowClick(index)
}

//export onSwitcherTab
func onSwitcherTab() {
	switcher.mu.Lock()
	defer switcher.mu.Unlock()
	if !switcher.visible || len(switcher.windows) == 0 {
		return
	}
	switcher.currentIndex = (switcher.currentIndex + 1) % len(switcher.windows)
	switcher.updateUI()
}

//export onSwitcherShiftTab
func onSwitcherShiftTab() {
	switcher.mu.Lock()
	defer switcher.mu.Unlock()
	if !switcher.visible || len(switcher.windows) == 0 {
		return
	}
	n := len(switcher.windows)
	switcher.currentIndex = (switcher.currentIndex - 1 + n) % n
	switcher.updateUI()
}

//export onSwitcherEscape
func onSwitcherEscape() {
	switcher.mu.Lock()
	defer switcher.mu.Unlock()
	if switcher.visible {
		switcher.visible = false
		C.hideSwitcherUI()
	}
}

func handleWindowClick(index int) {
	switcher.mu.Lock()
	defer switcher.mu.Unlock()

	if !switcher.visible || index < 0 || index >= len(switcher.windows) {
		return
	}

	switcher.currentIndex = index
	switcher.activate()
}

func handleHotkey() {
	switcher.mu.Lock()

	if !switcher.visible {
		switcher.loadWindows()
		if len(switcher.windows) == 0 {
			switcher.mu.Unlock()
			return
		}

		switcher.currentIndex = 0
		if len(switcher.windows) > 1 {
			switcher.currentIndex = 1
		}
		switcher.visible = true
		switcher.displayWindows()

		go monitorOptionKey()
	} else {
		if len(switcher.windows) > 0 {
			switcher.currentIndex = (switcher.currentIndex + 1) % len(switcher.windows)
			switcher.updateUI()
		}
	}

	switcher.mu.Unlock()
}

func monitorOptionKey() {
	for {
		time.Sleep(80 * time.Millisecond)

		switcher.mu.Lock()
		if !switcher.visible {
			switcher.mu.Unlock()
			return
		}

		if !bool(C.isOptionKeyPressed()) {
			switcher.activate()
			switcher.mu.Unlock()
			return
		}
		switcher.mu.Unlock()
	}
}

func (as *AppSwitcher) loadWindows() {
	as.windows = []WindowInfo{}

	var count C.int
	windowsPtr := C.getWindowList(&count)

	if windowsPtr == nil || count == 0 {
		return
	}

	defer C.freeWindowList(windowsPtr, count)

	windowsSlice := (*[1 << 20]C.WindowInfoC)(unsafe.Pointer(windowsPtr))[:count:count]

	seen := make(map[int]bool)
	for i := 0; i < int(count); i++ {
		win := windowsSlice[i]
		appName := C.GoString(win.appName)
		windowID := int(win.windowID)
		if appName == "" || seen[windowID] {
			continue
		}
		seen[windowID] = true
		as.windows = append(as.windows, WindowInfo{
			Title:       C.GoString(win.title),
			AppName:     appName,
			WindowID:    windowID,
			ProcessID:   int(win.processID),
			IsMinimized: bool(win.isMinimized),
		})
	}
}

func (as *AppSwitcher) displayWindows() {
	as.showUI()
}

func (as *AppSwitcher) showUI() {
	if len(as.windows) == 0 {
		return
	}

	count := len(as.windows)
	appNames := make([]*C.char, count)
	titles := make([]*C.char, count)
	windowIDs := make([]C.int, count)
	for i, win := range as.windows {
		appName := win.AppName
		if appName == "" {
			appName = "Unknown App"
		}
		title := win.Title
		if title == "" {
			title = "Untitled"
		}
		appNames[i] = C.CString(appName)
		titles[i] = C.CString(title)
		windowIDs[i] = C.int(win.WindowID)
	}

	C.showSwitcherUI(&appNames[0], &titles[0], C.int(count), C.int(as.currentIndex), &windowIDs[0])
	for i := 0; i < count; i++ {
		C.free(unsafe.Pointer(appNames[i]))
		C.free(unsafe.Pointer(titles[i]))
	}
}

func (as *AppSwitcher) updateUI() {
	C.updateSelection(C.int(as.currentIndex))
}

func (as *AppSwitcher) activate() {
	if !as.visible || len(as.windows) == 0 {
		return
	}

	selectedWindow := as.windows[as.currentIndex]
	as.visible = false

	C.activateWindow(C.int(selectedWindow.WindowID), C.int(selectedWindow.ProcessID))
	C.hideSwitcherUI()
}
