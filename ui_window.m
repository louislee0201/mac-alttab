#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "ui_window.h"

extern void onWindowClicked(int index);
extern void onSwitcherTab(void);
extern void onSwitcherShiftTab(void);
extern void onSwitcherEscape(void);

// 内存缓存：windowID -> NSImage
static NSMutableDictionary<NSNumber *, NSImage *> *snapshotCache;
// icon 缓存：appName -> NSImage（全局复用，避免每次重查 runningApplications）
static NSMutableDictionary<NSString *, NSImage *> *iconCache;

// ── 磁盘持久化 ──────────────────────────────────────────────────
static NSString* diskCacheDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *caches = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        // 用 alloc/initWithFormat 保证非ARC下不被 autorelease pool 释放
        dir = [[NSString alloc] initWithFormat:@"%@/mac-alttab", caches];
        [[NSFileManager defaultManager]
            createDirectoryAtPath:dir
          withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

// 用 appName + title 生成合法文件名（windowID 重启后会变，不能用）
static NSString* diskCacheKey(NSString *appName, NSString *title) {
    NSString *raw = [NSString stringWithFormat:@"%@__%@", appName ?: @"", title ?: @""];
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/:\\?*\"|<>"];
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        [safe appendString:[bad characterIsMember:c] ? @"_" : [NSString stringWithCharacters:&c length:1]];
    }
    if (safe.length > 200) [safe deleteCharactersInRange:NSMakeRange(200, safe.length - 200)];
    return [safe stringByAppendingString:@".png"];
}

static NSImage* loadDiskSnapshot(NSString *appName, NSString *title) {
    NSString *path = [diskCacheDir() stringByAppendingPathComponent:diskCacheKey(appName, title)];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return [[NSImage alloc] initWithContentsOfFile:path];
}

static void saveDiskSnapshot(NSImage *img, NSString *appName, NSString *title) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        NSString *path = [diskCacheDir() stringByAppendingPathComponent:diskCacheKey(appName, title)];
        NSData *tiff = img.TIFFRepresentation;
        if (!tiff) return;
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:path atomically:YES];
    });
}
// ────────────────────────────────────────────────────────────────

// 异步抓单个窗口截图，完成后主线程回调
static void captureOneSnapshot(int windowID, void (^onDone)(NSImage *img)) {
    if (windowID <= 0) { dispatch_async(dispatch_get_main_queue(), ^{ onDone(nil); }); return; }

    if (@available(macOS 14.0, *)) {
        [SCShareableContent getShareableContentWithCompletionHandler:
         ^(SCShareableContent *content, NSError *error) {
            if (error || !content) {
                dispatch_async(dispatch_get_main_queue(), ^{ onDone(nil); });
                return;
            }
            SCWindow *target = nil;
            for (SCWindow *w in content.windows) {
                if ((int)w.windowID == windowID) { target = w; break; }
            }
            if (!target || target.frame.size.width < 1) {
                dispatch_async(dispatch_get_main_queue(), ^{ onDone(nil); });
                return;
            }
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];
            SCStreamConfiguration *cfg = [[SCStreamConfiguration alloc] init];
            CGFloat scale = MIN(420.0 / target.frame.size.width, 280.0 / target.frame.size.height);
            cfg.width       = MAX(1, (size_t)(target.frame.size.width  * scale));
            cfg.height      = MAX(1, (size_t)(target.frame.size.height * scale));
            cfg.showsCursor = NO;
            [SCScreenshotManager captureImageWithFilter:filter
                                          configuration:cfg
                                      completionHandler:^(CGImageRef img, NSError *err) {
                NSImage *nsImg = (img && !err)
                    ? [[NSImage alloc] initWithCGImage:img size:NSZeroSize] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{ onDone(nsImg); });
            }];
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ onDone(nil); });
    }
}

@interface ClickableItemView : NSView
@property (assign) int itemIndex;
@property (assign, nonatomic) BOOL isSelected;
@property (strong) NSImageView *snapshotView;
@end

@implementation ClickableItemView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 8;
        self.layer.borderWidth = 0;
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
               owner:self userInfo:nil]];
}

- (void)mouseEntered:(NSEvent *)event {
    if (!self.isSelected) {
        self.layer.borderWidth = 2;
        self.layer.borderColor = [[NSColor colorWithWhite:0.7 alpha:0.5] CGColor];
    }
}
- (void)mouseExited:(NSEvent *)event { [self updateBg]; }

