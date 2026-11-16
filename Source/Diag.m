#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>

// 诊断出口：写沙盒文件 + 以 UDP 发到本机监听端（127.0.0.1:18888）。
// UDP 无连接、非阻塞、失败即丢，绝不影响主线程与 App 行为。

static int SGLSock = -1;
static NSUInteger SGLSent = 0;

static void SGLEnsureSocket(void) {
    if (SGLSock >= 0) return;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    SGLSock = fd;
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

    // 网络：限速，最多每 200ms 发一条，超了直接丢
    static CFAbsoluteTime lastSent = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastSent < 0.2) return;
    lastSent = now;
    if (SGLSent > 50000) return;

    SGLEnsureSocket();
    if (SGLSock < 0) return;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(18888);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    NSData *payload = [row dataUsingEncoding:NSUTF8StringEncoding];
    if (sendto(SGLSock, payload.bytes, payload.length, 0,
               (struct sockaddr *)&addr, sizeof(addr)) > 0) {
        SGLSent++;
    }
}
