#import "Settings.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// All settings intentionally live in Spotify's standard defaults: Swift reads the same keys.
static NSString *const kEnabled = @"sgl.enabled";
static NSString *const kWidth = @"sgl.width";
static NSString *const kFontSize = @"sgl.fontSize";
static NSString *const kArtworkColor = @"sgl.artworkColor";
static NSString *const kHideOnPause = @"sgl.hideOnPause";
static NSString *const kAutoHide = @"sgl.autoHide";
static NSString *const kHidden = @"sgl.hidden";
static NSString *const kLyricsTitle = @"Lyrics";
static NSString *const kLockScreenLyricsKey = @"spotifyglass.lockScreenLyrics";

typedef id (*SGModPageInitIMP)(id, SEL, NSString *, NSString *, NSArray *, NSString *);
typedef id (*SGPageRowIMP)(NSString *, id);
typedef id (*SGSectionIMP)(NSString *, NSArray *);
typedef id (*SGOptionRowIMP)(NSString *, NSString *, NSString *);
typedef id (*SGSwitchRowIMP)(NSString *, NSString *, NSString *);
typedef id (*SGChoiceRowIMP)(NSString *, NSString *, NSString *, NSArray *, NSInteger);

static SGModPageInitIMP sOriginalInit;
static SGPageRowIMP sPageRow;
static SGSectionIMP sSection;
static SGOptionRowIMP sOptionRow;
static SGSwitchRowIMP sSwitchRow;
static SGChoiceRowIMP sChoiceRow;
static BOOL sInstalled;

static BOOL HasLockScreenLyricsRow(NSArray *sections) {
    for (id section in sections) {
        NSArray *rows = ((id (*)(id, SEL))objc_msgSend)(section, @selector(rows));
        for (id row in rows) {
            NSString *key = ((id (*)(id, SEL))objc_msgSend)(row, @selector(key));
            if ([key isEqualToString:kLockScreenLyricsKey]) return YES;
        }
    }
    return NO;
}

static id OptionRow(NSString *title, NSString *key) {
    return sOptionRow(title, nil, key);
}

static id SwitchRow(NSString *title, NSString *key) {
    return sSwitchRow(title, nil, key);
}

static id SettingsPage(void) {
    NSArray *widthNames = @[@"Standard", @"Longest"];
    NSArray *fontNames = @[@"Small", @"Standard", @"Large"];
    NSArray *hideNames = @[@"Never", @"5 seconds", @"30 seconds", @"60 seconds", @"5 minutes"];
    id width = sChoiceRow(@"Width", nil, kWidth, widthNames, 0);
    id font = sChoiceRow(@"Font size", nil, kFontSize, fontNames, 1);
    // SGChoiceRow stores the chosen INDEX (0...4); the Swift side maps it to 0/5/30/60/300 seconds.
    id autoHide = sChoiceRow(@"Auto close", nil, kAutoHide, hideNames, 0);
    id active = OptionRow(@"Live Island lyrics", kEnabled);       // false when unset
    id color = SwitchRow(@"Use cover colours", kArtworkColor);     // true when unset
    id pause = SwitchRow(@"Hide when paused", kHideOnPause);       // true when unset
    id hidden = OptionRow(@"Hide Live Island", kHidden);           // false when unset
    id first = sSection(nil, @[active, width, font]);
    id display = sSection(@"Display", @[color, pause, autoHide]);
    id visibility = sSection(nil, @[hidden]);
    Class pageClass = NSClassFromString(@"SGModPage");
    SEL init = @selector(initWithTitle:intro:sections:footer:);
    return ((id (*)(id, SEL, NSString *, NSString *, NSArray *, NSString *))objc_msgSend)(
        [pageClass alloc], init, @"Live Island lyrics", nil, @[first, display, visibility], nil);
}

static id LyricsPageInit(id self, SEL _cmd, NSString *title, NSString *intro, NSArray *sections, NSString *footer) {
    // Key is the durable identity; title rejects unrelated SGModPage instances containing a copied row.
    if (![title isEqualToString:kLyricsTitle] || !HasLockScreenLyricsRow(sections))
        return sOriginalInit(self, _cmd, title, intro, sections, footer);
    NSMutableArray *extended = [sections mutableCopy];
    id entry = sPageRow(@"Live Island lyrics", ^UIViewController *{ return SettingsPage(); });
    [extended addObject:sSection(nil, @[entry])];
    return sOriginalInit(self, _cmd, title, intro, extended, footer);
}

void SGLInstallSettings(void) {
    void (^install)(void) = ^{
        if (sInstalled) return;
        Class pageClass = NSClassFromString(@"SGModPage");
        if (!pageClass) return; // Spotify/the original tweak has not loaded: a later call retries.
        Method method = class_getInstanceMethod(pageClass, @selector(initWithTitle:intro:sections:footer:));
        if (!method) return;
        void *pageRow = dlsym(RTLD_DEFAULT, "SGPageRow");
        void *section = dlsym(RTLD_DEFAULT, "SGSection");
        void *optionRow = dlsym(RTLD_DEFAULT, "SGOptionRow");
        void *switchRow = dlsym(RTLD_DEFAULT, "SGSwitchRow");
        void *choiceRow = dlsym(RTLD_DEFAULT, "SGChoiceRow");
        if (!pageRow || !section || !optionRow || !switchRow || !choiceRow) return;
        sPageRow = (SGPageRowIMP)pageRow;
        sSection = (SGSectionIMP)section;
        sOptionRow = (SGOptionRowIMP)optionRow;
        sSwitchRow = (SGSwitchRowIMP)switchRow;
        sChoiceRow = (SGChoiceRowIMP)choiceRow;
        sOriginalInit = (SGModPageInitIMP)method_getImplementation(method);
        if (!sOriginalInit) return;
        if ((IMP)sOriginalInit == (IMP)LyricsPageInit) {
            sInstalled = YES;
            return;
        }
        method_setImplementation(method, (IMP)LyricsPageInit);
        sInstalled = YES;
    };
    if (NSThread.isMainThread) install();
    else dispatch_async(dispatch_get_main_queue(), install);
}
