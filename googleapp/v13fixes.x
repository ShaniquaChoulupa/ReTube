// v13fixes.x
// TubeReplacer
//
// 13.x: a search-results crash guard and the watch page layout (description above the buttons).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Searching crashed with "unrecognized selector -entry" sent to a cell that is not one of the app's entry cells (the
// section controller then calls -[cell entry] unconditionally). Skip those cells (they stay blank) and say which ones they are.
%hook YTSectionController
- (void)updateCell:(id)cell forEntry:(id)entry {
    if (cell && ![cell respondsToSelector:@selector(entry)]) {
        static int logged = 0;
        if (logged++ < 8) NSLog(@"[TubeReplacer] section %@: cell %@ has no -entry (entry %@), skipped", NSStringFromClass([self class]), NSStringFromClass([cell class]), NSStringFromClass([entry class]));
        return;
    }
    %orig;
}
%end

// The expanded watch header draws title, views, like/share/save buttons, the owner row and then the description.
// Move the description up, directly under the views (the buttons and the owner row shift down by its height).
%hook YTSlimVideoMetadataCell
- (void)layoutSubviews {
    %orig;
    @try {
        UIView *desc = [self valueForKey:@"descriptionContainer"];
        UIView *acts = [self valueForKey:@"_videoDetailsActionsView"];
        if (![desc isKindOfClass:[UIView class]] || ![acts isKindOfClass:[UIView class]]) return;
        if (!desc.superview || desc.hidden || desc.alpha < 0.01 || desc.frame.size.height < 1) return;
        CGFloat ay = acts.frame.origin.y, dy = desc.frame.origin.y, dh = desc.frame.size.height;
        if (!acts.superview || acts.hidden || ay >= dy) return; // collapsed, or already above
        UIView *host = desc.superview;
        for (UIView *v in [host subviews]) {
            if (v == desc) continue;
            CGRect f = v.frame;
            if (f.origin.y >= ay - 0.5 && f.origin.y < dy - 0.5) { f.origin.y += dh; v.frame = f; }
        }
        CGRect df = desc.frame; df.origin.y = ay; desc.frame = df;
    } @catch (NSException *e) {}
}
%end

// ---- iPad landscape watch page of 11.x / 12.x ----
#import "general.h"

static BOOL TRPadV1112(void) {
    int mv = majorVersion();
    return (mv == 11 || mv == 12) && [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad;
}
static BOOL TRSend0(id o, SEL s) { return [o respondsToSelector:s] ? ((BOOL (*)(id, SEL))objc_msgSend)(o, s) : NO; }

// The wide layout shows the video info (and sections the app counts as "details") in the left column and the rest in
// the right one. Comments were in the list on the right: count the comment sections as details, so they sit below the video info.
%hook YTWatchNextResultsViewController
- (BOOL)containsMetadataRenderer:(id)section {
    BOOL r = %orig;
    if (r || !TRPadV1112()) return r;
    @try {
        if (![NSStringFromClass([section class]) isEqualToString:@"YTIItemSectionRenderer"]) return r;
        NSArray *items = [section respondsToSelector:@selector(contentsArray)] ? [section performSelector:@selector(contentsArray)] : nil;
        for (id it in items) {
            if (TRSend0(it, @selector(hasCommentThreadRenderer)) || TRSend0(it, @selector(hasCommentsHeaderRenderer))) return YES;
        }
    } @catch (NSException *e) {}
    return r;
}
%end

// The right column is narrow, but the regular size class picks the wide row layout (with the channel picture): the text ran
// off the edge. Use the compact row layout whenever the row is narrow.
// ---- bigger suggested-video tiles (ReTube 1.3, best effort) ----
// The row's picture is made ~25% larger when the row has room for it. -sizeThatFits: asks for the extra height, and the picture
// only grows as far as the row's real height allows, so a row the app lays out by other means is left exactly as it was.
static const CGFloat kTRTileScale = 1.25;

static BOOL TRBigTilesOn(void) {
    static NSTimeInterval at = 0; static BOOL on = YES;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - at > 3.0) {
        at = now;
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/dev.preloading.tubereplacer.preferences.plist"];
        on = !p[@"BigTiles"] || [p[@"BigTiles"] boolValue];
    }
    return on;
}

