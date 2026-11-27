// signin12.x
// TubeReplacer - cookie based sign-in for YouTube 12.x.
//
// 12.x replaced GTMOAuth2Authentication / GTMOAuth2SignInInternal with SSOLoginScopedAuthorization and
// SSOOAuth2SignIn. signin.x emulates a web session on the old classes; this does the same for the
// new ones (the hooks only attach when those classes exist).

#include <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#include "appheaders.h"
#include "general.h"
#include "Translators/TRJSONUtils.h"

@interface SSOLoginScopedAuthorization : NSObject
- (NSString *)userEmail; - (void)setUserEmail:(NSString *)v;
- (NSString *)userID; - (void)setUserID:(NSString *)v;
- (void)setCode:(NSString *)v;
- (void)setAccessToken:(NSString *)v;
- (void)setRefreshToken:(NSString *)v;
- (void)setExpirationDate:(NSDate *)v;
- (void)tr_fillAccountInfo:(NSMutableDictionary *)p;
- (void)setParameters:(NSDictionary *)p;
@end

@interface NSObject (TRSignIn12)
- (id)authorization;
- (id)authorizationURL;
- (void)setAuthorizationURL:(NSURL *)u;
- (id)delegate;
- (void)authCodeObtained;
- (void)generateSelectAccountPageWithSID:(NSString *)sid hsid:(NSString *)hsid ssid:(NSString *)ssid sapisid:(NSString *)sapisid;
@end

static const char kTRParamsKey;
static NSString *const kTRDummy = @"this value shouldn't be seen. if you see this in a request, ping @Preloading with the request sent!";

static UIWebView *TRSignInWebView(id delegate) {
    @try {
        if ([delegate respondsToSelector:@selector(webView)]) return [delegate performSelector:@selector(webView)];
        return [delegate valueForKey:@"webView"];
    } @catch (NSException *e) { return nil; }
}

static NSString *TRFormEncode(NSString *s) {
    NSString *r = (NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)(s ?: @""), NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
    return [r autorelease];
}

// the account fields shared by the cookie jar, the keychain and the request signer
static NSMutableDictionary *TRParams(id auth) {
    NSMutableDictionary *d = objc_getAssociatedObject(auth, &kTRParamsKey);
    if (!d) { d = [NSMutableDictionary dictionary]; objc_setAssociatedObject(auth, &kTRParamsKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return d;
}

static void TRMarkSignedIn(id auth) {
    NSMutableDictionary *p = TRParams(auth);
    @try {
        [auth setAccessToken:kTRDummy];
        [auth setRefreshToken:kTRDummy];
        [auth setExpirationDate:[NSDate dateWithTimeIntervalSinceNow:100000000]];
        if ([p[@"userEmail"] length]) [auth setUserEmail:p[@"userEmail"]];
        NSString *uid = [p[@"userID"] length] ? p[@"userID"] : p[@"DATASYNC_ID"];
        if ([uid length]) [auth setUserID:uid];
    } @catch (NSException *e) { NSLog(@"[TubeReplacer] signin12: mark failed %@", e); }
}

extern NSDictionary *gTRLastAccountParams;

%hook SSOLoginScopedAuthorization

%new
-(NSMutableDictionary*)parameters { return TRParams(self); }

%new
-(void)setParameters:(NSDictionary*)params {
    NSMutableDictionary *p = TRParams(self);
    [p removeAllObjects];
    if ([params isKindOfClass:[NSDictionary class]]) [p addEntriesFromDictionary:params];
    { NSDictionary *old = gTRLastAccountParams; gTRLastAccountParams = [p copy]; [old release]; }
    TRMarkSignedIn(self);
}

%new
-(void)setKeysForResponseDictionary:(NSDictionary*)dict {
    [TRParams(self) addEntriesFromDictionary:dict];
    TRMarkSignedIn(self);
}

%new
-(NSString*)sid { return TRParams(self)[@"SID"]; }
%new
-(NSString*)hsid { return TRParams(self)[@"HSID"]; }
%new
-(NSString*)ssid { return TRParams(self)[@"SSID"]; }
%new
-(NSString*)sapisid { return TRParams(self)[@"SAPISID"]; }
%new
-(NSString*)sidcc { return TRParams(self)[@"SIDCC"]; }
%new
-(NSString*)datasyncID { return TRParams(self)[@"DATASYNC_ID"]; }
%new
-(NSString*)channelID { return TRParams(self)[@"CHANNEL_ID"]; }
%new
-(NSString*)pageID { return TRParams(self)[@"PAGE_ID"]; }
%new
-(NSString*)loginInfo { return TRParams(self)[@"LOGIN_INFO"]; }

-(BOOL)canAuthorize {
    NSDictionary *p = TRParams(self);
    return [p[@"SID"] length] && [p[@"HSID"] length] && [p[@"SSID"] length] && [p[@"SAPISID"] length] && [p[@"DATASYNC_ID"] length];
}

-(BOOL)shouldRefreshAccessToken { return NO; }

%new
-(NSString*)persistenceResponseString {
    NSDictionary *p = TRParams(self);
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"SID", @"HSID", @"SSID", @"SAPISID", @"SIDCC", @"DATASYNC_ID", @"CHANNEL_ID", @"PAGE_ID", @"LOGIN_INFO", @"userEmail", @"fullName", @"avatar"])
        if ([p[k] length]) data[k] = p[k];
    if ([p[@"DATASYNC_ID"] length]) data[@"userID"] = p[@"DATASYNC_ID"];
    data[@"refresh_token"] = kTRDummy;
    data[@"access_token"] = kTRDummy;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in data) [parts addObject:[NSString stringWithFormat:@"%@=%@", TRFormEncode(k), TRFormEncode(data[k])]];
    return [parts componentsJoinedByString:@"&"];
}

