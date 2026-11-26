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
%hook YTCompactVideoView
- (void)layoutSubviews {
    if (TRPadV1112() && [self respondsToSelector:@selector(layoutSubviews_compact)]) {
        CGFloat w = ((UIView *)self).bounds.size.width;
        if (w > 0 && w < 520) { ((void (*)(id, SEL))objc_msgSend)(self, @selector(layoutSubviews_compact)); return; }
    }
    %orig;
}
%end
