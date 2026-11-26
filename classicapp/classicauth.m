// classicauth.m
// TubeReplacer - classic YouTube sign-in
//
// The classic app signs in with Google's long-dead ClientLogin (username/password).
// Instead we show a popup web view (like the App Store YouTube app's sign-in sheet)
// that runs Google's OAuth2 *device flow* with the YouTube TV client, the same
// scheme erievs/Lincoln uses:
//
//   1. POST oauth2.googleapis.com/device/code  -> user_code + verification_url
//   2. the user opens google.com/device (here in the web view, or in Safari / on
//      another device) and enters the code
//   3. we poll oauth2.googleapis.com/token until we get access + refresh tokens
//   4. tokens are stored; requests send "Authorization: Bearer <access token>"
//      with the TVHTML5 InnerTube client (see TRCMakeTVRequest).

#import "trlog.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "classicauth.h"

// Public YouTube-TV OAuth client (the same one Lincoln and other open-source TV clients use).
static NSString *const kTRCClientID     = @"861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com";
static NSString *const kTRCClientSecret = @"SboVhoG9s0rNafixCSGGKXAT";
static NSString *const kTRCScope        = @"http://gdata.youtube.com";
static NSString *const kTRCTVKey        = @"AIzaSyDCU8hByM-4DrUqRUYnGn-3llEO78bcxq8";
static NSString *const kTRCDefaultsKey  = @"TubeReplacerClassicAuth";

NSString *const TRCSignedInStateDidChangeNotification = @"TRCSignedInStateDidChangeNotification";

#pragma mark - Token store

static NSMutableDictionary *TRCLoadTokens(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kTRCDefaultsKey];
    return d ? [[d mutableCopy] autorelease] : nil;
}

static void TRCStoreTokens(NSDictionary *d) {
    NSUserDefaults *u = [NSUserDefaults standardUserDefaults];
    if (d) [u setObject:d forKey:kTRCDefaultsKey]; else [u removeObjectForKey:kTRCDefaultsKey];
    [u synchronize];
}

BOOL TRCSignedIn(void) {
    return [TRCLoadTokens()[@"refresh_token"] length] > 0 || [TRCLoadTokens()[@"access_token"] length] > 0;
}

NSString *TRCAccountName(void) {
    NSString *n = TRCLoadTokens()[@"name"];
    return [n length] ? n : @"YouTube";
}

static NSString *TRCFormEncode(NSDictionary *params) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in params) {
        NSString *v = params[k];
        CFStringRef enc = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)v, NULL, (CFStringRef)@"!*'();:@&=+$,/?%#[]", kCFStringEncodingUTF8);
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, (NSString *)enc]];
        CFRelease(enc);
    }
    return [parts componentsJoinedByString:@"&"];
}

static NSMutableURLRequest *TRCFormRequest(NSString *url, NSDictionary *params) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:20.0];
    [r setHTTPMethod:@"POST"];
    [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [r setHTTPBody:[TRCFormEncode(params) dataUsingEncoding:NSUTF8StringEncoding]];
    return r;
}

static void TRCSaveTokenResponse(NSDictionary *resp) {
    NSMutableDictionary *t = TRCLoadTokens() ?: [NSMutableDictionary dictionary];
    if ([resp[@"access_token"] length]) t[@"access_token"] = resp[@"access_token"];
    if ([resp[@"refresh_token"] length]) t[@"refresh_token"] = resp[@"refresh_token"];
    double life = [resp[@"expires_in"] doubleValue];
    t[@"expires_at"] = @([[NSDate date] timeIntervalSince1970] + (life > 120 ? life - 60 : 60));
    TRCStoreTokens(t);
}

