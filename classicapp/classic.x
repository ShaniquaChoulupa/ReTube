// classic.x
// TubeReplacer - classic (Apple / "Invoxi") YouTube app support
//
// The classic app's UI sits on top of the private YouTube.framework, which fetches
// GData v2 Atom feeds (dead since 2015). Every list of videos in the app comes out
// of a YTSearchRequest (a YTFeedRequest -> YTXMLHTTPRequest -> XMLSAXHTTPRequest).
//
// Instead of emulating Atom XML we let the framework's own machinery run (so
// loading state, spinners, errors and delegate callbacks all behave natively),
// but:
//   1. point the request at an InnerTube endpoint (see -tr_load...),
//   2. replace -[YTFeedRequest parseData:] so the JSON response is turned into
//      YTVideo objects instead of being fed to the XML parser.
//
// Playback URLs are resolved lazily when the player asks for them.

#import <Foundation/Foundation.h>
#import "trlog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "appheaders.h"
#import "TRRequestBuilder.h"
#import "TRJSONUtils.h"
#import "common/YoutubeClientType.h"
#import "classicauth.h"

static NSString *const kTRCResolveHost = @"tr-resolve.invalid";
static const char kTRCInfoKey;

#pragma mark - Small helpers

static NSDictionary *TRCPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/dev.preloading.tubereplacer.preferences.plist"];
}

static NSMutableDictionary *TRCTokens(void) {
    static NSMutableDictionary *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[NSMutableDictionary alloc] init]; });
    return t;
}

static NSMutableDictionary *TRCStreamCache(void) {
    static NSMutableDictionary *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[NSMutableDictionary alloc] init]; });
    return t;
}

static NSMutableURLRequest *TRCMakeRequest(NSString *endpoint, NSData *body, YoutubeClientType *client, BOOL noauth) {
    NSString *u = [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/%@?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false%@",
                   endpoint, noauth ? @"&noauth=1" : @""];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:30.0];
    [r setHTTPMethod:@"POST"];
    [r setHTTPBody:body];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if ([client.useragent length]) [r setValue:client.useragent forHTTPHeaderField:@"User-Agent"];
    return r;
}

// "1,234 views" / "1.2M views" / "35K" -> number
static unsigned int TRCParseCount(NSString *s) {
    if (![s length]) return 0;
    NSString *t = [[s lowercaseString] stringByReplacingOccurrencesOfString:@"views" withString:@""];
    t = [t stringByReplacingOccurrencesOfString:@"view" withString:@""];
    t = [t stringByReplacingOccurrencesOfString:@"," withString:@""];
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    double mult = 1;
    if ([t hasSuffix:@"k"]) mult = 1e3; else if ([t hasSuffix:@"m"]) mult = 1e6; else if ([t hasSuffix:@"b"]) mult = 1e9;
    if (mult != 1) t = [t substringToIndex:[t length] - 1];
    double v = [t doubleValue] * mult;
    if (v < 0) v = 0;
    if (v > 4294967295.0) v = 4294967295.0;
    return (unsigned int)v;
}

#pragma mark - JSON -> video dictionaries

static NSString *TRCFirstString(NSDictionary *d, NSArray *paths) {
    for (NSString *p in paths) {
        NSString *s = [TRJSONUtils stringFromJSON:d keyPath:p];
        if ([s length]) return s;
    }
    return nil;
}

