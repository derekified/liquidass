#import "LGKitGlassView.h"
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <simd/simd.h>

void LGLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#define LG_KIT_MAX_RECTANGLES 16

const LGKitGlassParameters LGKitGlassParametersRegular = {
    .glassThickness = 10.0,
    .refractiveIndex = 1.5,
    .dispersionStrength = 5.0,
    .fresnelDistanceRange = 70.0,
    .fresnelIntensity = 0.0,
    .fresnelEdgeSharpness = 0.0,
    .glareDistanceRange = 30.0,
    .glareAngleConvergence = 0.1,
    .glareOppositeSideBias = 1.0,
    .glareIntensity = 0.1,
    .glareEdgeSharpness = -0.15,
    .backgroundTextureScaleCoefficient = 0.2,
    .backgroundTextureBlurRadius = 0.3,
};

// Must match ShaderUniforms in kLGKitShaderSource; simd types give Metal's alignment.
typedef struct {
    simd_float2 resolution;
    float contentsScale;
    simd_float2 touchPoint;
    float shapeMergeSmoothness;
    float cornerRadius;
    float cornerRoundnessExponent;
    simd_float4 materialTint;
    float glassThickness;
    float refractiveIndex;
    float dispersionStrength;
    float fresnelDistanceRange;
    float fresnelIntensity;
    float fresnelEdgeSharpness;
    float glareDistanceRange;
    float glareAngleConvergence;
    float glareOppositeSideBias;
    float glareIntensity;
    float glareEdgeSharpness;
    float glareDirectionOffset;
    int32_t rectangleCount;
    simd_float4 rectangles[LG_KIT_MAX_RECTANGLES];
} LGKitShaderUniforms;

#define LG_MSL(...) #__VA_ARGS__