// What a cell looks like (first few only): the log tells how to size the tiles properly if the guess below does nothing.
static void TRTileDumpTree(UIView *v, int depth, NSMutableString *d) {
    if (depth > 4) return;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2 + 4) withString:@" " startingAtIndex:0];
    for (UIView *s in v.subviews) {
        [d appendFormat:@"\n%@%@ %@%@", pad, NSStringFromClass([s class]), NSStringFromCGRect(s.frame), s.hidden ? @" hidden" : @""];
        TRTileDumpTree(s, depth + 1, d);
    }
}
static void TRTileDump(UIView *root, NSString *tag) {
    static int n = 0;
    if (n >= 4 || root.bounds.size.width < 50 || root.bounds.size.height < 30) return;
    n++;
    NSMutableString *d = [NSMutableString stringWithFormat:@"[TubeReplacer] tile #%d (%@): %@ %@", n, tag, NSStringFromClass([root class]), NSStringFromCGRect(root.frame)];
    UIView *up = root.superview;
    for (int i = 0; up && i < 3; i++, up = up.superview) [d appendFormat:@" < %@ %@", NSStringFromClass([up class]), NSStringFromCGRect(up.frame)];
    TRTileDumpTree(root, 0, d);
    NSLog(@"%@", d);
}

static BOOL TRIsThumbShape(UIView *v, CGFloat rowW) {
    CGRect f = v.frame;
    if (v.hidden || f.size.height < 40 || f.size.width < 70 || f.size.width > rowW * 0.65) return NO;
    CGFloat ar = f.size.width / f.size.height;
    return ar >= 1.5 && ar <= 1.95;
}
// The view (the root or something below it) that has the picture as a direct child.
static UIView *TRFindTileRow(UIView *root, int depth) {
    CGFloat w = root.bounds.size.width;
    for (UIView *v in root.subviews) if (TRIsThumbShape(v, w)) return root;
    if (depth >= 4) return nil;
    for (UIView *v in root.subviews) { UIView *r = TRFindTileRow(v, depth + 1); if (r) return r; }
    return nil;
}

static void TRBigTile(UIView *row) {
    @try {
        if (!TRBigTilesOn()) return;
        CGRect rb = row.bounds;
        // the picture: the biggest direct child with a video-like shape
        UIView *thumb = nil; CGFloat best = 0;
        for (UIView *v in row.subviews) {
            CGRect f = v.frame;
            if (v.hidden || f.size.height < 40 || f.size.width < 70 || f.size.width > rb.size.width * 0.65) continue;
            CGFloat ar = f.size.width / f.size.height;
            if (ar < 1.5 || ar > 1.95) continue;
            if (f.size.width * f.size.height > best) { best = f.size.width * f.size.height; thumb = v; }
        }
        if (!thumb) return;
        CGRect tf = thumb.frame;
        static const char kTRTileKey = 0;
        NSValue *was = objc_getAssociatedObject(thumb, &kTRTileKey);
        if (was && CGRectEqualToRect([was CGRectValue], tf)) return;   // the app did not re-lay it out: already enlarged
        CGFloat bottomPad = MAX(tf.origin.y, 4.0);
        CGFloat room = rb.size.height - tf.origin.y - bottomPad;       // height the row can give the picture
        CGFloat s = MIN(kTRTileScale, room / tf.size.height);
        if (s < 1.04) return;                                           // no room: leave the row alone
        CGFloat nw = floor(tf.size.width * s), nh = floor(tf.size.height * s);
        CGFloat dw = nw - tf.size.width, dh = nh - tf.size.height;
        // everything to the right of the picture moves over (and gets narrower when it ran to the edge)
        NSMutableArray *moves = [NSMutableArray array];
        for (UIView *v in row.subviews) {
            if (v == thumb) continue;
            CGRect f = v.frame;
            if (f.origin.x >= CGRectGetMaxX(tf) - 1.0) {
                CGRect g = f; g.origin.x += dw;
                if (CGRectGetMaxX(f) >= rb.size.width - 24.0) g.size.width = MAX(rb.size.width - 8.0 - g.origin.x, 0);
                if (g.size.width < 50.0 || CGRectGetMaxX(g) > rb.size.width + 1.0) return;   // would not fit: touch nothing
                [moves addObject:@[ v, [NSValue valueWithCGRect:g] ]];
            } else if (CGRectContainsPoint(tf, CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f)))) {
                // an overlay on the picture (length badge ...) keeps its place relative to the picture's corners
                CGFloat fx = (CGRectGetMidX(f) - tf.origin.x) / tf.size.width, fy = (CGRectGetMidY(f) - tf.origin.y) / tf.size.height;
                CGRect g = f; g.origin.x += dw * fx; g.origin.y += dh * fy;
                [moves addObject:@[ v, [NSValue valueWithCGRect:g] ]];
            }
        }
        for (NSArray *m in moves) ((UIView *)m[0]).frame = [m[1] CGRectValue];
        CGRect ng = tf; ng.size.width = nw; ng.size.height = nh;
        thumb.frame = ng;
        objc_setAssociatedObject(thumb, &kTRTileKey, [NSValue valueWithCGRect:ng], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) {}
}