%new
-(BOOL)authorizeNSRequest:(NSMutableURLRequest **)request {
    NSDictionary *p = TRParams(self);
    NSString *sid = p[@"SID"], *hsid = p[@"HSID"], *ssid = p[@"SSID"], *sapisid = p[@"SAPISID"];
    NSString *sidcc = p[@"SIDCC"], *datasyncID = p[@"DATASYNC_ID"], *pageID = p[@"PAGE_ID"], *loginInfo = p[@"LOGIN_INFO"];
    if (![hsid length] || ![ssid length] || ![sapisid length] || ![sid length] || ![datasyncID length] || !*request) return NO;
    [*request setHTTPShouldHandleCookies:NO];
    NSMutableString *cookie = [NSMutableString stringWithFormat:@"hideBrowserUpgradeBox=true; HSID=%@; SSID=%@; SAPISID=%@; __Secure-3PAPISID=%@; SID=%@", hsid, ssid, sapisid, sapisid, sid];
    if ([sidcc length]) [cookie appendFormat:@"; SIDCC=%@", sidcc];
    if ([loginInfo length]) [cookie appendFormat:@"; LOGIN_INFO=%@", loginInfo];
    [*request setValue:cookie forHTTPHeaderField:@"Cookie"];
    NSURL *u = [*request URL];
    long now = (long)[[NSDate date] timeIntervalSince1970];
    NSString *toHash = nil;
    for (NSString *c in [datasyncID componentsSeparatedByString:@"||"]) if ([c length]) toHash = c;
    NSString *src = [NSString stringWithFormat:@"%@ %ld %@ %@://%@", toHash, now, sapisid, [u scheme], [u host]];
    NSData *sd = [src dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t dg[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([sd bytes], (CC_LONG)[sd length], dg);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", dg[i]];
    [*request setValue:[NSString stringWithFormat:@"SAPISIDHASH %ld_%@_u", now, hex] forHTTPHeaderField:@"Authorization"];
    [*request setValue:[NSString stringWithFormat:@"%@://%@", [u scheme], [u host]] forHTTPHeaderField:@"Origin"];
    if ([pageID length]) {
        [*request setValue:@"0" forHTTPHeaderField:@"X-Goog-AuthUser"];
        [*request setValue:pageID forHTTPHeaderField:@"X-Goog-PageId"];
    }
    return YES;
}

// 13.x: handler-style authorization, handler(error)
-(void)authorizeRequest:(NSMutableURLRequest*)request completionHandler:(void (^)(NSError *))handler {
    NSError *err = nil;
    if (![(id)self authorizeNSRequest:&request])
        err = [NSError errorWithDomain:@"com.google.sso" code:-1001 userInfo:nil];
    if (handler) handler(err);
}

// delegate-style authorization (some callers still use it directly)
-(void)authorizeRequest:(NSMutableURLRequest*)request delegate:(id)delegate didFinishSelector:(SEL)sel {
    NSError *err = nil;
    if (![(id)self authorizeNSRequest:&request])
        err = [NSError errorWithDomain:@"com.google.sso" code:-1001 userInfo:nil];
    if (delegate && sel) ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, sel, self, request, err);
}

// "token fetch": the cookies are the credentials, so the only thing left to learn is who the account is
%new
-(void)tr_fillAccountInfo:(NSMutableDictionary*)params {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://m.youtube.com/getAccountSwitcherEndpoint"]];
    NSString *pageId = params[@"PAGE_ID"];
    NSMutableString *cookie = [NSMutableString stringWithFormat:@"hideBrowserUpgradeBox=true; HSID=%@; SSID=%@; SAPISID=%@; __Secure-3PAPISID=%@; SID=%@", params[@"HSID"], params[@"SSID"], params[@"SAPISID"], params[@"SAPISID"], params[@"SID"]];
    if ([params[@"SIDCC"] length]) [cookie appendFormat:@"; SIDCC=%@", params[@"SIDCC"]];
    [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    params[@"userEmail"] = @"invalid@email.address";
    NSURLResponse *rsp = nil; NSError *err = nil;
    NSData *raw = [NSURLConnection sendSynchronousRequest:req returningResponse:&rsp error:&err];
    if (err || ![raw length]) { NSLog(@"[TubeReplacer] signin12: account info failed: %@", err); return; }
    NSData *clean = raw;
    const unsigned char *b = [raw bytes];
    if ([raw length] >= 5 && b[0] == ')' && b[1] == ']' && b[2] == '}' && b[3] == '\'' && b[4] == '\n') clean = [NSData dataWithBytes:b + 5 length:[raw length] - 5];
    id json = [NSJSONSerialization JSONObjectWithData:clean options:NSJSONReadingMutableContainers error:nil];
    NSDictionary *hdr = [TRJSONUtils dictFromJSON:json keyPath:@"data.actions[0].getMultiPageMenuAction.menu.multiPageMenuRenderer.sections[0].accountSectionListRenderer.header.googleAccountHeaderRenderer"];
    NSString *email = hdr[@"email"][@"simpleText"], *name = hdr[@"name"][@"simpleText"];
    if ([email length]) { params[@"userEmail"] = email; params[@"email"] = email; }
    if ([name length]) params[@"fullName"] = name;
    NSArray *accounts = [TRJSONUtils arrayFromJSON:json keyPath:@"data.actions[0].getMultiPageMenuAction.menu.multiPageMenuRenderer.sections[0].accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents"];
    for (NSDictionary *a in accounts) {
        NSString *ap = [TRJSONUtils stringFromJSON:a keyPath:@"accountItem.serviceEndpoint.selectActiveIdentityEndpoint.supportedTokens[0].pageIdToken"];
        if ((!ap && ![pageId length]) || [ap isEqualToString:pageId]) {
            NSString *photo = [TRJSONUtils stringFromJSON:a keyPath:@"accountItem.accountPhoto.thumbnails[0].url"];
            if (photo) params[@"avatar"] = photo;
            break;
        }
    }
}

-(id)beginTokenFetchWithDelegate:(id)delegate didFinishSelector:(SEL)sel {
    NSLog(@"[TubeReplacer] signin12: token fetch (datasync=%@)", [TRParams(self) objectForKey:@"DATASYNC_ID"]);
    if ([[TRParams(self) objectForKey:@"DATASYNC_ID"] length]) return nil; // already complete: also the refresh path
    SSOLoginScopedAuthorization *me = [(id)self retain];
    id dg = [delegate retain];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://m.youtube.com/feed/library?app=mobile"]];
    NSDictionary *p0 = TRParams(self);
    NSMutableString *cookie = [NSMutableString stringWithFormat:@"hideBrowserUpgradeBox=true; HSID=%@; SSID=%@; SAPISID=%@; __Secure-3PAPISID=%@; SID=%@", p0[@"HSID"], p0[@"SSID"], p0[@"SAPISID"], p0[@"SAPISID"], p0[@"SID"]];
    if ([p0[@"LOGIN_INFO"] length]) [cookie appendFormat:@"; LOGIN_INFO=%@", p0[@"LOGIN_INFO"]];
    if ([p0[@"SIDCC"] length]) [cookie appendFormat:@"; SIDCC=%@", p0[@"SIDCC"]];
    [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    [req setValue:@"https://accounts.google.com/" forHTTPHeaderField:@"Referer"];
    if ([p0[@"PAGE_ID"] length]) { [req setValue:@"0" forHTTPHeaderField:@"X-Goog-AuthUser"]; [req setValue:p0[@"PAGE_ID"] forHTTPHeaderField:@"X-Goog-PageId"]; }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURLResponse *rsp = nil; NSError *err = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&rsp error:&err];
        NSMutableDictionary *params = [NSMutableDictionary dictionaryWithDictionary:TRParams(me)];
        NSString *html = [data length] ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
        NSString *datasync = nil, *channel = nil;
        if (html) {
            NSRange r = [html rangeOfString:@"\"datasyncId\":\""];
            if (r.location != NSNotFound) {
                NSUInteger s = r.location + r.length;
                NSRange e = [html rangeOfString:@"\"," options:0 range:NSMakeRange(s, [html length] - s)];
                if (e.location != NSNotFound) datasync = [html substringWithRange:NSMakeRange(s, e.location - s)];
            }
            NSRange endR = [html rangeOfString:@"\\x22,\\x22webPageType\\x22:\\x22WEB_PAGE_TYPE_CHANNEL\\x22" options:NSBackwardsSearch];
            if (endR.location != NSNotFound) {
                NSRange sr = [html rangeOfString:@"\\/channel\\/" options:NSBackwardsSearch range:NSMakeRange(0, endR.location)];
                if (sr.location != NSNotFound) {
                    NSInteger is = sr.location + sr.length, il = endR.location - is;
                    if (il > 0) channel = [[html substringWithRange:NSMakeRange(is, il)] stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                }
            }
            if (!channel) {
                NSRange f = [html rangeOfString:@"\"url\":\"/channel/"];
                if (f.location != NSNotFound) {
                    NSUInteger s = f.location + f.length;
                    NSRange e = [html rangeOfString:@"/videos\"" options:0 range:NSMakeRange(s, [html length] - s)];
                    if (e.location != NSNotFound) channel = [html substringWithRange:NSMakeRange(s, e.location - s)];
                }
            }
        }
        NSLog(@"[TubeReplacer] signin12: library page %lu bytes err=%@ datasync=%@ channel=%@", (unsigned long)[data length], err, datasync, channel);
        NSError *outErr = err;
        if ([datasync length]) {
            params[@"DATASYNC_ID"] = datasync; params[@"userID"] = datasync;
            if ([channel length]) params[@"CHANNEL_ID"] = channel;
            NSLog(@"[TubeReplacer] signin12: reading account details");
            [me tr_fillAccountInfo:params];
            NSLog(@"[TubeReplacer] signin12: account details email=%@ name=%@", params[@"userEmail"], params[@"fullName"]);
            for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:[NSURL URLWithString:@"https://www.youtube.com"]])
                if ([c.name isEqualToString:@"SIDCC"]) params[@"SIDCC"] = c.value;
            outErr = nil;
        } else if (!outErr) {
            outErr = [NSError errorWithDomain:@"com.google.sso" code:-1002 userInfo:@{ NSLocalizedDescriptionKey: @"Could not read the account." }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[TubeReplacer] signin12: token fetch done err=%@, calling the sign-in delegate", outErr);
            if (!outErr) [me setParameters:params];
            if (dg && sel) ((void (*)(id, SEL, id, id, id))objc_msgSend)(dg, sel, me, nil, outErr);
            [dg release]; [me release];
        });
    });
    return nil;
}

