// captions.x
// TubeReplacer
//
// Subtitles in YouTube 2.2.0+ come from the *player response*, not from the video:
// the controller reads playerData.captions.playerCaptionsRenderer.baseUrl, asks a
// (long dead) timedtext "list" endpoint for the tracks, then builds a per-track URL
// from that base URL.  Modern captions are different: every track in the player JSON
// (captions.playerCaptionsTracklistRenderer.captionTracks) has its own signed URL.
//
// So, in every version that has this architecture we
//   1. remember the caption tracks of each player response (TRCacheCaptionTracks),
//   2. answer the "list tracks" request from that cache, and
//   3. fetch a chosen track from *its own* URL, parsed by the app's own parser
//      (the tweak's XML parser for SBV-style, the native one for "format 3").
//
// YTSubtitlesService is used by 2.2.0 - 2.3.1, YTCaptionService by 2.9.3+.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include "general.h"

// The tracks' signed timedtext URLs only work with a proof-of-origin token these apps cannot make.
// The app is given a URL on a made-up host instead, answered by TRCaptionProtocol below with the
// web transcript turned into "format 3" XML (or the original file, when that one does work).
static NSString *const kTRCaptionHost = @"tr-captions.local";
extern void TRFetchTranscriptXML(NSString *videoID, void (^cb)(NSString *xml)); // innertube.x
static NSString *TRPercent(NSString *s) {
    return [(NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)s, NULL, CFSTR("!*'();:@&=+$,/?#[]%"), kCFStringEncodingUTF8) autorelease];
}
static NSString *TRCaptionProtoURL(NSString *videoID, NSString *lang, NSString *orig) {
    return [NSString stringWithFormat:@"http://%@/c?v=%@&l=%@&u=%@", kTRCaptionHost, TRPercent(videoID ?: @""), TRPercent(lang ?: @""), TRPercent(orig ?: @"")];
}

#pragma mark - Cache of caption tracks per video

static NSMutableDictionary *TRCaptionCache(void) {
    static NSMutableDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSMutableDictionary alloc] init]; });
    return d;
}

// tracks: the player JSON's captions.playerCaptionsTracklistRenderer.captionTracks
void TRCacheCaptionTracks(NSString *videoID, NSArray *tracks) {
    if (![videoID length] || ![tracks isKindOfClass:[NSArray class]]) return;
    NSMutableArray *clean = [NSMutableArray array];
    for (NSDictionary *t in tracks) {
        if (![t isKindOfClass:[NSDictionary class]]) continue;
        NSString *url = t[@"baseUrl"];
        if (![url length]) continue;
        if ([url hasPrefix:@"/"]) url = [@"https://www.youtube.com" stringByAppendingString:url];
        NSString *orig = url;
        url = TRCaptionProtoURL(videoID, t[@"languageCode"] ?: @"", orig); // served by TRCaptionProtocol

        NSString *name = nil;
        NSDictionary *n = t[@"name"];
        if ([n isKindOfClass:[NSDictionary class]]) {
            NSArray *runs = n[@"runs"];
            name = [runs count] ? runs[0][@"text"] : n[@"simpleText"];
        }
        if (![name length]) name = t[@"languageCode"] ?: @"Unknown";
        [clean addObject:@{ @"url": url, @"orig": orig, @"lang": t[@"languageCode"] ?: @"", @"name": name,
                            @"vss": t[@"vssId"] ?: @"" }];
    }
    @synchronized (TRCaptionCache()) { TRCaptionCache()[videoID] = clean; }
}

// captions.playerCaptionsTracklistRenderer.captionTracks for the apps that read the list from the player response
NSArray *TRCaptionTrackJSON(NSString *videoID, NSArray *origTracks) {
    NSArray *tracks; @synchronized (TRCaptionCache()) { tracks = [[TRCaptionCache()[videoID] copy] autorelease]; }
    // the player's own entries (name, kind, rtl, ...) with only the URL swapped; the cache skipped entries without a URL
    NSMutableArray *orig = [NSMutableArray array];
    for (id o in origTracks) if ([o isKindOfClass:[NSDictionary class]] && [o[@"baseUrl"] length]) [orig addObject:o];
    BOOL same = [orig count] == [tracks count];
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < [tracks count]; i++) {
        NSDictionary *t = tracks[i];
        if (same) {
            NSMutableDictionary *m = [[orig[i] mutableCopy] autorelease];
            m[@"baseUrl"] = t[@"url"];
            [out addObject:m];
        } else {
            [out addObject:@{ @"baseUrl": t[@"url"], @"name": @{ @"simpleText": t[@"name"] }, @"vssId": [t[@"vss"] length] ? t[@"vss"] : [@"." stringByAppendingString:t[@"lang"]],
                              @"languageCode": t[@"lang"] }];
        }
    }
    return out;
}

