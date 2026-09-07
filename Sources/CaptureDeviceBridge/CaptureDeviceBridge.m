#import "CaptureDeviceBridge.h"

static BOOL TPFailure(NSError **error, NSInteger code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:@"app.teleprompter.camera.configuration"
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

@implementation TPCameraConfigurator
+ (BOOL)configureVideoOutput:(AVCaptureVideoDataOutput *)output
                     width:(NSInteger)width
                    height:(NSInteger)height
                     error:(NSError **)error {
    @try {
        if (width <= 0 || height <= 0) {
            return TPFailure(error, 5, @"The selected camera dimensions are invalid.");
        }
        NSNumber *pixelFormat = @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
        if (![output.availableVideoCVPixelFormatTypes containsObject:pixelFormat]) {
            pixelFormat = @(kCVPixelFormatType_32BGRA);
        }
        if (![output.availableVideoCVPixelFormatTypes containsObject:pixelFormat]) {
            return TPFailure(error, 6, @"The selected camera cannot deliver a supported SDR pixel format.");
        }
        // On macOS the data output can retain dimensions from its initial preset.
        // Configure after activeFormat and request the exact native dimensions.
        output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                                 (id)kCVPixelBufferWidthKey: @(width),
                                 (id)kCVPixelBufferHeightKey: @(height)};
        return YES;
    } @catch (NSException *exception) {
        return TPFailure(error, 7, [NSString stringWithFormat:
            @"The camera rejected the requested output size. Select another supported profile. %@", exception.reason ?: @""]);
    }
}

+ (BOOL)configureDevice:(AVCaptureDevice *)device
                 format:(AVCaptureDeviceFormat *)format
          frameDuration:(CMTime)duration
                  error:(NSError **)error {
    BOOL locked = NO;
    @try {
        if (![device lockForConfiguration:error]) { return NO; }
        locked = YES;
        if (!device.connected || ![device.formats containsObject:format]) {
            return TPFailure(error, 1, @"The camera or its formats changed. Refresh devices and select a profile again.");
        }
        if (device.videoFrameDurationLocked || device.followingExternalSyncDevice) {
            return TPFailure(error, 2, @"The camera's frame timing is controlled externally. Release that control before selecting a recording profile.");
        }
        BOOL supported = NO;
        if (CMTIME_IS_NUMERIC(duration) && duration.timescale > 0 && duration.value > 0 && duration.epoch == 0) {
            for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
                if (CMTimeCompare(duration, range.minFrameDuration) >= 0 &&
                    CMTimeCompare(duration, range.maxFrameDuration) <= 0) {
                    supported = YES;
                    break;
                }
            }
        }
        if (!supported) {
            return TPFailure(error, 3, @"The requested frame rate is outside this camera format's supported range. Select another profile.");
        }
        if (![device.activeFormat isEqual:format]) { device.activeFormat = format; }
        if (format.autoVideoFrameRateSupported) { device.autoVideoFrameRateEnabled = NO; }
        // Keep the intermediate min/max interval valid when moving to a slower rate.
        if (CMTIME_IS_NUMERIC(device.activeVideoMaxFrameDuration) &&
            CMTimeCompare(duration, device.activeVideoMaxFrameDuration) > 0) {
            device.activeVideoMaxFrameDuration = duration;
            device.activeVideoMinFrameDuration = duration;
        } else {
            device.activeVideoMinFrameDuration = duration;
            device.activeVideoMaxFrameDuration = duration;
        }
        return YES;
    } @catch (NSException *exception) {
        return TPFailure(error, 4, [NSString stringWithFormat:
            @"The camera rejected this profile. Refresh devices or select another profile. %@",
            exception.reason ?: @""]);
    } @finally {
        if (locked) { [device unlockForConfiguration]; }
    }
}
@end