%end

static BOOL TRProcessSignInCookies(id signIn, id cookieStorage) {
    NSURL *url = [NSURL URLWithString:@"https://m.youtube.com/ytscframe"];
    NSArray *cookies = [cookieStorage cookiesForURL:url];
    NSHTTPCookie *sid = nil, *hsid = nil, *ssid = nil, *sapisid = nil, *sidcc = nil, *logininfo = nil, *pageid = nil;
    for (NSHTTPCookie *c in cookies) {
        NSString *n = [c name];
        if ([n isEqual:@"SID"]) sid = c;
        else if ([n isEqual:@"HSID"]) hsid = c;
        else if ([n isEqual:@"SSID"]) ssid = c;
        else if ([n isEqual:@"SAPISID"] || [n isEqual:@"__Secure-3PAPISID"]) sapisid = c;
        else if ([n isEqual:@"SIDCC"]) sidcc = c;
        else if ([n isEqual:@"LOGIN_INFO"]) logininfo = c;
        else if ([n isEqual:@"tubereplacer_account_selected"]) pageid = c;
    }
    {
        NSMutableArray *names = [NSMutableArray array];
        for (NSHTTPCookie *c in cookies) [names addObject:[c name]];
        NSLog(@"[TubeReplacer] signin12: cookiesChanged: %lu cookies for ytscframe [%@] SID=%d HSID=%d SSID=%d SAPISID=%d selected=%d",
              (unsigned long)[cookies count], [names componentsJoinedByString:@","], sid != nil, hsid != nil, ssid != nil, sapisid != nil, pageid != nil);
    }
    if (!(sid && hsid && ssid && sapisid)) return NO;
    if (!pageid) {
        UIWebView *webView = TRSignInWebView([signIn delegate]);
        if (![[[[webView request] URL] absoluteString] isEqualToString:@"https://m.youtube.com/ytscframe?tubereplacer_next_login=1"]) {
            NSLog(@"[TubeReplacer] signin12: cookies ready, showing the account selector");
            [webView loadHTMLString:@"Loading..." baseURL:[NSURL URLWithString:@"https://m.youtube.com/ytscframe?tubereplacer_next_login=1"]];
            [signIn generateSelectAccountPageWithSID:[sid value] hsid:[hsid value] ssid:[ssid value] sapisid:[sapisid value]];
        }
        return NO;
    }
    NSString *pageValue = [pageid value];
    if ([pageValue isEqualToString:@"None"]) pageValue = nil;
    NSMutableDictionary *code = [@{ @"SID": [sid value], @"HSID": [hsid value], @"SSID": [ssid value], @"SAPISID": [sapisid value] } mutableCopy];
    if (pageValue) code[@"PAGE_ID"] = pageValue;
    if ([logininfo value]) code[@"LOGIN_INFO"] = [logininfo value];
    if ([sidcc value]) code[@"SIDCC"] = [sidcc value];
    NSLog(@"[TubeReplacer] signin12: account chosen (page %@)", pageValue ?: @"main");
    id auth = [signIn authorization];
    [auth setKeysForResponseDictionary:code];
    [code release];
    [signIn authCodeObtained];
    [cookieStorage deleteCookie:sid];
    return YES;
}