static NSString *const kLGKitShaderSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
LG_MSL(
constant float refractiveIndexRed = 1.0f - 0.02f;
constant float refractiveIndexGreen = 1.0f;
constant float refractiveIndexBlue = 1.0f + 0.02f;

struct VertexOutput {
    float4 position [[position]];
    half2 uv;
};

constant int maxRectangles = 16;

struct ShaderUniforms {
    float2 resolution;
    float contentsScale;
    float2 touchPoint;
    float shapeMergeSmoothness;
    float cornerRadius;
    float cornerRoundnessExponent;
    float4 materialTint;
    float glassThickness;
    float refractiveIndex;
    float dispersionStrength;
    float fresnelDistanceRange;
    float fresnelIntensity;
    float fresnelEdgeSharpness;
    float glareDistanceRange;
    float glareAngleConvergence;
    float glareOppositeSideBias;
    float glareIntensity;
    float glareEdgeSharpness;
    float glareDirectionOffset;
    int rectangleCount;
    float4 rectangles[maxRectangles];
};

constexpr sampler textureSampler(filter::linear, mag_filter::linear, min_filter::linear,
                                 address::clamp_to_edge);

vertex VertexOutput fullscreenQuad(uint vertexID [[vertex_id]]) {
    float2 positions[4] = { float2(-1.0f, -1.0f), float2(1.0f, -1.0f),
                            float2(-1.0f, 1.0f), float2(1.0f, 1.0f) };
    float2 uvs[4] = { float2(0.0f, 0.0f), float2(1.0f, 0.0f),
                      float2(0.0f, 1.0f), float2(1.0f, 1.0f) };
    VertexOutput output;
    output.position = float4(positions[vertexID], 0.0f, 1.0f);
    output.uv = half2(uvs[vertexID]);
    return output;
}

float superellipseCornerSDF(float2 point, float radius, float exponent) {
    point = abs(point);
    float value = pow(pow(point.x, exponent) + pow(point.y, exponent), 1.0f / exponent);
    return value - radius;
}

float roundedRectangleSDF(float2 fragmentCoord, float4 rect, float cornerRadius,
                          float roundnessExponent, constant ShaderUniforms& uniforms) {
    float2 rectOriginPx = rect.xy * uniforms.contentsScale;
    float2 rectSizePx = rect.zw * uniforms.contentsScale;
    float scaledCornerRadius = cornerRadius * uniforms.contentsScale;
    float2 rectCenterPx = rectOriginPx + rectSizePx * 0.5f;
    float2 point = fragmentCoord - rectCenterPx;
    float2 halfExtents = rectSizePx * 0.5f;
    float2 edgeDistance = abs(point) - halfExtents;
    float surfaceDistance;
    if (edgeDistance.x > -scaledCornerRadius && edgeDistance.y > -scaledCornerRadius) {
        float2 cornerCenter = sign(point) * (halfExtents - float2(scaledCornerRadius));
        float2 cornerRelativePoint = point - cornerCenter;
        surfaceDistance = superellipseCornerSDF(cornerRelativePoint, scaledCornerRadius, roundnessExponent);
    } else {
        surfaceDistance = min(max(edgeDistance.x, edgeDistance.y), 0.0f) + length(max(edgeDistance, 0.0f));
    }
    return surfaceDistance;
}

float smoothUnion(float distanceA, float distanceB, float smoothness) {
    float hermite = clamp(0.5f + 0.5f * (distanceB - distanceA) / smoothness, 0.0f, 1.0f);
    return mix(distanceB, distanceA, hermite) - smoothness * hermite * (1.0f - hermite);
}

float primaryShapeSDF(float2 fragmentCoord, constant ShaderUniforms& uniforms) {
    float combinedDistance = 1e10f;
    for (int i = 0; i < uniforms.rectangleCount && i < maxRectangles; ++i) {
        float4 rect = uniforms.rectangles[i];
        if (rect.z <= 0.0f || rect.w <= 0.0f) continue;
        float rectDistance = roundedRectangleSDF(fragmentCoord, rect, uniforms.cornerRadius,
                                                 uniforms.cornerRoundnessExponent, uniforms);
        float normalizedRectDist = rectDistance / uniforms.resolution.y;
        if (i == 0) combinedDistance = normalizedRectDist;
        else combinedDistance = smoothUnion(combinedDistance, normalizedRectDist, uniforms.shapeMergeSmoothness);
    }
    return combinedDistance;
}

float2 computeSurfaceNormal(float2 fragmentCoord, constant ShaderUniforms& uniforms) {
    float2 epsilon = float2(max(abs(dfdx(fragmentCoord.x)), 0.0001f),
                            max(abs(dfdy(fragmentCoord.y)), 0.0001f));
    float2 gradient = float2(
        primaryShapeSDF(fragmentCoord + float2(epsilon.x, 0.0f), uniforms) -
        primaryShapeSDF(fragmentCoord - float2(epsilon.x, 0.0f), uniforms),
        primaryShapeSDF(fragmentCoord + float2(0.0f, epsilon.y), uniforms) -
        primaryShapeSDF(fragmentCoord - float2(0.0f, epsilon.y), uniforms)
    ) / (2.0f * epsilon);
    return gradient * 1.414213562f * 1000.0f;
}

constant float3 d65WhitePoint = float3(0.95045592705f, 1.0f, 1.08905775076f);
constant float3 whiteReference = d65WhitePoint;

constant float3x3 rgbToXyzMatrix = float3x3(
    float3(0.4124f, 0.3576f, 0.1805f),
    float3(0.2126f, 0.7152f, 0.0722f),
    float3(0.0193f, 0.1192f, 0.9505f));

constant float3x3 xyzToRgbMatrix = float3x3(
    float3( 3.2406255f, -1.537208f , -0.4986286f),
    float3(-0.9689307f,  1.8757561f,  0.0415175f),
    float3( 0.0557101f, -0.2040211f,  1.0569959f));

float linearizeSRGB(float channel) {
    return channel > 0.04045f ? pow((channel + 0.055f) / 1.055f, 2.4f) : channel / 12.92f;
}

float gammaCorrectSRGB(float linear) {
    return linear <= 0.0031308f ? 12.92f * linear : 1.055f * pow(linear, 0.41666666666f) - 0.055f;
}

half3 srgbToLinear(half3 srgb) {
    return half3(linearizeSRGB(srgb.x), linearizeSRGB(srgb.y), linearizeSRGB(srgb.z));
}

half3 linearToSrgb(half3 linear) {
    return half3(gammaCorrectSRGB(linear.x), gammaCorrectSRGB(linear.y), gammaCorrectSRGB(linear.z));
}

float xyzToLabNonlinear(float normalizedX) {
    return normalizedX > 0.00885645167f ? pow(normalizedX, 1.0f / 3.0f) : 7.78703703704f * normalizedX + 0.13793103448f;
}

float3 xyzToLab(float3 xyz) {
    float3 scaledXyz = xyz / whiteReference;
    scaledXyz = float3(xyzToLabNonlinear(scaledXyz.x), xyzToLabNonlinear(scaledXyz.y),
                       xyzToLabNonlinear(scaledXyz.z));
    return float3(116.0f * scaledXyz.y - 16.0f, 500.0f * (scaledXyz.x - scaledXyz.y),
                  200.0f * (scaledXyz.y - scaledXyz.z));
}

float3 srgbToLch(half3 srgb) {
    float3 lab = xyzToLab(float3(srgbToLinear(srgb)) * rgbToXyzMatrix);
    return float3(lab.x, sqrt(dot(lab.yz, lab.yz)), atan2(lab.z, lab.y) * (180.0f / M_PI_F));
}

float labToXyzNonlinear(float transformed) {
    return transformed > 0.206897f ? transformed * transformed * transformed : 0.12841854934f * (transformed - 0.137931034f);
}

half3 lchToSrgb(float3 lch) {
    float hueRadians = lch.z * (M_PI_F / 180.0f);
    float3 lab = float3(lch.x, lch.y * cos(hueRadians), lch.y * sin(hueRadians));
    float whiteScaled = (lab.x + 16.0f) / 116.0f;
    float3 xyz = whiteReference * float3(labToXyzNonlinear(whiteScaled + lab.y / 500.0f),
                                         labToXyzNonlinear(whiteScaled),
                                         labToXyzNonlinear(whiteScaled - lab.z / 200.0f));
    return linearToSrgb(half3(xyz * xyzToRgbMatrix));
}

float vectorToAngle(float2 vector) {
    float angle = atan2(vector.y, vector.x);
    return (angle < 0.0f) ? angle + 2.0f * M_PI_F : angle;
}

half4 sampleWithDispersion(texture2d<half> texture, float2 baseUv, float2 offset, float dispersionFactor) {
    half4 color = half4(1.0h);
    color.r = texture.sample(textureSampler, baseUv + offset * (1.0f - (refractiveIndexRed - 1.0f) * dispersionFactor)).r;
    color.g = texture.sample(textureSampler, baseUv + offset * (1.0f - (refractiveIndexGreen - 1.0f) * dispersionFactor)).g;
    color.b = texture.sample(textureSampler, baseUv + offset * (1.0f - (refractiveIndexBlue - 1.0f) * dispersionFactor)).b;
    return color;
}

fragment half4 liquidGlassEffect(VertexOutput input [[stage_in]],
                                 constant ShaderUniforms& uniforms [[buffer(0)]],
                                 texture2d<half> background [[texture(0)]]) {
    float2 logicalResolution = uniforms.resolution / uniforms.contentsScale;
    float2 fragmentPixelCoord = float2(input.uv) * uniforms.resolution;
    float shapeDistance = primaryShapeSDF(fragmentPixelCoord, uniforms);
    half4 outputColor;

    if (shapeDistance < 0.005f) {
        float normalizedDepth = -shapeDistance * logicalResolution.y;
        float depthRatio = 1.0f - normalizedDepth / uniforms.glassThickness;
        float incidentAngle = asin(pow(depthRatio, 2.0f));
        float transmittedAngle = asin(1.0f / uniforms.refractiveIndex * sin(incidentAngle));
        float edgeShiftFactor = -tan(transmittedAngle - incidentAngle);
        if (normalizedDepth >= uniforms.glassThickness) edgeShiftFactor = 0.0f;

        if (edgeShiftFactor <= 0.0f) {
            outputColor = background.sample(textureSampler, float2(input.uv));
            outputColor = mix(outputColor, half4(half3(uniforms.materialTint.rgb), 1.0h), half(uniforms.materialTint.a * 0.8f));
        } else {
            float2 surfaceNormal = computeSurfaceNormal(fragmentPixelCoord, uniforms);
            half2 offsetUv = half2(-surfaceNormal * edgeShiftFactor * 0.05f * uniforms.contentsScale * float2(
                uniforms.resolution.y / (logicalResolution.x * uniforms.contentsScale), 1.0f));
            half4 refractedWithDispersion = sampleWithDispersion(background, float2(input.uv), float2(offsetUv), uniforms.dispersionStrength);

            outputColor = mix(refractedWithDispersion, half4(half3(uniforms.materialTint.rgb), 1.0h), half(uniforms.materialTint.a * 0.8f));

            float fresnelValue = clamp(pow(1.0f + shapeDistance * logicalResolution.y / 1500.0f *
                pow(500.0f / uniforms.fresnelDistanceRange, 2.0f) + uniforms.fresnelEdgeSharpness, 5.0f), 0.0f, 1.0f);
            half3 fresnelBaseTint = mix(half3(1.0h), half3(uniforms.materialTint.rgb), half(uniforms.materialTint.a * 0.5f));
            float3 fresnelLch = srgbToLch(fresnelBaseTint);
            fresnelLch.x += 20.0f * fresnelValue * uniforms.fresnelIntensity;
            fresnelLch.x = clamp(fresnelLch.x, 0.0f, 100.0f);
            outputColor = mix(outputColor, half4(lchToSrgb(fresnelLch), 1.0h),
                              half(fresnelValue * uniforms.fresnelIntensity * 0.7f * length(surfaceNormal)));

            float glareGeometryValue = clamp(pow(1.0f + shapeDistance * logicalResolution.y / 1500.0f *
                pow(500.0f / uniforms.glareDistanceRange, 2.0f) + uniforms.glareEdgeSharpness, 5.0f), 0.0f, 1.0f);
            float glareAngle = (vectorToAngle(normalize(surfaceNormal)) - M_PI_F / 4.0f + uniforms.glareDirectionOffset) * 2.0f;
            int isFarSide = 0;
            if ((glareAngle > M_PI_F * (2.0f - 0.5f) && glareAngle < M_PI_F * (4.0f - 0.5f)) || glareAngle < M_PI_F * (0.0f - 0.5f))
                isFarSide = 1;
            float angularGlare = (0.5f + sin(glareAngle) * 0.5f) *
                                 (isFarSide == 1 ? 1.2f * uniforms.glareOppositeSideBias : 1.2f) *
                                 uniforms.glareIntensity;
            angularGlare = clamp(pow(angularGlare, 0.1f + uniforms.glareAngleConvergence * 2.0f), 0.0f, 1.0f);

            half3 baseGlare = mix(refractedWithDispersion.rgb, half3(uniforms.materialTint.rgb), half(uniforms.materialTint.a * 0.5f));
            float3 glareLch = srgbToLch(baseGlare);
            glareLch.x += 150.0f * angularGlare * glareGeometryValue;
            glareLch.y += 30.0f * angularGlare * glareGeometryValue;
            glareLch.x = clamp(glareLch.x, 0.0f, 120.0f);
            outputColor = mix(outputColor, half4(lchToSrgb(glareLch), 1.0h),
                              half(angularGlare * glareGeometryValue * length(surfaceNormal)));
        }
    } else {
        outputColor = half4(0);
    }

    return mix(outputColor, half4(0), smoothstep(-0.01f, 0.005f, shapeDistance));
}
);

