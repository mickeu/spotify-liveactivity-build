#import "Artwork.h"
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#import <stdint.h>
#import <string.h>

// Verified against skopevoj/spoti.pw v0.23.0-beta, commit
// 49e02e204f397b1e4197876dd622d4ee1663188e:
// Redesigned/Kit/SGRBridges.h:40 and SGRBridges.x:161-170.
// UIImage *SGRNowPlayingArtwork(NSString **trackURI, NSString **identity);
// Shared/Lyrics/Lyrics.h:109: NSString *SGKaraokePlayingTrack(void);
// Both are exported by the supplied Spotify 9.2.0 plugin. The artwork getter
// only reads cached fields; it does NOT call followPlayer() or start a fetch.
// It may return the OLD track's image: an exact URI match is mandatory.
// SGArtworkInInfo(info, artwork, key) is a dictionary writer, NOT a getter.
typedef UIImage *(*SGLArtworkGetter)(NSString * __autoreleasing *,
                                    NSString * __autoreleasing *);
typedef NSString *(*SGLTrackGetter)(void);

// Everything below except the pixel worker is confined to the main thread.
static SGLArtworkGetter sArtworkGetter;
static SGLTrackGetter sTrackGetter;
static NSString *sTrack;
static NSString *sHex;
static NSString *sPendingTrack; // one latest request; never holds an image
static uint64_t sGeneration;
static NSUInteger sAttempts;
static CFTimeInterval sNextAttempt;
static BOOL sBusy;
static dispatch_queue_t sWorker;
static const NSUInteger kMaxAttempts = 10;
static const size_t kSide = 32;

static NSString *SGLTrackID(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *text = value;
    if (text.length == 36 && [text hasPrefix:@"spotify:track:"])
        text = [text substringFromIndex:14];
    if (text.length != 22) return nil;
    for (NSUInteger i = 0; i < 22; i++) {
        unichar c = [text characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
              (c >= 'a' && c <= 'z'))) return nil;
    }
    return [text copy];
}