%hook SSOOAuth2SignIn

%new
-(void)generateSelectAccountPageWithSID:(NSString*)sid hsid:(NSString*)hsid ssid:(NSString*)ssid sapisid:(NSString*)sapisid {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://m.youtube.com/getAccountSwitcherEndpoint"]]; // thanks for asking, yes, it is the same as the user in myprofile.x. it doesn't include channel id, so we can't use this outright, would make my life easier tho.

  NSString *cookieData = [NSString stringWithFormat:@"hideBrowserUpgradeBox=true; HSID=%@; SSID=%@; SAPISID=%@; __Secure-3PAPISID=%@; SID=%@", hsid,ssid,sapisid,sapisid,sid];
  [request setValue:cookieData forHTTPHeaderField:@"Cookie"];

  [NSURLConnection sendAsynchronousRequest:request 
                                      queue:[NSOperationQueue mainQueue] 
                          completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
      NSString *htmlString = @"";
      if (error) {
          htmlString = [NSString stringWithFormat:@"<html><body>Something went wrong. %@", error];
          NSLog(@"Error: %@", error.localizedDescription);
      } else {
          NSData *cleanData = [NSData dataWithBytes:([data bytes] + 5) length:([data length]-5)];
          NSDictionary *json = [NSJSONSerialization JSONObjectWithData:cleanData options:NSJSONReadingMutableContainers error:nil];

          NSArray *accounts = [TRJSONUtils arrayFromJSON:json keyPath:@"data.actions[0].getMultiPageMenuAction.menu.multiPageMenuRenderer.sections[0].accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents"];

          // int index = -1;
          
          NSMutableString *allAccountsHTML = [[NSMutableString alloc] init];
          for (NSDictionary *account in accounts) {
              if (![TRJSONUtils stringFromJSON:account keyPath:@"accountItem.accountName.simpleText"]) continue;
              NSLog(@"account -> %@", account);
              // index++;

              NSString *pageId = [TRJSONUtils stringFromJSON:account keyPath:@"accountItem.serviceEndpoint.selectActiveIdentityEndpoint.supportedTokens[0].pageIdToken.pageId"];
              if (!pageId) {
                pageId = @"None";
              }

              NSString *accountElement = [NSString stringWithFormat:@"<li class=\"active-session-account\">"
                                  "<button onclick=\"javascript:selectAccount('%@')\">"
                                  "<img class=\"account-image\" alt=\"\" src=\"%@\">" // photo
                                  "<span class=\"account-name\">%@</span>" // name
                                  "<span class=\"account-email\">%@</span>" // handle
                                  "</button>"
                                  "</li>", 
                                  pageId,
                                  [TRJSONUtils stringFromJSON:account keyPath:@"accountItem.accountPhoto.thumbnails[0].url"],
                                  [TRJSONUtils stringFromJSON:account keyPath:@"accountItem.accountName.simpleText"],
                                  [TRJSONUtils stringFromJSON:account keyPath:@"accountItem.channelHandle.simpleText"]
              ];

              [allAccountsHTML appendString:accountElement];
          }
          NSError *err = nil;
          NSString *baseHTML = [NSString stringWithContentsOfFile:@"/Library/Application Support/TubeReplacer/account_selector.html" encoding:NSUTF8StringEncoding error:&err];
          htmlString = [baseHTML stringByReplacingOccurrencesOfString:@"{{ SPECIAL_TUBEREPLACER_ACCOUNTS_FIELD }}" withString:allAccountsHTML];


          htmlString = [htmlString stringByReplacingOccurrencesOfString:@"{{ SPECIAL_TUBEREPLACER_SIDCC_FIELD }}" withString:allAccountsHTML]; // hack!
        }

        // gets rid of some... problematic cookies for setting profile.
        NSHTTPCookieStorage *browserCookies = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSArray<NSHTTPCookie*> *urlCookies = [browserCookies cookiesForURL:[NSURL URLWithString:@"https://m.youtube.com/ytscframe"]];

        for (NSHTTPCookie* cookie in urlCookies) {
            NSString *cookieName = [cookie name];
            if ([cookieName isEqual:@"SID"]) {
                continue;
            }
            if ([cookieName isEqual:@"HSID"]) {
                continue;
            }
            if ([cookieName isEqual:@"SSID"]) {
                continue;
            }
            if ([cookieName isEqual:@"SAPISID"]) {
                continue;
            }
            if ([cookieName isEqual:@"SIDCC"]) {
                continue;
            }
            if ([cookieName isEqual:@"__Secure-3PAPISID"]) { // same value as sapisid
                continue;
            }
            if ([cookieName isEqual:@"tubereplacer_account_selected"]) {
                continue;
            }
            if ([cookieName isEqual:@"LOGIN_INFO"]) {
                continue;
            }
            [browserCookies deleteCookie:cookie];
        }

        // render
        UIWebView *webView = TRSignInWebView([(id)self delegate]);
        [webView loadHTMLString:htmlString baseURL:[NSURL URLWithString:@"https://m.youtube.com/ytscframe?tubereplacer_next_login=1"]];
  }];

  


}

