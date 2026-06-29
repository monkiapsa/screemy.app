#import "ExceptionBridge.h"

BOOL SCMSafeAppendSampleBuffer(AVAssetWriterInput *input,
                                CMSampleBufferRef buffer,
                                NSString * _Nullable * _Nullable outError) {
    @try {
        return [input appendSampleBuffer:buffer];
    } @catch (NSException *exception) {
        if (outError) {
            *outError = [NSString stringWithFormat:@"%@: %@",
                         exception.name, exception.reason ?: @"(nil)"];
        }
        return NO;
    }
}

BOOL SCMSafeAppendPixelBuffer(AVAssetWriterInputPixelBufferAdaptor *adaptor,
                               CVPixelBufferRef pixelBuffer,
                               CMTime presentationTime,
                               NSString * _Nullable * _Nullable outError) {
    @try {
        return [adaptor appendPixelBuffer:pixelBuffer withPresentationTime:presentationTime];
    } @catch (NSException *exception) {
        if (outError) {
            *outError = [NSString stringWithFormat:@"%@: %@",
                         exception.name, exception.reason ?: @"(nil)"];
        }
        return NO;
    }
}
