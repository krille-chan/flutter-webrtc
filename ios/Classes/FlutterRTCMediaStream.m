#import <objc/runtime.h>

#import <WebRTC/RTCAVFoundationVideoSource.h>
#import <WebRTC/RTCAudioTrack.h>
#import <WebRTC/RTCVideoTrack.h>
#import <WebRTC/RTCMediaConstraints.h>
#import <WebRTC/RTCMediaStream.h>
#import <WebRTC/RTCMediaStreamTrack.h>
#import <WebRTC/RTCPeerConnectionFactory.h>

#import "FlutterRTCMediaStream.h"
#import "FlutterRTCPeerConnection.h"

@implementation AVCaptureDevice (Flutter)

- (NSString*)positionString {
  switch (self.position) {
    case AVCaptureDevicePositionUnspecified: return @"unspecified";
    case AVCaptureDevicePositionBack: return @"back";
    case AVCaptureDevicePositionFront: return @"front";
  }
  return nil;
}

@end

@implementation  FlutterWebRTCPlugin (RTCMediaStream)

/**
 * {@link https://www.w3.org/TR/mediacapture-streams/#navigatorusermediaerrorcallback}
 */
typedef void (^NavigatorUserMediaErrorCallback)(NSString *errorType, NSString *errorMessage);

/**
 * {@link https://www.w3.org/TR/mediacapture-streams/#navigatorusermediasuccesscallback}
 */
typedef void (^NavigatorUserMediaSuccessCallback)(RTCMediaStream *mediaStream);

- (RTCMediaConstraints *)defaultMediaStreamConstraints {
    NSDictionary *mandatoryConstraints
    = @{ kRTCMediaConstraintsMinWidth     : @"1280",
         kRTCMediaConstraintsMinHeight    : @"720",
         kRTCMediaConstraintsMinFrameRate : @"30" };
    RTCMediaConstraints* constraints =
    [[RTCMediaConstraints alloc]
     initWithMandatoryConstraints:mandatoryConstraints
     optionalConstraints:nil];
    return constraints;
}

/**
 * Initializes a new {@link RTCAudioTrack} which satisfies specific constraints,
 * adds it to a specific {@link RTCMediaStream}, and reports success to a
 * specific callback. Implements the audio-specific counterpart of the
 * {@code getUserMedia()} algorithm.
 *
 * @param constraints The {@code MediaStreamConstraints} which the new
 * {@code RTCAudioTrack} instance is to satisfy.
 * @param successCallback The {@link NavigatorUserMediaSuccessCallback} to which
 * success is to be reported.
 * @param errorCallback The {@link NavigatorUserMediaErrorCallback} to which
 * failure is to be reported.
 * @param mediaStream The {@link RTCMediaStream} which is being initialized as
 * part of the execution of the {@code getUserMedia()} algorithm, to which a
 * new {@code RTCAudioTrack} is to be added, and which is to be reported to
 * {@code successCallback} upon success.
 */
- (void)getUserAudio:(NSDictionary *)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream *)mediaStream {
    NSString *trackId = [[NSUUID UUID] UUIDString];
    RTCAudioTrack *audioTrack
    = [self.peerConnectionFactory audioTrackWithTrackId:trackId];
    
    [mediaStream addAudioTrack:audioTrack];
    
    successCallback(mediaStream);
}

// TODO: Use RCTConvert for constraints ...
-(void)getUserMedia:(NSDictionary *)constraints
             result:(FlutterResult) result  {
    // Initialize RTCMediaStream with a unique label in order to allow multiple
    // RTCMediaStream instances initialized by multiple getUserMedia calls to be
    // added to 1 RTCPeerConnection instance. As suggested by
    // https://www.w3.org/TR/mediacapture-streams/#mediastream to be a good
    // practice, use a UUID (conforming to RFC4122).
    NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
    RTCMediaStream *mediaStream
    = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
    
    [self
     getUserMedia:constraints
     successCallback:^ (RTCMediaStream *mediaStream) {
         NSString *mediaStreamId = mediaStream.streamId;
         NSMutableArray *tracks = [NSMutableArray array];
         
         for (NSString *propertyName in @[ @"audioTracks", @"videoTracks" ]) {
             SEL sel = NSSelectorFromString(propertyName);
             for (RTCMediaStreamTrack *track in [mediaStream performSelector:sel]) {
                 NSString *trackId = track.trackId;
                 
                 self.localTracks[trackId] = track;
                 [tracks addObject:@{
                                     @"enabled": @(track.isEnabled),
                                     @"id": trackId,
                                     @"kind": track.kind,
                                     @"label": trackId,
                                     @"readyState": @"live",
                                     @"remote": @(NO)
                                     }];
             }
         }
         self.localStreams[mediaStreamId] = mediaStream;
         result(@{@"streamId": mediaStreamId, @"tracks" : tracks });
     }
     errorCallback:^ (NSString *errorType, NSString *errorMessage) {
         result([FlutterError errorWithCode:[NSString stringWithFormat:@"Error %@", errorType]
                                    message:errorMessage
                                    details:nil]);
     }
     mediaStream:mediaStream];
}