-(BOOL)cookiesChanged:(id)cookieStorage {
    return TRProcessSignInCookies(self, cookieStorage);
}

// 13.x: the sign-in screen hands over the cookie array and looks for an oauth_code cookie itself
-(void)cookiesDidUpdate:(id)cookies {
    TRProcessSignInCookies(self, [NSHTTPCookieStorage sharedHTTPCookieStorage]);
}

-(void)authCodeObtained {
    if ([[self valueForKey:@"_hasHandledCallback"] boolValue]) return;
    [self setValue:@YES forKey:@"_hasHandledCallback"];
    NSLog(@"[TubeReplacer] signin12: fetching account details");
    ((id (*)(id, SEL, id, SEL))objc_msgSend)([(id)self authorization], NSSelectorFromString(@"beginTokenFetchWithDelegate:didFinishSelector:"), self, NSSelectorFromString(@"auth:finishedWithFetcher:error:"));
}

-(void)auth:(id)a finishedWithFetcher:(id)f error:(NSError*)e {
    NSLog(@"[TubeReplacer] signin12: auth:finishedWithFetcher err=%@", e);
    %orig;
    NSLog(@"[TubeReplacer] signin12: auth:finishedWithFetcher returned");
}

-(void)invokeFinalCallbackWithError:(NSError*)e {
    NSLog(@"[TubeReplacer] signin12: final callback err=%@ delegate=%@", e, [(id)self delegate]);
    %orig;
    NSLog(@"[TubeReplacer] signin12: final callback returned");
}

