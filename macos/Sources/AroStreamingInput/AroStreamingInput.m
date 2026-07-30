#import <AroStreamingInput/AroStreamingInput.h>

// SFBAudioEngine's abstract base class implements this initializer but keeps
// it out of the public header. Redeclaring it locally is sufficient for a
// well-behaved subclass and avoids depending on any of its private ivars.
@interface SFBInputSource (AroSubclassing)
- (instancetype)initWithURL:(NSURL *)url;
@end

@interface AroStreamingInputSource () {
    int64_t _length;
    int64_t _offset;
    BOOL _open;
    AroStreamingReadBlock _readBlock;
    NSLock *_lock;
}
@end

@implementation AroStreamingInputSource

+ (nullable SFBAudioDecoder *)decoderForInputSource:(SFBInputSource *)inputSource
                                               kind:(AroStreamingDecoderKind)kind
                                              error:(NSError **)error {
    SFBAudioDecoderName name;
    switch (kind) {
        case AroStreamingDecoderKindFLAC:
            name = SFBAudioDecoderNameFLAC;
            break;
        case AroStreamingDecoderKindOggVorbis:
            name = SFBAudioDecoderNameOggVorbis;
            break;
        case AroStreamingDecoderKindCoreAudio:
            name = SFBAudioDecoderNameCoreAudio;
            break;
    }
    return [[SFBAudioDecoder alloc] initWithInputSource:inputSource
                                           decoderName:name
                                                 error:error];
}

- (instancetype)initWithURL:(NSURL *)url
                      length:(int64_t)length
                   readBlock:(AroStreamingReadBlock)readBlock {
    NSParameterAssert(url != nil);
    NSParameterAssert(length >= 0);
    NSParameterAssert(readBlock != nil);
    if ((self = [super initWithURL:url])) {
        _length = length;
        _readBlock = [readBlock copy];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (BOOL)openReturningError:(NSError **)error {
    [_lock lock];
    _open = YES;
    [_lock unlock];
    return YES;
}

- (BOOL)closeReturningError:(NSError **)error {
    [_lock lock];
    _open = NO;
    [_lock unlock];
    return YES;
}

- (BOOL)isOpen {
    [_lock lock];
    BOOL result = _open;
    [_lock unlock];
    return result;
}

- (BOOL)readBytes:(void *)buffer
           length:(NSInteger)length
        bytesRead:(NSInteger *)bytesRead
            error:(NSError **)error {
    NSParameterAssert(buffer != NULL);
    NSParameterAssert(length >= 0);
    NSParameterAssert(bytesRead != NULL);

    [_lock lock];
    int64_t offset = _offset;
    NSUInteger requested = (NSUInteger)MIN(
        (int64_t)length,
        MAX((int64_t)0, _length - offset)
    );
    [_lock unlock];

    if (requested == 0) {
        *bytesRead = 0;
        return YES;
    }

    NSData *data = _readBlock(offset, requested);
    if (data == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorCannotLoadFromNetwork
                                     userInfo:nil];
        }
        return NO;
    }

    NSUInteger count = MIN(requested, data.length);
    [data getBytes:buffer length:count];
    [_lock lock];
    _offset += (int64_t)count;
    [_lock unlock];
    *bytesRead = (NSInteger)count;
    return YES;
}

- (BOOL)atEOF {
    [_lock lock];
    BOOL result = _offset >= _length;
    [_lock unlock];
    return result;
}

- (BOOL)getOffset:(NSInteger *)offset error:(NSError **)error {
    NSParameterAssert(offset != NULL);
    [_lock lock];
    *offset = (NSInteger)_offset;
    [_lock unlock];
    return YES;
}

- (BOOL)getLength:(NSInteger *)length error:(NSError **)error {
    NSParameterAssert(length != NULL);
    *length = (NSInteger)_length;
    return YES;
}

- (BOOL)supportsSeeking {
    return YES;
}

- (BOOL)seekToOffset:(NSInteger)offset error:(NSError **)error {
    if (offset < 0 || (int64_t)offset > _length) {
        return NO;
    }
    [_lock lock];
    _offset = (int64_t)offset;
    [_lock unlock];
    return YES;
}

@end
