#import <Foundation/Foundation.h>
#import "Artwork.h"
#import "Settings.h"
#import "Diag.h"
FOUNDATION_EXPORT void SGLLogLine(NSString *line);
NS_ASSUME_NONNULL_BEGIN
// 使用 Clang 导入器确定 C ABI 和 ARC 返回值规则。
FOUNDATION_EXPORT id _Nullable SGLLiveIslandSafeValue(id _Nullable object, NSString *key);
NS_ASSUME_NONNULL_END
