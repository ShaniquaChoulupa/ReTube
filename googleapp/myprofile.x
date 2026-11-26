// myprofile.x
// TubeReplacer
//
// User profile request and parsing hooks

#include <Foundation/Foundation.h>
extern void TRNoteProfile(NSString *name, NSString *handle, NSString *photo);
#import <CoreGraphics/CoreGraphics.h>
#include "appheaders.h"
#include "Translators/TRTranslators.h"
#include "general.h"

#pragma mark - Request Building

%hook YTGDataRequest

+(id)requestForMyUserProfileWithAuth:(id)authentication {
    // Uses a special endpoint that returns account switcher data
    return [self requestWithURLString:@"https://m.youtube.com/getAccountSwitcherEndpoint" 
                       authentication:authentication];
}

%end

%hook YTGDataRequestFactory

-(id)requestForMyUserProfileWithAuth:(id)authentication {
    // Uses a special endpoint that returns account switcher data
    return [self requestWithURLString:@"https://m.youtube.com/getAccountSwitcherEndpoint" 
                       authentication:authentication];
}

%end

#pragma mark - Request Dispatch

%hook YTGDataService 

-(void)makeMyUserProfileRequestWithAuth:(GTMOAuth2Authentication*)auth responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    NSLog(@"[TubeReplacer] user profile: requested");
    id request;
    if ([version() isEqualToString:@"1.0.0"] || [version() isEqualToString:@"1.0.1"])  {
        request = [%c(YTGDataRequest) requestForMyUserProfileWithAuth:auth];
    } else {
        request = [(YTGDataRequestFactory*)[self valueForKey:l(@"GDataRequestFactory")] requestForMyUserProfileWithAuth:auth];

    }

    void (^originalResponseBlock)(id) = [responseBlock copy];
    void (^newResponseBlock)(id) = ^(NSArray *accounts) {
        if (!originalResponseBlock) return;
        // kinda annoyed this has to exist, buh oh well.
        NSDictionary *accountInfo = nil;
        for (NSDictionary *account in accounts) {
            // i hope this'll work
            NSString *accountPageId = [TRJSONUtils stringFromJSON:account keyPath:@"accountItem.serviceEndpoint.selectActiveIdentityEndpoint.supportedTokens[0].pageIdToken.pageId"];
            if ([auth pageID] == nil && accountPageId == nil) {
                accountInfo = account[@"accountItem"];
                break;
            }
            if ([accountPageId isEqualToString:[auth pageID]]) {
                accountInfo = account[@"accountItem"];
                break;
            }
        }

        if (!accountInfo) {
            // no page id matched (v10 reports none, or a different one): take the selected account, else the first.
            // Without a profile the app thinks there is no channel and answers commenting with "update your YouTube channel".
            for (NSDictionary *account in ([accounts isKindOfClass:[NSArray class]] ? accounts : @[])) {
                NSDictionary *ai = [account isKindOfClass:[NSDictionary class]] ? account[@"accountItem"] : nil;
                if (![ai isKindOfClass:[NSDictionary class]]) continue;
                if ([ai[@"isSelected"] boolValue]) { accountInfo = ai; break; }
                if (!accountInfo) accountInfo = ai;
            }
            NSLog(@"[TubeReplacer] user profile: no page id match, fell back to %@", accountInfo ? @"the selected/first account" : @"nothing");
        }
        if (!accountInfo) {
            NSLog(@"YTUserProfileParser: Could not find account info");
            originalResponseBlock(nil);
            return;
        }
        
        NSString *displayName = [TRJSONUtils stringFromJSON:accountInfo keyPath:@"accountName.simpleText"];
        
        NSString *channelHandle = [TRJSONUtils stringFromJSON:accountInfo keyPath:@"channelHandle.simpleText"];
        if ([channelHandle hasPrefix:@"@"]) {
            channelHandle = [channelHandle substringFromIndex:1];
        }
        
        {   // remember the YouTube identity for the Account tab and own-channel detection
            NSString *pu = [TRJSONUtils stringFromJSON:accountInfo keyPath:@"accountPhoto.thumbnails[0].url"];
            TRNoteProfile(displayName, channelHandle, pu);
        }
        NSString *bylineText = [TRJSONUtils stringFromJSON:accountInfo keyPath:@"accountByline.simpleText"];
        int subscribersCount = (int)[TRJSONUtils numberFromText:bylineText];
        
        NSString *thumbUrl = [TRJSONUtils stringFromJSON:accountInfo keyPath:@"accountPhoto.thumbnails[0].url"];
        NSURL *thumbnail = thumbUrl ? [NSURL URLWithString:thumbUrl] : nil;
        
        YTUserProfile *profile = nil;
        if ([version() isEqualToString:@"1.0.0"] || [version() isEqualToString:@"1.0.1"]) {
            profile = [[[%c(YTUserProfile) alloc] 
                initWithUsername:channelHandle
                displayName:displayName
                age:0
                thumbnailURL:thumbnail
                uploadsURL:[NSURL URLWithString:@"https://youtube.com"]
                playlistsURL:[NSURL URLWithString:@"https://youtube.com"]
                uploadedCount:0
                favoritesCount:0
                subscriptionsCount:0
                uploadViewsCount:0
                channelViewsCount:0
                subscribersCount:subscribersCount
            ] autorelease];
        } else if ([version() isEqualToString:@"1.1.0"])  {
            profile = [[[%c(YTUserProfile) alloc] 
                initWithDisplayName:displayName
                channelID:channelHandle
                age:0
                thumbnailURL:thumbnail
                uploadsURL:[NSURL URLWithString:@"https://youtube.com"]
                playlistsURL:[NSURL URLWithString:@"https://youtube.com"]
                uploadedCount:0
                favoritesCount:0
                subscriptionsCount:0
                uploadViewsCount:0
                channelViewsCount:0
                subscribersCount:subscribersCount
            ] autorelease];
        } else if ([version() isEqualToString:@"1.2.1"] || [version() isEqualToString:@"1.3.0"] || [version() isEqualToString:@"1.4.0"]) {
            profile = [[[%c(YTUserProfile) alloc] 
                initWithDisplayName:displayName
                hasChannel:true // i mean probably lmao
                channelID:channelHandle
                eligibleForChannel:true // i mean i guess??????
                googlePlusUserID:(channelHandle ?: @"1") // non-nil: a nil id marks the account as a lightweight one that must "update its YouTube channel" before commenting
                age:0
                thumbnailURL:thumbnail
                uploadsURL:[NSURL URLWithString:@"https://youtube.com"]
                playlistsURL:[NSURL URLWithString:@"https://youtube.com"]
                uploadedCount:0
                favoritesCount:0
                subscriptionsCount:0
                uploadViewsCount:0
                channelViewsCount:0
                subscribersCount:subscribersCount
            ] autorelease];
        } else if ([%c(YTUserProfile) instancesRespondToSelector:@selector(initWithDisplayName:userID:hasChannel:channelID:channelName:eligibleForChannel:googlePlusUserID:age:thumbnailURL:uploadsURL:playlistsURL:uploadedCount:favoritesCount:subscriptionsCount:uploadViewsCount:channelViewsCount:subscribersCount:)]) {
            // 2.3.1 and later add userID:
            profile = [[[%c(YTUserProfile) alloc]
                initWithDisplayName:displayName
                userID:channelHandle
                hasChannel:true
                channelID:channelHandle
                channelName:displayName
                eligibleForChannel:true
                googlePlusUserID:(channelHandle ?: @"1")
                age:0
                thumbnailURL:thumbnail
                uploadsURL:[NSURL URLWithString:@"https://youtube.com"]
                playlistsURL:[NSURL URLWithString:@"https://youtube.com"]
                uploadedCount:0
                favoritesCount:0
                subscriptionsCount:0
                uploadViewsCount:0
                channelViewsCount:0
                subscribersCount:subscribersCount
            ] autorelease];
        } else { // 2.0.0 - 2.2.0
            profile = [[[%c(YTUserProfile) alloc] 
                initWithDisplayName:displayName
                hasChannel:true // i mean probably lmao
                channelID:channelHandle
                channelName:displayName // I think channel name == display name?????
                eligibleForChannel:true // i mean i guess??????
                googlePlusUserID:(channelHandle ?: @"1") // non-nil: a nil id marks the account as a lightweight one that must "update its YouTube channel" before commenting
                age:0
                thumbnailURL:thumbnail
                uploadsURL:[NSURL URLWithString:@"https://youtube.com"]
                playlistsURL:[NSURL URLWithString:@"https://youtube.com"]
                uploadedCount:0
                favoritesCount:0
                subscriptionsCount:0
                uploadViewsCount:0
                channelViewsCount:0
                subscribersCount:subscribersCount
            ] autorelease];
        }
        NSLog(@"[TubeReplacer] user profile built: name=%@ channel=%@ (%@)", displayName, channelHandle, [profile class]);
        originalResponseBlock(profile);
    };

    [self makeGETRequest:request 
              withParser:[self valueForKey:l(@"userProfileParser")] 
           responseBlock:newResponseBlock 
              errorBlock:errorBlock];
}


