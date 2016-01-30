//
//  PBJMediaWriter.m
//  Vision
//
//  Created by Patrick Piemonte on 1/27/14.
//  Copyright (c) 2013-present, Patrick Piemonte, http://patrickpiemonte.com
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of
//  this software and associated documentation files (the "Software"), to deal in
//  the Software without restriction, including without limitation the rights to
//  use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
//  the Software, and to permit persons to whom the Software is furnished to do so,
//  subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
//  FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
//  COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
//  IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
//  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#import "PBJMediaWriter.h"
#import "PBJVisionUtilities.h"
#import "PBJVision.h"

#import <UIKit/UIDevice.h>
#import <MobileCoreServices/UTCoreTypes.h>

#define LOG_WRITER 1
#if !defined(NDEBUG) && LOG_WRITER
#   define DLog(fmt, ...) NSLog((@"writer: " fmt), ##__VA_ARGS__);
#else
#   define DLog(...)
#endif

@interface PBJMediaWriter ()
{
    AVAssetWriter *_assetWriter;
	AVAssetWriterInput *_assetWriterAudioInput;
    AVAssetWriterInput *_assetWriterVideoInput;
    AVAssetWriterInputPixelBufferAdaptor *_videoPixelBufferAdaptor;

    NSURL *_outputURL;

    CMTime _audioTimestamp;
    CMTime _videoTimestamp;
    CMTime _nextVideoFrameTimeStamp;
    CMTime _nextAudioFrameTimeStamp;
    
    CMTime _nextVideoPTS;
    CMTime _nextAudioPTS;
    CMTime _timeOffset;
    CMTime _startTime;
}

@end

@implementation PBJMediaWriter

@synthesize delegate = _delegate;
@synthesize outputURL = _outputURL;
@synthesize audioTimestamp = _audioTimestamp;
@synthesize videoTimestamp = _videoTimestamp;

#pragma mark - getters/setters

- (BOOL)isAudioReady
{
    AVAuthorizationStatus audioAuthorizationStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];

    BOOL isAudioNotAuthorized = (audioAuthorizationStatus == AVAuthorizationStatusNotDetermined || audioAuthorizationStatus == AVAuthorizationStatusDenied);
    BOOL isAudioSetup = (_assetWriterAudioInput != nil) || isAudioNotAuthorized;

    return isAudioSetup;
}

- (BOOL)isVideoReady
{
    AVAuthorizationStatus videoAuthorizationStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

    BOOL isVideoNotAuthorized = (videoAuthorizationStatus == AVAuthorizationStatusNotDetermined || videoAuthorizationStatus == AVAuthorizationStatusDenied);
    BOOL isVideoSetup = (_assetWriterVideoInput != nil) || isVideoNotAuthorized;

    return isVideoSetup;
}

- (NSError *)error
{
    return _assetWriter.error;
}

#pragma mark - init

- (id)initWithOutputURL:(NSURL *)outputURL
{
    self = [super init];
    if (self) {
        NSError *error = nil;
        _assetWriter = [AVAssetWriter assetWriterWithURL:outputURL fileType:(NSString *)kUTTypeMPEG4 error:&error];
        if (error) {
            DLog(@"error setting up the asset writer (%@)", error);
            _assetWriter = nil;
            return nil;
        }

        _outputURL = outputURL;
        _timeScale = 1;
        _timeOffset = kCMTimeZero;

        _assetWriter.shouldOptimizeForNetworkUse = YES;
        _assetWriter.metadata = [self _metadataArray];

        _audioTimestamp = kCMTimeInvalid;
        _videoTimestamp = kCMTimeInvalid;
        _videoFrameDuration = kCMTimeInvalid;
        _nextVideoFrameTimeStamp = kCMTimeZero;
        _nextAudioFrameTimeStamp = kCMTimeZero;
        _nextVideoPTS = kCMTimeZero;
        _nextAudioPTS = kCMTimeZero;

        // ensure authorization is permitted, if not already prompted
        // it's possible to capture video without audio or audio without video
        if ([[AVCaptureDevice class] respondsToSelector:@selector(authorizationStatusForMediaType:)]) {

            AVAuthorizationStatus audioAuthorizationStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];

            if (audioAuthorizationStatus == AVAuthorizationStatusNotDetermined || audioAuthorizationStatus == AVAuthorizationStatusDenied) {
                if (audioAuthorizationStatus == AVAuthorizationStatusDenied && [_delegate respondsToSelector:@selector(mediaWriterDidObserveAudioAuthorizationStatusDenied:)]) {
                    [_delegate mediaWriterDidObserveAudioAuthorizationStatusDenied:self];
                }
            }

            AVAuthorizationStatus videoAuthorizationStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

            if (videoAuthorizationStatus == AVAuthorizationStatusNotDetermined || videoAuthorizationStatus == AVAuthorizationStatusDenied) {
                if (videoAuthorizationStatus == AVAuthorizationStatusDenied && [_delegate respondsToSelector:@selector(mediaWriterDidObserveVideoAuthorizationStatusDenied:)]) {
                    [_delegate mediaWriterDidObserveVideoAuthorizationStatusDenied:self];
                }
            }

        }

        DLog(@"prepared to write to (%@)", outputURL);
    }
    return self;
}