static void TRBigTileIn(UIView *root, NSString *tag) {
    @try {
        if (!TRBigTilesOn()) return;
        TRTileDump(root, tag);
        UIView *row = TRFindTileRow(root, 0);
        if (row) TRBigTile(row);
    } @catch (NSException *e) {}
}
static BOOL gTRInSize = NO;
static CGSize TRBigTileSize(CGSize r) {
    if (r.height > 50.0 && r.height < 300.0 && TRBigTilesOn()) r.height += floor((r.height - 16.0) * (kTRTileScale - 1.0));
    return r;
}

%hook YTCompactVideoView
- (void)layoutSubviews {
    if (TRPadV1112() && [self respondsToSelector:@selector(layoutSubviews_compact)]) {
        CGFloat w = ((UIView *)self).bounds.size.width;
        if (w > 0 && w < 520) { ((void (*)(id, SEL))objc_msgSend)(self, @selector(layoutSubviews_compact)); TRBigTileIn((UIView *)self, @"YTCompactVideoView"); return; }
    }
    %orig;
    TRBigTileIn((UIView *)self, @"YTCompactVideoView");
}
- (CGSize)sizeThatFits:(CGSize)size {
    if (gTRInSize) return %orig;                  // only the outermost call (view inside cell, subclass inside superclass) adds the height
    gTRInSize = YES; CGSize r = %orig; gTRInSize = NO;
    return TRBigTileSize(r);
}
%end

// 12.x draws the suggestions with these cells (the view above is not always the one that gets laid out)
%hook YTCompactSuggestedVideoCell
- (void)layoutSubviews { %orig; TRBigTileIn((UIView *)self, @"YTCompactSuggestedVideoCell"); }
- (CGSize)sizeThatFits:(CGSize)size {
    if (gTRInSize) return %orig;                  // only the outermost call (view inside cell, subclass inside superclass) adds the height
    gTRInSize = YES; CGSize r = %orig; gTRInSize = NO;
    return TRBigTileSize(r);
}
%end

%hook YTCompactVideoCell
- (void)layoutSubviews { %orig; TRBigTileIn((UIView *)self, @"YTCompactVideoCell"); }
- (CGSize)sizeThatFits:(CGSize)size {
    if (gTRInSize) return %orig;                  // only the outermost call (view inside cell, subclass inside superclass) adds the height
    gTRInSize = YES; CGSize r = %orig; gTRInSize = NO;
    return TRBigTileSize(r);
}
%end

%hook YTSuggestedVideoCell
- (void)layoutSubviews { %orig; TRBigTileIn((UIView *)self, @"YTSuggestedVideoCell"); }
- (CGSize)sizeThatFits:(CGSize)size {
    if (gTRInSize) return %orig;                  // only the outermost call (view inside cell, subclass inside superclass) adds the height
    gTRInSize = YES; CGSize r = %orig; gTRInSize = NO;
    return TRBigTileSize(r);
}
%end
