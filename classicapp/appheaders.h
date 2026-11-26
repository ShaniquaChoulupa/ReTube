// Declarations for the private iOS 6/7 YouTube.framework classes used by the
// classic (Apple) YouTube app. Taken from class-dumps of iOS 6.0 and 7.0 (the
// relevant interfaces are identical on both).
#import <Foundation/Foundation.h>

@interface YTVideoReference : NSObject
- (id)initWithContentURL:(NSURL *)url duration:(unsigned int)duration profile:(int)profile;
- (NSURL *)contentURL;
@end

@interface YTVideo : NSObject
- (id)initWithID:(NSString *)videoID title:(NSString *)title dateUpdated:(id)dateUpdated dateAdded:(id)dateAdded
 videoReferences:(NSArray *)refs infoURL:(NSURL *)infoURL videoDescription:(NSString *)desc category:(NSString *)category
            tags:(NSArray *)tags author:(NSString *)author thumbnailURL:(NSURL *)thumb numLikes:(unsigned int)likes
     numDislikes:(unsigned int)dislikes numberOfViews:(unsigned int)views batchStatus:(int)batchStatus
     commentsURL:(NSURL *)commentsURL editURL:(NSURL *)editURL ratingsURL:(NSURL *)ratingsURL captionsURL:(NSURL *)captionsURL
         shortID:(NSString *)shortID unplayable:(NSString *)unplayable isProcessing:(BOOL)isProcessing privacy:(int)privacy
restrictedCountries:(NSString *)restricted;
- (NSString *)ID;
- (id)bestVideoReference;
- (id)anyVideoReference;
- (id)videoReferenceForProfile:(int)profile;
@end

@interface XMLSAXHTTPRequest : NSObject
- (void)loadRequest:(NSURLRequest *)request;
@end

@interface YTXMLHTTPRequest : XMLSAXHTTPRequest
@end

@interface YTFeedRequest : YTXMLHTTPRequest
- (void)loadRequest:(NSURLRequest *)request withDelegate:(id)delegate accountAuthRequired:(BOOL)auth;
- (int)parseData:(NSData *)data;
@end

@interface YTSubscriptionsRequest : NSObject
@end

@interface YTSearchRequest : YTFeedRequest
- (void)searchForVideosMatchingString:(NSString *)q startingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate;
- (void)searchForStandardFeedVideosOfType:(NSString *)type startIndex:(unsigned int)start maxResults:(unsigned int)max timeQualifier:(id)tq withDelegate:(id)delegate;
- (void)searchForVideoWithID:(NSString *)videoID withDelegate:(id)delegate;
- (void)searchForVideosRelatedToVideo:(id)video startingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate;
- (void)searchForVideosByAuthor:(NSString *)author startingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate;
- (void)searchForVideosWithIDs:(NSArray *)ids withDelegate:(id)delegate;
- (void)searchForFavoriteVideosStartingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate;
- (void)searchForMyVideosStartingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate;
- (void)searchForRecentVideosStartingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate;
- (void)searchForVideosFromWatchLaterPlaylistStartingAtIndex:(unsigned int)start maxResults:(unsigned int)max withDelegate:(id)delegate;
- (void)searchForVideosWithFeedURLBase:(id)base startingAtIndex:(unsigned int)start maxResults:(unsigned int)max withTimeQualifier:(id)tq withFormatFilter:(BOOL)ff authenticationRequired:(BOOL)auth withDelegate:(id)delegate;
- (BOOL)receivedValidResponse:(id)response;
@end