- (void)updateBg {
    if (self.isSelected) {
        self.layer.borderWidth = 3;
        self.layer.borderColor = [[NSColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:1.0] CGColor];
    } else {
        self.layer.borderWidth = 0;
        self.layer.borderColor = nil;
    }
}

- (void)setIsSelected:(BOOL)v { _isSelected = v; [self updateBg]; }
- (void)mouseDown:(NSEvent *)event { onWindowClicked(self.itemIndex); }

@end

@interface SwitcherWindow : NSPanel
@property (strong) NSMutableArray *itemViews;
@property (assign) int selectedIndex;
@end

@implementation SwitcherWindow

- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (instancetype)initWithContentRect:(NSRect)r {
    self = [super initWithContentRect:r
                            styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered defer:NO];
    if (self) {
        self.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.95];
        self.level = NSPopUpMenuWindowLevel;
        self.opaque = YES; self.hasShadow = YES;
        [self setFloatingPanel:YES]; [self setHidesOnDeactivate:NO];
        self.contentView.wantsLayer = YES;
        self.contentView.layer.cornerRadius = 12;
        self.contentView.layer.masksToBounds = YES;
        self.itemViews = [NSMutableArray array];
    }
    return self;
}

- (void)keyDown:(NSEvent *)event {
    unsigned short k = event.keyCode;
    // Tab/Shift+Tab 由 local monitor 消费，不会到这里；仅保留其他快捷键
    if (k == 53) { onSwitcherEscape(); return; }
    if (k == 36 || k == 49) { onWindowClicked(self.selectedIndex); return; }
    [super keyDown:event];
}

- (void)updateSelectionToIndex:(int)idx {
    for (int i = 0; i < (int)self.itemViews.count; i++)
        [(ClickableItemView *)self.itemViews[i] setIsSelected:(i == idx)];
    self.selectedIndex = idx;
}

@end

static SwitcherWindow *globalWindow = nil;
static id localKeyMonitor = nil;