static NSDictionary *TRCParseItem(NSString *type, NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    if (d[@"upcomingEventData"]) return nil; // scheduled / not playable yet

    BOOL lockup = [type isEqualToString:@"lockupViewModel"];
    BOOL tile = [type isEqualToString:@"tileRenderer"];
    BOOL plist = [type isEqualToString:@"playlistVideoRenderer"];
    NSString *vid = lockup ? d[@"contentId"] : d[@"videoId"];
    if (tile) vid = [TRJSONUtils stringFromJSON:d keyPath:@"onSelectCommand.watchEndpoint.videoId"];
    if (![vid isKindOfClass:[NSString class]] || [vid length] != 11) return nil;

    NSString *title, *author, *durationText, *label, *viewText;
    if (tile) {
        // TV (TVHTML5) layout, as used by the authenticated feeds (same paths as Lincoln)
        NSString *lines = @"metadata.tileMetadataRenderer.lines";
        title = TRCFirstString(d, @[@"metadata.tileMetadataRenderer.title.simpleText"]);
        author = TRCFirstString(d, @[[lines stringByAppendingString:@"[0].lineRenderer.items[0].lineItemRenderer.text.simpleText"]]);
        durationText = TRCFirstString(d, @[@"header.tileHeaderRenderer.thumbnailOverlays[0].thumbnailOverlayTimeStatusRenderer.text.simpleText"]);
        label = TRCFirstString(d, @[[lines stringByAppendingString:@"[1].lineRenderer.items[0].lineItemRenderer.text.accessibility.accessibilityData.label"]]);
        viewText = TRCFirstString(d, @[[lines stringByAppendingString:@"[1].lineRenderer.items[0].lineItemRenderer.text.simpleText"]]);
    } else if (plist) {
        title = TRCFirstString(d, @[@"title.runs[0].text", @"title.simpleText"]);
        author = TRCFirstString(d, @[@"shortBylineText.runs[0].text", @"longBylineText.runs[0].text"]);
        durationText = TRCFirstString(d, @[@"lengthText.simpleText", @"lengthText.runs[0].text"]);
        label = TRCFirstString(d, @[@"title.accessibility.accessibilityData.label"]);
        viewText = TRCFirstString(d, @[@"videoInfo.runs[0].text"]);
        if (![durationText length] && [d[@"lengthSeconds"] length]) {
            long s = [d[@"lengthSeconds"] longLongValue];
            durationText = [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
        }
    } else if (lockup) {
        NSString *base = @"metadata.lockupMetadataViewModel.metadata.contentMetadataViewModel.metadataRows";
        title = TRCFirstString(d, @[@"metadata.lockupMetadataViewModel.title.content"]);
        author = TRCFirstString(d, @[[base stringByAppendingString:@"[0].metadataParts[0].text.content"]]);
        durationText = TRCFirstString(d, @[
            @"contentImage.thumbnailViewModel.overlays[0].thumbnailOverlayBadgeViewModel.thumbnailBadges[0].thumbnailBadgeViewModel.text",
            @"contentImage.thumbnailViewModel.overlays[0].thumbnailBottomOverlayViewModel.badges[0].thumbnailBadgeViewModel.text"]);
        label = TRCFirstString(d, @[@"rendererContext.accessibilityContext.label"]);
        viewText = TRCFirstString(d, @[[base stringByAppendingString:@"[0].metadataParts[1].text.content"]]);
    } else {
        BOOL ctx = [type isEqualToString:@"videoWithContextRenderer"];
        title = TRCFirstString(d, ctx ? @[@"headline.runs[0].text", @"headline.simpleText"]
                                      : @[@"title.runs[0].text", @"title.simpleText"]);
        author = TRCFirstString(d, @[@"shortBylineText.runs[0].text", @"longBylineText.runs[0].text", @"ownerText.runs[0].text"]);
        durationText = TRCFirstString(d, @[@"lengthText.runs[0].text", @"lengthText.simpleText"]);
        label = TRCFirstString(d, ctx ? @[@"headline.accessibility.accessibilityData.label"]
                                      : @[@"title.accessibility.accessibilityData.label"]);
        viewText = TRCFirstString(d, @[@"viewCountText.simpleText", @"viewCountText.runs[0].text",
                                       @"shortViewCountText.simpleText", @"shortViewCountText.runs[0].text"]);
    }
    if (![title length] || [title isEqualToString:@"[Deleted video]"]) return nil;

    // The accessibility label is "<title> by <author> 35,908 views 5 days ago 4 minutes, 20 seconds"
    unsigned int views = 0;
    NSDate *date = nil;
    if ([label length]) {
        NSArray *parts = [label componentsSeparatedByString:@" "];
        for (NSUInteger i = 1; i < [parts count]; i++) {
            if ([[parts[i] lowercaseString] isEqualToString:@"views"]) {
                views = TRCParseCount(parts[i - 1]);
                NSMutableString *when = [NSMutableString string];
                for (NSUInteger j = i + 1; j < [parts count]; j++) {
                    NSString *p = [parts[j] stringByReplacingOccurrencesOfString:@"," withString:@""];
                    [when appendFormat:@"%@ ", p];
                    if ([[p lowercaseString] isEqualToString:@"ago"]) break;
                }
                if ([when hasSuffix:@"ago "]) {
                    date = [TRJSONUtils dateFromTimeAgo:[when stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
                }
                break;
            }
        }
    }
    if (!views && [viewText length]) views = TRCParseCount(viewText);

    long dur = [durationText length] ? [TRJSONUtils secondsFromDurationText:durationText] : 0;
    if (dur < 0) dur = 0;

    return @{ @"id": vid, @"title": title, @"author": author ?: @"", @"views": @(views),
              @"duration": @(dur), @"date": date ?: [NSDate date] };
}

static void TRCCollect(id node, NSMutableArray *out, NSMutableSet *seen) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) TRCCollect(v, out, seen);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *d = node;
    static NSArray *keys = nil;
    if (!keys) keys = [@[@"videoWithContextRenderer", @"compactVideoRenderer", @"videoRenderer", @"gridVideoRenderer",
                         @"playlistVideoRenderer", @"tileRenderer"] retain];
    for (NSString *k in keys) {
        if ([d[k] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *item = TRCParseItem(k, d[k]);
            if (item && ![seen containsObject:item[@"id"]]) { [seen addObject:item[@"id"]]; [out addObject:item]; }
            return;
        }
    }
    if ([d[@"contentType"] isEqual:@"LOCKUP_CONTENT_TYPE_VIDEO"] && d[@"contentId"]) {
        NSDictionary *item = TRCParseItem(@"lockupViewModel", d);
        if (item && ![seen containsObject:item[@"id"]]) { [seen addObject:item[@"id"]]; [out addObject:item]; }
        return;
    }
    for (id v in [d allValues]) TRCCollect(v, out, seen);
}

static NSString *TRCFindContinuation(id node) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) { NSString *t = TRCFindContinuation(v); if (t) return t; }
    } else if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *cc = node[@"continuationCommand"];
        if ([cc isKindOfClass:[NSDictionary class]] && [cc[@"token"] isKindOfClass:[NSString class]]) return cc[@"token"];
        NSDictionary *nc = node[@"nextContinuationData"]; // TV layout
        if ([nc isKindOfClass:[NSDictionary class]] && [nc[@"continuation"] isKindOfClass:[NSString class]]) return nc[@"continuation"];
        for (id v in [node allValues]) { NSString *t = TRCFindContinuation(v); if (t) return t; }
    }
    return nil;
}

#pragma mark - Building YTVideo

static NSArray *TRCReferences(NSURL *url, unsigned int duration) {
    // We don't know what the framework's "profile" numbers map to, so offer the
    // same URL under each of them; whichever one it asks for resolves.
    Class refClass = NSClassFromString(@"YTVideoReference");
    NSMutableArray *refs = [NSMutableArray array];
    for (int profile = 0; profile <= 7; profile++) {
        id ref = [[[refClass alloc] initWithContentURL:url duration:duration profile:profile] autorelease];
        if (ref) [refs addObject:ref];
    }
    return refs;
}

