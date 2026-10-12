#import <UIKit/UIKit.h>
#import "../Shared/LGCompat.h"
#import <math.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static void *kLGAppIconGlassKey = &kLGAppIconGlassKey;

static BOOL LGIsAppIconImageView(UIView *view) {
    if (!view || !isExactClass(view, @"SBIconImageView")) return NO;
    if (fabs(CGRectGetWidth(view.bounds) - 60.0) > 0.5 ||
        fabs(CGRectGetHeight(view.bounds) - 60.0) > 0.5) return NO;

    UIView *parent = view.superview;
    UIView *grandparent = parent.superview;
    Class iconViewClass = NSClassFromString(@"SBIconView");
    if (!iconViewClass || !parent) return NO;
    if ([grandparent isKindOfClass:iconViewClass]) return YES;
    return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 13 &&
           [parent isKindOfClass:iconViewClass];
}

static void LGRemoveAppIconGlass(UIView *iconView) {
    LGLiveBackdropView *glass = objc_getAssociatedObject(iconView, kLGAppIconGlassKey);
    [glass removeFromSuperview];
    objc_setAssociatedObject(iconView, kLGAppIconGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGInstallAppIconGlass(UIView *iconView) {
    if (!LGIsAppIconImageView(iconView) || !iconView.window ||
        !lgHostEnabled(@"AppIcons")) {
        LGRemoveAppIconGlass(iconView);
        return;
    }

    UIView *parent = iconView.superview;
    if (!parent) return;

    LGLiveBackdropView *glass = objc_getAssociatedObject(iconView, kLGAppIconGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(iconView.frame, nil, @"AppIcons");
        if (!glass) return;
        glass.userInteractionEnabled = NO;
        glass.autoresizingMask = UIViewAutoresizingNone;
        objc_setAssociatedObject(iconView, kLGAppIconGlassKey,
                                 glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (glass.superview != parent) [glass removeFromSuperview];
    // the source icon stays visible above its glass underlay
    [parent insertSubview:glass belowSubview:iconView];
    glass.frame = iconView.frame;

    CGFloat radius = CGRectGetWidth(iconView.frame) * 0.225;
    glass.layer.cornerRadius = radius;
    LGLayerSetContinuousCorners(glass.layer);
    glass.layer.masksToBounds = YES;
    lgTrackGlass(glass, @"AppIcons", nil);
}

%hook SBIconImageView

- (void)didMoveToWindow {
    %orig;
    LGInstallAppIconGlass((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGInstallAppIconGlass((UIView *)self);
}

%end