#pragma mark - Renderer

@interface LGKitRenderer : NSObject
@property (nonatomic, strong, readonly) id<MTLDevice> device;
@property (nonatomic, strong, readonly) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign, readonly) BOOL supportsMPS;
+ (instancetype)shared;
@end

@implementation LGKitRenderer

+ (instancetype)shared {
    static LGKitRenderer *renderer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ renderer = [[LGKitRenderer alloc] initPrivate]; });
    return renderer;
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        LGLog(@"[LGKit] no Metal device");
        return nil;
    }
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kLGKitShaderSource options:[MTLCompileOptions new] error:&error];
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"fullscreenQuad"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"liquidGlassEffect"];
    if (!vertexFunction || !fragmentFunction) {
        LGLog(@"[LGKit] shader compile failed: %@", error.localizedDescription);
        return nil;
    }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    _commandQueue = [_device newCommandQueue];
    if (!_pipelineState || !_commandQueue) {
        LGLog(@"[LGKit] pipeline creation failed: %@", error.localizedDescription);
        return nil;
    }
    _supportsMPS = MPSSupportsMTLDevice(_device);
    LGLog(@"[LGKit] renderer ready device=%@ mps=%d", _device.name, _supportsMPS);
    return self;
}

@end

#pragma mark - Zero-copy bridge

