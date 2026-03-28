#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "window_manager.h"

void ensurePermissionsGranted(void) {
    // Check both permissions upfront
    BOOL hasScreenRecording = YES;
    if (@available(macOS 12.3, *)) {
        hasScreenRecording = CGPreflightScreenCaptureAccess();
    }
    BOOL hasAccessibility = AXIsProcessTrusted();

    // ── Step 1: Accessibility ─────────────────────────────────────
    if (!hasAccessibility) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText     = @"Accessibility Permission Required";
        alert.informativeText = @"Mac AltTab needs Accessibility to switch windows.\n\nGo to:\nSystem Settings > Privacy & Security > Accessibility\nEnable Mac AltTab.\n\nmacOS will ask you to restart — click \"Restart\".";
        [alert addButtonWithTitle:@"Open System Settings"];
        [alert runModal];
        [alert release];

        [[NSWorkspace sharedWorkspace] openURL:
            [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
        return; // Wait for relaunch before asking next permission
    }

    // ── Step 2: Screen Recording ──────────────────────────────────
    if (!hasScreenRecording) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText     = @"Screen Recording Permission Required";
        alert.informativeText = @"Mac AltTab needs Screen Recording to show window previews.\n\nGo to:\nSystem Settings > Privacy & Security > Screen Recording\nEnable Mac AltTab, then relaunch the app.";
        [alert addButtonWithTitle:@"Open System Settings"];
        [alert runModal];
        [alert release];

        [[NSWorkspace sharedWorkspace] openURL:
            [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
    }
}

static NSDictionary<NSNumber*, NSString*>* getAXTitlesByWindowID(pid_t pid, NSArray *cgWindows) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    AXUIElementRef appElement = AXUIElementCreateApplication(pid);
    if (!appElement) return result;

    CFArrayRef windowListAX = NULL;
    if (AXUIElementCopyAttributeValues(appElement, kAXWindowsAttribute, 0, 100, &windowListAX)
        != kAXErrorSuccess || !windowListAX) {
        CFRelease(appElement);
        return result;
    }

    NSMutableArray<NSString*> *axTitles = [NSMutableArray array];
    CFIndex n = CFArrayGetCount(windowListAX);
    for (CFIndex i = 0; i < n; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windowListAX, i);
        CFStringRef axTitle = NULL;
        NSString *title = @"";
        if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, (CFTypeRef*)&axTitle)
            == kAXErrorSuccess && axTitle) {
            title = [(__bridge NSString *)axTitle copy]; CFRelease(axTitle);
        }
        [axTitles addObject:title];
    }
    CFRelease(windowListAX);
    CFRelease(appElement);

    NSMutableArray<NSNumber*> *cgWids = [NSMutableArray array];
    for (NSDictionary *w in cgWindows) {
        if ([w[(NSString*)kCGWindowOwnerPID] intValue] != pid) continue;
        NSNumber *wid = w[(NSString*)kCGWindowNumber];
        if (wid) [cgWids addObject:wid];
    }

    NSInteger count = MIN((NSInteger)axTitles.count, (NSInteger)cgWids.count);
    for (NSInteger i = 0; i < count; i++) {
        if ([axTitles[i] length] > 0) result[cgWids[i]] = axTitles[i];
    }
    return result;
}

