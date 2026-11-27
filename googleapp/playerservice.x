// playerservice.x
// TubeReplacer
//
// YouTube 2.2.0 no longer plays videos through YTVideo.streams / YTPlayerController.
// Instead the watch screen asks YTPlayerService for a protobuf YTIPlayerResponse
// (from a long-dead Apiary backend) and feeds its streamingData into
// MLStreamManifest -> MLProxy -> MLPlayer.
//
// We answer -makePlayerRequestWithVideoID:... ourselves: fetch the player data from
// InnerTube, then build a real YTIPlayerResponse (playability, video details and
// playable MP4 formats) so the app's own manifest / proxy / player code runs as-is.
//
// The generated protobuf classes have no static accessors (they are @dynamic and
// resolved at runtime), so everything is driven through selectors by name; the
// names and types come straight from the 2.2.0 binary's property metadata.

#import <Foundation/Foundation.h>
#import "common/SABR/TRMuxer.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include "appheaders.h"
#include "Translators/TRRequestBuilder.h"
#include "Translators/TRJSONUtils.h"
#include "common/YoutubeClientType.h"
#include "general.h"

@interface YTPlayerService : YTBaseService
- (void)makePlayerRequestWithVideoID:(NSString *)videoID responseBlock:(id)responseBlock errorBlock:(id)errorBlock;
@end

// appheaders.h declares performErrorBlock:error: with a bogus (void) argument type, so
// call the service's delivery helpers through correctly typed function pointers.
static void TRDeliverResponse(id service, id block, id response) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(service, NSSelectorFromString(@"performResponseBlock:response:"), block, response);
}
static void TRDeliverError(id service, id block, NSError *error) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(service, NSSelectorFromString(@"performErrorBlock:error:"), block, error);
}

// captions.x
extern void TRCacheCaptionTracks(NSString *videoID, NSArray *tracks);
extern BOOL TRHasCaptionTracks(NSString *videoID);
extern NSString *TRCaptionBaseURL(NSString *videoID);

#pragma mark - Protobuf helpers (all by selector name)

static id TRPBBuilder(NSString *messageClass) {
    Class c = NSClassFromString(messageClass);
    if (!c) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"builder"));
}

static id TRPBBuild(id builder) {
    return ((id (*)(id, SEL))objc_msgSend)(builder, NSSelectorFromString(@"build"));
}

static SEL TRPBSetter(NSString *key) {
    return NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
                                 [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]]);
}

static void TRPBSetObject(id b, NSString *key, id value) {
    if (!b || !value) return;
    ((void (*)(id, SEL, id))objc_msgSend)(b, TRPBSetter(key), value);
}
static void TRPBSetInt(id b, NSString *key, int value) {
    if (!b) return;
    ((void (*)(id, SEL, int))objc_msgSend)(b, TRPBSetter(key), value);
}
static void TRPBSetInt64(id b, NSString *key, long long value) {
    if (!b) return;
    ((void (*)(id, SEL, long long))objc_msgSend)(b, TRPBSetter(key), value);
}
static void TRPBSetUInt64(id b, NSString *key, unsigned long long value) {
    if (!b) return;
    ((void (*)(id, SEL, unsigned long long))objc_msgSend)(b, TRPBSetter(key), value);
}
static void TRPBSetBool(id b, NSString *key, BOOL value) {
    if (!b) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(b, TRPBSetter(key), value);
}

// PBArray of message objects (value type 0 == object, taken from +[PBArray arrayWithObject:]).
static id TRPBObjectArray(NSArray *objects) {
    Class c = NSClassFromString(@"PBArray");
    if (!c || ![objects count]) return nil;
    return ((id (*)(id, SEL, id, int))objc_msgSend)(c, NSSelectorFromString(@"arrayWithArray:valueType:"), objects, 0);
}

#pragma mark - Choosing streams

static NSDictionary *TRPlayerPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/dev.preloading.tubereplacer.preferences.plist"];
}