static id TRCMakeVideo(NSString *vid, NSString *title, NSString *author, unsigned int views,
                       unsigned int duration, NSDate *date, NSString *desc, NSURL *streamURL) {
    NSURL *content = streamURL ?: [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/%@", kTRCResolveHost, vid]];
    NSURL *thumb = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", vid]];
    NSURL *info = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@", vid]];
    YTVideo *v = [[NSClassFromString(@"YTVideo") alloc] initWithID:vid
                                                             title:title
                                                       dateUpdated:date
                                                         dateAdded:date
                                                   videoReferences:TRCReferences(content, duration)
                                                           infoURL:info
                                                  videoDescription:desc ?: @""
                                                          category:@""
                                                              tags:@[]
                                                            author:author
                                                      thumbnailURL:thumb
                                                          numLikes:0
                                                       numDislikes:0
                                                     numberOfViews:views
                                                       batchStatus:0
                                                       commentsURL:nil
                                                           editURL:nil
                                                        ratingsURL:nil
                                                       captionsURL:nil
                                                           shortID:vid
                                                        unplayable:nil
                                                      isProcessing:NO
                                                           privacy:0
                                               restrictedCountries:nil];
    return [v autorelease];
}

#pragma mark - Stream URL resolution

// Pick a progressive MP4 (H.264/AAC) from a player response, falling back to HLS.
static NSURL *TRCStreamFromPlayer(NSDictionary *json) {
    NSArray *formats = [TRJSONUtils arrayFromJSON:json keyPath:@"streamingData.formats"];
    NSString *best = nil;
    for (NSDictionary *f in formats) {
        NSString *url = f[@"url"];
        NSString *mime = f[@"mimeType"];
        if (![url length] || ![mime hasPrefix:@"video/mp4"]) continue;
        if ([mime rangeOfString:@"avc1"].location == NSNotFound) continue;
        if ([[f[@"itag"] description] isEqualToString:@"18"]) { best = url; break; }
        if (!best) best = url;
    }
    if (!best) best = [TRJSONUtils stringFromJSON:json keyPath:@"streamingData.hlsManifestUrl"];
    return best ? [NSURL URLWithString:best] : nil;
}

static NSDictionary *TRCSyncPlayerRequest(NSString *vid, YoutubeClientType *client) {
    NSData *body = [TRRequestBuilder playerBodyWithVideoId:vid poToken:nil signatureTimestamp:nil client:client];
    NSMutableURLRequest *req = TRCMakeRequest(@"player", body, client, YES);
    [req setTimeoutInterval:15.0];
    NSURLResponse *resp = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    if (!data) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

static NSMutableDictionary *TRCFailures(void) {
    static NSMutableDictionary *t = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[NSMutableDictionary alloc] init]; });
    return t;
}

static NSURL *TRCResolveStream(NSString *vid) {
    if (![vid length]) return nil;
    @synchronized (TRCStreamCache()) {
        NSURL *cached = TRCStreamCache()[vid];
        if (cached) return cached;
        // Don't re-block the UI on every access after a failure.
        NSDate *failedAt = TRCFailures()[vid];
        if (failedAt && -[failedAt timeIntervalSinceNow] < 30.0) return nil;
    }
    NSLog(@"[TubeReplacerClassic] resolving stream for %@", vid);

    NSDictionary *prefs = TRCPrefs();
    NSString *type = prefs[@"StreamType"];
    NSURL *url = nil;
    if ([type isEqualToString:@"tuberepair"]) {
        url = [NSURL URLWithString:[@"https://tuberepair.uptimetrackers.com/getvideo/" stringByAppendingString:vid]];
    } else if ([type isEqualToString:@"custom"] && [prefs[@"CustomStreamURL"] length]) {
        url = [NSURL URLWithString:[prefs[@"CustomStreamURL"] stringByReplacingOccurrencesOfString:@"%v" withString:vid]];
    } else {
        // Clients that hand out plain (non-ciphered) URLs.
        NSArray *clients = @[[YoutubeClientType androidVrClient], [YoutubeClientType iosClient]];
        for (YoutubeClientType *c in clients) {
            NSDictionary *json = TRCSyncPlayerRequest(vid, c);
            if (json) url = TRCStreamFromPlayer(json);
            if (url) break;
        }
    }
    if (url) {
        NSLog(@"[TubeReplacerClassic] stream for %@ -> %@", vid, url);
        @synchronized (TRCStreamCache()) { TRCStreamCache()[vid] = url; [TRCFailures() removeObjectForKey:vid]; }
    } else {
        NSLog(@"[TubeReplacerClassic] could NOT resolve a playable stream for %@", vid);
        @synchronized (TRCStreamCache()) { TRCFailures()[vid] = [NSDate date]; }
    }
    return url;
}

%hook YTVideoReference

- (NSURL *)contentURL {
    NSURL *u = %orig;
    if ([[u host] isEqualToString:kTRCResolveHost]) {
        NSURL *real = TRCResolveStream([u lastPathComponent]);
        if (real) return real;
    }
    return u;
}

%end

// The framework asks for a reference by "profile" (quality tier). We offer the same
// stream for every tier, but never let a lookup come back empty.
%hook YTVideo

- (id)bestVideoReference {
    id r = %orig;
    if (r) return r;
    return [self anyVideoReference];
}

- (id)videoReferenceForProfile:(int)profile {
    id r = %orig;
    if (r) return r;
    NSArray *refs = [self valueForKey:@"_videoReferences"];
    return [refs count] ? refs[0] : nil;
}

%end


#pragma mark - Account lists (subscriptions / playlists) served as Atom to the framework's own parser