// Whether any caption tracks are known for a video (used to decide on advertising captions).
BOOL TRHasCaptionTracks(NSString *videoID) {
    @synchronized (TRCaptionCache()) { return [TRCaptionCache()[videoID] count] > 0; }
}

// A representative track URL (used as the player response's captions "baseUrl").
NSString *TRCaptionBaseURL(NSString *videoID) {
    @synchronized (TRCaptionCache()) { return [TRCaptionCache()[videoID] firstObject][@"url"]; }
}

#pragma mark - Building track objects (class differs by version)

static id TRMakeTrackObject(NSDictionary *t, NSUInteger index) {
    NSURL *url = [NSURL URLWithString:t[@"url"]];
    Class legacy = NSClassFromString(@"YTSubtitlesTrack");
    Class modern = NSClassFromString(@"YTCaptionTrack");
    if (legacy) { // 2.2.0 - 2.3.1
        SEL s = NSSelectorFromString(@"initWithLanguageCode:languageName:trackName:format:");
        id obj = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)([legacy alloc], s, t[@"lang"], t[@"name"], url, @"ass");
        return [obj autorelease];
    }
    if (modern) { // 2.9.3+
        SEL s = NSSelectorFromString(@"initWithID:languageCode:languageName:trackName:format:VSSID:");
        if ([modern instancesRespondToSelector:s]) {
            id obj = [modern alloc];
            obj = ((id (*)(id, SEL, id, id, id, id, id, id))objc_msgSend)(
                obj, s, [NSString stringWithFormat:@"%lu", (unsigned long)index], t[@"lang"], t[@"name"], url, @"ass", t[@"vss"]);
            return [obj autorelease];
        }
    }
    return nil;
}

static BOOL TRCanBuildTracks(void) {
    Class legacy = NSClassFromString(@"YTSubtitlesTrack");
    Class modern = NSClassFromString(@"YTCaptionTrack");
    if ([legacy instancesRespondToSelector:NSSelectorFromString(@"initWithLanguageCode:languageName:trackName:format:")]) return YES;
    return [modern instancesRespondToSelector:NSSelectorFromString(@"initWithID:languageCode:languageName:trackName:format:VSSID:")];
}

static NSArray *TRCaptionTrackObjects(NSString *videoID) {
    NSArray *tracks;
    @synchronized (TRCaptionCache()) { tracks = [[TRCaptionCache()[videoID] copy] autorelease]; }
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger i = 0;
    for (NSDictionary *t in tracks) {
        id o = TRMakeTrackObject(t, i++);
        if (o) [out addObject:o];
    }
    return out;
}

#pragma mark - Shared helpers

static void TRDeliver(id service, SEL sel, id block, id obj) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(service, sel, block, obj);
}

@interface NSObject (TRCaptionPerform)
- (void)performHTTPRequest:(id)request parser:(id)parser responseBlock:(id)responseBlock errorBlock:(id)errorBlock;
@end

// Fetch a track from its own URL.  format3: ask for the "srv3" (format 3) rendition.
// Returns NO (and does nothing) when the track doesn't carry one of our URLs, so the caller
// can fall back to the app's own implementation.
static BOOL TRFetchTrack(id service, id track, NSString *parserIvar, BOOL format3, id responseBlock, id errorBlock) {
    id trackName = [track respondsToSelector:@selector(trackName)] ? [track performSelector:@selector(trackName)] : nil;
    if (![trackName isKindOfClass:[NSURL class]]) return NO;
    NSString *abs = [(NSURL *)trackName absoluteString];
    if (format3 && [abs rangeOfString:kTRCaptionHost].location == NSNotFound && [abs rangeOfString:@"fmt="].location == NSNotFound) {
        abs = [abs stringByAppendingString:([abs rangeOfString:@"?"].location == NSNotFound ? @"?fmt=srv3" : @"&fmt=srv3")];
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:abs]];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10B329 Safari/8536.25"
 forHTTPHeaderField:@"User-Agent"];
    id parser = TRHasIvar(service, parserIvar) ? [service valueForKey:parserIvar] : nil;
    [service performHTTPRequest:req parser:parser responseBlock:responseBlock errorBlock:errorBlock];
    return YES;
}

