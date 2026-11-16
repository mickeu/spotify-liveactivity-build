// Bootstrap.m
//
// Swift 没有 +load 语义，dylib 加载后需要一个 C 构造器把主循环拉起来。
// 不 import 任何头文件，避免依赖 Swift 生成的头与模块名。

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void SGLLiveIslandBootstrap(void) {
    Class cls = NSClassFromString(@"SGLLiveIsland");
    if (!cls) return;
    SEL sel = NSSelectorFromString(@"start");
    if (![cls respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)((id)cls, sel);
}