-(void)startSigningIn {
    // 12.x's auth advice has no URL we can set (it is built from the dead server's answer), so the
    // sign-in is pointed at the YouTube web login here
    NSLog(@"[TubeReplacer] signin12: start signing in (advice url: %@)", [(id)self authorizationURL]);
    [(id)self setAuthorizationURL:[NSURL URLWithString:@"https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=https://m.youtube.com/ytscframe&app=m&hl=en&next=%2F&hl=en&flowName=WebLiteSignIn"]];
    %orig;
}

%end

%hook SSOSignInViewController

-(BOOL)webView:(UIWebView*)wv shouldStartLoadWithRequest:(NSURLRequest*)req navigationType:(int)t {
    NSLog(@"[TubeReplacer] signin12: web load %@", [[req URL] absoluteString]);
    return %orig;
}
-(void)webViewDidFinishLoad:(UIWebView*)wv {
    NSLog(@"[TubeReplacer] signin12: web finished %@", [[[wv request] URL] absoluteString]);
    %orig;
}
-(void)webView:(UIWebView*)wv didFailLoadWithError:(NSError*)e {
    NSLog(@"[TubeReplacer] signin12: web failed %@", e);
    %orig;
}

// start every sign-in from a clean browser, like GTMOAuth2ViewControllerTouch does in signin.x
-(void)viewWillAppear:(BOOL)animated {
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSString *u in @[@"https://m.youtube.com/", @"https://accounts.youtube.com/", @"https://accounts.google.com/"])
        for (NSHTTPCookie *c in [[storage cookiesForURL:[NSURL URLWithString:u]] copy]) [storage deleteCookie:c];
    NSLog(@"[TubeReplacer] signin12: sign-in screen");
    %orig;
}