/**
 * Initializes a new {@link RTCAudioTrack} or a new {@link RTCVideoTrack} which
 * satisfies specific constraints and adds it to a specific
 * {@link RTCMediaStream} if the specified {@code mediaStream} contains no track
 * of the respective media type and the specified {@code constraints} specify
 * that a track of the respective media type is required; otherwise, reports
 * success for the specified {@code mediaStream} to a specific
 * {@link NavigatorUserMediaSuccessCallback}. In other words, implements a media
 * type-specific iteration of or successfully concludes the
 * {@code getUserMedia()} algorithm. The method will be recursively invoked to
 * conclude the whole {@code getUserMedia()} algorithm either with (successful)
 * satisfaction of the specified {@code constraints} or with failure.
 *
 * @param constraints The {@code MediaStreamConstraints} which specifies the
 * requested media types and which the new {@code RTCAudioTrack} or
 * {@code RTCVideoTrack} instance is to satisfy.
 * @param successCallback The {@link NavigatorUserMediaSuccessCallback} to which
 * success is to be reported.
 * @param errorCallback The {@link NavigatorUserMediaErrorCallback} to which
 * failure is to be reported.
 * @param mediaStream The {@link RTCMediaStream} which is being initialized as
 * part of the execution of the {@code getUserMedia()} algorithm.
 */
- (void)getUserMedia:(NSDictionary *)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream *)mediaStream {
    // If mediaStream contains no audioTracks and the constraints request such a
    // track, then run an iteration of the getUserMedia() algorithm to obtain
    // local audio content.
    if (mediaStream.audioTracks.count == 0) {
        // constraints.audio
        id audioConstraints = constraints[@"audio"];
        BOOL constraintsIsDictionary = [audioConstraints isKindOfClass:[NSDictionary class]];
        if (audioConstraints && (constraintsIsDictionary || [audioConstraints boolValue])) {
            [self requestAccessForMediaType:AVMediaTypeAudio
                                constraints:constraints
                            successCallback:successCallback
                              errorCallback:errorCallback
                                mediaStream:mediaStream];
            return;
        }
    }
    
    // If mediaStream contains no videoTracks and the constraints request such a
    // track, then run an iteration of the getUserMedia() algorithm to obtain
    // local video content.
    if (mediaStream.videoTracks.count == 0) {
        // constraints.video
        id videoConstraints = constraints[@"video"];
        if (videoConstraints) {
            BOOL requestAccessForVideo
            = [videoConstraints isKindOfClass:[NSNumber class]]
            ? [videoConstraints boolValue]
            : [videoConstraints isKindOfClass:[NSDictionary class]];
            
            if (requestAccessForVideo) {
                [self requestAccessForMediaType:AVMediaTypeVideo
                                    constraints:constraints
                                successCallback:successCallback
                                  errorCallback:errorCallback
                                    mediaStream:mediaStream];
                return;
            }
        }
    }
    
    // There are audioTracks and/or videoTracks in mediaStream as requested by
    // constraints so the getUserMedia() is to conclude with success.
    successCallback(mediaStream);
}

/**
 * Initializes a new {@link RTCVideoTrack} which satisfies specific constraints,
 * adds it to a specific {@link RTCMediaStream}, and reports success to a
 * specific callback. Implements the video-specific counterpart of the
 * {@code getUserMedia()} algorithm.
 *
 * @param constraints The {@code MediaStreamConstraints} which the new
 * {@code RTCVideoTrack} instance is to satisfy.
 * @param successCallback The {@link NavigatorUserMediaSuccessCallback} to which
 * success is to be reported.
 * @param errorCallback The {@link NavigatorUserMediaErrorCallback} to which
 * failure is to be reported.
 * @param mediaStream The {@link RTCMediaStream} which is being initialized as
 * part of the execution of the {@code getUserMedia()} algorithm, to which a
 * new {@code RTCVideoTrack} is to be added, and which is to be reported to
 * {@code successCallback} upon success.
 */
