#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"

static const void *kLGSpotlightOriginalTextTransformKey =
    &kLGSpotlightOriginalTextTransformKey;

static void LGUpdateSpotlightTextField(UIView *view) {
    NSValue *original = objc_getAssociatedObject(
        view, kLGSpotlightOriginalTextTransformKey);
    if (!lgHostEnabled(@"Spotlight")) {
        if (original) {
            view.transform = original.CGAffineTransformValue;
            objc_setAssociatedObject(view,
                                     kLGSpotlightOriginalTextTransformKey, nil,
                                     OBJC_ASSOCIATION_ASSIGN);
        }
        return;
    }
    if (!original) {
        objc_setAssociatedObject(
            view, kLGSpotlightOriginalTextTransformKey,
            [NSValue valueWithCGAffineTransform:view.transform],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.transform = CGAffineTransformTranslate(
        [objc_getAssociatedObject(view,
            kLGSpotlightOriginalTextTransformKey) CGAffineTransformValue],
        0.0, -5.0);
}

static BOOL LGSpotlightIsLegacy(void) {
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 13;
}

static UIView *LGSpotlightLegacyTintView(UIView *blurView) {
    UIView *field = blurView.superview;
    if (!field || ![field respondsToSelector:NSSelectorFromString(@"tintView")]) return nil;
    UIView *tint = nil;
    @try { tint = [field valueForKey:@"tintView"]; } @catch (__unused NSException *e) {}
    return [tint isKindOfClass:UIView.class] ? tint : nil;
}

static void LGUpdateSpotlightGlass(UIView *view) {
    if (LGSpotlightIsLegacy() && !hasAncestorOfClassName(view.superview, @"SPUITextField")) return;
    UIView *legacyTint = LGSpotlightIsLegacy() ? LGSpotlightLegacyTintView(view) : nil;
    if (!lgHostEnabled(@"Spotlight") || !view.window || CGRectIsEmpty(view.bounds)) {
        BOOL hadGlass = LGMaterialHasGlass(view, kGlassKey);
        LGRemoveGlassFromMaterial(view, kGlassKey);
        if (hadGlass) legacyTint.hidden = NO;
        return;
    }
    CGFloat radius = CGRectGetHeight(view.bounds) * 0.5;
    if (LGInstallRegisteredGlassInMaterial(view, kGlassKey, @"Spotlight",
                                           UIEdgeInsetsZero, radius, nil))
        legacyTint.hidden = YES;
}

%group LGSpotlightHooks

%hook SPUIHeaderBlurView

- (void)didMoveToWindow {
    %orig;
    LGUpdateSpotlightGlass((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGUpdateSpotlightGlass((UIView *)self);
}

- (void)setHidden:(BOOL)hidden {
    if (LGMaterialHasGlass((UIView *)self, kGlassKey)) hidden = YES;
    %orig(hidden);
}

%end

%end

%group LGSpotlightFieldHooks

%hook SPUITextField

- (void)didMoveToWindow {
    %orig;
    LGUpdateSpotlightTextField((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGUpdateSpotlightTextField((UIView *)self);
}

%end

%end

%ctor {
    BOOL modern = [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:
            (NSOperatingSystemVersion){16, 0, 0}];
    if (modern || (LGSpotlightIsLegacy() && NSClassFromString(@"SPUIHeaderBlurView")))
        %init(LGSpotlightHooks);
    if (modern) %init(LGSpotlightFieldHooks);
}