%end

%hook SSOSignInViewController
-(void)signIn:(id)si finishedWithAuth:(id)a error:(NSError*)e {
    NSLog(@"[TubeReplacer] signin12: view controller signIn:finishedWithAuth err=%@", e);
    %orig;
    NSLog(@"[TubeReplacer] signin12: view controller signIn:finishedWithAuth returned");
}
%end

%hook SSOService
-(BOOL)writeAndAuthorizeIdentity:(id)ident outputIdentity:(id*)out error:(NSError**)err {
    NSLog(@"[TubeReplacer] signin12: writeAndAuthorizeIdentity %@", ident);
    BOOL r = %orig;
    NSLog(@"[TubeReplacer] signin12: writeAndAuthorizeIdentity -> %d err=%@", r, err ? *err : nil);
    return r;
}
-(BOOL)updateKeychainForIdentity:(id)ident error:(NSError**)err {
    BOOL r = %orig;
    NSLog(@"[TubeReplacer] signin12: updateKeychain -> %d err=%@", r, err ? *err : nil);
    return r;
}
-(void)markIdentityAsSelected:(id)ident {
    NSLog(@"[TubeReplacer] signin12: markIdentityAsSelected");
    %orig;
}
-(void)postIdentityListChangedNotificationWithUserInfo:(id)ui {
    NSLog(@"[TubeReplacer] signin12: identity list changed");
    %orig;
}
%end

