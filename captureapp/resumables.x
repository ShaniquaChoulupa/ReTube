#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "captureheaders.h"
#include "general.h"
#import "potoken/potoken-google.h"

// Capture 2.0.x talks to the long-dead GData resumable upload API. We keep the
// app's own queue/UI (KUUploader) and swap the network legs for the YouTube
// Studio ones: start a scotty session, upload chunks, then create the video.

@interface KUVideoMetadata : NSObject
-(NSString*)title; -(NSString*)desc; -(int)privacy; -(void)setVideoID:(NSString*)v;
@end
@interface KUVideo : NSObject
-(KUVideoMetadata*)metadata; -(int)transcodeState; -(NSString*)transcodedVideoURL;
@end
@interface KUUploader : NSObject
-(KUVideo*)video;
-(void)startSendingBytes;
-(void)uploadSucceeded;
-(void)uploadFailedWithError:(NSError*)error responseData:(NSData*)data;
-(id)valueForKey:(NSString*)key;
@end

static NSString *TRStudioUA = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
static NSString *gBGClientResponse = nil; // fresh botguard snapshot for the next createvideo
static NSString *gStudioKey = nil, *gStudioDelegated = nil, *gStudioVisitor = nil;

static NSString *TRStudioSessionToken(void) {
    NSString *t = [[NSUserDefaults standardUserDefaults] stringForKey:@"TRStudioSessionToken"];
    NSDate *d = [[NSUserDefaults standardUserDefaults] objectForKey:@"TRStudioSessionTokenDate"];
    return (t && d && -[d timeIntervalSinceNow] < 6 * 24 * 3600) ? t : nil;
}

// withToken: include the cached session token (context.request.sessionInfo.token)
static NSDictionary *TRStudioContext(NSString *channelId, BOOL withToken) {
    NSDictionary *deleg = @{ @"roleType": @{ @"channelRoleType": @"CREATOR_CHANNEL_ROLE_TYPE_OWNER" },
                             @"externalChannelId": channelId ?: @"" };
    NSMutableDictionary *request = [@{ @"returnLogEntry": @YES, @"internalExperimentFlags": @[] } mutableCopy];
    NSString *tok = withToken ? TRStudioSessionToken() : nil;
    if (tok) request[@"sessionInfo"] = @{ @"token": tok };
    return @{ @"client": @{ @"clientName": @62, @"clientVersion": @"1.20260518.01.00", @"hl": @"en-GB", @"gl": @"GB",
                            @"experimentsToken": @"", @"utcOffsetMinutes": @0 },
              @"request": [request autorelease],
              @"user": @{ @"onBehalfOfUser": gStudioDelegated ?: @"", @"delegationContext": deleg, @"serializedDelegationContext": @"" },
              @"clientScreenNonce": @"" };
}

static NSURL *TRStudioURL(NSString *path) {
    NSString *u = [NSString stringWithFormat:@"https://studio.youtube.com/youtubei/v1/%@?alt=json", path];
    if ([gStudioKey length]) u = [u stringByAppendingFormat:@"&key=%@", gStudioKey];
    return [NSURL URLWithString:u];
}

static void TRStudioFetch(NSMutableURLRequest *req, void (^cb)(NSData *data, NSDictionary *headers, NSInteger code, NSError *err)) {
    [req setValue:@"https://studio.youtube.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"https://studio.youtube.com" forHTTPHeaderField:@"x-origin"];
    [req setValue:@"0" forHTTPHeaderField:@"x-goog-authuser"];
    if ([gStudioVisitor length]) [req setValue:gStudioVisitor forHTTPHeaderField:@"x-goog-visitor-id"];
    [req setValue:TRStudioUA forHTTPHeaderField:@"User-Agent"];
    GTMHTTPFetcher *f = [%c(GTMHTTPFetcher) fetcherWithRequest:req];
    [f setAuthorizer:[[%c(KUUserAuthenticator) sharedInstance] authentication]];
    [f beginFetchWithCompletionHandler:^(NSData *data, NSError *err) {
        cb(data, [f responseHeaders], [f statusCode], err);
    }];
}

static NSString *TRRegexGroup(NSString *src, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:src options:0 range:NSMakeRange(0, [src length])];
    return m && m.numberOfRanges > 1 ? [src substringWithRange:[m rangeAtIndex:1]] : nil;
}