-(void)makeMyManagedChannelsRequestWithAuth:(id)auth responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    // Initializers differ per version (10.11 dropped both legacy ones), so check at runtime.
    Class subCls = NSClassFromString(@"YTSubscription");
    Class pageCls = NSClassFromString(@"YTPage");
    SEL subSel = @selector(initWithDisplayName:channelID:type:publishedDate:updatedDate:countHint:unreadCount:editURL:thumbnailURL:);
    SEL pageSel = @selector(initWithEntries:totalResults:entriesPerPage:startIndex:nextURL:previousURL:);
    SEL pageTokSel = @selector(initWithEntries:totalResults:entriesPerPage:nextToken:previousToken:);
    NSMutableArray *entries = [NSMutableArray array];
    if (subCls && [subCls instancesRespondToSelector:subSel]) {
        id sub = [[[subCls alloc]
            initWithDisplayName:@"channel name" channelID:@"channel id" type:1
            publishedDate:[NSDate date] updatedDate:[NSDate date]
            countHint:0 unreadCount:0
            editURL:[NSURL URLWithString:@"https://youtube.com"]
            thumbnailURL:[NSURL URLWithString:@"https://youtube.com"]] autorelease];
        if (sub) [entries addObject:sub];
    }
    id page = nil;
    if (pageCls && [pageCls instancesRespondToSelector:pageSel]) {
        page = [[[pageCls alloc] initWithEntries:entries totalResults:entries.count entriesPerPage:1
            startIndex:1 nextURL:nil previousURL:nil] autorelease];
    } else if (pageCls && [pageCls instancesRespondToSelector:pageTokSel]) {
        page = [[[pageCls alloc] initWithEntries:entries totalResults:entries.count entriesPerPage:1
            nextToken:nil previousToken:nil] autorelease];
    }
    [self performResponseBlock:responseBlock response:page];
}


%end

#pragma mark - Profile Parsing

%hook YTUserProfileParser
    
-(id)parseElement:(id)body error:(NSError *)error {
    if (![body isKindOfClass:[NSDictionary class]]) {
        NSLog(@"YTUserProfileParser: input is not NSDictionary");
        return nil;
    }
    
    NSDictionary *data = body;
    NSArray *accounts = [TRJSONUtils arrayFromJSON:data 
        keyPath:@"data.actions[0].getMultiPageMenuAction.menu.multiPageMenuRenderer.sections[0].accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents"];
    return accounts;
}

%end