static NSString *TRCXML(NSString *s) {
    if (!s) return @"";
    s = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    s = [s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    s = [s stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    return [s stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
}

static NSDictionary *TRCSyncGET(NSString *url, NSString *token) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
    [r setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    NSHTTPURLResponse *resp = nil; NSError *err = nil;
    NSData *d = [NSURLConnection sendSynchronousRequest:r returningResponse:&resp error:&err];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSLog(@"[TubeReplacerClassic] GET %@ -> %ld, %lu bytes err=%@", url, (long)[resp statusCode], (unsigned long)[d length], err);
    return [j isKindOfClass:[NSDictionary class]] && [resp statusCode] < 400 ? j : nil;
}

static NSString *TRCThumb(NSDictionary *snippet) {
    NSDictionary *th = snippet[@"thumbnails"];
    return th[@"high"][@"url"] ?: th[@"medium"][@"url"] ?: th[@"default"][@"url"] ?: @"http://www.youtube.com/img/pic_youtubelogo_123x63.gif";
}

static NSString *TRCAtomHeader(NSString *kind, NSString *title, NSUInteger count) {
    return [NSString stringWithFormat:
        @"<?xml version='1.0' encoding='UTF-8'?><feed xmlns='http://www.w3.org/2005/Atom' xmlns:media='http://search.yahoo.com/mrss/' "
        @"xmlns:openSearch='http://a9.com/-/spec/opensearchrss/1.0/' xmlns:gd='http://schemas.google.com/g/2005' xmlns:yt='http://gdata.youtube.com/schemas/2007'>"
        @"<id>http://gdata.youtube.com/feeds/api/users/default/%@</id><updated>2014-01-01T00:00:00.000Z</updated>"
        @"<category scheme='http://schemas.google.com/g/2005#kind' term='http://gdata.youtube.com/schemas/2007#%@'/>"
        @"<title type='text'>%@</title><author><name>default</name><uri>http://gdata.youtube.com/feeds/api/users/default</uri></author>"
        @"<openSearch:totalResults>%lu</openSearch:totalResults><openSearch:startIndex>1</openSearch:startIndex><openSearch:itemsPerPage>%lu</openSearch:itemsPerPage>",
        kind, [kind isEqualToString:@"subscriptions"] ? @"subscription" : @"playlistLink", title, (unsigned long)count, (unsigned long)count];
}

static NSData *TRCSubscriptionsAtom(NSString *token) {
    NSDictionary *j = TRCSyncGET(@"https://www.googleapis.com/youtube/v3/subscriptions?part=snippet&mine=true&maxResults=50", token);
    NSArray *items = j[@"items"];
    if (!j) return nil;
    NSMutableString *x = [NSMutableString stringWithString:TRCAtomHeader(@"subscriptions", @"Subscriptions", [items count])];
    for (NSDictionary *it in items) {
        NSDictionary *sn = it[@"snippet"];
        NSString *cid = sn[@"resourceId"][@"channelId"] ?: @"unknown";
        NSString *title = TRCXML(sn[@"title"] ?: @"Untitled");
        NSString *sid = TRCXML(it[@"id"] ?: cid);
        [x appendFormat:
            @"<entry><id>tag:youtube.com,2008:user:default:subscription:%@</id><published>2014-01-01T00:00:00.000Z</published><updated>2014-01-01T00:00:00.000Z</updated>"
            @"<category scheme='http://schemas.google.com/g/2005#kind' term='http://gdata.youtube.com/schemas/2007#subscription'/>"
            @"<category scheme='http://gdata.youtube.com/schemas/2007/subscriptiontypes.cat' term='channel'/>"
            @"<title type='text'>%@</title>"
            @"<content type='application/atom+xml' src='http://gdata.youtube.com/feeds/api/users/%@/uploads'/>"
            @"<link rel='self' type='application/atom+xml' href='http://gdata.youtube.com/feeds/api/users/default/subscriptions/%@'/>"
            @"<link rel='edit' type='application/atom+xml' href='http://gdata.youtube.com/feeds/api/users/default/subscriptions/%@'/>"
            @"<author><name>%@</name><uri>http://gdata.youtube.com/feeds/api/users/%@</uri></author>"
            @"<gd:feedLink rel='http://gdata.youtube.com/schemas/2007#user.uploads' href='http://gdata.youtube.com/feeds/api/users/%@/uploads'/>"
            @"<media:group><media:thumbnail url='%@' height='88' width='88' yt:name='default'/></media:group>"
            @"<yt:username>%@</yt:username><yt:subscriptionType>channel</yt:subscriptionType></entry>",
            sid, title, cid, sid, sid, title, cid, cid, TRCXML(TRCThumb(sn)), title];
    }
    [x appendString:@"</feed>"];
    return [x dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *TRCPlaylistsAtom(NSString *token) {
    NSDictionary *j = TRCSyncGET(@"https://www.googleapis.com/youtube/v3/playlists?part=snippet,contentDetails&mine=true&maxResults=50", token);
    NSArray *items = j[@"items"];
    if (!j) return nil;
    NSMutableString *x = [NSMutableString stringWithString:TRCAtomHeader(@"playlists", @"Playlists", [items count])];
    for (NSDictionary *it in items) {
        NSDictionary *sn = it[@"snippet"];
        NSString *pid = TRCXML(it[@"id"] ?: @"");
        NSString *title = TRCXML(sn[@"title"] ?: @"Untitled");
        NSString *desc = TRCXML(sn[@"description"] ?: @"");
        [x appendFormat:
            @"<entry><id>http://gdata.youtube.com/feeds/api/users/default/playlists/%@</id><published>2014-01-01T00:00:00.000Z</published><updated>2014-01-01T00:00:00.000Z</updated>"
            @"<category scheme='http://schemas.google.com/g/2005#kind' term='http://gdata.youtube.com/schemas/2007#playlistLink'/>"
            @"<title type='text'>%@</title><content type='application/atom+xml' src='http://gdata.youtube.com/feeds/api/playlists/%@'/>"
            @"<link rel='alternate' type='text/html' href='http://gdata.youtube.com/feeds/api/playlists/%@'/>"
            @"<link rel='self' type='application/atom+xml' href='http://gdata.youtube.com/feeds/api/users/default/playlists/%@'/>"
            @"<link rel='edit' type='application/atom+xml' href='http://gdata.youtube.com/feeds/api/playlists/%@'/>"
            @"<author><name>%@</name><uri>http://gdata.youtube.com/feeds/api/users/default</uri></author>"
            @"<yt:description>%@</yt:description><summary>%@</summary>"
            @"<media:group><media:thumbnail url='%@' height='90' width='120' yt:name='default'/></media:group>"
            @"<yt:countHint>%@</yt:countHint><yt:playlistId>%@</yt:playlistId></entry>",
            pid, title, pid, pid, pid, pid, TRCXML(TRCAccountName()), desc, desc, TRCXML(TRCThumb(sn)),
            it[@"contentDetails"][@"itemCount"] ?: @0, pid];
    }
    [x appendString:@"</feed>"];
    return [x dataUsingEncoding:NSUTF8StringEncoding];
}

// Feed the framework's own XML parser, exactly as the connection would have.
static void TRCServeAccountList(id request, NSURLRequest *urlRequest) {
    NSString *path = [[urlRequest URL] path] ?: @"";
    BOOL playlists = [path rangeOfString:@"playlists"].location != NSNotFound;
    id req = [request retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *atom = nil;
        NSString *token = TRCValidAccessToken();
        if ([token length]) atom = playlists ? TRCPlaylistsAtom(token) : TRCSubscriptionsAtom(token);
        if (!atom) { // signed out or request refused: an empty (valid) feed
            NSString *empty = [NSString stringWithFormat:@"%@</feed>", TRCAtomHeader(playlists ? @"playlists" : @"subscriptions", playlists ? @"Playlists" : @"Subscriptions", 0)];
            atom = [empty dataUsingEncoding:NSUTF8StringEncoding];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                int rc = ((int (*)(id, SEL, id))objc_msgSend)(req, @selector(parseData:), atom);
                NSLog(@"[TubeReplacerClassic] account list (%@) parsed rc=%d", playlists ? @"playlists" : @"subscriptions", rc);
                if (rc == 0) ((void (*)(id, SEL))objc_msgSend)(req, @selector(didParseData));
                else ((void (*)(id, SEL, id))objc_msgSend)(req, @selector(failWithError:), [NSError errorWithDomain:@"TubeReplacer" code:rc userInfo:nil]);
            } @catch (NSException *e) { NSLog(@"[TubeReplacerClassic] account list threw %@", e); }
            [req release];
        });
    });
}

#pragma mark - Skip the (dead) device-auth deferral

// YTXMLHTTPRequest -loadRequest: parks the request until device/account
// authentication finishes. None of that can work any more, so go straight to the
// base class implementation that actually opens the connection.
%hook YTXMLHTTPRequest

- (void)loadRequest:(NSURLRequest *)request {
    if ([self isKindOfClass:NSClassFromString(@"YTSubscriptionsRequest")]) {
        TRCServeAccountList(self, request);
        return;
    }
    struct objc_super sup;
    sup.receiver = self;
    sup.super_class = NSClassFromString(@"XMLSAXHTTPRequest");
    ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&sup, @selector(loadRequest:), request);
}

%end

#pragma mark - Delegate plumbing

static void TRCDeliver(id request, id delegate, NSArray *videos, unsigned int start, unsigned int remaining) {
    SEL sel = NSSelectorFromString(@"searchRequest:receivedVideos:startIndex:videosRemaining:");
    if (![delegate respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, id, unsigned int, unsigned int))objc_msgSend)(delegate, sel, request, videos, start, remaining);
}