// Plain (non-ciphered) muxed MP4 formats; the app can play these progressively.
static NSArray *TRMuxedFormats(NSDictionary *json) {
    NSArray *formats = [TRJSONUtils arrayFromJSON:json keyPath:@"streamingData.formats"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *f in formats) {
        if (![f isKindOfClass:[NSDictionary class]]) continue;
        NSString *url = f[@"url"], *mime = f[@"mimeType"];
        if (![url length] || ![mime length]) continue;
        BOOL mp4 = [mime hasPrefix:@"video/mp4"] || [mime hasPrefix:@"video/3gpp"];
        BOOL muxed = [mime rangeOfString:@"mp4a"].location != NSNotFound || [mime hasPrefix:@"video/3gpp"];
        BOOL h264 = [mime rangeOfString:@"avc1"].location != NSNotFound || [mime hasPrefix:@"video/3gpp"];
        if (mp4 && muxed && h264) [out addObject:f];
    }
    // itag 18 (360p) first: it is the most widely playable on old devices.
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL a18 = [[a[@"itag"] description] isEqualToString:@"18"];
        BOOL b18 = [[b[@"itag"] description] isEqualToString:@"18"];
        if (a18 != b18) return a18 ? NSOrderedAscending : NSOrderedDescending;
        return [@([b[@"height"] intValue]) compare:@([a[@"height"] intValue])];
    }];
    return out;
}

static NSString *TRHLSURL(NSDictionary *json) {
    NSString *u = [TRJSONUtils stringFromJSON:json keyPath:@"streamingData.hlsManifestUrl"];
    return [u length] ? u : nil;
}

static BOOL TRPlayable(NSDictionary *json) {
    NSString *status = [TRJSONUtils stringFromJSON:json keyPath:@"playabilityStatus.status"];
    return [status isEqualToString:@"OK"] && ([TRMuxedFormats(json) count] || TRHLSURL(json));
}

static NSArray *TRClientsForPreference(NSString *type) {
    if ([type isEqualToString:@"android"]) return @[[YoutubeClientType androidClient]];
    if ([type isEqualToString:@"androidvr"]) return @[[YoutubeClientType androidVrClient]];
    if ([type isEqualToString:@"visionos"]) return @[[YoutubeClientType visionOSClient]];
    // Default (also "web"/"mweb", which hand out no plain URLs): the android client, plain 360p.
    return @[[YoutubeClientType androidClient]];
}

static NSOperationQueue *TRPlayerQueue(void) {
    static NSOperationQueue *q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = [[NSOperationQueue alloc] init];
        [q setMaxConcurrentOperationCount:2];
    });
    return q;
}

typedef void (^TRPlayerFetchDone)(NSDictionary *json, NSString *failureReason);
static void TRFetchPlayer(NSString *videoID, NSArray *clients, NSUInteger index, NSString *firstFailure, TRPlayerFetchDone done);


// Plain 360p links from the android/iOS clients stop working after about a minute of data. Hand the app a
// 127.0.0.1 link instead: it fetches the real stream in small ranges and swaps in a fresh URL when YouTube says 403.
static BOOL TRUsesOverride(NSString *type) { return [type isEqualToString:@"tuberepair"] || ([type isEqualToString:@"custom"] && [TRPlayerPrefs()[@"CustomStreamURL"] length]); }