#pragma mark - private

- (NSArray *)_metadataArray
{
    UIDevice *currentDevice = [UIDevice currentDevice];

    // device model
    AVMutableMetadataItem *modelItem = [[AVMutableMetadataItem alloc] init];
    [modelItem setKeySpace:AVMetadataKeySpaceCommon];
    [modelItem setKey:AVMetadataCommonKeyModel];
    [modelItem setValue:[currentDevice localizedModel]];

    // software
    AVMutableMetadataItem *softwareItem = [[AVMutableMetadataItem alloc] init];
    [softwareItem setKeySpace:AVMetadataKeySpaceCommon];
    [softwareItem setKey:AVMetadataCommonKeySoftware];
    [softwareItem setValue:@"PBJVision"];

    // creation date
    AVMutableMetadataItem *creationDateItem = [[AVMutableMetadataItem alloc] init];
    [creationDateItem setKeySpace:AVMetadataKeySpaceCommon];
    [creationDateItem setKey:AVMetadataCommonKeyCreationDate];
    [creationDateItem setValue:[NSString PBJformattedTimestampStringFromDate:[NSDate date]]];

    return @[modelItem, softwareItem, creationDateItem];
}

#pragma mark - setup

- (BOOL)setupAudioWithSettings:(NSDictionary *)audioSettings
{
	if (!_assetWriterAudioInput && [_assetWriter canApplyOutputSettings:audioSettings forMediaType:AVMediaTypeAudio]) {

		_assetWriterAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
		_assetWriterAudioInput.expectsMediaDataInRealTime = YES;

		if (_assetWriterAudioInput && [_assetWriter canAddInput:_assetWriterAudioInput]) {
			[_assetWriter addInput:_assetWriterAudioInput];

            DLog(@"setup audio input with settings sampleRate (%f) channels (%lu) bitRate (%ld)",
                [[audioSettings objectForKey:AVSampleRateKey] floatValue],
                (unsigned long)[[audioSettings objectForKey:AVNumberOfChannelsKey] unsignedIntegerValue],
                (long)[[audioSettings objectForKey:AVEncoderBitRateKey] integerValue]);

        } else {
			DLog(@"couldn't add asset writer audio input");
		}

	} else {

        _assetWriterAudioInput = nil;
		DLog(@"couldn't apply audio output settings");

    }

    return self.isAudioReady;
}