@interface YTSearchRequest (TRClassic)
- (void)tr_loadKind:(NSString *)kind key:(NSString *)key endpoint:(NSString *)endpoint body:(NSData *)body
             client:(YoutubeClientType *)client noauth:(BOOL)noauth startIndex:(unsigned int)start delegate:(id)delegate;
- (void)tr_startRequest:(NSMutableURLRequest *)req kind:(NSString *)kind key:(NSString *)key start:(unsigned int)start delegate:(id)delegate;
- (void)tr_loadTVBrowseId:(NSString *)browseId params:(NSString *)params key:(NSString *)key start:(unsigned int)start delegate:(id)delegate;
- (void)tr_deliverEmptyWithStart:(unsigned int)start delegate:(id)delegate;
- (void)tr_loadMyVideosStart:(unsigned int)start delegate:(id)delegate;
- (void)tr_loadWebBrowseId:(NSString *)browseId params:(NSString *)params key:(NSString *)key start:(unsigned int)start delegate:(id)delegate;
- (void)tr_standardFeedOfType:(NSString *)type start:(unsigned int)start delegate:(id)delegate;
- (void)tr_searchQuery:(NSString *)query key:(NSString *)key sortBy:(int)sortBy posted:(int)posted start:(unsigned int)start delegate:(id)delegate;
- (void)tr_standardFeedOfType:(NSString *)type timeQualifier:(NSString *)tq start:(unsigned int)start delegate:(id)delegate;
@end

%hook YTSearchRequest

%new
- (void)tr_deliverEmptyWithStart:(unsigned int)start delegate:(id)delegate {
    NSLog(@"[TubeReplacerClassic] unsupported/account feed -> empty list");
    id me = [self retain];
    id del = [delegate retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        TRCDeliver(me, del, @[], start, 0);
        [me release];
        [del release];
    });
}

%new
- (void)tr_startRequest:(NSMutableURLRequest *)req kind:(NSString *)kind key:(NSString *)key start:(unsigned int)start delegate:(id)delegate {
    NSDictionary *info = @{ @"kind": kind, @"key": key, @"start": @(start) };
    NSLog(@"[TubeReplacerClassic] request kind=%@ key=%@ start=%u", kind, key, start);
    objc_setAssociatedObject(self, &kTRCInfoKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self loadRequest:req withDelegate:delegate accountAuthRequired:NO];
}

%new
- (void)tr_loadKind:(NSString *)kind key:(NSString *)key endpoint:(NSString *)endpoint body:(NSData *)body
             client:(YoutubeClientType *)client noauth:(BOOL)noauth startIndex:(unsigned int)start delegate:(id)delegate {
    NSData *actualBody = body;
    if (start > 1 && ![kind isEqualToString:@"video"]) {
        NSString *token = nil;
        @synchronized (TRCTokens()) { token = TRCTokens()[key]; }
        if (!token) { [self tr_deliverEmptyWithStart:start delegate:delegate]; return; }
        actualBody = [TRRequestBuilder continueWithContext:token client:client];
    }
    [self tr_startRequest:TRCMakeRequest(endpoint, actualBody, client, noauth) kind:kind key:key start:start delegate:delegate];
}