- (void)getUserVideo:(NSDictionary *)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream *)mediaStream {
    id videoConstraints = constraints[@"video"];
    AVCaptureDevice *videoDevice;
    if ([videoConstraints isKindOfClass:[NSDictionary class]]) {
        // constraints.video.optional
        id optionalVideoConstraints = videoConstraints[@"optional"];
        if (optionalVideoConstraints
            && [optionalVideoConstraints isKindOfClass:[NSArray class]]) {
            NSArray *options = optionalVideoConstraints;
            for (id item in options) {
                if ([item isKindOfClass:[NSDictionary class]]) {
                    NSString *sourceId = ((NSDictionary *)item)[@"sourceId"];
                    if (sourceId) {
                        videoDevice = [AVCaptureDevice deviceWithUniqueID:sourceId];
                        if (videoDevice) {
                            break;
                        }
                    }
                }
            }
        }
        if (!videoDevice) {
            // constraints.video.facingMode
            //
            // https://www.w3.org/TR/mediacapture-streams/#def-constraint-facingMode
            id facingMode = videoConstraints[@"facingMode"];
            if (facingMode && [facingMode isKindOfClass:[NSString class]]) {
                AVCaptureDevicePosition position;
                if ([facingMode isEqualToString:@"environment"]) {
                    position = AVCaptureDevicePositionBack;
                } else if ([facingMode isEqualToString:@"user"]) {
                    position = AVCaptureDevicePositionFront;
                } else {
                    // If the specified facingMode value is not supported, fall back to
                    // the default video device.
                    position = AVCaptureDevicePositionUnspecified;
                }
                if (AVCaptureDevicePositionUnspecified != position) {
                    for (AVCaptureDevice *aVideoDevice in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
                        if (aVideoDevice.position == position) {
                            videoDevice = aVideoDevice;
                            break;
                        }
                    }
                }
            }
        }
        if (!videoDevice) {
            videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        }
    }
    
    if (videoDevice) {
        // TODO: Actually use constraints...
        RTCAVFoundationVideoSource *videoSource = [self.peerConnectionFactory avFoundationVideoSourceWithConstraints:[self defaultMediaStreamConstraints]];
        // FIXME The effort above to find a videoDevice value which satisfies the
        // specified constraints was pretty much wasted. Salvage facingMode for
        // starters because it is kind of a common and hence important feature on
        // a mobile device.
        switch (videoDevice.position) {
            case AVCaptureDevicePositionBack:
                if (videoSource.canUseBackCamera) {
                    videoSource.useBackCamera = YES;
                }
                break;
            case AVCaptureDevicePositionFront:
                videoSource.useBackCamera = NO;
                break;
        }
        
        NSString *trackUUID = [[NSUUID UUID] UUIDString];
        RTCVideoTrack *videoTrack = [self.peerConnectionFactory videoTrackWithSource:videoSource trackId:trackUUID];
        [mediaStream addVideoTrack:videoTrack];
        
        successCallback(mediaStream);
    } else {
        // According to step 6.2.3 of the getUserMedia() algorithm, if there is no
        // source, fail with a new OverconstrainedError.
        errorCallback(@"OverconstrainedError", /* errorMessage */ nil);
    }
}

-(void)mediaStreamRelease:(RTCMediaStream *)stream
{
    if (stream) {
        for (RTCVideoTrack *track in stream.videoTracks) {
            [self.localTracks removeObjectForKey:track.trackId];
        }
        for (RTCAudioTrack *track in stream.audioTracks) {
            [self.localTracks removeObjectForKey:track.trackId];
        }
        [self.localStreams removeObjectForKey:stream.streamId];
    }
}


/**
 * Obtains local media content of a specific type. Requests access for the
 * specified {@code mediaType} if necessary. In other words, implements a media
 * type-specific iteration of the {@code getUserMedia()} algorithm.
 *
 * @param mediaType Either {@link AVMediaTypAudio} or {@link AVMediaTypeVideo}
 * which specifies the type of the local media content to obtain.
 * @param constraints The {@code MediaStreamConstraints} which are to be
 * satisfied by the obtained local media content.
 * @param successCallback The {@link NavigatorUserMediaSuccessCallback} to which
 * success is to be reported.
 * @param errorCallback The {@link NavigatorUserMediaErrorCallback} to which
 * failure is to be reported.
 * @param mediaStream The {@link RTCMediaStream} which is to collect the
 * obtained local media content of the specified {@code mediaType}.
 */