// the studio page's ytcfg holds the api key, delegated session id and visitor data every call needs
static void TRStudioEnsureConfig(void (^cb)(void)) {
    static BOOL tried = NO;
    if ([gStudioKey length] || tried) { cb(); return; }
    tried = YES;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://studio.youtube.com/"]];
    [r setHTTPMethod:@"GET"];
    void (^done)(void) = [cb copy];
    TRStudioFetch(r, ^(NSData *data, NSDictionary *h, NSInteger code, NSError *err) {
        NSString *page = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
        gStudioKey = [TRRegexGroup(page ?: @"", @"\"INNERTUBE_API_KEY\"\\s*:\\s*\"([^\"]+)\"") copy];
        gStudioDelegated = [TRRegexGroup(page ?: @"", @"\"DELEGATED_SESSION_ID\"\\s*:\\s*\"([^\"]*)\"") copy];
        gStudioVisitor = [TRRegexGroup(page ?: @"", @"\"VISITOR_DATA\"\\s*:\\s*\"([^\"]+)\"") copy];
        NSLog(@"[TRCapture] studio page http=%ld bytes=%lu key=%d delegated=%d visitor=%d err=%@", (long)code, (unsigned long)[data length],
              [gStudioKey length] > 0, [gStudioDelegated length] > 0, [gStudioVisitor length] > 0, err);
        done();
        [done release];
    });
}

@interface TRReauthController : UIViewController <UIWebViewDelegate> {
    UIWebView *web_; void (^done_)(void);
}
-(id)initWithURL:(NSURL*)url done:(void(^)(void))done;
@end
@implementation TRReauthController
-(id)initWithURL:(NSURL*)url done:(void(^)(void))done {
    if ((self = [super init])) {
        done_ = [done copy];
        web_ = [[UIWebView alloc] initWithFrame:CGRectZero];
        web_.delegate = self; web_.scalesPageToFit = YES;
        [web_ loadRequest:[NSURLRequest requestWithURL:url]];
        self.title = @"Verify it's you";
        self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(finish)] autorelease];
    }
    return self;
}
-(void)loadView { web_.frame = [UIScreen mainScreen].bounds; self.view = web_; }
-(void)finish {
    void (^d)(void) = done_; done_ = nil;
    [self dismissViewControllerAnimated:YES completion:^{ if (d) d(); [d release]; }];
}
-(void)dealloc { web_.delegate = nil; [web_ release]; [done_ release]; [super dealloc]; }
@end

static NSString *TRFindURL(id o) {
    if ([o isKindOfClass:[NSString class]]) return [(NSString*)o hasPrefix:@"http"] ? o : nil;
    if ([o isKindOfClass:[NSDictionary class]]) {
        for (id k in o) { if ([k isEqual:@"responseContext"]) continue; NSString *r = TRFindURL(o[k]); if (r) return r; }
    } else if ([o isKindOfClass:[NSArray class]]) {
        for (id v in o) { NSString *r = TRFindURL(v); if (r) return r; }
    }
    return nil;
}


