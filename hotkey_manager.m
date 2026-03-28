#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#import "hotkey_manager.h"

// 从 Go 导出的函数
extern void onHotkeyPressed();
extern void onOptionKeyReleased();

static EventHotKeyRef hotKeyRef;
static EventHotKeyID hotKeyID;

OSStatus hotkeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    EventHotKeyID hkID;
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hkID), NULL, &hkID);
    
    if (hkID.id == hotKeyID.id) {
        onHotkeyPressed();
    }
    
    return noErr;
}

void registerHotkey() {
    @autoreleasepool {
        // 注册 Option+Tab (Alt+Tab)
        hotKeyID.signature = 'altb';
        hotKeyID.id = 1;
        
        EventTypeSpec eventType;
        eventType.eventClass = kEventClassKeyboard;
        eventType.eventKind = kEventHotKeyPressed;
        
        InstallApplicationEventHandler(&hotkeyHandler, 1, &eventType, NULL, NULL);
        
        // Option 键 (Alt) = optionKey
        // Tab = 48
        RegisterEventHotKey(48, optionKey, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef);
    }
}

void unregisterHotkey() {
    if (hotKeyRef) {
        UnregisterEventHotKey(hotKeyRef);
    }
}

// 检查 Option 键是否按下
bool isOptionKeyPressed() {
    return (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & kCGEventFlagMaskAlternate) != 0;
}

void initApp(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

extern void onAppReady(void);

void runEventLoopWithSetup(void) {
    @autoreleasepool {
        // 事件循环启动后立刻异步执行权限检查和热键注册
        dispatch_async(dispatch_get_main_queue(), ^{
            onAppReady();
        });
        [NSApp run];
    }
}