WindowInfoC* getWindowList(int* count) {
    @autoreleasepool {
        NSMutableArray *windowList = [NSMutableArray array];

        CFArrayRef windowListRef = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID);
        if (!windowListRef) { *count = 0; return NULL; }

        NSArray *windows = (__bridge NSArray *)windowListRef;
        NSMutableDictionary<NSNumber*, NSDictionary*> *pidToAxTitles = [NSMutableDictionary dictionary];

        for (NSDictionary *window in windows) {
            NSNumber *layer = window[(NSString *)kCGWindowLayer];
            if (layer && [layer intValue] != 0) continue;

            NSNumber *processID = window[(NSString *)kCGWindowOwnerPID];
            if (!processID) continue;

            NSString *appName = window[(NSString *)kCGWindowOwnerName];
            if (!appName.length) {
                NSRunningApplication *app = [NSRunningApplication
                    runningApplicationWithProcessIdentifier:[processID intValue]];
                appName = app.localizedName ?: app.bundleIdentifier
                       ?: [NSString stringWithFormat:@"App-%@", processID];
            }
            if (!appName.length) continue;

            if ([appName isEqualToString:@"Window Server"] ||
                [appName isEqualToString:@"Dock"] ||
                [appName isEqualToString:@"SystemUIServer"]) continue;

            NSNumber *windowID = window[(NSString *)kCGWindowNumber];
            if (!windowID) continue;

            NSDictionary *bounds = window[(NSString *)kCGWindowBounds];
            if (bounds) {
                CGRect rect;
                CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &rect);
                if (rect.size.width < 100 || rect.size.height < 100) continue;
            }

            if (!pidToAxTitles[processID]) {
                pidToAxTitles[processID] = getAXTitlesByWindowID([processID intValue], windows);
            }

            NSString *axTitle = pidToAxTitles[processID][windowID];
            NSString *title = nil;

            if (axTitle.length) {
                // Reverse "file — folder" → "folder — file"
                NSString *emDash = @" \u2014 ";
                if ([axTitle containsString:emDash]) {
                    NSArray<NSString*> *parts = [axTitle componentsSeparatedByString:emDash];
                    if (parts.count >= 2) {
                        axTitle = [[parts reverseObjectEnumerator].allObjects
                                   componentsJoinedByString:emDash];
                    }
                }
                title = ([axTitle rangeOfString:@" - "].location != NSNotFound ||
                         [axTitle isEqualToString:appName])
                    ? axTitle
                    : [NSString stringWithFormat:@"%@ - %@", appName, axTitle];
            }
            if (!title.length) {
                NSString *cgName = window[(NSString *)kCGWindowName];
                title = (cgName.length && ![cgName isEqualToString:appName])
                    ? [NSString stringWithFormat:@"%@ - %@", appName, cgName]
                    : appName;
            }

            [windowList addObject:@{
                @"title":     title,
                @"appName":   appName,
                @"windowID":  windowID,
                @"processID": processID
            }];
        }
        CFRelease(windowListRef);

        *count = (int)[windowList count];
        if (*count == 0) return NULL;

        WindowInfoC *result = (WindowInfoC *)malloc(sizeof(WindowInfoC) * (*count));
        for (int i = 0; i < *count; i++) {
            NSDictionary *win = windowList[i];
            result[i].title     = strdup([win[@"title"]   UTF8String] ?: "Untitled");
            result[i].appName   = strdup([win[@"appName"] UTF8String] ?: "Unknown");
            result[i].windowID  = [win[@"windowID"]  intValue];
            result[i].processID = [win[@"processID"] intValue];
            result[i].isMinimized = false;
        }
        return result;
    }
}

void freeWindowList(WindowInfoC* windows, int count) {
    if (!windows) return;
    for (int i = 0; i < count; i++) {
        if (windows[i].title)   free(windows[i].title);
        if (windows[i].appName) free(windows[i].appName);
    }
    free(windows);
}

int activateWindow(int windowID, int processID) {
    @autoreleasepool {
        __block int success = 0;

        NSString *cgTitle = nil;
        {
            CFArrayRef cgList = CGWindowListCopyWindowInfo(
                kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                kCGNullWindowID);
            if (cgList) {
                for (NSDictionary *w in (__bridge NSArray *)cgList) {
                    if ([w[(NSString*)kCGWindowNumber] intValue] == windowID) {
                        NSString *raw = w[(NSString*)kCGWindowName];
                        if (raw) cgTitle = [[raw retain] autorelease];
                        break;
                    }
                }
                CFRelease(cgList);
            }
        }

        NSString *titleCopy = [cgTitle copy];
        dispatch_sync(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                AXUIElementRef appElement = AXUIElementCreateApplication(processID);
                if (!appElement) return;

                CFArrayRef windowList = NULL;
                AXError axErr = AXUIElementCopyAttributeValues(appElement, kAXWindowsAttribute, 0, 100, &windowList);

                if (axErr == kAXErrorSuccess && windowList) {
                    CFIndex n = CFArrayGetCount(windowList);
                    AXUIElementRef matchedWin = NULL;

                    for (CFIndex i = 0; i < n; i++) {
                        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windowList, i);
                        CFStringRef axTitle = NULL;
                        NSString *axTitleStr = @"";
                        if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, (CFTypeRef*)&axTitle)
                            == kAXErrorSuccess && axTitle) {
                            axTitleStr = [(__bridge NSString *)axTitle copy];
                            CFRelease(axTitle);
                        }
                        if (titleCopy.length > 0 && [axTitleStr isEqualToString:titleCopy]) {
                            matchedWin = win;
                            [axTitleStr release];
                            break;
                        }
                        [axTitleStr release];
                    }

                    if (!matchedWin && n > 0) {
                        matchedWin = (AXUIElementRef)CFArrayGetValueAtIndex(windowList, 0);
                    }

                    if (matchedWin) {
                        AXUIElementSetAttributeValue(matchedWin, kAXMainAttribute, kCFBooleanTrue);
                        AXUIElementSetAttributeValue(matchedWin, kAXFocusedAttribute, kCFBooleanTrue);
                        AXUIElementPerformAction(matchedWin, kAXRaiseAction);
                        success = 1;
                    }
                    CFRelease(windowList);
                }
                CFRelease(appElement);

                NSRunningApplication *app = [NSRunningApplication
                    runningApplicationWithProcessIdentifier:processID];
                if (app) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                    [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
                    success = 1;
                }
            }
        });
        [titleCopy release];

        return success;
    }
}