// att/get with the signed-in studio identity (the old solver code sent it anonymously,
// and esr then rejects a challenge that was never bound to the account)
static void TRFetchStudioChallenge(TRPOTokenSolver *solver, NSString *channelId, void (^cb)(NSError *)) {
    NSDictionary *ctx = TRStudioContext(channelId, NO);
    NSDictionary *body = @{
        @"context": ctx,
        @"engagementType": @"ENGAGEMENT_TYPE_UNBOUND",
        @"ids": @[ @{ @"externalChannelId": channelId ?: @"" } ] };
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:TRStudioURL(@"att/get")];
    [r setHTTPMethod:@"POST"];
    [r setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    TRStudioFetch(r, ^(NSData *data, NSDictionary *h, NSInteger code, NSError *err) {
        NSDictionary *j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSLog(@"[TRCapture] att/get http=%ld keys=%@ err=%@", (long)code, [j isKindOfClass:[NSDictionary class]] ? [j allKeys] : nil, err);
        if (![j isKindOfClass:[NSDictionary class]] || !j[@"challenge"]) {
            if (data && ![j isKindOfClass:[NSDictionary class]] == NO) NSLog(@"[TRCapture] att/get body %@", [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]);
            cb(err ?: [NSError errorWithDomain:@"TRCapture" code:code userInfo:nil]); return;
        }
        solver.botguardChallenge = j[@"challenge"];
        NSDictionary *bg = j[@"bgChallenge"];
        solver.program = bg[@"program"];
        solver.interpreterHash = bg[@"interpreterHash"];
        solver.globalName = bg[@"globalName"];
        solver.clientExperimentsStateBlob = bg[@"clientExperimentsStateBlob"];
        NSString *vmURL = bg[@"interpreterUrl"][@"privateDoNotAccessOrElseTrustedResourceUrlWrappedValue"];
        if (![vmURL length]) { cb([NSError errorWithDomain:@"TRCapture" code:-2 userInfo:nil]); return; }
        if ([vmURL hasPrefix:@"//"]) vmURL = [@"https:" stringByAppendingString:vmURL];
        NSMutableURLRequest *vr = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:vmURL]];
        [NSURLConnection sendAsynchronousRequest:vr queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *resp, NSData *d2, NSError *e2) {
            NSLog(@"[TRCapture] interpreter js: %lu bytes err=%@", (unsigned long)[d2 length], e2);
            if (e2 || ![d2 length]) { cb(e2 ?: [NSError errorWithDomain:@"TRCapture" code:-3 userInfo:nil]); return; }
            solver.safeScript = [[[NSString alloc] initWithData:d2 encoding:NSUTF8StringEncoding] autorelease];
            cb(nil);
        }];
    });
}