@interface LGKitZeroCopyBridge : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)setupBufferWithWidth:(size_t)width height:(size_t)height;
- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions;
@end

@implementation LGKitZeroCopyBridge {
    CVMetalTextureCacheRef _textureCache;
    CVPixelBufferRef _pixelBuffer;
    CVMetalTextureRef _cvTexture;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_textureCache);
    if (status != kCVReturnSuccess) {
        LGLog(@"[LGKit] texture cache creation failed: %d", status);
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_cvTexture) CFRelease(_cvTexture);
    if (_pixelBuffer) CVPixelBufferRelease(_pixelBuffer);
    if (_textureCache) CFRelease(_textureCache);
}

- (void)setupBufferWithWidth:(size_t)width height:(size_t)height {
    if (_cvTexture) { CFRelease(_cvTexture); _cvTexture = NULL; }
    if (_pixelBuffer) { CVPixelBufferRelease(_pixelBuffer); _pixelBuffer = NULL; }
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attributes, &_pixelBuffer);
    if (status != kCVReturnSuccess || !_pixelBuffer) {
        LGLog(@"[LGKit] pixel buffer creation failed: %d", status);
        _pixelBuffer = NULL;
        return;
    }
    status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, _pixelBuffer, NULL,
                                                       MTLPixelFormatBGRA8Unorm, width, height, 0, &_cvTexture);
    if (status != kCVReturnSuccess) _cvTexture = NULL;
}

- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions {
    if (!_pixelBuffer || !_cvTexture) return nil;
    CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(_pixelBuffer),
                                                 CVPixelBufferGetWidth(_pixelBuffer),
                                                 CVPixelBufferGetHeight(_pixelBuffer), 8,
                                                 CVPixelBufferGetBytesPerRow(_pixelBuffer), colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (context) {
        actions(context);
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
    CVMetalTextureCacheFlush(_textureCache, 0);
    return context ? CVMetalTextureGetTexture(_cvTexture) : nil;
}

@end

#pragma mark - Backdrop capture view

@interface LGKitBackdropView : UIView
- (void)lgSetCaptureBlurRadius:(CGFloat)radius;
@end

@implementation LGKitBackdropView {
    CGFloat _captureBlurRadius;
}

+ (Class)layerClass { return NSClassFromString(@"CABackdropLayer") ?: CALayer.class; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    @try {
        [self.layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
        [self.layer setValue:@YES forKey:@"windowServerAware"];
        [self.layer setValue:NSUUID.UUID.UUIDString forKey:@"groupName"];
    } @catch (__unused NSException *exception) {}
    return self;
}

// Used only when MPS cannot run on the device: the blur is applied by the render
// server while the snapshot is taken instead of on the captured texture.
- (void)lgSetCaptureBlurRadius:(CGFloat)radius {
    if (fabs(_captureBlurRadius - radius) < 0.01) return;
    _captureBlurRadius = radius;
    Class filterClass = NSClassFromString(@"CAFilter");
    SEL filterWithName = NSSelectorFromString(@"filterWithName:");
    if (radius <= 0.0 || ![filterClass respondsToSelector:filterWithName]) {
        self.layer.filters = nil;
        return;
    }
    @try {
        id blur = ((id (*)(Class, SEL, NSString *))objc_msgSend)(filterClass, filterWithName, @"gaussianBlur");
        [blur setValue:@(radius) forKey:@"inputRadius"];
        [blur setValue:@YES forKey:@"inputNormalizeEdges"];
        self.layer.filters = blur ? @[blur] : nil;
    } @catch (__unused NSException *exception) {}
}

@end

#pragma mark - Glass view

@implementation LGKitGlassView {
    LGKitBackdropView *_backdropView;
    LGKitZeroCopyBridge *_zeroCopyBridge;
    id<MTLTexture> _backgroundTexture;
    MPSImageGaussianBlur *_blur;
    float _blurSigma;
    size_t _bufferWidth;
    size_t _bufferHeight;
}

+ (BOOL)lgEngineAvailable {
    return LGKitRenderer.shared != nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    LGKitRenderer *renderer = LGKitRenderer.shared;
    if (!renderer) return nil;
    self = [super initWithFrame:frame device:renderer.device];
    if (!self) return nil;
    _zeroCopyBridge = [[LGKitZeroCopyBridge alloc] initWithDevice:renderer.device];
    if (!_zeroCopyBridge) return nil;
    _backdropView = [LGKitBackdropView new];
    _lgParameters = LGKitGlassParametersRegular;
    _lgShapeRect = CGRectNull;
    _lgGlareDirectionOffset = -M_PI_4;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    self.userInteractionEnabled = NO;
    self.opaque = NO;
    self.layer.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.enableSetNeedsDisplay = NO;
    self.paused = YES;
    return self;
}

- (void)dealloc {
    [_backdropView removeFromSuperview];
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
    [super willMoveToSuperview:newSuperview];
    if (newSuperview != self.superview) [_backdropView removeFromSuperview];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self lgUpdatePaused];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    _backdropView.hidden = hidden;
    [self lgUpdatePaused];
}

- (void)lgUpdatePaused {
    self.paused = !self.window || self.hidden;
}

- (void)setLgParameters:(LGKitGlassParameters)parameters {
    BOOL scaleChanged = fabs(parameters.backgroundTextureScaleCoefficient -
                             _lgParameters.backgroundTextureScaleCoefficient) > 0.001;
    _lgParameters = parameters;
    if (scaleChanged) [self setNeedsLayout];
}

- (CGFloat)lgContentsScale {
    CGFloat scale = self.window.screen.scale;
    return scale > 0.0 ? scale : UIScreen.mainScreen.scale;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = [self lgContentsScale] * _lgParameters.backgroundTextureScaleCoefficient;
    size_t width = (size_t)MAX(1.0, ceil(CGRectGetWidth(self.bounds) * scale));
    size_t height = (size_t)MAX(1.0, ceil(CGRectGetHeight(self.bounds) * scale));
    if (width != _bufferWidth || height != _bufferHeight) {
        _bufferWidth = width;
        _bufferHeight = height;
        _backgroundTexture = nil;
        [_zeroCopyBridge setupBufferWithWidth:width height:height];
    }
}

#pragma mark Background capture

- (void)captureBackdrop {
    UIView *superview = self.superview;
    if (!superview) return;
    CGFloat scaleCoefficient = [self lgContentsScale] * _lgParameters.backgroundTextureScaleCoefficient;

    // The presentation layer carries the in-flight frame during UIView animations.
    CALayer *currentLayer = self.layer.presentationLayer ?: self.layer;
    CGRect captureRect = [currentLayer convertRect:currentLayer.bounds toLayer:superview.layer];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!CGRectEqualToRect(_backdropView.frame, captureRect)) _backdropView.frame = captureRect;
    if (_backdropView.superview != superview) [superview insertSubview:_backdropView belowSubview:self];
    [CATransaction commit];

    BOOL serverBlur = !LGKitRenderer.shared.supportsMPS;
    [_backdropView lgSetCaptureBlurRadius:serverBlur
        ? _lgParameters.backgroundTextureBlurRadius / MAX(0.01, _lgParameters.backgroundTextureScaleCoefficient)
        : 0.0];

    LGKitBackdropView *backdropView = _backdropView;
    _backgroundTexture = [_zeroCopyBridge renderWithActions:^(CGContextRef context) {
        CGContextClearRect(context, CGRectMake(0, 0, CGBitmapContextGetWidth(context), CGBitmapContextGetHeight(context)));
        CGContextScaleCTM(context, scaleCoefficient, scaleCoefficient);
        UIGraphicsPushContext(context);
        [backdropView drawViewHierarchyInRect:backdropView.bounds afterScreenUpdates:NO];
        UIGraphicsPopContext();
    }];
}