// Returns a usable access token, refreshing it (synchronously) if it has expired.
NSString *TRCValidAccessToken(void) {
    NSMutableDictionary *t = TRCLoadTokens();
    if (!t) return nil;
    NSString *access = t[@"access_token"];
    double expires = [t[@"expires_at"] doubleValue];
    if ([access length] && expires > [[NSDate date] timeIntervalSince1970]) return access;

    NSString *refresh = t[@"refresh_token"];
    if (![refresh length]) return [access length] ? access : nil;

    NSURLResponse *resp = nil; NSError *err = nil;
    NSMutableURLRequest *req = TRCFormRequest(@"https://oauth2.googleapis.com/token", @{
        @"client_id": kTRCClientID, @"client_secret": kTRCClientSecret,
        @"refresh_token": refresh, @"grant_type": @"refresh_token" });
    [req setTimeoutInterval:15.0];
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"access_token"] length]) {
        TRCSaveTokenResponse(json);
        NSLog(@"[TubeReplacerClassic] refreshed access token");
        return json[@"access_token"];
    }
    NSLog(@"[TubeReplacerClassic] token refresh failed: %@ %@", err, json);
    // A revoked refresh token means we are no longer signed in.
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"error"] isEqualToString:@"invalid_grant"]) {
        TRCSignOut();
        return nil;
    }
    return [access length] ? access : nil;
}

void TRCSignOut(void) {
    TRCStoreTokens(nil);
    [[NSNotificationCenter defaultCenter] postNotificationName:TRCSignedInStateDidChangeNotification object:nil];
}

#pragma mark - Authenticated InnerTube (TV) requests

NSMutableURLRequest *TRCMakeTVRequest(NSString *endpoint, NSDictionary *extraBody, NSString *params) {
    NSString *token = TRCValidAccessToken();
    if (![token length]) return nil;

    NSDictionary *client = @{
        @"hl": @"en", @"gl": @"US", @"deviceMake": @"Samsung", @"deviceModel": @"SmartTV",
        @"userAgent": @"Mozilla/5.0 (SMART-TV; Linux; Tizen 5.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/5.0 NativeTVAds Safari/538.1,gzip(gfe)",
        @"clientName": @"TVHTML5", @"clientVersion": @"7.20250209.19.00", @"osName": @"Tizen", @"osVersion": @"5.0",
        @"platform": @"TV", @"clientFormFactor": @"UNKNOWN_FORM_FACTOR", @"screenPixelDensity": @1 };
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObject:@{ @"client": client } forKey:@"context"];
    [body addEntriesFromDictionary:extraBody];

    NSMutableString *url = [NSMutableString stringWithFormat:@"https://www.googleapis.com/youtubei/v1/%@?key=%@", endpoint, kTRCTVKey];
    if ([params length]) [url appendFormat:@"&params=%@", params];

    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:30.0];
    [r setHTTPMethod:@"POST"];
    [r setHTTPBody:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil]];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [r setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [r setValue:client[@"userAgent"] forHTTPHeaderField:@"User-Agent"];
    return r;
}

// Best-effort display name for the signed-in account.
static void TRCFetchAccountName(void (^done)(NSString *name)) {
    NSMutableURLRequest *req = TRCMakeTVRequest(@"account/accounts_list", @{}, nil);
    if (!req) { done(nil); return; }
    [NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *r, NSData *data, NSError *e) {
        NSString *found = nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        // depth-first search for accountName.simpleText
        NSMutableArray *stack = json ? [NSMutableArray arrayWithObject:json] : [NSMutableArray array];
        while ([stack count] && !found) {
            id n = [stack lastObject]; [stack removeLastObject];
            if ([n isKindOfClass:[NSDictionary class]]) {
                id an = n[@"accountName"];
                if ([an isKindOfClass:[NSDictionary class]] && [an[@"simpleText"] length]) { found = an[@"simpleText"]; break; }
                [stack addObjectsFromArray:[n allValues]];
            } else if ([n isKindOfClass:[NSArray class]]) {
                [stack addObjectsFromArray:n];
            }
        }
        done(found);
    }];
}

#pragma mark - Telling the classic framework we're signed in

