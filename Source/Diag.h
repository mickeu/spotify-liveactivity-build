#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// 诊断出口：写 Documents/sgl.log，并尝试发往本机 127.0.0.1:18890。
FOUNDATION_EXPORT void SGLLogLine(NSString *line);
NS_ASSUME_NONNULL_END
