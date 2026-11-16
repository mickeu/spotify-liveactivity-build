// Bootstrap.m
//
// Swift 没有 +load 语义，dylib 加载后需要一个 C 构造器把主循环拉起来。
// LoadControl 扫 Frameworks 的顺序不保证，所以初始化要能重复尝试：
// 原插件晚到时，设置页 hook 与歌词符号绑定都会在后一次尝试里接上。

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import "Settings.h"

id _Nullable SGLLiveIslandSafeValue(id _Nullable obj, NSString *key) {
    if (!obj || !key) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL sStarted;

static void SGLLiveIslandAttempt(void) {
    if (@available(iOS 16.2, *)) {
        Class cls = NSClassFromString(@"SGLLiveIsland");
        SEL sel = NSSelectorFromString(@"start");
        if (!sStarted && cls && [cls respondsToSelector:sel]) {
            ((void (*)(id, SEL))objc_msgSend)((id)cls, sel);
            sStarted = YES;
        }
    }
    // 幂等：已经装过就直接返回，插件没加载则下次再试。
    SGLInstallSettings();
}

__attribute__((constructor))
static void SGLLiveIslandBootstrap(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SGLLiveIslandAttempt();
        for (NSNumber *delay in @[@1.0, @3.0, @8.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                SGLLiveIslandAttempt();
            });
        }
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
            SGLLiveIslandAttempt();
        }];
    });
}