// Authenticated browse (liked videos, watch later, subscriptions, ...) via the TV client.
%new
- (void)tr_loadTVBrowseId:(NSString *)browseId params:(NSString *)params key:(NSString *)key start:(unsigned int)start delegate:(id)delegate {
    if (!TRCSignedIn()) {
        NSLog(@"[TubeReplacerClassic] %@ needs sign-in -> empty list", key);
        [self tr_deliverEmptyWithStart:start delegate:delegate];
        return;
    }
    NSMutableURLRequest *req = nil;
    if (start > 1) {
        NSString *token = nil;
        @synchronized (TRCTokens()) { token = TRCTokens()[key]; }
        if (!token) { [self tr_deliverEmptyWithStart:start delegate:delegate]; return; }
        req = TRCMakeTVRequest(@"browse", @{ @"continuation": token }, nil);
    } else {
        req = TRCMakeTVRequest(@"browse", @{ @"browseId": browseId }, params);
    }
    if (!req) { [self tr_deliverEmptyWithStart:start delegate:delegate]; return; }
    [self tr_startRequest:req kind:@"list" key:key start:start delegate:delegate];
}

// Public browse (channel uploads, playlists) with the desktop client.
%new
- (void)tr_loadWebBrowseId:(NSString *)browseId params:(NSString *)params key:(NSString *)key start:(unsigned int)start delegate:(id)delegate {
    YoutubeClientType *c = [YoutubeClientType webClient];
    NSData *body = [TRRequestBuilder browseBodyWithId:browseId params:params client:c];
    [self tr_loadKind:@"list" key:key endpoint:@"browse" body:body client:c noauth:NO startIndex:start delegate:delegate];
}

// "My Videos": the signed-in account's uploads playlist.
%new
- (void)tr_loadMyVideosStart:(unsigned int)start delegate:(id)delegate {
    if (!TRCSignedIn()) { [self tr_deliverEmptyWithStart:start delegate:delegate]; return; }
    id me = [self retain]; id del = [delegate retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        static NSString *uploads = nil;
        if (!uploads) {
            NSString *token = TRCValidAccessToken();
            NSDictionary *j = [token length] ? TRCSyncGET(@"https://www.googleapis.com/youtube/v3/channels?part=contentDetails&mine=true", token) : nil;
            NSString *u = j[@"items"][0][@"contentDetails"][@"relatedPlaylists"][@"uploads"];
            if ([u length]) uploads = [u copy];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([uploads length]) [me tr_loadTVBrowseId:[@"VL" stringByAppendingString:uploads] params:nil key:@"acct:uploads" start:start delegate:del];
            else [me tr_deliverEmptyWithStart:start delegate:del];
            [me release]; [del release];
        });
    });
}

%new
- (void)tr_searchQuery:(NSString *)query key:(NSString *)key sortBy:(int)sortBy posted:(int)posted start:(unsigned int)start delegate:(id)delegate {
    YoutubeClientType *c = [YoutubeClientType webMobileClient];
    NSData *body = [TRRequestBuilder searchBodyWithQuery:query type:1 sortBy:sortBy duration:0 hasCC:NO posted:posted client:c];
    [self tr_loadKind:@"list" key:key endpoint:@"search" body:body client:c noauth:NO startIndex:start delegate:delegate];
}

// GData standardfeeds/<type>?time=<qualifier> -> InnerTube.
%new
- (void)tr_standardFeedOfType:(NSString *)type timeQualifier:(NSString *)tq start:(unsigned int)start delegate:(id)delegate {
    NSString *t = [type lowercaseString];
    NSString *q = [tq lowercaseString];
    int posted = 0; // all_time
    if ([q rangeOfString:@"today"].location != NSNotFound) posted = 2;
    else if ([q rangeOfString:@"week"].location != NSNotFound) posted = 3;
    else if ([q rangeOfString:@"month"].location != NSNotFound) posted = 4;

    // A broad query is needed to sort the whole catalogue (override with ClassicFeedQuery).
    NSString *query = TRCPrefs()[@"ClassicFeedQuery"];
    if (![query length]) query = @"the";

    if ([t hasPrefix:@"most_recent"] || [t hasPrefix:@"recently_added"] || [t isEqualToString:@"recent"]) {
        [self tr_searchQuery:query key:@"feed:recent" sortBy:2 posted:0 start:start delegate:delegate];
    } else if ([t hasPrefix:@"most_viewed"] || [t hasPrefix:@"most_popular"]) {
        [self tr_searchQuery:query key:[NSString stringWithFormat:@"feed:viewed:%d", posted] sortBy:3 posted:posted start:start delegate:delegate];
    } else if ([t hasPrefix:@"top_rated"] || [t hasPrefix:@"top_favorites"]) {
        [self tr_searchQuery:query key:[NSString stringWithFormat:@"feed:rated:%d", posted] sortBy:1 posted:posted start:start delegate:delegate];
    } else {
        // Featured and anything else: the curated "trending" playlist (same default as the Google app).
        NSString *browseId = TRCPrefs()[@"TrendingBrowseId"];
        if (![browseId length] || [browseId isEqualToString:@"VLPLbgMm37FwiYk"]) {
            // The old curated playlist is gone; "featured" = most viewed this week.
            [self tr_searchQuery:query key:@"feed:featured" sortBy:3 posted:3 start:start delegate:delegate];
            return;
        }
        YoutubeClientType *c = [YoutubeClientType webMobileClient];
        NSData *body = [TRRequestBuilder browseBodyWithId:browseId params:nil client:c];
        [self tr_loadKind:@"list" key:@"feed:trending" endpoint:@"browse" body:body client:c noauth:NO startIndex:start delegate:delegate];
    }
}

%new
- (void)tr_standardFeedOfType:(NSString *)type start:(unsigned int)start delegate:(id)delegate {
    [self tr_standardFeedOfType:type timeQualifier:nil start:start delegate:delegate];
}