void showSwitcherUI(const char **appNames, const char **titles,
                    int count, int selectedIndex, int *windowIDs) {
    int displayCount = count > 24 ? 24 : count;
    if (displayCount <= 0) return;

    if (!snapshotCache) snapshotCache = [[NSMutableDictionary alloc] init];
    if (!iconCache)     iconCache     = [[NSMutableDictionary alloc] init];

    NSMutableArray *appNameArray = [NSMutableArray arrayWithCapacity:displayCount];
    NSMutableArray *titleArray   = [NSMutableArray arrayWithCapacity:displayCount];
    NSMutableArray *widArray     = [NSMutableArray arrayWithCapacity:displayCount];
    for (int i = 0; i < displayCount; i++) {
        [appNameArray addObject:appNames[i] ? @(appNames[i]) : @"Unknown"];
        [titleArray   addObject:titles[i]   ? @(titles[i])   : @"Unknown"];
        [widArray     addObject:@(windowIDs ? windowIDs[i] : 0)];
    }

    // 当前窗口 = index 0（切换前正在使用的）
    int currentWID = windowIDs ? windowIDs[0] : 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (globalWindow) { [globalWindow close]; globalWindow = nil; }
        if (localKeyMonitor) { [NSEvent removeMonitor:localKeyMonitor]; localKeyMonitor = nil; }

        int itemsPerRow = 5;
        int rows = (displayCount + itemsPerRow - 1) / itemsPerRow;
        CGFloat itemW = 210, itemH = 140, gap = 12, pad = 20;
        CGFloat topBarH = 28, previewH = itemH - topBarH;
        CGFloat ww = itemW * itemsPerRow + gap * (itemsPerRow - 1) + pad * 2;
        CGFloat wh = itemH * rows        + gap * (rows - 1)        + pad * 2;

        NSRect sr = [NSScreen mainScreen].visibleFrame;
        NSRect winRect = NSMakeRect(sr.origin.x + (sr.size.width  - ww) / 2,
                                    sr.origin.y + (sr.size.height - wh) / 2, ww, wh);

        globalWindow = [[SwitcherWindow alloc] initWithContentRect:winRect];

        for (int i = 0; i < displayCount; i++) {
            int row = i / itemsPerRow, col = i % itemsPerRow;
            CGFloat x = pad + col * (itemW + gap);
            CGFloat y = wh  - pad - itemH - row * (itemH + gap);

            ClickableItemView *item = [[ClickableItemView alloc]
                initWithFrame:NSMakeRect(x, y, itemW, itemH)];
            item.itemIndex  = i;
            item.isSelected = (i == selectedIndex);
            item.layer.masksToBounds = YES;

            // 顶部信息栏：图标 + 名字
            NSString *appName = appNameArray[i];
            NSString *title = titleArray[i];
            NSString *display = ([title isEqualToString:appName] || title.length == 0)
                ? appName : title;

            NSView *topBar = [[NSView alloc] initWithFrame:NSMakeRect(0, previewH, itemW, topBarH)];
            topBar.wantsLayer = YES;
            topBar.layer.backgroundColor = [[NSColor colorWithWhite:0.10 alpha:0.95] CGColor];
            [item addSubview:topBar];

            // 图标（左侧，垂直居中）
            NSImage *icon = iconCache[appName];
            if (!icon) {
                for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
                    if ([app.localizedName isEqualToString:appName]) {
                        icon = app.bundleURL
                            ? [NSWorkspace.sharedWorkspace iconForFile:app.bundleURL.path] : nil;
                        break;
                    }
                }
                if (!icon) icon = [NSWorkspace.sharedWorkspace iconForFile:@"/Applications"];
                iconCache[appName] = icon ?: [NSImage imageNamed:NSImageNameApplicationIcon];
            }
            // 名字先加（下层）：全宽居中，左右留 icon 宽度做对称 padding 避免被遮太多
            CGFloat iconSize = 20;
            CGFloat hPad = iconSize + 8;
            NSTextField *tf = [[NSTextField alloc]
                initWithFrame:NSMakeRect(hPad, -6, itemW - hPad * 2, topBarH)];
            tf.stringValue = display;
            tf.font = [NSFont systemFontOfSize:10];
            tf.textColor = [NSColor whiteColor];
            tf.backgroundColor = [NSColor clearColor];
            tf.bordered = NO; tf.editable = NO;
            tf.lineBreakMode = NSLineBreakByTruncatingTail;
            tf.maximumNumberOfLines = 1;
            tf.alignment = NSTextAlignmentCenter;
            [topBar addSubview:tf];

            // 图标后加（上层）：垂直居中，紧贴左边
            CGFloat iconY = (topBarH - iconSize) / 2;
            NSImageView *iv = [[NSImageView alloc]
                initWithFrame:NSMakeRect(5, iconY, iconSize, iconSize)];
            iv.image = icon;
            iv.imageScaling = NSImageScaleProportionallyUpOrDown;
            [topBar addSubview:iv];

            // 截图区（顶栏下方，占满剩余高度）
            NSImageView *sv = [[NSImageView alloc]
                initWithFrame:NSMakeRect(0, 0, itemW, previewH)];
            sv.imageScaling   = NSImageScaleProportionallyUpOrDown;
            sv.imageAlignment = NSImageAlignCenter;
            sv.wantsLayer = YES;
            NSImage *cached = snapshotCache[widArray[i]];
            if (cached) {
                sv.image = cached;
            } else {
                sv.layer.backgroundColor = [[NSColor colorWithWhite:0.18 alpha:1.0] CGColor];
                NSNumber *wid = widArray[i];
                NSString *an = appName, *tt = title;
                NSImageView *svRef = sv;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                    NSImage *disk = loadDiskSnapshot(an, tt);
                    if (!disk) return;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!snapshotCache[wid]) snapshotCache[wid] = disk;
                        if (svRef.image) return;
                        svRef.layer.backgroundColor = nil;
                        svRef.image = disk;
                    });
                });
            }
            [item addSubview:sv];
            item.snapshotView = sv;

            [globalWindow.contentView addSubview:item];
            [globalWindow.itemViews addObject:item];
        }

        globalWindow.selectedIndex = selectedIndex;
        [NSApp activateIgnoringOtherApps:YES];
        [globalWindow makeKeyAndOrderFront:nil];
        [globalWindow makeFirstResponder:globalWindow];

        localKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
            handler:^NSEvent *(NSEvent *ev) {
                unsigned short k = ev.keyCode;
                if (k == 48) {
                    // Tab/Shift+Tab：Carbon 热键已处理 Option+Tab（前进），
                    // 这里只处理 Shift+Tab（后退）和单独 Tab（无 Option）
                    if (ev.modifierFlags & NSEventModifierFlagShift) {
                        onSwitcherShiftTab();
                        return nil;
                    }
                    // Option+Tab 由 Carbon 热键处理，消费事件防止重复
                    return nil;
                }
                if (k == 53) { onSwitcherEscape(); return nil; }
                if (k == 36 || k == 49) {
                    if (globalWindow) onWindowClicked(globalWindow.selectedIndex);
                    return nil;
                }
                return ev;
            }];

        // 抓所有没有缓存的窗口截图，逐一更新卡片
        for (int i = 0; i < displayCount; i++) {
            NSNumber *wid   = widArray[i];
            if (snapshotCache[wid]) continue; // 内存已有，跳过
            NSString *an    = appNameArray[i];
            NSString *tt    = titleArray[i];
            int widInt      = [wid intValue];
            ClickableItemView *itemRef = globalWindow.itemViews[i];
            NSImageView *svRef = itemRef.snapshotView;
            captureOneSnapshot(widInt, ^(NSImage *img) {
                if (!img) return;
                snapshotCache[wid] = img;
                saveDiskSnapshot(img, an, tt);
                if (svRef && globalWindow) {
                    svRef.layer.backgroundColor = nil;
                    svRef.image = img;
                }
            });
        }
    });
}

