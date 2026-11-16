#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>

// 诊断出口：写沙盒文件 + 通过 TCP 发到本机 iSH 监听端（127.0.0.1:18890）。
// 连接、发送、关闭都在后台串行队列；主线程只做一次入队，绝不阻塞 UI。
// 发送失败（监听端没开）就静默丢弃，不影响 App 行为。

static dispatch_queue_t SGLDiagQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("sgl.diag", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static BOOL SGLDiagBusy = NO;

static void SGLDiagSend(NSData *payload) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(18890);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        const char *bytes = payload.bytes;
        size_t left = payload.length;
        while (left > 0) {
            ssize_t n = send(fd, bytes, left, 0);
            if (n <= 0) break;
            bytes += n;
            left -= (size_t)n;
        }
    }
    close(fd);
}

void SGLLogLine(NSString *line) {
    if (line.length == 0) return;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sgl.log"];
    NSString *row = [line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"];

    // 文件：超 128KB 轮转一次，避免无限增长
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if ([attrs[NSFileSize] unsignedLongLongValue] > 128 * 1024) {
        [fm removeItemAtPath:path error:NULL];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:[row dataUsingEncoding:NSUTF8StringEncoding]]; }
        @finally { [fh closeFile]; }
    } else {
        [[row dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO];
    }

    // 网络：同一时刻只允许一个在途发送，忙则丢弃（日志不值得拖慢任何东西）
    if (SGLDiagBusy) return;
    SGLDiagBusy = YES;
    NSData *payload = [row dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(SGLDiagQueue(), ^{
        SGLDiagSend(payload);
        SGLDiagBusy = NO;
    });
}