- (void)searchForVideosMatchingString:(NSString *)q startingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate {
    [self tr_searchQuery:q ?: @"" key:[@"q:" stringByAppendingString:q ?: @""] sortBy:0 posted:0 start:start delegate:delegate];
}

- (void)searchForVideosByAuthor:(NSString *)author startingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate {
    [self tr_searchQuery:author ?: @"" key:[@"a:" stringByAppendingString:author ?: @""] sortBy:0 posted:0 start:start delegate:delegate];
}

- (void)searchForStandardFeedVideosOfType:(NSString *)type startIndex:(unsigned int)start maxResults:(unsigned int)max timeQualifier:(id)tq withDelegate:(id)delegate {
    NSLog(@"[TubeReplacerClassic] standard feed type=%@ time=%@ start=%u", type, tq, start);
    [self tr_standardFeedOfType:type timeQualifier:[tq description] start:start delegate:delegate];
}

- (void)searchForVideoWithID:(NSString *)videoID withDelegate:(id)delegate {
    YoutubeClientType *c = [YoutubeClientType androidVrClient];
    NSData *body = [TRRequestBuilder playerBodyWithVideoId:videoID poToken:nil signatureTimestamp:nil client:c];
    [self tr_loadKind:@"video" key:[@"v:" stringByAppendingString:videoID ?: @""] endpoint:@"player" body:body
               client:c noauth:YES startIndex:1 delegate:delegate];
}

- (void)searchForVideosRelatedToVideo:(id)video startingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate {
    NSString *vid = [video respondsToSelector:@selector(ID)] ? [video ID] : nil;
    if (![vid length]) { [self tr_deliverEmptyWithStart:start delegate:delegate]; return; }
    YoutubeClientType *c = [YoutubeClientType webMobileClient];
    NSData *body = [TRRequestBuilder nextBodyWithVideoId:vid client:c];
    [self tr_loadKind:@"list" key:[@"r:" stringByAppendingString:vid] endpoint:@"next" body:body
               client:c noauth:NO startIndex:start delegate:delegate];
}

// The generic entry point; other feed types funnel through here.
- (void)searchForVideosWithFeedURLBase:(id)base startingAtIndex:(unsigned int)start maxResults:(unsigned int)max
                     withTimeQualifier:(id)tq withFormatFilter:(BOOL)ff authenticationRequired:(BOOL)auth withDelegate:(id)delegate {
    NSString *s = [[base description] lowercaseString];
    NSLog(@"[TubeReplacerClassic] feed url=%@ time=%@ auth=%d start=%u", s, tq, auth, start);
    NSRange r = [s rangeOfString:@"standardfeeds/"];
    if (r.location != NSNotFound) {
        NSString *type = [s substringFromIndex:r.location + r.length];
        // standardfeeds/[<region>/]<feed>[_<category>]
        NSArray *parts = [type componentsSeparatedByString:@"/"];
        type = [parts lastObject];
        NSRange q = [type rangeOfString:@"?"];
        if (q.location != NSNotFound) type = [type substringToIndex:q.location];
        [self tr_standardFeedOfType:type timeQualifier:[tq description] start:start delegate:delegate];
    } else if ([s rangeOfString:@"newsubscriptionvideos"].location != NSNotFound || [s rangeOfString:@"subscriptions"].location != NSNotFound) {
        [self tr_loadTVBrowseId:@"FEsubscriptions" params:nil key:@"acct:subs" start:start delegate:delegate];
    } else if ([s rangeOfString:@"watch_history"].location != NSNotFound || [s rangeOfString:@"history"].location != NSNotFound) {
        [self tr_loadTVBrowseId:@"FEhistory" params:nil key:@"acct:history" start:start delegate:delegate];
    } else if ([s rangeOfString:@"recommendations"].location != NSNotFound) {
        [self tr_loadTVBrowseId:@"FEwhat_to_watch" params:nil key:@"acct:recs" start:start delegate:delegate];
    } else if ([s rangeOfString:@"favorites"].location != NSNotFound) {
        [self tr_loadTVBrowseId:@"VLLL" params:@"cAc%253D" key:@"acct:fav" start:start delegate:delegate];
    } else if ([s rangeOfString:@"watch_later"].location != NSNotFound || [s rangeOfString:@"watchlater"].location != NSNotFound) {
        [self tr_loadTVBrowseId:@"FEmy_youtube" params:@"cAc%253D" key:@"acct:wl" start:start delegate:delegate];
    } else if ([s rangeOfString:@"/uploads"].location != NSNotFound) {
        NSRange u = [s rangeOfString:@"users/"];
        NSString *who = @"default";
        if (u.location != NSNotFound) {
            NSString *rest = [s substringFromIndex:u.location + u.length];
            who = [[rest componentsSeparatedByString:@"/"] firstObject];
        }
        if ([who isEqualToString:@"default"]) [self tr_loadMyVideosStart:start delegate:delegate];
        else {
            // channel IDs are case sensitive; take them from the original string
            NSString *orig = [base description];
            NSRange uo = [orig rangeOfString:@"users/" options:NSCaseInsensitiveSearch];
            NSString *cid = uo.location != NSNotFound ? [[[orig substringFromIndex:uo.location + uo.length] componentsSeparatedByString:@"/"] firstObject] : who;
            [self tr_loadWebBrowseId:cid params:@"EgZ2aWRlb3PyBgQKAjoA" key:[@"uploads:" stringByAppendingString:cid] start:start delegate:delegate];
        }
    } else if ([s rangeOfString:@"playlists/"].location != NSNotFound) {
        NSString *orig = [base description];
        NSRange po = [orig rangeOfString:@"playlists/" options:NSCaseInsensitiveSearch];
        NSString *pid = [[[[orig substringFromIndex:po.location + po.length] componentsSeparatedByString:@"?"] firstObject] componentsSeparatedByString:@"/"][0];
        [self tr_loadWebBrowseId:[@"VL" stringByAppendingString:pid] params:nil key:[@"pl:" stringByAppendingString:pid] start:start delegate:delegate];
    } else {
        // Anything else: report an empty list instead of hanging.
        NSLog(@"[TubeReplacerClassic] unhandled feed url %@", s);
        [self tr_deliverEmptyWithStart:start delegate:delegate];
    }
}