- (void)encodeBlurIntoCommandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    LGKitRenderer *renderer = LGKitRenderer.shared;
    if (!renderer.supportsMPS || _lgParameters.backgroundTextureBlurRadius <= 0.0 || !_backgroundTexture) return;
    float sigma = (float)(_lgParameters.backgroundTextureBlurRadius * [self lgContentsScale]);
    if (!_blur || fabsf(_blurSigma - sigma) > 0.001f) {
        _blur = [[MPSImageGaussianBlur alloc] initWithDevice:renderer.device sigma:sigma];
        _blur.edgeMode = MPSImageEdgeModeClamp;
        _blurSigma = sigma;
    }
    id<MTLTexture> texture = _backgroundTexture;
    MPSCopyAllocator allocator = ^id<MTLTexture> NS_RETURNS_RETAINED (MPSKernel *kernel, id<MTLCommandBuffer> buffer, id<MTLTexture> source) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat
                                                               width:source.width
                                                              height:source.height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        descriptor.storageMode = MTLStorageModePrivate;
        return [buffer.device newTextureWithDescriptor:descriptor];
    };
    if ([_blur encodeToCommandBuffer:commandBuffer inPlaceTexture:&texture fallbackCopyAllocator:allocator])
        _backgroundTexture = texture;
}