// Studio asks the account to re-verify before it creates a video. Run the same
// attestation + reauth-url dance as the web client, show the page, then retry.
static void TRStudioReauth(void (^cb)(BOOL ok)) {
    id authn = [[%c(KUUserAuthenticator) sharedInstance] authentication];
    NSString *channelId = [authn respondsToSelector:@selector(channelID)] ? [authn channelID] : @"";
    TRPOTokenSolver *solver = [[TRPOTokenSolver alloc] init];
    __block BOOL finished = NO, presented = NO;
    void (^cbOnce)(BOOL) = [^(BOOL ok) {
        if (finished) return; finished = YES; cb(ok);
    } copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (finished || presented) return;
        NSLog(@"[TRCapture] reauth: timed out");
        cbOnce(NO);
    });
    NSLog(@"[TRCapture] reauth: starting solver webview");
    solver.errorAlert = ^(NSString *m) { NSLog(@"[TRCapture] reauth: solver error %@", m); };
    [solver initWebViewWithCallback:^{
    NSLog(@"[TRCapture] reauth: webview ready, fetching botguard challenge");
    TRFetchStudioChallenge(solver, channelId, ^(NSError *error) {
        if (error) { NSLog(@"[TRCapture] reauth: challenge failed %@", error); cbOnce(NO); return; }
        NSLog(@"[TRCapture] reauth: starting botguard vm");
        [solver startBotguardVM:^{
        NSLog(@"[TRCapture] reauth: vm ready");
        [solver startFetchingChallengeResponseWithCallback:^(NSString *bgResponse) {
            NSLog(@"[TRCapture] reauth: botguard response %lu chars", (unsigned long)[bgResponse length]);
            // ytstudio (python) sends the snapshot inline as botguardClientResponse on createvideo,
            // which avoids the att/esr round trip entirely
            if ([bgResponse length]) {
                gBGClientResponse = [bgResponse copy];
                cbOnce(YES);
                return;
            }
            NSDictionary *ctx = TRStudioContext(channelId, NO);
            NSDictionary *deleg = ctx[@"user"][@"delegationContext"];
            // the exact esr body isn't documented; try a few shapes until one is accepted
            NSDictionary *esrBase = @{ @"context": ctx, @"botguardResponse": bgResponse ?: @"", @"challenge": solver.botguardChallenge ?: @"", @"xguardClientStatus": @0 };
            NSArray *bodies = @[ esrBase,
                @{ @"context": ctx, @"botguardResponse": bgResponse ?: @"", @"challenge": solver.botguardChallenge ?: @"" },
                @{ @"context": ctx, @"botguardResponse": bgResponse ?: @"", @"challenge": solver.botguardChallenge ?: @"", @"xguardClientStatus": @0, @"delegationContext": deleg } ];
            __block void (^tryEsr)(NSUInteger) = nil;
            tryEsr = [^(NSUInteger idx) {
            NSMutableURLRequest *r1 = [NSMutableURLRequest requestWithURL:TRStudioURL(@"att/esr")];
            [r1 setHTTPMethod:@"POST"];
            [r1 setHTTPBody:[NSJSONSerialization dataWithJSONObject:bodies[idx] options:0 error:nil]];
            [r1 setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
            TRStudioFetch(r1, ^(NSData *d1, NSDictionary *h1, NSInteger c1, NSError *e1) {
                NSDictionary *j1 = d1 ? [NSJSONSerialization JSONObjectWithData:d1 options:0 error:nil] : nil;
                NSString *ivctx = [j1 isKindOfClass:[NSDictionary class]] ? j1[@"ctx"] : nil;
                NSString *token = [j1 isKindOfClass:[NSDictionary class]] ? j1[@"sessionToken"] : nil;
                NSLog(@"[TRCapture] reauth: esr variant %lu http=%ld token=%d ctx=%d body=%@", (unsigned long)idx, (long)c1, token != nil, ivctx != nil,
                      d1 && !token ? [[[NSString alloc] initWithData:d1 encoding:NSUTF8StringEncoding] autorelease] : nil);
                if (!token && !ivctx && idx + 1 < bodies.count) { tryEsr(idx + 1); return; }
                if (token) {
                    [[NSUserDefaults standardUserDefaults] setObject:token forKey:@"TRStudioSessionToken"];
                    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"TRStudioSessionTokenDate"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                    cbOnce(YES); return;
                }
                if (!ivctx) { cbOnce(NO); return; }
                NSMutableURLRequest *r2 = [NSMutableURLRequest requestWithURL:TRStudioURL(@"security/get_web_reauth_url")];
                [r2 setHTTPMethod:@"POST"];
                [r2 setHTTPBody:[NSJSONSerialization dataWithJSONObject:@{ @"botguardResponse": bgResponse ?: @"", @"challenge": solver.botguardChallenge ?: @"",
                    @"continueUrl": @"https://studio.youtube.com/reauth", @"flow": @"REAUTH_FLOW_YT_STUDIO_COLD_LOAD", @"ivctx": ivctx,
                    @"context": ctx, @"delegationContext": deleg } options:0 error:nil]];
                [r2 setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                TRStudioFetch(r2, ^(NSData *d2, NSDictionary *h2, NSInteger c2, NSError *e2) {
                    NSDictionary *j2 = d2 ? [NSJSONSerialization JSONObjectWithData:d2 options:0 error:nil] : nil;
                    NSString *url = TRFindURL(j2);
                    NSLog(@"[TRCapture] reauth: url http=%ld url=%@ body=%@", (long)c2, url,
                          d2 && !url ? [[[NSString alloc] initWithData:d2 encoding:NSUTF8StringEncoding] autorelease] : nil);
                    if (!url) { cbOnce(NO); return; }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        presented = YES;
                        UIViewController *root = [[[UIApplication sharedApplication] keyWindow] rootViewController];
                        while (root.presentedViewController) root = root.presentedViewController;
                        TRReauthController *c = [[[TRReauthController alloc] initWithURL:[NSURL URLWithString:url] done:^{ cbOnce(YES); }] autorelease];
                        UINavigationController *nav = [[[UINavigationController alloc] initWithRootViewController:c] autorelease];
                        [root presentViewController:nav animated:YES completion:nil];
                    });
                });
            });
            } copy];
            tryEsr(0);
        }];
        }];
    });
    }];
}