- (BOOL)setupVideoWithSettings:(NSDictionary *)videoSettings withAdditional:(NSDictionary *)additional {
	if (!_assetWriterVideoInput && [_assetWriter canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo]) {

		_assetWriterVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
		_assetWriterVideoInput.expectsMediaDataInRealTime = YES;
		_assetWriterVideoInput.transform = CGAffineTransformIdentity;

        if (additional != nil) {
            NSNumber *angle = additional[PBJVisionVideoRotation];
            if (angle) {
                _assetWriterVideoInput.transform = CGAffineTransformMakeRotation([angle floatValue]);
            }
        }
        
        if (_timeScale != 1) {
            CGFloat width = [videoSettings[AVVideoWidthKey] floatValue];
            CGFloat height = [videoSettings[AVVideoHeightKey] floatValue];
            NSDictionary *pixelBufferAttributes = @{
                                                    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8PlanarFullRange),//[NSNumber numberWithInt:kCVPixelFormatType_32BGRA],
                                                    (id)kCVPixelBufferWidthKey : @(width),
                                                    (id)kCVPixelBufferHeightKey : @(height)
                                                    };
            
            _videoPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_assetWriterVideoInput sourcePixelBufferAttributes:pixelBufferAttributes];
        }

		if (_assetWriterVideoInput && [_assetWriter canAddInput:_assetWriterVideoInput]) {
			[_assetWriter addInput:_assetWriterVideoInput];

#if !defined(NDEBUG) && LOG_WRITER
            NSDictionary *videoCompressionProperties = videoSettings[AVVideoCompressionPropertiesKey];
            if (videoCompressionProperties) {
                DLog(@"setup video with compression settings bps (%f) frameInterval (%ld)",
                        [videoCompressionProperties[AVVideoAverageBitRateKey] floatValue],
                        (long)[videoCompressionProperties[AVVideoMaxKeyFrameIntervalKey] integerValue]);
            } else {
                DLog(@"setup video");
            }
#endif

		} else {
			DLog(@"couldn't add asset writer video input");
		}

	} else {

        _assetWriterVideoInput = nil;
		DLog(@"couldn't apply video output settings");

	}

    return self.isVideoReady;
}

#pragma mark - sample buffer writing

- (BOOL)_isReadyToHaveSampleBuffer:(CMSampleBufferRef)sampleBuffer withMediaTypeVideo:(BOOL)video
{
    
    if (_timeScale == 1.0)
        return true;
    
    BOOL result = NO;
    
    CMTime currentFrameTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTimeScale deviceFrameRate = _videoFrameDuration.timescale;
    
    
    if (video) {
        if (CMTimeCompare(currentFrameTimeStamp, _nextVideoFrameTimeStamp) >= 0) {
            DLog(@"Capture %f, %f, %f > %f", (float)deviceFrameRate, (float)_timeScale * 30, CMTimeGetSeconds(currentFrameTimeStamp), CMTimeGetSeconds(_nextVideoFrameTimeStamp));
            
            CMTime recordableFrameDuration = CMTimeMake(1 / _timeScale, deviceFrameRate);
            _nextVideoFrameTimeStamp = (CMTimeGetSeconds(_nextVideoFrameTimeStamp) > 0.0f)? _nextVideoFrameTimeStamp : currentFrameTimeStamp;
            _nextVideoFrameTimeStamp = CMTimeAdd(_nextVideoFrameTimeStamp, recordableFrameDuration);
            result = YES;
            
            DLog(@"Skip %f < %f", CMTimeGetSeconds(currentFrameTimeStamp), CMTimeGetSeconds(_nextVideoFrameTimeStamp));
        }
    } else {
        if (CMTimeCompare(currentFrameTimeStamp, _nextAudioFrameTimeStamp) >= 0) {
            
            CMTime recordableFrameDuration = CMTimeMake(1 / _timeScale, deviceFrameRate);
            _nextAudioFrameTimeStamp = (CMTimeGetSeconds(_nextAudioFrameTimeStamp) > 0.0f)? _nextAudioFrameTimeStamp : currentFrameTimeStamp;
            _nextAudioFrameTimeStamp = CMTimeAdd(_nextAudioFrameTimeStamp, recordableFrameDuration);
            result = YES;
            
//            NSLog(@"Skip %f < %f", CMTimeGetSeconds(currentFrameTimeStamp), CMTimeGetSeconds(_nextAudioFrameTimeStamp));
        }
    }
    
    
    
    return result;
}

- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer withMediaTypeVideo:(BOOL)video
{
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }

    // setup the writer
	if ( _assetWriter.status == AVAssetWriterStatusUnknown ) {

        if ([_assetWriter startWriting]) {
            CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            _startTime = timestamp;
            _nextVideoPTS = timestamp;
            _nextAudioPTS = timestamp;
			[_assetWriter startSessionAtSourceTime:timestamp];
            DLog(@"started writing with status (%ld)", (long)_assetWriter.status);
		} else {
			DLog(@"error when starting to write (%@)", [_assetWriter error]);
            return;
		}

	}

    // check for completion state
    if ( _assetWriter.status == AVAssetWriterStatusFailed ) {
        DLog(@"writer failure, (%@)", _assetWriter.error.localizedDescription);
        return;
    }

    if (_assetWriter.status == AVAssetWriterStatusCancelled) {
        DLog(@"writer cancelled");
        return;
    }

    if ( _assetWriter.status == AVAssetWriterStatusCompleted) {
        DLog(@"writer finished and completed");
        return;
    }

    // perform write
	if ( _assetWriter.status == AVAssetWriterStatusWriting ) {
        
        if (![self _isReadyToHaveSampleBuffer:sampleBuffer withMediaTypeVideo:video])
            return;

        CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
        if (duration.value > 0) {
            timestamp = CMTimeAdd(timestamp, duration);
        }
        
        if (_timeScale == 1) {
            if (video) {
                if (_assetWriterVideoInput.readyForMoreMediaData) {
                    if ([_assetWriterVideoInput appendSampleBuffer:sampleBuffer]) {
                        _videoTimestamp = timestamp;
                    } else {
                        DLog(@"writer error appending video (%@)", _assetWriter.error);
                    }
                }
            } else {
                if (_assetWriterAudioInput.readyForMoreMediaData) {
                    if ([_assetWriterAudioInput appendSampleBuffer:sampleBuffer]) {
                        _audioTimestamp = timestamp;
                    } else {
                        DLog(@"writer error appending audio (%@)", _assetWriter.error);
                    }
                }
            }
        } else {
            if (video) {
                CMTime frameDuration = CMTimeMake(1, 30);
                CMSampleTimingInfo timingInfo = kCMTimingInfoInvalid;
                timingInfo.duration = frameDuration;
                timingInfo.presentationTimeStamp = _nextVideoPTS;
                CMSampleBufferRef sbufWithNewTiming = NULL;
                
                OSStatus err = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault,
                                                                     sampleBuffer,
                                                                     1, // numSampleTimingEntries
                                                                     &timingInfo,
                                                                     &sbufWithNewTiming);
                
                if (err) {
                    DLog(@"CMSampleBufferCreateCopyWithNewTiming error");
                    return;
                }
                
                if (_assetWriterVideoInput.readyForMoreMediaData) {
                    if ([_assetWriterVideoInput appendSampleBuffer:sbufWithNewTiming]) {
                        _nextVideoPTS = CMTimeAdd(frameDuration, _nextVideoPTS);
                    } else {
                        DLog(@"writer error appending video (%@)", _assetWriter.error);
                    }
                }
                CFRelease(sbufWithNewTiming);
            } else {
                CMTime frameDuration = CMTimeMake(1, 30);
                CMSampleTimingInfo timingInfo = kCMTimingInfoInvalid;
                timingInfo.duration = frameDuration;
                timingInfo.presentationTimeStamp = _nextAudioPTS;
                CMSampleBufferRef sbufWithNewTiming = NULL;
                
                OSStatus err = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault,
                                                                     sampleBuffer,
                                                                     1, // numSampleTimingEntries
                                                                     &timingInfo,
                                                                     &sbufWithNewTiming);
                
                if (err) {
                    DLog(@"CMSampleBufferCreateCopyWithNewTiming error");
                    return;
                }
                
                if (_assetWriterAudioInput.readyForMoreMediaData) {
                    if ([_assetWriterAudioInput appendSampleBuffer:sbufWithNewTiming]) {
                        _nextAudioPTS = CMTimeAdd(frameDuration, _nextAudioPTS);
                        _audioTimestamp = timestamp;
                    } else {
                        DLog(@"writer error appending video (%@)", _assetWriter.error);
                    }
                }
                CFRelease(sbufWithNewTiming);
            }
        }

		

	}
}

- (void)finishWritingWithCompletionHandler:(void (^)(void))handler
{
    if (_assetWriter.status == AVAssetWriterStatusUnknown ||
        _assetWriter.status == AVAssetWriterStatusCompleted) {
        DLog(@"asset writer was in an unexpected state (%@)", @(_assetWriter.status));
        return;
    }
    [_assetWriterVideoInput markAsFinished];
    [_assetWriterAudioInput markAsFinished];
    [_assetWriter finishWritingWithCompletionHandler:handler];
}


@end