void TRCApplySignedInState(void) {
    NSDictionary *t = TRCLoadTokens();
    if (!t) return;
    id auth = [NSClassFromString(@"YTAccountAuthenticator") performSelector:NSSelectorFromString(@"sharedAuthenticator")];
    if (!auth) return;
    NSString *name = TRCAccountName();
    [auth performSelector:NSSelectorFromString(@"setAccount:") withObject:name];
    [auth performSelector:NSSelectorFromString(@"setAccountToken:") withObject:(t[@"access_token"] ?: @"token")];
    [auth performSelector:NSSelectorFromString(@"setAccountTokenDate:") withObject:[NSDate date]];
    [auth performSelector:NSSelectorFromString(@"setAccountYouTubeName:") withObject:name];
    // Posts the notification that moves the app into its signed-in state.
    if ([auth respondsToSelector:NSSelectorFromString(@"_postNewAccountTokenAvailable")])
        [auth performSelector:NSSelectorFromString(@"_postNewAccountTokenAvailable")];
    [[NSNotificationCenter defaultCenter] postNotificationName:TRCSignedInStateDidChangeNotification object:nil];
}

#pragma mark - Sign-in popup

// the navigation controller currently showing the popup (unretained)
static UINavigationController *sTRCNav = nil;

@interface TRCSignInViewController : UIViewController <UIWebViewDelegate> {
    UIWebView *_web;
    NSString *_deviceCode;
    NSString *_userCode;
    NSString *_verificationURL;
    NSTimeInterval _interval;
    NSTimer *_timer;
    BOOL _polling;
    BOOL _finished;
    BOOL _showingGoogle;
}
@end

static NSString *TRCHTMLEscape(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    s = [s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    return [s stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
}

static NSString *TRCPage(NSString *body) {
    return [NSString stringWithFormat:
        @"<html><head><meta name='viewport' content='width=device-width, initial-scale=1.0, maximum-scale=1.0'>"
        "<style>body{font-family:Helvetica,Arial,sans-serif;background:#f1f1f1;color:#222;margin:0;padding:16px;text-align:center}"
        "h1{font-size:20px;margin:6px 0 14px}p{font-size:15px;line-height:1.4;margin:8px 0}"
        ".code{font-size:34px;font-weight:bold;letter-spacing:4px;background:#fff;border:1px solid #ccc;border-radius:8px;padding:14px 6px;margin:12px 0}"
        ".url{font-weight:bold;color:#cc181e}"
        "a.btn{display:block;margin:10px 0;padding:13px;border-radius:8px;background:#cc181e;color:#fff;text-decoration:none;font-weight:bold;font-size:16px}"
        "a.alt{background:#fff;color:#cc181e;border:1px solid #cc181e}"
        "#status{margin-top:14px;font-size:14px;color:#555}</style>"
        "<script>function setStatus(t){document.getElementById('status').innerHTML=t}</script>"
        "</head><body>%@</body></html>", body];
}

@implementation TRCSignInViewController

- (void)dealloc {
    sTRCNav = nil;
    [self cancelTimer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _web.delegate = nil;
    [_web release]; [_deviceCode release]; [_userCode release]; [_verificationURL release];
    [super dealloc];
}

- (void)loadView {
    _web = [[UIWebView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
    _web.delegate = self;
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _web.scalesPageToFit = NO;
    _web.backgroundColor = [UIColor colorWithWhite:0.945 alpha:1.0];
    self.view = _web;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sign in to YouTube";
    self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStyleBordered
                                                                             target:self action:@selector(cancel)] autorelease];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appBecameActive)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
    [self showMessage:@"Contacting Google…"];
    [self requestDeviceCode];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return YES; }

- (void)showMessage:(NSString *)msg {
    _showingGoogle = NO;
    [_web loadHTMLString:TRCPage([NSString stringWithFormat:@"<h1>Sign in to YouTube</h1><p>%@</p>", TRCHTMLEscape(msg)])
                 baseURL:[NSURL URLWithString:@"http://tubereplacer.local/"]];
}

- (void)showCode {
    _showingGoogle = NO;
    NSString *body = [NSString stringWithFormat:
        @"<h1>Sign in to YouTube</h1>"
        "<p>1. Go to <span class='url'>%@</span></p>"
        "<p>2. Enter this code:</p><div class='code'>%@</div>"
        "<p>3. Pick your Google account and allow access.</p>"
        "<a class='btn' href='trc://inapp'>Open Google sign-in here</a>"
        "<a class='btn alt' href='trc://safari'>Open in Safari</a>"
        "<a class='btn alt' href='trc://copy'>Copy code</a>"
        "<div id='status'>Waiting for you to finish sign-in…</div>",
        TRCHTMLEscape(_verificationURL ?: @"google.com/device"), TRCHTMLEscape(_userCode ?: @"")];
    [_web loadHTMLString:TRCPage(body) baseURL:[NSURL URLWithString:@"http://tubereplacer.local/"]];
    self.navigationItem.rightBarButtonItem = nil;
}

- (void)setStatus:(NSString *)text {
    if (_showingGoogle) return;
    NSString *js = [NSString stringWithFormat:@"setStatus(\"%@\")",
                    [[text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
    [_web stringByEvaluatingJavaScriptFromString:js];
}

#pragma mark Device flow

- (void)requestDeviceCode {
    NSMutableURLRequest *req = TRCFormRequest(@"https://oauth2.googleapis.com/device/code",
                                              @{ @"client_id": kTRCClientID, @"scope": kTRCScope });
    [NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *r, NSData *data, NSError *err) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]] || ![json[@"user_code"] length]) {
            NSLog(@"[TubeReplacerClassic] device code request failed: %@ %@", err, json);
            [self showMessage:@"Couldn't reach Google. Check your connection and try again."];
            return;
        }
        [_deviceCode release]; _deviceCode = [json[@"device_code"] copy];
        [_userCode release]; _userCode = [json[@"user_code"] copy];
        [_verificationURL release]; _verificationURL = [(json[@"verification_url"] ?: @"https://www.google.com/device") copy];
        _interval = MAX(5.0, [json[@"interval"] doubleValue]);
        NSLog(@"[TubeReplacerClassic] device code obtained (interval %.0fs)", _interval);
        [self showCode];
        [self scheduleNextPoll];
    }];
}

