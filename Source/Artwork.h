#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Nonblocking polling API. Call on the main thread with a base62 Spotify track ID
// (22 ASCII characters) or spotify:track:<ID>. nil/empty/invalid clears our cache.
// Off-main calls return nil without scheduling or touching main-thread state.
// Returns six uppercase RGB hex digits, without '#', only from matching artwork.
// nil means absent, pending, unsuitable, or this track's retry budget exhausted.
// No synthetic fallback color. The caller must keep its own non-artwork fallback
// separate and poll again; this module sends no notifications and makes no requests.
FOUNDATION_EXPORT __attribute__((visibility("default")))
NSString * _Nullable SGLArtworkHex(NSString * _Nullable trackID);
NS_ASSUME_NONNULL_END