// 启动时预抓所有窗口截图，填充缓存
void prefetchSnapshots(const char **appNames, const char **titles, int count, int *windowIDs) {
    if (!snapshotCache) snapshotCache = [[NSMutableDictionary alloc] init];

    for (int i = 0; i < count; i++) {
        int wid = windowIDs[i];
        NSNumber *widKey = @(wid);
        if (snapshotCache[widKey]) continue; // 内存已有

        NSString *an = appNames[i] ? @(appNames[i]) : @"";
        NSString *tt = titles[i]   ? @(titles[i])   : @"";

        // 先尝试从磁盘加载
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            NSImage *disk = loadDiskSnapshot(an, tt);
            if (disk) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!snapshotCache[widKey]) snapshotCache[widKey] = disk;
                });
                return;
            }
            // 磁盘也没有，抓新截图
            captureOneSnapshot(wid, ^(NSImage *img) {
                if (!img) return;
                snapshotCache[widKey] = img;
                saveDiskSnapshot(img, an, tt);
            });
        });
    }
}

void hideSwitcherUI() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (localKeyMonitor) { [NSEvent removeMonitor:localKeyMonitor]; localKeyMonitor = nil; }
        if (globalWindow) { [globalWindow close]; globalWindow = nil; }
    });
}

void updateSelection(int newIndex) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (globalWindow) [globalWindow updateSelectionToIndex:newIndex];
    });
}

// ── 开机启动 ─────────────────────────────────────────────────────────────────

static NSString* launchAgentPath(void) {
    NSString *home = NSHomeDirectory();
    return [home stringByAppendingPathComponent:
            @"Library/LaunchAgents/com.local.mac-alttab.plist"];
}

static BOOL isLaunchAtLoginEnabled(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:launchAgentPath()];
}

static void setLaunchAtLogin(BOOL enable) {
    NSString *plistPath = launchAgentPath();
    if (enable) {
        NSString *execPath = [[NSBundle mainBundle] executablePath];
        if (!execPath) return;
        NSDictionary *plist = @{
            @"Label":            @"com.local.mac-alttab",
            @"ProgramArguments": @[execPath],
            @"RunAtLoad":        @YES,
            @"KeepAlive":        @NO,
        };
        [plist writeToFile:plistPath atomically:YES];
        // 加载 agent 使其立即生效
        NSTask *task = [NSTask launchedTaskWithLaunchPath:@"/bin/launchctl"
            arguments:@[@"load", plistPath]];
        [task waitUntilExit];
    } else {
        if (isLaunchAtLoginEnabled()) {
            NSTask *task = [NSTask launchedTaskWithLaunchPath:@"/bin/launchctl"
                arguments:@[@"unload", plistPath]];
            [task waitUntilExit];
            [[NSFileManager defaultManager] removeItemAtPath:plistPath error:nil];
        }
    }
}

void promptLaunchAtLogin(void) {
    // If already enabled, nothing to ask
    if (isLaunchAtLoginEnabled()) return;

    // Ask every launch until user says Yes
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText     = @"Launch at Login";
        alert.informativeText = @"Would you like Mac AltTab to launch automatically at login?";
        [alert addButtonWithTitle:@"Yes, Launch at Login"];
        [alert addButtonWithTitle:@"No Thanks"];
        alert.alertStyle = NSAlertStyleInformational;

        NSModalResponse resp = [alert runModal];
        if (resp == NSAlertFirstButtonReturn) {
            setLaunchAtLogin(YES);
        }
        [alert release];
    });
}