// 10.x/11.x: the app builds the request for a track itself (track URL + "format=3"). The server
// ignores "format"; it wants fmt=srv3 for the format-3 XML the app's parser reads.
static id TRFixFormat3Request(id req) {
    @try {
        NSURL *u = [req respondsToSelector:@selector(URL)] ? [req URL] : nil;
        NSString *abs = [u absoluteString];
        if ([abs length] && [abs rangeOfString:kTRCaptionHost].location == NSNotFound && [abs rangeOfString:@"fmt=srv3"].location == NSNotFound) {
            NSMutableArray *kept = [NSMutableArray array];
            NSArray *parts = [abs componentsSeparatedByString:@"?"];
            NSString *base = parts[0];
            NSString *query = [parts count] > 1 ? [[parts subarrayWithRange:NSMakeRange(1, [parts count] - 1)] componentsJoinedByString:@"?"] : @"";
            for (NSString *kv in [query componentsSeparatedByString:@"&"]) {
                if (![kv length] || [kv hasPrefix:@"format="] || [kv hasPrefix:@"fmt="]) continue;
                [kept addObject:kv];
            }
            [kept addObject:@"fmt=srv3"];
            NSString *ns = [NSString stringWithFormat:@"%@?%@", base, [kept componentsJoinedByString:@"&"]];
            NSMutableURLRequest *m = [[req mutableCopy] autorelease];
            [m setURL:[NSURL URLWithString:ns]];
            [m setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 6_1_3 like Mac OS X) AppleWebKit/536.26 (KHTML, like Gecko) Version/6.0 Mobile/10B329 Safari/8536.25" forHTTPHeaderField:@"User-Agent"];
            NSLog(@"[TubeReplacer] captions: format3 request -> %@", [ns length] > 140 ? [ns substringToIndex:140] : ns);
            return m;
        }
    } @catch (NSException *e) {}
    return req;
}


static NSString *TRQueryValue(NSURL *url, NSString *key) {
    for (NSString *kv in [[url query] componentsSeparatedByString:@"&"]) {
        NSRange r = [kv rangeOfString:@"="];
        if (r.location == NSNotFound || ![[kv substringToIndex:r.location] isEqualToString:key]) continue;
        return [[kv substringFromIndex:r.location + 1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    }
    return nil;
}

// Resolve one of our made-up caption URLs to format-3 XML (called on any thread, calls back on a background queue).
static void TRCaptionXMLForURL(NSURL *url, void (^cb)(NSString *xml)) {
    NSString *vid = TRQueryValue(url, @"v"), *orig = TRQueryValue(url, @"u");
    NSLog(@"[TubeReplacer] captions: file requested for %@", vid);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. the track's own file, asked for as format 3 (works for some videos / networks)
        NSString *body = nil;
        if ([orig length] && ![orig hasSuffix:@"tr=1"]) {
            NSString *u2 = [orig rangeOfString:@"fmt="].location == NSNotFound ? [orig stringByAppendingString:@"&fmt=srv3"] : orig;
            NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u2]];
            NSHTTPURLResponse *resp = nil;
            NSData *d = [NSURLConnection sendSynchronousRequest:r returningResponse:&resp error:nil];
            NSString *t = d ? [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease] : nil;
            NSLog(@"[TubeReplacer] captions: track file http=%ld %lu byte(s)", (long)[resp statusCode], (unsigned long)[d length]);
            if ([t rangeOfString:@"<timedtext"].location != NSNotFound) body = t;
        }
        if ([body length]) { cb(body); return; }
        // 2. the web transcript
        TRFetchTranscriptXML(vid, ^(NSString *xml) { cb(xml); });
    });
}

@interface YTSubtitlesService : NSObject
@end

@interface YTCaptionService : NSObject
@end


