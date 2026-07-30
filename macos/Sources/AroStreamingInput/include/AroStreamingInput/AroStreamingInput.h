#import <Foundation/Foundation.h>
#import <SFBAudioEngine/SFBAudioDecoder.h>
#import <SFBAudioEngine/SFBInputSource.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AroStreamingDecoderKind) {
    AroStreamingDecoderKindFLAC,
    AroStreamingDecoderKindOggVorbis,
    AroStreamingDecoderKindCoreAudio,
} NS_SWIFT_NAME(StreamingDecoderKind);

typedef NSData * _Nullable (^AroStreamingReadBlock)(
    int64_t offset,
    NSUInteger length
);

/// A seekable SFBAudioEngine input whose bytes are supplied on demand.
///
/// SFBAudioEngine performs reads on its decoding worker. The block may
/// therefore wait for a remote byte range without blocking AppKit's main
/// thread.
NS_SWIFT_NAME(StreamingInputSource)
@interface AroStreamingInputSource : SFBInputSource

- (instancetype)initWithURL:(NSURL *)url
                      length:(int64_t)length
                   readBlock:(AroStreamingReadBlock)readBlock;

+ (nullable SFBAudioDecoder *)decoderForInputSource:(SFBInputSource *)inputSource
                                               kind:(AroStreamingDecoderKind)kind
                                              error:(NSError **)error
    NS_SWIFT_NAME(decoder(inputSource:kind:));

@end

NS_ASSUME_NONNULL_END