- (void)requestAccessForMediaType:(NSString *)mediaType
                      constraints:(NSDictionary *)constraints
                  successCallback:(NavigatorUserMediaSuccessCallback)successCallback
                    errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
                      mediaStream:(RTCMediaStream *)mediaStream {
    // According to step 6.2.1 of the getUserMedia() algorithm, if there is no
    // source, fail "with a new DOMException object whose name attribute has the
    // value NotFoundError."
    // XXX The following approach does not work for audio in Simulator. That is
    // because audio capture is done using AVAudioSession which does not use
    // AVCaptureDevice there. Anyway, Simulator will not (visually) request access
    // for audio.
    if (mediaType == AVMediaTypeVideo
        && [AVCaptureDevice devicesWithMediaType:mediaType].count == 0) {
        // Since successCallback and errorCallback are asynchronously invoked
        // elsewhere, make sure that the invocation here is consistent.
        dispatch_async(dispatch_get_main_queue(), ^ {
            errorCallback(@"DOMException", @"NotFoundError");
        });
        return;
    }
    
    [AVCaptureDevice
     requestAccessForMediaType:mediaType
     completionHandler:^ (BOOL granted) {
         dispatch_async(dispatch_get_main_queue(), ^ {
             if (granted) {
                 NavigatorUserMediaSuccessCallback scb
                 = ^ (RTCMediaStream *mediaStream) {
                     [self getUserMedia:constraints
                        successCallback:successCallback
                          errorCallback:errorCallback
                            mediaStream:mediaStream];
                 };
                 
                 if (mediaType == AVMediaTypeAudio) {
                     [self getUserAudio:constraints
                        successCallback:scb
                          errorCallback:errorCallback
                            mediaStream:mediaStream];
                 } else if (mediaType == AVMediaTypeVideo) {
                     [self getUserVideo:constraints
                        successCallback:scb
                          errorCallback:errorCallback
                            mediaStream:mediaStream];
                 }
             } else {
                 // According to step 10 Permission Failure of the getUserMedia()
                 // algorithm, if the user has denied permission, fail "with a new
                 // DOMException object whose name attribute has the value
                 // NotAllowedError."
                 errorCallback(@"DOMException", @"NotAllowedError");
             }
         });
     }];
}

-(void)mediaStreamTrackGetSources{
  NSMutableArray *sources = [NSMutableArray array];
  NSArray *videoDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
  for (AVCaptureDevice *device in videoDevices) {
    [sources addObject:@{
                         @"facing": device.positionString,
                         @"deviceId": device.uniqueID,
                         @"label": device.localizedName,
                         @"kind": @"videoinput",
                         }];
  }
  NSArray *audioDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
  for (AVCaptureDevice *device in audioDevices) {
    [sources addObject:@{
                         @"facing": @"",
                         @"deviceId": device.uniqueID,
                         @"label": device.localizedName,
                         @"kind": @"audioinput",
                         }];
  }
  //TODO: resolve(sources);
}

-(void)mediaStreamTrackRelease:(RTCMediaStream *)mediaStream  track:(RTCMediaStreamTrack *)track
{
  // what's different to mediaStreamTrackStop? only call mediaStream explicitly?
  if (mediaStream && track) {
    track.isEnabled = NO;
    // FIXME this is called when track is removed from the MediaStream,
    // but it doesn't mean it can not be added back using MediaStream.addTrack
    //TODO: [self.localTracks removeObjectForKey:trackID];
    if ([track.kind isEqualToString:@"audio"]) {
      [mediaStream removeAudioTrack:(RTCAudioTrack *)track];
    } else if([track.kind isEqualToString:@"video"]) {
      [mediaStream removeVideoTrack:(RTCVideoTrack *)track];
    }
  }
}

-(void)mediaStreamTrackSetEnabled:(RTCMediaStreamTrack *)track : (BOOL)enabled
{
  if (track && track.isEnabled != enabled) {
    track.isEnabled = enabled;
  }
}

-(void)mediaStreamTrackSwitchCamera:(RTCMediaStreamTrack *)track
{
  if (track) {
    RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
    RTCVideoSource *source = videoTrack.source;
    if ([source isKindOfClass:[RTCAVFoundationVideoSource class]]) {
      RTCAVFoundationVideoSource *avSource = (RTCAVFoundationVideoSource *)source;
      avSource.useBackCamera = !avSource.useBackCamera;
    }
  }
}

-(void)mediaStreamTrackStop:(RTCMediaStreamTrack *)track
{
  if (track) {
    track.isEnabled = NO;
    [self.localTracks removeObjectForKey:track.trackId];
  }
}

@end