// 11.x / 12.x: YTCaptionService hands the track request straight to the network service, whose
// session ignores NSURLProtocol. Answer our made-up caption URLs there.
static void TRServeCaptionRequest(id service, NSURLRequest *request, id parser, id responseBlock, id errorBlock, BOOL rawData) {
    NSURL *u = [request URL];
    id rb = [responseBlock copy], eb = [errorBlock copy], svc = [service retain], par = [parser retain];
    TRCaptionXMLForURL(u, ^(NSString *xml) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id result = nil; NSError *err = nil;
            if ([xml length]) {
                NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
                @try { result = rawData ? data : [par performSelector:NSSelectorFromString(@"parse:error:") withObject:data withObject:(id)&err]; }
                @catch (NSException *e) { NSLog(@"[TubeReplacer] captions: parse failed: %@", e); }
            }
            if (result) {
                NSLog(@"[TubeReplacer] captions: delivering captions (%lu char(s) of XML)", (unsigned long)[xml length]);
                if (rb) ((void (^)(id))rb)(result);
            } else {
                NSLog(@"[TubeReplacer] captions: no captions for this track (err=%@)", err);
                if (eb) ((void (^)(id))eb)(err ?: [NSError errorWithDomain:@"TubeReplacer" code:310 userInfo:@{ NSLocalizedDescriptionKey: @"No captions." }]);
            }
            [rb release]; [eb release]; [svc release]; [par release];
        });
    });
}

%hook YTBaseNetworkService
- (void)performHTTPRequest:(id)request parser:(id)parser responseBlock:(id)responseBlock errorBlock:(id)errorBlock retryConfig:(id)retryConfig {
    if (majorVersion() >= 11 && [[[request URL] host] isEqualToString:kTRCaptionHost]) { TRServeCaptionRequest(self, request, parser, responseBlock, errorBlock, NO); return; }
    %orig;
}
- (void)performHTTPRequest:(id)request parser:(id)parser responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (majorVersion() >= 11 && [[[request URL] host] isEqualToString:kTRCaptionHost]) { TRServeCaptionRequest(self, request, parser, responseBlock, errorBlock, NO); return; }
    %orig;
}
- (void)performHTTPRequest:(id)request dataBlock:(id)dataBlock errorBlock:(id)errorBlock retryConfig:(id)retryConfig {
    if (majorVersion() >= 11 && [[[request URL] host] isEqualToString:kTRCaptionHost]) { TRServeCaptionRequest(self, request, nil, dataBlock, errorBlock, YES); return; }
    %orig;
}
- (void)performHTTPRequest:(id)request dataBlock:(id)dataBlock errorBlock:(id)errorBlock {
    if (majorVersion() >= 11 && [[[request URL] host] isEqualToString:kTRCaptionHost]) { TRServeCaptionRequest(self, request, nil, dataBlock, errorBlock, YES); return; }
    %orig;
}
%end

%hook YTSubtitlesService

// "list the tracks": answer from the player response's tracks (2.2.0 - 2.3.1)
- (void)makeSubtitlesTracksRequestWithURL:(id)url videoID:(NSString *)videoID responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (!TRCanBuildTracks()) { %orig; return; }
    NSArray *tracks = TRCaptionTrackObjects(videoID);
    NSLog(@"[TubeReplacer] subtitles: %lu track(s) for %@", (unsigned long)[tracks count], videoID);
    TRDeliver(self, NSSelectorFromString(@"performResponseBlock:response:"), responseBlock, tracks);
}

// 2.2.0
- (void)makeSubtitlesRequestWithURL:(id)url videoID:(NSString *)videoID track:(id)track responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (!TRFetchTrack(self, track, @"_subtitlesParser", NO, responseBlock, errorBlock)) %orig;
}

// 2.3.1
- (void)makeSBVSubtitlesRequestWithURL:(id)url videoID:(NSString *)videoID track:(id)track responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (!TRFetchTrack(self, track, @"_sbvSubtitlesParser", NO, responseBlock, errorBlock)) %orig;
}

- (void)makeFormat3CaptionsRequestWithURL:(id)url videoID:(NSString *)videoID track:(id)track responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (!TRFetchTrack(self, track, @"_format3CaptionsParser", YES, responseBlock, errorBlock)) %orig;
}

%end

%hook YTCaptionService

