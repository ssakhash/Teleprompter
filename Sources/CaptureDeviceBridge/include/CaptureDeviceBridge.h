#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Keeps AVFoundation's Objective-C exceptions inside Objective-C frames. Device
/// configuration failures cross into Swift as NSError, with the lock always released.
@interface TPCameraConfigurator : NSObject
+ (BOOL)configureDevice:(AVCaptureDevice *)device
                 format:(AVCaptureDeviceFormat *)format
          frameDuration:(CMTime)duration
                  error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)configureVideoOutput:(AVCaptureVideoDataOutput *)output
                     width:(NSInteger)width
                    height:(NSInteger)height
                     error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
