#import <UIKit/UIKit.h>
#import "../Shared/LGCompat.h"
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import <objc/runtime.h>

static const void *kLGPageDotsGlassKey = &kLGPageDotsGlassKey;
static NSHashTable<UIPageControl *> *sLGPageDotsControls;

static BOOL isSearchPillMaterial(UIView *mat) {
    if (!isExactClass(mat, @"MTMaterialView")) return NO;
    return hasAncestorOfClassName(mat, @"SBFolderScrollAccessoryView");
}

static void LGRemovePageDotsPill(UIPageControl *control) {
    UIView *glass = objc_getAssociatedObject(control, kLGPageDotsGlassKey);
    [glass removeFromSuperview];
    objc_setAssociatedObject(control, kLGPageDotsGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGUpdatePageDotsPill(UIPageControl *control) {
    NSInteger minimumPages = control.hidesForSinglePage ? 2 : 1;
    if (!control.window || !lgHostEnabled(@"SearchPill") ||
        control.numberOfPages < minimumPages || CGRectIsEmpty(control.bounds)) {
        LGRemovePageDotsPill(control);
        return;
    }
    if (!sLGPageDotsControls) sLGPageDotsControls = [NSHashTable weakObjectsHashTable];
    [sLGPageDotsControls addObject:control];

    CGSize dots = [control sizeForNumberOfPages:control.numberOfPages];
    CGFloat height = MIN(26.0, CGRectGetHeight(control.bounds));
    CGFloat width = MIN(CGRectGetWidth(control.bounds), dots.width + 20.0);
    CGRect frame = CGRectMake(floor(CGRectGetMidX(control.bounds) - width * 0.5),
                              floor(CGRectGetMidY(control.bounds) - height * 0.5),
                              width, height);

    LGLiveBackdropView *glass = objc_getAssociatedObject(control, kLGPageDotsGlassKey);
    if (!glass) {
        glass = LGCreateRegisteredGlass(frame, nil, @"SearchPill");
        if (!glass) return;
        glass.autoresizingMask = UIViewAutoresizingNone;
        objc_setAssociatedObject(control, kLGPageDotsGlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"SearchPill", nil);
    }
    if (glass.superview != control || control.subviews.firstObject != glass)
        [control insertSubview:glass atIndex:0];
    if (!CGRectEqualToRect(glass.frame, frame)) glass.frame = frame;
    if (fabs(glass.layer.cornerRadius - height * 0.5) > 0.01) {
        glass.layer.cornerRadius = height * 0.5;
        LGLayerSetContinuousCorners(glass.layer);
        glass.layer.masksToBounds = YES;
        [glass applyFilters];
    }
}

%group LGLegacyPageDotsHooks

%hook SBIconListPageControl

- (void)didMoveToWindow {
    %orig;
    LGUpdatePageDotsPill((UIPageControl *)self);
}

- (void)layoutSubviews {
    %orig;
    LGUpdatePageDotsPill((UIPageControl *)self);
}

- (void)setNumberOfPages:(NSInteger)pages {
    %orig;
    LGUpdatePageDotsPill((UIPageControl *)self);
}

%end

%end

%ctor {
    LGRegisterMaterialHost(@"SearchPill", 100, ^BOOL(UIView *material) {
        return isSearchPillMaterial(material);
    }, UIEdgeInsetsZero, ^CGFloat(UIView *material) {

        return material.layer.cornerRadius > 0.0 ? -1.0 : CGRectGetHeight(material.bounds) * 0.5;
    }, nil, nil);

    Class pageControl = NSClassFromString(@"SBIconListPageControl");
    if (pageControl && NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 13) {
        %init(LGLegacyPageDotsHooks, SBIconListPageControl = pageControl);
        lgObservePreferenceReload(^{
            for (UIPageControl *control in sLGPageDotsControls.allObjects)
                LGUpdatePageDotsPill(control);
        });
    }
}
