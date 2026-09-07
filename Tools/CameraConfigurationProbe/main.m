#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import "CaptureDeviceBridge.h"

// Exercises device setters without AVCaptureSession, device inputs, or media outputs.
// Skips cameras in use elsewhere and restores each device's original configuration.
int main(void) {
    @autoreleasepool {
        AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeContinuityCamera]
            mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
        NSUInteger total = 0;
        BOOL failed = NO;
        for (AVCaptureDevice *device in discovery.devices) {
            if (device.inUseByAnotherApplication) {
                printf("SKIP %s: camera is in use by another application.\n", device.localizedName.UTF8String);
                continue;
            }
            AVCaptureDeviceFormat *originalFormat = device.activeFormat;
            CMTime originalMin = device.activeVideoMinFrameDuration;
            CMTime originalMax = device.activeVideoMaxFrameDuration;
            BOOL originalAuto = device.autoVideoFrameRateEnabled;
            BOOL changed = NO;
            @try {
                NSUInteger checked = 0;
                for (AVCaptureDeviceFormat *format in device.formats) {
                    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
                        NSError *error = nil;
                        changed = YES;
                        if (![TPCameraConfigurator configureDevice:device format:format frameDuration:range.minFrameDuration error:&error]) {
                            printf("FAIL %s: %s\n", device.localizedName.UTF8String, error.localizedDescription.UTF8String);
                            failed = YES;
                            break;
                        }
                        if (CMTimeCompare(device.activeVideoMinFrameDuration, range.minFrameDuration) != 0 ||
                            CMTimeCompare(device.activeVideoMaxFrameDuration, range.minFrameDuration) != 0) {
                            printf("FAIL %s: selected timing did not match reported timing.\n", device.localizedName.UTF8String);
                            failed = YES;
                            break;
                        }
                        // Exercise movement to a slower supported rate, then back to maximum.
                        if (CMTimeCompare(range.minFrameDuration, range.maxFrameDuration) < 0) {
                            if (![TPCameraConfigurator configureDevice:device format:format frameDuration:range.maxFrameDuration error:&error] ||
                                ![TPCameraConfigurator configureDevice:device format:format frameDuration:range.minFrameDuration error:&error]) {
                                printf("FAIL %s: could not switch slow/fast rates: %s\n", device.localizedName.UTF8String, error.localizedDescription.UTF8String);
                                failed = YES;
                                break;
                            }
                        }
                        // Invalid timings must return NSError without calling the dangerous setter.
                        error = nil;
                        if ([TPCameraConfigurator configureDevice:device format:format frameDuration:kCMTimeZero error:&error] || error == nil) {
                            printf("FAIL %s: invalid timing was not rejected safely.\n", device.localizedName.UTF8String);
                            failed = YES;
                            break;
                        }
                        ++checked;
                    }
                    if (failed) { break; }
                }
                if (!failed) {
                    printf("PASS %s: %lu native format/range configurations, slow/fast switching, and safe invalid-input rejection.\n",
                           device.localizedName.UTF8String, (unsigned long)checked);
                    total += checked;
                }
            } @catch (NSException *exception) {
                printf("FAIL unexpected native exception: %s\n", exception.reason.UTF8String);
                failed = YES;
            } @finally {
                if (changed) {
                    BOOL locked = NO;
                    @try {
                        NSError *error = nil;
                        if (![device lockForConfiguration:&error]) {
                            printf("FAIL could not restore %s: %s\n", device.localizedName.UTF8String, error.localizedDescription.UTF8String);
                            failed = YES;
                        } else {
                            locked = YES;
                            device.activeFormat = originalFormat;
                            if (originalFormat.autoVideoFrameRateSupported) { device.autoVideoFrameRateEnabled = NO; }
                            if (CMTimeCompare(originalMin, device.activeVideoMaxFrameDuration) > 0) {
                                device.activeVideoMaxFrameDuration = originalMax;
                                device.activeVideoMinFrameDuration = originalMin;
                            } else {
                                device.activeVideoMinFrameDuration = originalMin;
                                device.activeVideoMaxFrameDuration = originalMax;
                            }
                            if (originalFormat.autoVideoFrameRateSupported) { device.autoVideoFrameRateEnabled = originalAuto; }
                            printf("RESTORED %s original camera settings.\n", device.localizedName.UTF8String);
                        }
                    } @catch (NSException *exception) {
                        printf("FAIL could not restore camera settings: %s\n", exception.reason.UTF8String);
                        failed = YES;
                    } @finally {
                        if (locked) { [device unlockForConfiguration]; }
                    }
                }
            }
        }
        if (failed) { return 1; }
        if (total == 0) { printf("No available cameras were tested.\n"); return 2; }
        printf("PASS %lu configuration checks. No capture session was started.\n", (unsigned long)total);
        return 0;
    }
}