// The timer is owned (retained) here: a one-shot NSTimer is released by the run loop after
// it fires, so an unretained pointer would dangle and crash on the next -invalidate.
- (void)cancelTimer {
    [_timer invalidate];
    [_timer release];
    _timer = nil;
}

- (void)scheduleNextPoll {
    [self cancelTimer];
    if (_finished) return;
    _timer = [[NSTimer scheduledTimerWithTimeInterval:_interval target:self selector:@selector(poll) userInfo:nil repeats:NO] retain];
}

- (void)appBecameActive {
    // Coming back from Safari: check straight away instead of waiting for the timer.
    if (_deviceCode && !_finished) [self poll];
}

- (void)poll {
    if (_finished || _polling || !_deviceCode) return;
    [self cancelTimer]; // a direct call (e.g. returning from Safari) replaces the scheduled one
    _polling = YES;
    NSMutableURLRequest *req = TRCFormRequest(@"https://oauth2.googleapis.com/token", @{
        @"client_id": kTRCClientID, @"client_secret": kTRCClientSecret, @"device_code": _deviceCode,
        @"grant_type": @"urn:ietf:params:oauth:grant-type:device_code" });
    [NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *r, NSData *data, NSError *err) {
        _polling = NO;
        if (_finished) return;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *d = [json isKindOfClass:[NSDictionary class]] ? json : nil;

        if ([d[@"access_token"] length]) {
            [self finishWithTokens:d];
            return;
        }
        NSString *e = d[@"error"];
        if ([e isEqualToString:@"slow_down"]) _interval += 5.0;
        if ([e isEqualToString:@"access_denied"]) {
            [self showMessage:@"Sign-in was cancelled. Close this and try again."]; _finished = YES; return;
        }
        if ([e isEqualToString:@"expired_token"] || [e isEqualToString:@"invalid_grant"]) {
            [self showMessage:@"That code expired. Close this and try again."]; _finished = YES; return;
        }
        // authorization_pending (or a network blip): keep waiting
        [self scheduleNextPoll];
    }];
}