static void TRProxyFormats(NSMutableDictionary *json, NSString *videoID, YoutubeClientType *client) {
    NSString *ptype = TRPlayerPrefs()[@"StreamType"];
    NSLog(@"[TubeReplacer] player %@: %@ StreamType=%@ proxy=%@", @"2.0.200", videoID, ptype ?: @"(default)", TRUsesOverride(ptype) ? @"off (custom server)" : @"on");
    if (TRUsesOverride(ptype)) return;
    for (NSMutableDictionary *f in TRMuxedFormats(json)) {
        if (![f isKindOfClass:[NSMutableDictionary class]]) continue;
        NSString *url = f[@"url"], *itag = [f[@"itag"] description];
        NSString *ua = client.useragent;
        NSString *(^refresh)(void) = ^NSString *{
            __block NSString *fresh = nil;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            TRFetchPlayer(videoID, @[client], 0, nil, ^(NSDictionary *j, NSString *why) {
                for (NSDictionary *g in TRMuxedFormats(j)) if ([[g[@"itag"] description] isEqualToString:itag]) { fresh = [g[@"url"] copy]; break; }
                dispatch_semaphore_signal(sem);
            });
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC));
            dispatch_release(sem);
            return [fresh autorelease];
        };
        NSString *local = TRProxyStream(url, ua, [f[@"contentLength"] longLongValue],
                                        [NSString stringWithFormat:@"%@/itag%@", videoID, itag], refresh);
        if (local) f[@"url"] = local;
    }
}

// Try each client in turn until one yields a playable response.
static void TRFetchPlayer(NSString *videoID, NSArray *clients, NSUInteger index, NSString *firstFailure, TRPlayerFetchDone done) {
    if (index >= [clients count]) {
        done(nil, firstFailure ?: @"No playable stream was found for this video.");
        return;
    }
    YoutubeClientType *client = clients[index];
    NSData *body = [TRRequestBuilder playerBodyWithVideoId:videoID poToken:nil signatureTimestamp:nil client:client];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false&noauth=1"]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:20.0];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:body];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if ([client.useragent length]) [req setValue:client.useragent forHTTPHeaderField:@"User-Agent"];

    [NSURLConnection sendAsynchronousRequest:req queue:TRPlayerQueue()
                           completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        NSDictionary *json = nil;
        if (data) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) json = parsed;
        }
        if (json && TRPlayable(json)) {
            TRProxyFormats((NSMutableDictionary *)json, videoID, client);
            done(json, nil);
            return;
        }
        NSString *reason = firstFailure;
        if (!reason && json) {
            NSString *status = [TRJSONUtils stringFromJSON:json keyPath:@"playabilityStatus.status"];
            NSString *why = [TRJSONUtils stringFromJSON:json keyPath:@"playabilityStatus.reason"];
            if ([why length]) reason = why;
            else if ([status length] && ![status isEqualToString:@"OK"]) reason = [NSString stringWithFormat:@"This video is unavailable (%@).", status];
        }
        NSLog(@"[TubeReplacer] player client %lu failed for %@ (%@)", (unsigned long)index, videoID, reason ?: err);
        TRFetchPlayer(videoID, clients, index + 1, reason, done);
    }];
}

// Exposed for innertube.x: fetch player JSON trying the plain-URL clients in turn.
void TRFetchPlayerJSON(NSString *videoID, void (^done)(NSDictionary *json, NSString *failure)) {
    NSString *type = [TRPlayerPrefs() objectForKey:@"StreamType"];
    // The settings app's "custom server" choices: the app gets that stream link instead (like the original tweak).
    NSURL *override = nil;
    if ([type isEqualToString:@"tuberepair"]) override = [NSURL URLWithString:[@"https://tuberepair.uptimetrackers.com/getvideo/" stringByAppendingString:videoID]];
    else if ([type isEqualToString:@"custom"] && [TRPlayerPrefs()[@"CustomStreamURL"] length])
        override = [NSURL URLWithString:[TRPlayerPrefs()[@"CustomStreamURL"] stringByReplacingOccurrencesOfString:@"%v" withString:videoID]];
    TRFetchPlayer(videoID, TRClientsForPreference(override ? nil : type), 0, nil, ^(NSDictionary *json, NSString *failure) {
        if (!override) { done(json, failure); return; }
        NSMutableDictionary *m = json ? [[json mutableCopy] autorelease] : [NSMutableDictionary dictionary];
        if (!json) {
            m[@"playabilityStatus"] = @{ @"status": @"OK" };
            m[@"videoDetails"] = @{ @"videoId": videoID, @"title": @"", @"lengthSeconds": @"0" };
        }
        NSMutableDictionary *sd = [NSMutableDictionary dictionary];
        sd[@"formats"] = @[ @{ @"itag": @18, @"url": [override absoluteString], @"mimeType": @"video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
                               @"width": @640, @"height": @360, @"bitrate": @0, @"quality": @"medium" } ];
        m[@"streamingData"] = sd;
        NSLog(@"[TubeReplacer] player: %@ uses the %@ server: %@", videoID, type, override);
        done(m, nil);
    });
}

