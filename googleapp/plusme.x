// The upload flow asks Google+ for the account's profile (…/plus/v2whitelisted/people/me) to get the channel info.
// Google+ is gone, the error comes back unparsed and the app crashes. Answer it locally with the YouTube identity.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

extern NSString *gTRProfileName, *gTRProfilePhoto, *gTRProfileHandle;

@interface TRPlusMeProtocol : NSURLProtocol
@end

@implementation TRPlusMeProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *p = [[request URL] path];
    return [p rangeOfString:@"/plus/v2whitelisted/people/me"].location != NSNotFound && [p hasSuffix:@"people/me"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *name = [gTRProfileName length] ? gTRProfileName : [ud stringForKey:@"TRIdName"];
    NSString *photo = [gTRProfilePhoto length] ? gTRProfilePhoto : [ud stringForKey:@"TRIdPhoto"];
    NSString *chan = [ud stringForKey:@"TRIdChannel"] ?: @"0";
    if (![name length]) name = @"YouTube";
    NSMutableDictionary *person = [NSMutableDictionary dictionaryWithDictionary:@{
        @"kind": @"plus#person", @"etag": @"\"0\"", @"id": chan, @"objectType": @"person", @"displayName": name,
        @"name": @{ @"formatted": name, @"givenName": name, @"familyName": @"" },
        @"url": [@"https://www.youtube.com/channel/" stringByAppendingString:chan],
        @"isPlusUser": @NO, @"verified": @NO }];
    if ([photo length]) person[@"image"] = @{ @"url": photo };
    NSData *d = [NSJSONSerialization dataWithJSONObject:person options:0 error:nil] ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *resp = [[[NSHTTPURLResponse alloc] initWithURL:[[self request] URL] statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{ @"Content-Type": @"application/json; charset=UTF-8", @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)[d length]] }] autorelease];
    NSLog(@"[TubeReplacer] plus people/me answered locally: %@", name);
    [[self client] URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [[self client] URLProtocol:self didLoadData:d];
    [[self client] URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end


static NSDictionary *TRPlusPersonDict(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *name = [gTRProfileName length] ? gTRProfileName : [ud stringForKey:@"TRIdName"];
    NSString *photo = [gTRProfilePhoto length] ? gTRProfilePhoto : [ud stringForKey:@"TRIdPhoto"];
    NSString *chan = [ud stringForKey:@"TRIdChannel"] ?: @"0";
    if (![name length]) name = @"YouTube";
    NSMutableDictionary *person = [NSMutableDictionary dictionaryWithDictionary:@{
        @"kind": @"plus#person", @"etag": @"\"0\"", @"id": chan, @"objectType": @"person", @"displayName": name,
        @"name": @{ @"formatted": name, @"givenName": name, @"familyName": @"" },
        @"url": [@"https://www.youtube.com/channel/" stringByAppendingString:chan],
        @"isPlusUser": @NO, @"verified": @NO }];
    if ([photo length]) person[@"image"] = @{ @"url": photo };
    return person;
}

// The Google sign-in framework fetches the profile (name, picture) from Google+ for the upload flow; that service is gone.
// Answer its request with the YouTube identity so the "could not load channel information" error (and the crash after it) cannot happen.
%hook SSOProfileSource
- (void)requestProfileForIdentity:(id)identity callback:(void (^)(id profile, NSError *error))callback {
    NSDictionary *p = TRPlusPersonDict();
    NSLog(@"[TubeReplacer] SSO profile request answered locally: %@", p[@"displayName"]);
    if (!callback) return;
    void (^cb)(id, NSError *) = [[callback copy] autorelease];
    dispatch_async(dispatch_get_main_queue(), ^{ cb(p, nil); });
}
%end

// sessions with their own configuration only use the protocols listed there
%hook NSURLSessionConfiguration
+ (id)defaultSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    NSMutableArray *p = [NSMutableArray arrayWithObject:[TRPlusMeProtocol class]];
    [p addObjectsFromArray:[c protocolClasses] ?: @[]];
    [c setProtocolClasses:p];
    return c;
}
+ (id)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    NSMutableArray *p = [NSMutableArray arrayWithObject:[TRPlusMeProtocol class]];
    [p addObjectsFromArray:[c protocolClasses] ?: @[]];
    [c setProtocolClasses:p];
    return c;
}
%end

%ctor {
    [NSURLProtocol registerClass:[TRPlusMeProtocol class]];
}

// "Invalid video – asset not readable": the editors refuse an asset whose isReadable is NO. On these devices the flag comes back NO
// for assets the app can in fact play, so accept anything playable or with tracks (the full editor and the lightweight one).
static BOOL TRAssetAcceptable(id asset, BOOL *decided) {
    *decided = NO;
    if (!asset) return NO;
    BOOL ok = NO;
    @try { ok = [asset respondsToSelector:@selector(isReadable)] ? [(AVAsset *)asset isReadable] : NO; } @catch (NSException *e) {}
    if (ok) return NO;
    BOOL playable = NO; NSUInteger tracks = 0;
    @try { if ([asset respondsToSelector:@selector(isPlayable)]) playable = [(AVAsset *)asset isPlayable]; } @catch (NSException *e) {}
    @try { if ([asset respondsToSelector:@selector(tracks)]) tracks = [[(AVAsset *)asset tracks] count]; } @catch (NSException *e) {}
    NSString *u = [asset isKindOfClass:[AVURLAsset class]] ? [[(AVURLAsset *)asset URL] absoluteString] : @"";
    NSLog(@"[TubeReplacer] upload: asset %@ %@ reports not readable (playable=%d tracks=%lu)%@", NSStringFromClass([asset class]), u, playable, (unsigned long)tracks, (playable || tracks) ? @", accepting it" : @"");
    *decided = YES;
    return playable || tracks;
}
%hook YTEditVideoViewController
- (BOOL)assetIsValid:(id)asset {
    BOOL decided; BOOL r = TRAssetAcceptable(asset, &decided);
    return decided && r ? YES : %orig;
}
%end
%hook YTEditLightweightVideoViewController
- (BOOL)assetIsValid:(id)asset {
    BOOL decided; BOOL r = TRAssetAcceptable(asset, &decided);
    return decided && r ? YES : %orig;
}
%end