static void TRCreateVideo(KUUploader *me, NSString *scotty, int attempt) {
    KUVideo *video = [me video];
    objc_setAssociatedObject(video, "trBusy", @"1", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![gStudioKey length]) {
        [me retain];
        TRStudioEnsureConfig(^{ TRCreateVideo(me, scotty, attempt); [me release]; });
        return;
    }
    KUVideoMetadata *meta = [video metadata];
    id authn = [[%c(KUUserAuthenticator) sharedInstance] authentication];
    NSString *channelId = [authn respondsToSelector:@selector(channelID)] ? [authn channelID] : @"";
    NSString *frontendId = objc_getAssociatedObject(video, "trFrontendId");
    if (!frontendId) {
        CFUUIDRef u = CFUUIDCreate(NULL);
        frontendId = [NSString stringWithFormat:@"innertube_studio:%@:0", [(NSString *)CFUUIDCreateString(NULL, u) autorelease]];
        CFRelease(u);
        objc_setAssociatedObject(video, "trFrontendId", frontendId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    int priv = [meta privacy];
    NSString *privacy = priv == 2 ? @"PUBLIC" : (priv == 1 ? @"UNLISTED" : @"PRIVATE");
    NSDictionary *ctx = TRStudioContext(channelId, YES);
    NSDictionary *body = @{
        @"channelId": channelId,
        @"resourceId": @{ @"scottyResourceId": @{ @"id": scotty } },
        @"frontendUploadId": frontendId,
        @"initialMetadata": @{
            @"title": @{ @"newTitle": [meta title] ?: @"" },
            @"description": @{ @"newDescription": [meta desc] ?: @"", @"shouldSegment": @YES },
            @"privacy": @{ @"newPrivacy": privacy },
            @"draftState": @{ @"isDraft": @NO } },
        @"context": ctx, @"delegationContext": ctx[@"user"][@"delegationContext"] };

    if (gBGClientResponse) {
        NSMutableDictionary *withBG = [[body mutableCopy] autorelease];
        withBG[@"botguardClientResponse"] = gBGClientResponse;
        body = withBG;
        NSLog(@"[TRCapture] createvideo with botguardClientResponse (%lu chars)", (unsigned long)[gBGClientResponse length]);
        [gBGClientResponse release]; gBGClientResponse = nil;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:TRStudioURL(@"upload/createvideo")];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [me retain];
    TRStudioFetch(req, ^(NSData *data, NSDictionary *headers, NSInteger code, NSError *err) {
        NSDictionary *r = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *vid = [r isKindOfClass:[NSDictionary class]] ? r[@"videoId"] : nil;
        NSString *challenge = [r isKindOfClass:[NSDictionary class]] ? r[@"responseContext"][@"webResponseContextExtensionData"][@"challenge"][@"type"] : nil;
        NSLog(@"[TRCapture] createvideo: attempt=%d http=%ld videoId=%@ challenge=%@ err=%@", attempt, (long)code, vid, challenge, err);
        if (!vid && !challenge && data) NSLog(@"[TRCapture] createvideo body: %@", [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!(challenge && attempt < 2)) objc_setAssociatedObject(video, "trBusy", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (vid) {
                @try { [meta setVideoID:vid]; } @catch (NSException *e) {}
                objc_setAssociatedObject(video, "trScotty", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(me, "trCreated", @"1", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [me uploadSucceeded];
                [me release];
            } else if (challenge && attempt < 2) {
                TRStudioReauth(^(BOOL ok) {
                    if (ok) TRCreateVideo(me, scotty, attempt + 1);
                    else { objc_setAssociatedObject(video, "trBusy", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [me uploadFailedWithError:[NSError errorWithDomain:@"TRCapture" code:401 userInfo:nil] responseData:nil]; }
                    [me release];
                });
            } else {
                [me uploadFailedWithError:(err ?: [NSError errorWithDomain:@"TRCapture" code:code userInfo:nil]) responseData:data];
                [me release];
            }
        });
    });
}

%hook KUUploader

-(void)upload { NSLog(@"[TRCapture] -upload"); %orig; }
-(void)beginUpload { NSLog(@"[TRCapture] -beginUpload"); %orig; }
-(void)prepareUpload { NSLog(@"[TRCapture] -prepareUpload (transcodeState=%d)", [[self video] transcodeState]); %orig; }
-(void)assetFileReady { NSLog(@"[TRCapture] -assetFileReady"); %orig; }
-(void)startSendingBytes {
    NSLog(@"[TRCapture] -startSendingBytes url=%@ file=%@", [self valueForKey:@"uploadURL"], [[self video] transcodedVideoURL]);
    %orig;
}
-(void)uploadFailedWithError:(id)error responseData:(NSData*)data {
    NSLog(@"[TRCapture] uploadFailed error=%@ data=%@", error, data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil);
    %orig;
}

// replaces the GData resumable-session request
-(void)requestResumableURL {
    if (objc_getAssociatedObject([self video], "trBusy")) {
        NSLog(@"[TRCapture] createvideo/reauth already in flight, ignoring retry");
        return;
    }
    NSString *held = objc_getAssociatedObject([self video], "trScotty");
    if (held) {
        NSLog(@"[TRCapture] bytes already uploaded, retrying createvideo only");
        TRCreateVideo(self, held, 1);
        return;
    }
    id authn = [[%c(KUUserAuthenticator) sharedInstance] authentication];
    NSString *channelId = [authn respondsToSelector:@selector(channelID)] ? [authn channelID] : nil;
    NSLog(@"[TRCapture] starting studio upload session (channel %@)", channelId);

    CFUUIDRef u = CFUUIDCreate(NULL);
    NSString *uuid = [(NSString *)CFUUIDCreateString(NULL, u) autorelease];
    CFRelease(u);
    NSString *frontendId = [NSString stringWithFormat:@"innertube_studio:%@:0", uuid];
    objc_setAssociatedObject([self video], "trFrontendId", frontendId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://upload.youtube.com/upload/studio"]];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:[[NSString stringWithFormat:@"{\"frontendUploadId\":\"%@\"}", frontendId] dataUsingEncoding:NSUTF8StringEncoding]];
    [req setValue:@"start" forHTTPHeaderField:@"x-goog-upload-command"];
    [req setValue:uuid forHTTPHeaderField:@"x-goog-upload-file-name"];
    [req setValue:@"resumable" forHTTPHeaderField:@"x-goog-upload-protocol"];
    [req setValue:@"application/x-www-form-urlencoded;charset=utf-8" forHTTPHeaderField:@"Content-Type"];

    KUUploader *me = [self retain];
    TRStudioFetch(req, ^(NSData *data, NSDictionary *headers, NSInteger code, NSError *err) {
        NSString *url = nil;
        for (NSString *k in headers) if ([[k lowercaseString] isEqualToString:@"x-goog-upload-url"]) url = headers[k];
        NSLog(@"[TRCapture] session start: http=%ld url=%@ err=%@ body=%@", (long)code, url, err,
              data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (url) {
                [me setValue:[NSURL URLWithString:url] forKey:@"uploadURL"];
                [me startSendingBytes];
            } else {
                [me uploadFailedWithError:(err ?: [NSError errorWithDomain:@"TRCapture" code:code userInfo:nil]) responseData:data];
            }
            [me release];
        });
    });
}

// bytes are done: tell YouTube to turn the scotty resource into a video
-(void)uploadSucceeded {
    if (objc_getAssociatedObject(self, "trCreated")) { %orig; return; }

    id fetcher = [self valueForKey:@"uploadFetcher"];
    NSData *resp = objc_getAssociatedObject(fetcher, "trFinalData");
    NSDictionary *j = resp ? [NSJSONSerialization JSONObjectWithData:resp options:0 error:nil] : nil;
    NSString *scotty = [j isKindOfClass:[NSDictionary class]] ? j[@"scottyResourceId"] : nil;
    NSLog(@"[TRCapture] upload bytes done, scotty present=%d", scotty != nil);
    if (!scotty) { %orig; return; }
    objc_setAssociatedObject([self video], "trScotty", scotty, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    TRCreateVideo(self, scotty, 0);
}

%end

// -[GTMHTTPUploadFetcher beginFetchWithDelegate:didFinishSelector:] fuckin confuses me. WHY ARE YOU PASSING -1???
%hook GTMHTTPUploadFetcher
- (void)uploadNextChunkWithOffset:(unsigned int)offset fetcherProperties:(NSDictionary *)properties {
    //         void *callstack[128];
	// int frames = backtrace(callstack, 128);
	// char **symbols = backtrace_symbols(callstack, frames);
	// NSMutableString *callstackString = [NSMutableString stringWithFormat:@"uploadNextChunkWithOffset"];
	// for (int i = 0; i < frames; i++) {
	// 	[callstackString appendFormat:@"%s\n", symbols[i]];
	// }
	// NSLog(@"%@", callstackString);


    NSUInteger chunkSize = [self chunkSize];
    NSUInteger fullUploadLength = [self fullUploadLength];
    
    NSData *chunkData = nil;
    NSString *contentLengthHeader = nil;
    NSLog(@"offset -> %i", offset);

    BOOL isFinalTransaction = false;
    if (offset == -1) {
        offset = 0;
    }
    
    NSUInteger remainingLength = fullUploadLength - offset;
    NSUInteger currentChunkSize = chunkSize;
    
    if ((offset + currentChunkSize > fullUploadLength) || (remainingLength < currentChunkSize + 2500)) {
        currentChunkSize = remainingLength;
        isFinalTransaction = YES;
    }
    
    chunkData = [self uploadSubdataWithOffset:offset length:currentChunkSize];
                            
    contentLengthHeader = [NSString stringWithFormat:@"%llu", (unsigned long long)currentChunkSize];
    
    NSLog(@"offset to calculate: %i", offset);

    [self setCurrentOffset:offset];

    NSURL *locationURL = [self locationURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:locationURL];
    [request setHTTPMethod:@"POST"];
    
    NSString *userAgent = [[self mutableRequest] valueForHTTPHeaderField:@"User-Agent"];
    if ([userAgent length] > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
    
    [request setValue:contentLengthHeader forHTTPHeaderField:@"Content-Length"];

    // additional headers YIPEEE
    [request setValue:@"application/x-www-form-urlencoded;charset=utf-8" forHTTPHeaderField:@"content-type"];
    [request setValue:@"upload" forHTTPHeaderField:@"x-goog-upload-command"];
    if (isFinalTransaction) {
        [request setValue:@"upload, finalize" forHTTPHeaderField:@"x-goog-upload-command"];
    }
    [request setValue:@"file" forHTTPHeaderField:@"x-goog-upload-file-name"]; // well
    [request setValue:[NSString stringWithFormat:@"%i", offset] forHTTPHeaderField:@"x-goog-upload-offset"];
    [request setValue:@"https://studio.youtube.com/" forHTTPHeaderField:@"Referer"];
    
    GTMHTTPFetcher *chunkFetcher = [%c(GTMHTTPFetcher) fetcherWithRequest:request];
    [chunkFetcher setDelegateQueue:[self delegateQueue]];
    [chunkFetcher setRunLoopModes:[self runLoopModes]];
    
    [chunkFetcher setProperties:properties];
    [chunkFetcher setPostData:chunkData];
    [chunkFetcher setRetryEnabled:[self isRetryEnabled]];
    [chunkFetcher setMaxRetryInterval:[self maxRetryInterval]];
    [chunkFetcher setSentDataSelector:[self sentDataSelector]];
    [chunkFetcher setCookieStorageMethod:[self cookieStorageMethod]];
    NSLog(@"done???? request -> %@", request);
    
    if ([self isRetryEnabled]) {
        [chunkFetcher setRetrySelector:@selector(chunkFetcher:willRetry:forError:)];
    }
    
    [self setMutableRequest:request];
    
    BOOL success = [chunkFetcher beginFetchWithDelegate:self 
                                      didFinishSelector:@selector(chunkFetcher:finishedWithData:error:)];
    if (success) {
        NSLog(@"a good occured");
        [self setChunkFetcher:chunkFetcher];
    } 
    else {
        NSLog(@"a bad occured");
        NSError *error = [NSError errorWithDomain:@"com.google.GTMHTTPFetcher"
                                             code:-3 
                                         userInfo:nil];
                                         
        [self invokeFinalCallbacksWithData:nil 
                                     error:error 
                  shouldInvalidateLocation:YES];
                  
        [self destroyChunkFetcher];
    }
}

-(void)chunkFetcher:(GTMHTTPFetcher*)fetcher finishedWithData:(NSData*)data error:(NSError*)error
{
    NSLog(@"chunk fetcher done");
    int statusCode = [fetcher statusCode];
    [self setStatusCode:statusCode];
    NSDictionary *responseHeaders = [fetcher responseHeaders];
    [self setResponseHeaders:responseHeaders];

    NSLog(@"error -> %@", error);

    if ([[responseHeaders valueForKey:@"X-Goog-Upload-Status"] isEqualToString:@"active"]) {
        NSLog(@"is active");

        NSUInteger chunkSize = [self chunkSize];
        NSUInteger fullUploadLength = [self fullUploadLength];
        NSUInteger offset = [self currentOffset];

        if (offset == -1) {
            offset = 0;
        }
        
        NSUInteger remainingLength = fullUploadLength - offset;
        NSUInteger currentChunkSize = chunkSize;
        
        if ((offset + currentChunkSize > fullUploadLength) || (remainingLength < currentChunkSize + 2500)) {
            currentChunkSize = remainingLength;
        }

        [self setCurrentOffset:offset + currentChunkSize];

        if ([self valueForKey:@"needsManualProgress_"]) // who knows if this will work?
            [self reportProgressManually];


        NSLog(@"location url -> %@", [self locationURL]);
        id properties = [[fetcher properties] retain];
        // NSURL *prevURL = [[[fetcher mutableRequest] URL] retain];
        [self destroyChunkFetcher];
        [self uploadNextChunkWithOffset:[self currentOffset] fetcherProperties:properties];

        // NSError *error = [NSError errorWithDomain:@"com.google.GTMHTTPFetcher"
        //                     code:308 userInfo:nil];

        // [self invokeFinalCallbacksWithData:data error:nil shouldInvalidateLocation:NO];
    } else {
        NSLog(@"is not active, status %i, %lu bytes", statusCode, (unsigned long)[data length]);
        if (data) objc_setAssociatedObject(self, "trFinalData", data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return %orig;
    }
    


    // [self destroyChunkFetcher];
}
%end


// todo: look at -[GTMHTTPUploadFetcher chunkFetcher:finishedWithData:error:](, since it expects cod 308, when we get 200 when we finish a chunk.