#pragma mark - Building YTIPlayerResponse

static id TRMakeFormatStream(NSString *url, NSString *mime, int itag, int bitrate, int width, int height,
                             long long contentLength, NSString *quality) {
    id b = TRPBBuilder(@"YTIFormatStream");
    if (!b) return nil;
    TRPBSetInt(b, @"itag", itag);
    TRPBSetObject(b, @"url", url);
    TRPBSetObject(b, @"mimeType", mime);
    TRPBSetInt(b, @"bitrate", bitrate);
    TRPBSetInt(b, @"width", width);
    TRPBSetInt(b, @"height", height);
    if (contentLength > 0) TRPBSetInt64(b, @"contentLength", contentLength);
    TRPBSetObject(b, @"quality", quality);
    TRPBSetBool(b, @"stereo3D", NO);
    TRPBSetBool(b, @"rtsp", NO);
    return TRPBBuild(b);
}

// json may be nil (custom/TubeRepair streams, or when only the stream URL is known).
static id TRMakePlayerResponse(NSString *videoID, NSDictionary *json, NSURL *overrideStream) {
    id response = TRPBBuilder(@"YTIPlayerResponse");
    if (!response) return nil;

    // playability: status 0 == OK (YTIPlayabilityStatus -isPlayable is status == 0)
    id status = TRPBBuilder(@"YTIPlayabilityStatus");
    TRPBSetInt(status, @"status", 0);
    TRPBSetObject(response, @"playabilityStatus", TRPBBuild(status));

    // video details
    id details = TRPBBuilder(@"YTIVideoDetails");
    TRPBSetObject(details, @"videoId", videoID);
    NSString *title = [TRJSONUtils stringFromJSON:json keyPath:@"videoDetails.title"];
    TRPBSetObject(details, @"title", title ?: @"");
    NSDictionary *vd = [json[@"videoDetails"] isKindOfClass:[NSDictionary class]] ? json[@"videoDetails"] : nil;
    TRPBSetUInt64(details, @"lengthSeconds", (unsigned long long)[vd[@"lengthSeconds"] longLongValue]);
    TRPBSetBool(details, @"isLive", [vd[@"isLive"] boolValue]);
    TRPBSetObject(response, @"videoDetails", TRPBBuild(details));

    // streaming data
    id streaming = TRPBBuilder(@"YTIStreamingData");
    NSMutableArray *formats = [NSMutableArray array];
    if (overrideStream) {
        id f = TRMakeFormatStream([overrideStream absoluteString],
                                  @"video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", 18, 0, 640, 360, 0, @"medium");
        if (f) [formats addObject:f];
    } else {
        for (NSDictionary *f in TRMuxedFormats(json)) {
            id fs = TRMakeFormatStream(f[@"url"], f[@"mimeType"], [f[@"itag"] intValue], [f[@"bitrate"] intValue],
                                       [f[@"width"] intValue], [f[@"height"] intValue],
                                       [f[@"contentLength"] longLongValue], f[@"quality"] ?: @"medium");
            if (fs) [formats addObject:fs];
        }
    }
    id arr = TRPBObjectArray(formats);
    if (arr) TRPBSetObject(streaming, @"formatsArray", arr);
    if (![formats count]) TRPBSetObject(streaming, @"hlsManifestUrl", TRHLSURL(json));
    TRPBSetObject(response, @"streamingData", TRPBBuild(streaming));

    // captions: remember the tracks (captions.x answers the app's track-list request from
    // this) and advertise captions so the subtitles button appears.
    NSArray *captionTracks = [TRJSONUtils arrayFromJSON:json keyPath:@"captions.playerCaptionsTracklistRenderer.captionTracks"];
    TRCacheCaptionTracks(videoID, captionTracks);
    if (TRHasCaptionTracks(videoID)) {
        id renderer = TRPBBuilder(@"YTIPlayerCaptionsRenderer");
        TRPBSetObject(renderer, @"baseUrl", TRCaptionBaseURL(videoID));
        id supported = TRPBBuilder(@"YTICaptionsSupportedRenderers");
        TRPBSetObject(supported, @"playerCaptionsRenderer", TRPBBuild(renderer));
        TRPBSetObject(response, @"captions", TRPBBuild(supported));
    }

    return TRPBBuild(response);
}