- (void)finishWithTokens:(NSDictionary *)tokens {
    _finished = YES;
    [self cancelTimer];
    TRCSaveTokenResponse(tokens);
    NSLog(@"[TubeReplacerClassic] signed in (refresh token: %@)", [tokens[@"refresh_token"] length] ? @"yes" : @"no");
    [self showMessage:@"Signed in! One moment…"];
    TRCFetchAccountName(^(NSString *name) {
        if ([name length]) {
            NSMutableDictionary *t = TRCLoadTokens();
            t[@"name"] = name;
            TRCStoreTokens(t);
        }
        TRCApplySignedInState();
        [self dismissViewControllerAnimated:YES completion:nil];
    });
}

#pragma mark UI actions

- (void)cancel {
    _finished = YES;
    [self cancelTimer];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)backToCode {
    [self showCode];
}

- (BOOL)webView:(UIWebView *)w shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)type {
    NSURL *url = [request URL];
    if ([[url scheme] isEqualToString:@"trc"]) {
        NSString *host = [url host];
        NSString *verify = _verificationURL ?: @"https://www.google.com/device";
        if ([host isEqualToString:@"safari"]) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:verify]];
        } else if ([host isEqualToString:@"copy"]) {
            [UIPasteboard generalPasteboard].string = _userCode ?: @"";
            [self setStatus:@"Code copied."];
        } else if ([host isEqualToString:@"inapp"]) {
            _showingGoogle = YES;
            self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Show code" style:UIBarButtonItemStyleBordered
                                                                                       target:self action:@selector(backToCode)] autorelease];
            [_web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:verify]]];
        }
        return NO;
    }
    return YES;
}

@end

#pragma mark - Presenting

static UIViewController *TRCControllerOfView(UIView *v, int depth) {
    for (UIResponder *r = v; r; r = [r nextResponder])
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
    if (depth > 3) return nil;
    for (UIView *sub in [v subviews]) {
        UIViewController *c = TRCControllerOfView(sub, depth + 1);
        if (c) return c;
    }
    return nil;
}

static UIViewController *TRCTopViewController(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIViewController *vc = nil;
    // the first classic versions have no rootViewController: look through every window
    NSMutableArray *windows = [NSMutableArray arrayWithObject:app.keyWindow ?: (id)[NSNull null]];
    for (UIWindow *w in [[app windows] reverseObjectEnumerator]) [windows addObject:w];
    for (id w in windows) {
        if (![w isKindOfClass:[UIWindow class]]) continue;
        vc = [(UIWindow *)w rootViewController];
        if (!vc) vc = TRCControllerOfView(w, 0);
        if (vc) break;
    }
    if (!vc) {
        id controller = [NSClassFromString(@"YTController") performSelector:NSSelectorFromString(@"sharedController")];
        if ([controller respondsToSelector:NSSelectorFromString(@"tabBarController")])
            vc = [controller performSelector:NSSelectorFromString(@"tabBarController")];
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void TRCPresentSignInAttempt(int attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Already showing?
        if (sTRCNav && (sTRCNav.presentingViewController || sTRCNav.view.window)) return;

        UIViewController *top = TRCTopViewController();
        if (!top) {
            // early in the launch there is nothing to present from yet: try again shortly
            if (attempt < 20) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TRCPresentSignInAttempt(attempt + 1); });
            } else NSLog(@"[TubeReplacerClassic] no view controller to present sign-in from");
            return;
        }

        TRCSignInViewController *vc = [[[TRCSignInViewController alloc] init] autorelease];
        UINavigationController *nav = [[[UINavigationController alloc] initWithRootViewController:vc] autorelease];
        nav.navigationBar.tintColor = [UIColor colorWithRed:0.8 green:0.09 blue:0.12 alpha:1.0];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        sTRCNav = nav; // not retained; cleared in -dealloc of the sign-in controller
        if ([top respondsToSelector:@selector(presentViewController:animated:completion:)])
            [top presentViewController:nav animated:YES completion:nil];
        else
            [top presentModalViewController:nav animated:YES];
    });
}

void TRCPresentSignIn(void) { TRCPresentSignInAttempt(0); }