// Local history (and similar) asks for videos by ID.
- (void)searchForVideosWithIDs:(NSArray *)ids withDelegate:(id)delegate {
    NSArray *list = [[ids copy] autorelease];
    if (![list count]) { [self tr_deliverEmptyWithStart:1 delegate:delegate]; return; }
    id me = [self retain];
    id del = [delegate retain];
    [list retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *out = [NSMutableArray array];
        NSUInteger n = 0;
        for (id raw in list) {
            if (n++ >= 25) break;
            NSString *vid = [raw isKindOfClass:[NSString class]] ? raw : nil;
            if (!vid && [raw respondsToSelector:@selector(videoID)]) vid = [raw performSelector:@selector(videoID)];
            if (![vid length]) continue;
            @try {
                NSDictionary *j = TRCSyncPlayerRequest(vid, [YoutubeClientType webMobileClient]);
                NSDictionary *vd = [TRJSONUtils dictFromJSON:j keyPath:@"videoDetails"];
                if (![vd[@"videoId"] length]) continue;
                id v = TRCMakeVideo(vd[@"videoId"], vd[@"title"] ?: @"", vd[@"author"] ?: @"",
                                    TRCParseCount([vd[@"viewCount"] description]),
                                    (unsigned int)[vd[@"lengthSeconds"] longLongValue],
                                    [NSDate date], vd[@"shortDescription"], nil);
                if (v) [out addObject:v];
            } @catch (NSException *e) { NSLog(@"[TubeReplacerClassic] history item failed: %@", e); }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            TRCDeliver(me, del, out, 1, 0);
            [me release]; [del release]; [list release];
        });
    });
}

- (void)searchForFavoriteVideosStartingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate {
    [self tr_loadTVBrowseId:@"VLLL" params:@"cAc%253D" key:@"acct:fav" start:start delegate:delegate];
}

- (void)searchForMyVideosStartingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate {
    [self tr_loadMyVideosStart:start delegate:delegate];
}

- (void)searchForRecentVideosStartingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate {
    [self tr_standardFeedOfType:@"most_recent" timeQualifier:nil start:start delegate:delegate];
}

- (void)searchForVideosFromWatchLaterPlaylistStartingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate {
    [self tr_loadTVBrowseId:@"FEmy_youtube" params:@"cAc%253D" key:@"acct:wl" start:start delegate:delegate];
}

// The stock check expects an Atom response; accept any 200 for our requests.
- (BOOL)receivedValidResponse:(id)response {
    if (objc_getAssociatedObject(self, &kTRCInfoKey)) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) return [(NSHTTPURLResponse *)response statusCode] == 200;
        return YES;
    }
    return %orig;
}

%end

#pragma mark - Response parsing

%hook YTFeedRequest

- (int)parseData:(NSData *)data {
    NSDictionary *info = objc_getAssociatedObject(self, &kTRCInfoKey);
    if (!info) return %orig;

    @try {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[TubeReplacerClassic] response was not JSON (%lu bytes)", (unsigned long)[data length]);
            return 1;
        }

        NSString *kind = info[@"kind"];
        unsigned int start = [info[@"start"] unsignedIntValue];
        NSMutableArray *videos = [NSMutableArray array];
        NSString *token = nil;

        if ([kind isEqualToString:@"video"]) {
            NSDictionary *vd = [TRJSONUtils dictFromJSON:json keyPath:@"videoDetails"];
            NSString *vid = vd[@"videoId"];
            if ([vid length]) {
                NSURL *stream = TRCStreamFromPlayer(json);
                NSString *type = TRCPrefs()[@"StreamType"];
                if ([type isEqualToString:@"tuberepair"] || [type isEqualToString:@"custom"]) stream = nil; // resolved lazily
                id v = TRCMakeVideo(vid, vd[@"title"] ?: @"", vd[@"author"] ?: @"",
                                    TRCParseCount([vd[@"viewCount"] description]),
                                    (unsigned int)[vd[@"lengthSeconds"] longLongValue],
                                    [NSDate date], vd[@"shortDescription"], stream);
                if (v) [videos addObject:v];
            }
        } else {
            NSMutableArray *items = [NSMutableArray array];
            TRCCollect(json, items, [NSMutableSet set]);
            for (NSDictionary *it in items) {
                id v = TRCMakeVideo(it[@"id"], it[@"title"], it[@"author"], [it[@"views"] unsignedIntValue],
                                    [it[@"duration"] unsignedIntValue], it[@"date"], nil, nil);
                if (v) [videos addObject:v];
            }
            token = TRCFindContinuation(json);
            NSString *key = info[@"key"];
            @synchronized (TRCTokens()) {
                if (token) TRCTokens()[key] = token; else [TRCTokens() removeObjectForKey:key];
            }
        }

        NSMutableArray *store = [self valueForKey:@"_videos"];
        if (![store isKindOfClass:[NSMutableArray class]]) {
            store = [NSMutableArray array];
            [self setValue:store forKey:@"_videos"];
        }
        [store removeAllObjects];
        [store addObjectsFromArray:videos];
        NSLog(@"[TubeReplacerClassic] parsed kind=%@ videos=%lu bytes=%lu next=%@",
              kind, (unsigned long)[videos count], (unsigned long)[data length], token ? @"yes" : @"no");

        unsigned int base = start > 0 ? start - 1 : 0;
        [self setValue:@(start) forKey:@"_startIndex"];
        [self setValue:@(base + (unsigned int)[videos count] + (token ? 100 : 0)) forKey:@"_totalResults"];
        return 0;
    } @catch (NSException *e) {
        NSLog(@"[TubeReplacerClassic] parse failed: %@", e);
        return 1;
    }
}

%end
