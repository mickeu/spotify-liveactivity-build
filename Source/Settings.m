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
static NSString *const kTranslation = @"sgl.showTranslation";
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

static BOOL HasLockScreenLyricsRow(NSArray *sections);


/// 直接展示沙盒里的诊断日志，避免依赖外部工具才能取日志。
@interface SGLLogViewController : UIViewController
@end

@implementation SGLLogViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"诊断日志";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *text = [[UITextView alloc] initWithFrame:self.view.bounds];
    text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    text.editable = NO;
    text.alwaysBounceVertical = YES;
    text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    text.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sgl.log"];
    NSString *body = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    text.text = body.length ? body : @"（还没有日志：插件可能没加载，或还没到写日志的时机）";
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"复制"
        style:UIBarButtonItemStylePlain target:self action:@selector(sg_copy)];
    self.navigationItem.rightBarButtonItem = copy;
    [self.view addSubview:text];
}
- (void)sg_copy {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sgl.log"];
    NSString *body = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    UIPasteboard.generalPasteboard.string = body;
}
@end

static void SGLLog(NSString *line) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sgl.log"];
    });
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n",
                       [NSDate date].description, line];
    NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if (attrs.fileSize > 64 * 1024) [fm removeItemAtPath:path error:NULL];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *e) {}
    [handle closeFile];
}

// 页面标题在中文环境下会被本地化成「歌词」，所以只认 key，
// 标题只作为 sections 为空时的备用信号。
static BOOL LooksLikeLyricsPage(NSString *title, NSArray *sections) {
    if (HasLockScreenLyricsRow(sections)) return YES;
    if (title.length == 0) return NO;
    return [title isEqualToString:@"Lyrics"] || [title isEqualToString:@"歌词"];
}

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
    NSArray *widthNames = @[@"标准", @"最长"];
    NSArray *fontNames = @[@"小", @"标准", @"大"];
    NSArray *hideNames = @[@"不关闭", @"5 秒", @"30 秒", @"1 分钟", @"5 分钟"];
    id width = sChoiceRow(@"宽度", nil, kWidth, widthNames, 0);
    id font = sChoiceRow(@"字号", nil, kFontSize, fontNames, 1);
    // SGChoiceRow stores the chosen INDEX (0...4); the Swift side maps it to 0/5/30/60/300 seconds.
    id autoHide = sChoiceRow(@"自动关闭", nil, kAutoHide, hideNames, 0);
    id active = OptionRow(@"灵动岛歌词", kEnabled);       // false when unset
    id color = SwitchRow(@"歌词使用封面颜色", kArtworkColor);     // true when unset
    id pause = SwitchRow(@"暂停时隐藏", kHideOnPause);       // true when unset
    id translation = SwitchRow(@"显示翻译", kTranslation);   // true when unset
    id hidden = OptionRow(@"隐藏灵动岛", kHidden);           // false when unset
    id first = sSection(nil, @[active, width, font]);
    id display = sSection(@"显示", @[color, translation, pause, autoHide]);
    id logRow = [[NSClassFromString(@"SGModRow") alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(logRow, NSSelectorFromString(@"setTitle:"), @"查看日志");
    void (^logPage)(void) = ^UIViewController *{ return [[SGLLogViewController alloc] init]; };
    ((void (*)(id, SEL, id))objc_msgSend)(logRow, NSSelectorFromString(@"setPage:"), logPage);
    id diag = sSection(@"诊断", @[logRow]);
    id visibility = sSection(nil, @[hidden]);
    Class pageClass = NSClassFromString(@"SGModPage");
    SEL init = @selector(initWithTitle:intro:sections:footer:);
    return ((id (*)(id, SEL, NSString *, NSString *, NSArray *, NSString *))objc_msgSend)(
        [pageClass alloc], init, @"灵动岛歌词", nil, @[first, display, visibility], nil);
}

static id LyricsPageInit(id self, SEL _cmd, NSString *title, NSString *intro, NSArray *sections, NSString *footer) {
    // Key is the durable identity; title rejects unrelated SGModPage instances containing a copied row.
    if (!LooksLikeLyricsPage(title, sections))
        return sOriginalInit(self, _cmd, title, intro, sections, footer);
    SGLLog([NSString stringWithFormat:@"attach to page '%@' (%lu sections)",
            title, (unsigned long)sections.count]);
    NSMutableArray *extended = [sections mutableCopy];
    id entry = sPageRow(@"灵动岛歌词", ^UIViewController *{ return SettingsPage(); });
    [extended addObject:sSection(nil, @[entry])];
    return sOriginalInit(self, _cmd, title, intro, extended, footer);
}

void SGLInstallSettings(void) {
    void (^install)(void) = ^{
        if (sInstalled) return;
        Class pageClass = NSClassFromString(@"SGModPage");
        if (!pageClass) { SGLLog(@"SGModPage not found yet"); return; }
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
        SGLLog(@"hook installed on SGModPage");
    };
    if (NSThread.isMainThread) install();
    else dispatch_async(dispatch_get_main_queue(), install);
}