#pragma mark Uniforms

- (LGKitShaderUniforms)currentUniforms {
    LGKitShaderUniforms uniforms;
    memset(&uniforms, 0, sizeof(uniforms));
    CGFloat scale = [self lgContentsScale];
    CGRect bounds = self.bounds;
    uniforms.resolution = simd_make_float2((float)(CGRectGetWidth(bounds) * scale),
                                           (float)(CGRectGetHeight(bounds) * scale));
    uniforms.contentsScale = (float)scale;
    uniforms.shapeMergeSmoothness = 0.2f;
    uniforms.cornerRoundnessExponent = 2.0f;

    CGRect shape = (CGRectIsNull(_lgShapeRect) || CGRectIsEmpty(_lgShapeRect)) ? bounds : _lgShapeRect;
    // The fullscreen quad puts uv (0,0) at the bottom-left, so rectangles are given bottom-up.
    uniforms.rectangleCount = 1;
    uniforms.rectangles[0] = simd_make_float4((float)CGRectGetMinX(shape),
                                              (float)(CGRectGetHeight(bounds) - CGRectGetMaxY(shape)),
                                              (float)CGRectGetWidth(shape), (float)CGRectGetHeight(shape));
    CGFloat radius = MAX(0.0, MIN(_lgCornerRadius, MIN(CGRectGetWidth(shape), CGRectGetHeight(shape)) * 0.5));
    uniforms.cornerRadius = (float)radius;

    CGFloat r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    if ([_lgTintColor getRed:&r green:&g blue:&b alpha:&a])
        uniforms.materialTint = simd_make_float4((float)r, (float)g, (float)b, (float)a);

    const LGKitGlassParameters *p = &_lgParameters;
    uniforms.glassThickness = (float)MAX(0.5, p->glassThickness);
    uniforms.refractiveIndex = (float)MAX(1.0001, p->refractiveIndex);
    uniforms.dispersionStrength = (float)p->dispersionStrength;
    uniforms.fresnelDistanceRange = (float)MAX(0.01, p->fresnelDistanceRange);
    uniforms.fresnelIntensity = (float)p->fresnelIntensity;
    uniforms.fresnelEdgeSharpness = (float)p->fresnelEdgeSharpness;
    uniforms.glareDistanceRange = (float)MAX(0.01, p->glareDistanceRange);
    uniforms.glareAngleConvergence = (float)p->glareAngleConvergence;
    uniforms.glareOppositeSideBias = (float)p->glareOppositeSideBias;
    uniforms.glareIntensity = (float)p->glareIntensity;
    uniforms.glareEdgeSharpness = (float)p->glareEdgeSharpness;
    uniforms.glareDirectionOffset = (float)_lgGlareDirectionOffset;
    return uniforms;
}

#pragma mark Drawing

- (void)drawRect:(CGRect)rect {
    if (!self.window || CGRectIsEmpty(self.bounds)) return;
    [self captureBackdrop];
    if (!_backgroundTexture) return;

    LGKitRenderer *renderer = LGKitRenderer.shared;
    id<MTLCommandBuffer> commandBuffer = [renderer.commandQueue commandBuffer];
    if (!commandBuffer) return;
    [self encodeBlurIntoCommandBuffer:commandBuffer];

    id<CAMetalDrawable> drawable = self.currentDrawable;
    MTLRenderPassDescriptor *pass = self.currentRenderPassDescriptor;
    if (!drawable || !pass) return;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return;

    LGKitShaderUniforms uniforms = [self currentUniforms];
    [encoder setRenderPipelineState:renderer.pipelineState];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:_backgroundTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

@end