#pragma mark - Hook

%hook YTPlayerService

- (void)makePlayerRequestWithVideoID:(NSString *)videoID responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (![videoID length]) { %orig; return; }

    NSDictionary *prefs = TRPlayerPrefs();
    NSString *type = prefs[@"StreamType"];
    NSURL *override = nil;
    if ([type isEqualToString:@"tuberepair"]) {
        override = [NSURL URLWithString:[@"https://tuberepair.uptimetrackers.com/getvideo/" stringByAppendingString:videoID]];
    } else if ([type isEqualToString:@"custom"] && [prefs[@"CustomStreamURL"] length]) {
        override = [NSURL URLWithString:[prefs[@"CustomStreamURL"] stringByReplacingOccurrencesOfString:@"%v" withString:videoID]];
    }

    id responseCopy = [responseBlock copy];
    id errorCopy = [errorBlock copy];
    id service = [self retain];

    TRPlayerFetchDone done = ^(NSDictionary *json, NSString *failure) {
        @try {
            if (!json && !override) {
                NSError *error = [NSError errorWithDomain:@"TubeReplacer" code:100
                                                 userInfo:@{NSLocalizedDescriptionKey: failure ?: @"Unable to load this video."}];
                TRDeliverError(service, errorCopy, error);
            } else {
                id response = TRMakePlayerResponse(videoID, json, override);
                if (response) {
                    TRDeliverResponse(service, responseCopy, response);
                } else {
                    NSError *error = [NSError errorWithDomain:@"TubeReplacer" code:101
                                                     userInfo:@{NSLocalizedDescriptionKey: @"Unable to build the player response."}];
                    TRDeliverError(service, errorCopy, error);
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[TubeReplacer] failed to deliver player response: %@", e);
            NSError *error = [NSError errorWithDomain:@"TubeReplacer" code:102
                                             userInfo:@{NSLocalizedDescriptionKey: [e reason] ?: @"Playback error."}];
            TRDeliverError(service, errorCopy, error);
        }
        [responseCopy release];
        [errorCopy release];
        [service release];
    };

    if (override) {
        // The stream URL is already known; still try to fetch metadata (length) but don't depend on it.
        TRFetchPlayer(videoID, TRClientsForPreference(nil), 0, nil, ^(NSDictionary *json, NSString *failure) {
            done(json, failure);
        });
    } else {
        TRFetchPlayer(videoID, TRClientsForPreference(type), 0, nil, done);
    }
}

%end

// HD streams are not built any more (plain 360p, like the original TubeReplacer): the bridge asks these and gets "none".
BOOL TRHDOnlyMode(void) { return NO; }
void TRFetchHDFormatsJSON(NSString *videoID, NSDictionary *primary, void (^done)(NSArray *adaptive, NSString *hls)) { done(nil, nil); }
