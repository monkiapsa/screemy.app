#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Wraps -[AVAssetWriterInput appendSampleBuffer:] in @try/@catch.
BOOL SCMSafeAppendSampleBuffer(AVAssetWriterInput *input,
                                CMSampleBufferRef buffer,
                                NSString * _Nullable * _Nullable outError);

/// Wraps -[AVAssetWriterInputPixelBufferAdaptor appendPixelBuffer:withPresentationTime:] in @try/@catch.
BOOL SCMSafeAppendPixelBuffer(AVAssetWriterInputPixelBufferAdaptor *adaptor,
                               CVPixelBufferRef pixelBuffer,
                               CMTime presentationTime,
                               NSString * _Nullable * _Nullable outError);

NS_ASSUME_NONNULL_END