static BOOL SGLPlayerMatches(NSString *track) {
    if (!sTrackGetter) return NO;
    @try {
        return [SGLTrackID(sTrackGetter()) isEqualToString:track];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static void SGLReset(NSString *track) {
    ++sGeneration;
    sTrack = [track copy];
    sHex = nil;
    sPendingTrack = nil;
    sAttempts = 0;
    sNextAttempt = 0;
    // Do not clear sBusy: old work must finish before a new image is retained.
}

// No full-resolution raster, UIImage draw, CI rendering, PNG/JPEG re-encoding,
// or image cache. Draw the existing CGImage into exactly 4096 RGBA bytes.
// CoreGraphics may perform internal source decoding; this code does not promise
// zero allocations or bound the framework's private decoder working set.
static NSString *SGLSample(CGImageRef image) {
    uint8_t rgba[32 * 32 * 4] = {0};
    // 4 bits per channel: fixed 4096-bin histogram, about 64 KiB on worker stack.
    uint32_t count[4096] = {0}, red[4096] = {0};
    uint32_t green[4096] = {0}, blue[4096] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!space) return nil;
    CGContextRef context = CGBitmapContextCreate(rgba, kSide, kSide, 8,
        kSide * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    @try {
        CGContextSetInterpolationQuality(context, kCGInterpolationLow);
        CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
    } @finally {
        CGContextRelease(context);
    }
    for (size_t i = 0; i < kSide * kSide; i++) {
        const uint8_t *p = rgba + i * 4;
        if (p[3] < 192) continue; // reject transparent padding; undo premultiplication
        unsigned r = MIN(255u, (unsigned)p[0] * 255u / p[3]);
        unsigned g = MIN(255u, (unsigned)p[1] * 255u / p[3]);
        unsigned b = MIN(255u, (unsigned)p[2] * 255u / p[3]);
        double luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
        if (luma < 0.24 || luma > 0.94) continue;
        unsigned bin = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
        count[bin]++; red[bin] += r; green[bin] += g; blue[bin] += b;
    }
    double best = 0;
    unsigned winner = 0;
    for (unsigned i = 0; i < 4096; i++) {
        if (count[i] < 3) continue;
        double r = (double)red[i] / count[i], g = (double)green[i] / count[i];
        double b = (double)blue[i] / count[i];
        double hi = fmax(r, fmax(g, b)), lo = fmin(r, fmin(g, b));
        double saturation = hi > 0 ? (hi - lo) / hi : 0;
        double score = count[i] * (1.0 + 0.75 * saturation);
        if (score > best) { best = score; winner = i; }
    }
    if (best == 0) return nil; // no invented green/white for an unsuitable cover
    return [NSString stringWithFormat:@"%02X%02X%02X",
        (unsigned)(red[winner] / count[winner]),
        (unsigned)(green[winner] / count[winner]),
        (unsigned)(blue[winner] / count[winner])];
}

static void SGLTryStart(void);

static void SGLTryStart(void) {
    if (!sTrack || sHex) return;
    if (sBusy) { sPendingTrack = sTrack; return; }
    if (sAttempts >= kMaxAttempts || CACurrentMediaTime() < sNextAttempt) return;
    sAttempts++;
    // Poll-driven attempts only; no timer, delayed blocks, or permanent thread.
    sNextAttempt = CACurrentMediaTime() + MIN(4.0, (double)sAttempts);
    @try {
        // A missing image/library is retried within the SAME bounded budget.
        if (!sArtworkGetter)
            sArtworkGetter = (SGLArtworkGetter)dlsym(RTLD_DEFAULT, "SGRNowPlayingArtwork");
        if (!sTrackGetter)
            sTrackGetter = (SGLTrackGetter)dlsym(RTLD_DEFAULT, "SGKaraokePlayingTrack");
        if (!sArtworkGetter || !SGLPlayerMatches(sTrack)) return;
        NSString *uri = nil;
        // identity is not needed: passing NULL avoids the getter's formatting work.
        UIImage *image = sArtworkGetter(&uri, NULL);
        if (![image isKindOfClass:UIImage.class] ||
            ![image respondsToSelector:@selector(CGImage)] ||
            ![SGLTrackID(uri) isEqualToString:sTrack]) return;
        CGImageRef source = image.CGImage;
        // Reject pathological inputs without allocating a full-sized bitmap.
        if (!source || CGImageGetWidth(source) == 0 || CGImageGetHeight(source) == 0 ||
            CGImageGetWidth(source) > 4096 || CGImageGetHeight(source) > 4096 ||
            CGImageGetWidth(source) * CGImageGetHeight(source) > 4096u * 1024u) return;
        NSString *track = sTrack;
        uint64_t generation = sGeneration;
        if (!sWorker) {
            dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
            sWorker = dispatch_queue_create("sgliveisland.artwork", attr);
        }
        CGImageRef held = CGImageRetain(source);
        sBusy = YES;
        sPendingTrack = nil;
        dispatch_async(sWorker, ^{
            @autoreleasepool {
                NSString *hex = nil;
                @try { hex = SGLSample(held); }
                @catch (__unused NSException *exception) { hex = nil; }
                @finally { CGImageRelease(held); }
                // The sole retained image is released BEFORE main completion.
                dispatch_async(dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        sBusy = NO;
                        if (generation == sGeneration && [track isEqualToString:sTrack] &&
                            SGLPlayerMatches(track)) sHex = hex;
                        NSString *pending = sPendingTrack;
                        sPendingTrack = nil;
                        if ([pending isEqualToString:sTrack]) SGLTryStart();
                    }
                });
            }
        });
    } @catch (__unused NSException *exception) {
        // Known C getter/Objective-C methods can still raise; fail closed.
    }
}

NSString *SGLArtworkHex(NSString *trackID) {
    if (!NSThread.isMainThread) return nil; // no dispatch_sync/deadlock/queue growth
    @autoreleasepool {
        @try {
            NSString *track = SGLTrackID(trackID);
            if (![track isEqualToString:sTrack]) SGLReset(track);
            if (!track) return nil;
            // Never return a cached color for a now-different real playing track.
            if (sHex && !SGLPlayerMatches(track)) { sHex = nil; return nil; }
            SGLTryStart();
            return sHex;
        } @catch (__unused NSException *exception) {
            SGLReset(nil);
            return nil;
        }
    }
}