%hook SSOIdentityPrivate
-(void)signIn:(id)si finishedWithAuth:(id)a error:(NSError*)e {
    NSLog(@"[TubeReplacer] signin12: identity signIn:finishedWithAuth err=%@ email=%@", e, [a respondsToSelector:@selector(userEmail)] ? [a userEmail] : nil);
    %orig;
    NSLog(@"[TubeReplacer] signin12: identity signIn:finishedWithAuth returned");
}
-(void)requestTokenForScopes:(id)sc clientID:(id)cid extraParameters:(id)ex callback:(id)cb callbackQueue:(id)q {
    NSLog(@"[TubeReplacer] signin12: identity requestTokenForScopes %@ client=%@", sc, cid);
    %orig;
}
-(void)requestTokenForService:(id)svc callback:(id)cb {
    NSLog(@"[TubeReplacer] signin12: identity requestTokenForService %@", svc);
    %orig;
}
-(void)writeLibraryAccessToken {
    NSLog(@"[TubeReplacer] signin12: writeLibraryAccessToken");
    %orig;
    NSLog(@"[TubeReplacer] signin12: writeLibraryAccessToken returned");
}
%end

@interface NSObject (TRIface)
- (id)signInContext;
- (id)signInCallback;
@end

%hook SSOInterfaceController
-(void)service:(id)svc willBeginSignInWithCallback:(id)cb {
    NSLog(@"[TubeReplacer] signin12: willBeginSignIn callback=%@ context=%@", cb, [(id)self signInContext]);
    %orig;
    NSLog(@"[TubeReplacer] signin12: willBeginSignIn done; context callback=%@", [[(id)self signInContext] signInCallback]);
}
-(void)service:(id)svc startSignInWithAuthAdvice:(id)advice {
    NSLog(@"[TubeReplacer] signin12: startSignInWithAuthAdvice context=%@ callback=%@ code=%@", [(id)self signInContext], [[(id)self signInContext] signInCallback], [advice valueForKey:@"adviceCode"]);
    %orig;
}
-(id)signInViewControllerWithService:(id)svc completionHandler:(id)h {
    NSLog(@"[TubeReplacer] signin12: creating sign-in view controller handler=%@", h);
    return %orig;
}
%end

// 12.x: say why an InnerTube call failed (the app only shows a generic message)
%hook YTBaseInnerTubeService
-(void)processErrorResponseWithRequestState:(id)state error:(NSError*)error {
    NSLog(@"[TubeReplacer] innertube error: %@", error);
    %orig;
}
%end
