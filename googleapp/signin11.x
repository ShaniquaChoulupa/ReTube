// 11.x: the sign-in finishes in the GTM view controller but nothing happens afterwards; trace where it stops
#import "general.h"
#import <objc/runtime.h>
extern NSDictionary *gTRLastAccountParams;

%group Sign11

%hook GTMOAuth2ViewControllerTouch
-(void)signIn:(id)si finishedWithAuth:(id)a error:(NSError*)e {
    id p = nil; BOOL can = NO; id em = nil, uid = nil, kc = nil;
    @try {
        p = [a valueForKey:@"parameters"];
        can = [[a valueForKey:@"canAuthorize"] boolValue];
        em = [a valueForKey:@"userEmail"]; uid = [a valueForKey:@"userID"];
        kc = [self valueForKey:@"keychainItemName"];
    } @catch (NSException *x) {}
    NSLog(@"[TubeReplacer] signin11: GTM VC finishedWithAuth err=%@ canAuthorize=%d email=%@ userID=%@ keys=%@ keychain=%@",
          e, can, em, uid, [[p allKeys] componentsJoinedByString:@","], kc);
    // the sign-in screen hands the identity code the Google userinfo profile; there is no such fetch here, so build it from the account details we already have
    if (!e && [p isKindOfClass:[NSDictionary class]] && [si respondsToSelector:@selector(setUserProfile:)]) {
        NSString *name = p[@"fullName"] ?: p[@"userEmail"] ?: @"YouTube";
        NSDictionary *profile = @{ @"id": p[@"userID"] ?: @"", @"email": p[@"userEmail"] ?: @"invalid@email.address",
            @"verified_email": @YES, @"name": name, @"given_name": name, @"family_name": name,
            @"picture": p[@"avatar"] ?: @"https://ssl.gstatic.com/accounts/ui/avatar_2x.png", @"locale": @"en" };
        [si performSelector:@selector(setUserProfile:) withObject:profile];
        { NSDictionary *old = gTRLastAccountParams; gTRLastAccountParams = [p copy]; [old release]; }
        NSLog(@"[TubeReplacer] signin11: set user profile %@", profile);
    }
    {
        unsigned int n = 0; Ivar *iv = class_copyIvarList([self class], &n);
        Class gc = NSClassFromString(@"GTMOAuth2ViewControllerTouch");
        NSMutableString *d = [NSMutableString string];
        unsigned int gn = 0; Ivar *giv = class_copyIvarList(gc, &gn);
        for (unsigned int i = 0; i < gn; i++) {
            const char *t = ivar_getTypeEncoding(giv[i]);
            if (t && (t[0] == 'B' || t[0] == 'c')) [d appendFormat:@"%s=%d ", ivar_getName(giv[i]), (int)*((char *)(__bridge void *)self + ivar_getOffset(giv[i]))];
            else if (t && t[0] == '@') {
                const char *nm = ivar_getName(giv[i]);
                if (strstr(nm, "elegate") || strstr(nm, "ompletion") || strstr(nm, "Selector") ) [d appendFormat:@"%s=%@ ", nm, object_getIvar(self, giv[i])];
            }
        }
        free(giv); if (iv) free(iv);
        NSLog(@"[TubeReplacer] signin11: GTM VC state %@", d);
    }
    %orig;
    NSLog(@"[TubeReplacer] signin11: GTM VC finishedWithAuth returned");
}
%end

%hook SSOIdentityPrivate
-(void)signInWithCode:(id)c finishedWithAuth:(id)a error:(NSError*)e {
    NSLog(@"[TubeReplacer] signin11: identity signInWithCode err=%@ ", e);
    %orig;
    NSLog(@"[TubeReplacer] signin11: identity signInWithCode returned");
}
%end

%hook SSOInterfaceController
-(id)signInViewControllerWithService:(id)svc completionHandler:(id)h {
    id hh = [h copy];
    id ic = [self retain];
    NSLog(@"[TubeReplacer] signin11: signInViewControllerWithService handler=%@", hh);
    void (^wrapped)(id, id, id) = ^(id profile, id auth, id err) {
        NSLog(@"[TubeReplacer] signin11: sign-in handler called profile=%@ auth=%@ err=%@", profile, auth, err);
        // the sign-in context only gets its callback after this view controller has been created, so look it up now
        id cb = hh; if (!cb) { @try { cb = [[ic valueForKey:@"signInContext"] valueForKey:@"signInCallback"]; } @catch (NSException *x) {} }
        NSLog(@"[TubeReplacer] signin11: forwarding to %@", cb);
        if (cb) ((void (^)(id, id, id))cb)(profile, auth, err);
        NSLog(@"[TubeReplacer] signin11: sign-in handler returned");
    };
    return %orig(svc, [[wrapped copy] autorelease]);
}
-(void)invokeSignInBlockWithIdentity:(id)i error:(id)e {
    NSLog(@"[TubeReplacer] signin11: invokeSignInBlock identity=%@ err=%@", i, e);
    %orig;
}
-(void)finishAddAccountWithAccountSelector:(id)s newIdentity:(id)i error:(id)e {
    NSLog(@"[TubeReplacer] signin11: finishAddAccount identity=%@ err=%@", i, e);
    %orig;
}
-(void)signInDidCancel:(id)s {
    NSLog(@"[TubeReplacer] signin11: signInDidCancel");
    %orig;
}
%end

%hook SSOService
-(void)signInIdentity:(id)i callback:(id)cb {
    NSLog(@"[TubeReplacer] signin11: service signInIdentity %@", i);
    %orig;
}
%end

%end

%ctor {
    if (majorVersion() == 11) {
        %init(Sign11);
    }
}