// 10.x/11.x: the app builds the request for a track itself (track URL + "format=3"). The server
// ignores "format"; it wants fmt=srv3 for the format-3 XML the app's parser reads.
- (id)format3RequestForTrack:(id)track { return TRFixFormat3Request(%orig); }
- (id)format3RequestForURL:(id)url { return TRFixFormat3Request(%orig); } // 11.x

// 11.x+: the app fetches the raw XML through its own network stack (NSURLSession), which ignores our
// NSURLProtocol. Answer our made-up URLs directly.
- (void)makeFormat3CaptionsXMLDataRequestWithURL:(id)url responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    NSURL *u = [url isKindOfClass:[NSURL class]] ? url : ([url isKindOfClass:[NSString class]] ? [NSURL URLWithString:url] : nil);
    if (![[u host] isEqualToString:kTRCaptionHost]) { %orig; return; }
    id rb = [responseBlock copy], eb = [errorBlock copy], svc = [self retain];
    TRCaptionXMLForURL(u, ^(NSString *xml) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([xml length]) {
                NSLog(@"[TubeReplacer] captions: delivering %lu char(s) of format 3", (unsigned long)[xml length]);
                TRDeliver(svc, NSSelectorFromString(@"performResponseBlock:response:"), rb, [xml dataUsingEncoding:NSUTF8StringEncoding]);
            } else {
                TRDeliver(svc, NSSelectorFromString(@"performErrorBlock:error:"), eb, [NSError errorWithDomain:@"TubeReplacer" code:310 userInfo:@{ NSLocalizedDescriptionKey: @"No captions." }]);
            }
            [rb release]; [eb release]; [svc release];
        });
    });
}

// 2.9.3+
- (void)makeCaptionTracksRequestWithURL:(id)url videoID:(NSString *)videoID responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (!TRCanBuildTracks()) { %orig; return; }
    NSArray *tracks = TRCaptionTrackObjects(videoID);
    NSLog(@"[TubeReplacer] captions: %lu track(s) for %@", (unsigned long)[tracks count], videoID);
    TRDeliver(self, NSSelectorFromString(@"performResponseBlock:response:"), responseBlock, tracks);
}

- (void)makeFormat3CaptionsRequestWithURL:(id)url videoID:(NSString *)videoID track:(id)track responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (!TRFetchTrack(self, track, @"_format3CaptionsParser", YES, responseBlock, errorBlock)) %orig;
}

%end

// 2.3.1 only reads format-3 captions when the (long dead) server-side client configuration says so.
%hook YTSettings
- (BOOL)useFormat3Captions { return YES; }
%end

#pragma mark - The made-up caption host

@interface TRCaptionProtocol : NSURLProtocol
@end

@implementation TRCaptionProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [[[request URL] host] isEqualToString:kTRCaptionHost]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)finishWithXML:(NSString *)xml {
    if (![xml length]) {
        [[self client] URLProtocol:self didFailWithError:[NSError errorWithDomain:@"TubeReplacer" code:310 userInfo:@{ NSLocalizedDescriptionKey: @"No captions." }]];
        return;
    }
    NSData *d = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *resp = [[[NSHTTPURLResponse alloc] initWithURL:[[self request] URL] statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                         headerFields:@{ @"Content-Type": @"text/xml; charset=utf-8", @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)[d length]] }] autorelease];
    [[self client] URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [[self client] URLProtocol:self didLoadData:d];
    [[self client] URLProtocolDidFinishLoading:self];
}
- (void)startLoading {
    [self retain];
    TRCaptionXMLForURL([[self request] URL], ^(NSString *xml) { [self finishWithXML:xml]; [self release]; });
}
- (void)stopLoading {}
@end

// Sessions with their own configuration (iOS 7+ apps) only use the protocols listed in the configuration.
%hook NSURLSessionConfiguration
+ (id)defaultSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    NSMutableArray *p = [NSMutableArray arrayWithObject:[TRCaptionProtocol class]];
    [p addObjectsFromArray:[c protocolClasses] ?: @[]];
    [c setProtocolClasses:p];
    return c;
}
+ (id)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    NSMutableArray *p = [NSMutableArray arrayWithObject:[TRCaptionProtocol class]];
    [p addObjectsFromArray:[c protocolClasses] ?: @[]];
    [c setProtocolClasses:p];
    return c;
}
%end

%ctor {
    [NSURLProtocol registerClass:[TRCaptionProtocol class]];
}
