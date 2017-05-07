//
//  ASImageNode.mm
//  Texture
//
//  Copyright (c) 2014-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under the BSD-style license found in the
//  LICENSE file in the /ASDK-Licenses directory of this source tree. An additional
//  grant of patent rights can be found in the PATENTS file in the same directory.
//
//  Modifications to this file made after 4/13/2017 are: Copyright (c) 2017-present,
//  Pinterest, Inc.  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//

#import <AsyncDisplayKit/ASImageNode.h>

#import <tgmath.h>

#import <AsyncDisplayKit/_ASDisplayLayer.h>
#import <AsyncDisplayKit/ASAssert.h>
#import <AsyncDisplayKit/ASDimension.h>
#import <AsyncDisplayKit/ASDisplayNode+FrameworkSubclasses.h>
#import <AsyncDisplayKit/ASDisplayNodeExtras.h>
#import <AsyncDisplayKit/ASDisplayNode+Beta.h>
#import <AsyncDisplayKit/ASLayout.h>
#import <AsyncDisplayKit/ASTextNode.h>
#import <AsyncDisplayKit/ASImageNode+AnimatedImagePrivate.h>
#import <AsyncDisplayKit/ASImageNode+CGExtras.h>
#import <AsyncDisplayKit/AsyncDisplayKit+Debug.h>
#import <AsyncDisplayKit/ASInternalHelpers.h>
#import <AsyncDisplayKit/ASEqualityHelpers.h>
#import <AsyncDisplayKit/ASHashing.h>
#import <AsyncDisplayKit/ASWeakMap.h>
#import <AsyncDisplayKit/CoreGraphics+ASConvenience.h>

// TODO: It would be nice to remove this dependency; it's the only subclass using more than +FrameworkSubclasses.h
#import <AsyncDisplayKit/ASDisplayNodeInternal.h>

#include <functional>

@interface ASImageNodeDrawParameters : NSObject {
  @package
  UIImage *_image;
  BOOL _opaque;
  CGRect _bounds;
  CGFloat _contentsScale;
  UIColor *_backgroundColor;
  UIViewContentMode _contentMode;
  BOOL _cropEnabled;
  BOOL _forceUpscaling;
  CGSize _forcedSize;
  CGRect _cropRect;
  CGRect _cropDisplayBounds;
  asimagenode_modification_block_t _imageModificationBlock;
  ASDisplayNodeContextModifier _willDisplayNodeContentWithRenderingContext;
  ASDisplayNodeContextModifier _didDisplayNodeContentWithRenderingContext;
}

@end

@implementation ASImageNodeDrawParameters

@end


/**
 * Contains all data that is needed to generate the content bitmap.
 */
@interface ASImageNodeContentsKey : NSObject

@property (nonatomic, strong) UIImage *image;
@property (nonatomic, assign) CGSize backingSize;
@property (nonatomic, assign) CGRect imageDrawRect;
@property (nonatomic, assign, getter=isOpaque) BOOL opaque;
@property (nonatomic, strong) UIColor *backgroundColor;
@property (nonatomic, copy) ASDisplayNodeContextModifier willDisplayNodeContentWithRenderingContext;
@property (nonatomic, copy) ASDisplayNodeContextModifier didDisplayNodeContentWithRenderingContext;
@property (nonatomic, copy) asimagenode_modification_block_t imageModificationBlock;

@end

@implementation ASImageNodeContentsKey

- (BOOL)isEqual:(id)object
{
  if (self == object) {
    return YES;
  }

  // Optimization opportunity: The `isKindOfClass` call here could be avoided by not using the NSObject `isEqual:`
  // convention and instead using a custom comparison function that assumes all items are heterogeneous.
  // However, profiling shows that our entire `isKindOfClass` expression is only ~1/40th of the total
  // overheard of our caching, so it's likely not high-impact.
  if ([object isKindOfClass:[ASImageNodeContentsKey class]]) {
    ASImageNodeContentsKey *other = (ASImageNodeContentsKey *)object;
    return [_image isEqual:other.image]
      && CGSizeEqualToSize(_backingSize, other.backingSize)
      && CGRectEqualToRect(_imageDrawRect, other.imageDrawRect)
      && _opaque == other.isOpaque
      && [_backgroundColor isEqual:other.backgroundColor]
      && _willDisplayNodeContentWithRenderingContext == other.willDisplayNodeContentWithRenderingContext
      && _didDisplayNodeContentWithRenderingContext == other.didDisplayNodeContentWithRenderingContext
      && _imageModificationBlock == other.imageModificationBlock;
  } else {
    return NO;
  }
}

- (NSUInteger)hash
{
  struct {
    NSUInteger imageHash;
    CGSize backingSize;
    CGRect imageDrawRect;
    BOOL isOpaque;
    NSUInteger backgroundColorHash;
    void *willDisplayNodeContentWithRenderingContext;
    void *didDisplayNodeContentWithRenderingContext;
    void *imageModificationBlock;
  } data = {
    _image.hash,
    _backingSize,
    _imageDrawRect,
    _opaque,
    _backgroundColor.hash,
    (void *)_willDisplayNodeContentWithRenderingContext,
    (void *)_didDisplayNodeContentWithRenderingContext,
    (void *)_imageModificationBlock
  };
  return ASHashBytes(&data, sizeof(data));
}

@end


@implementation ASImageNode
{
@private
  UIImage *_image;
  //ASWeakMapEntry *_weakCacheEntry;  // Holds a reference that keeps our contents in cache.


  void (^_displayCompletionBlock)(BOOL canceled);
  
  // Drawing
  ASTextNode *_debugLabelNode;
  
  // Cropping.
  BOOL _cropEnabled; // Defaults to YES.
  BOOL _forceUpscaling; //Defaults to NO.
  CGSize _forcedSize; //Defaults to CGSizeZero, indicating no forced size.
  CGRect _cropRect; // Defaults to CGRectMake(0.5, 0.5, 0, 0)
  CGRect _cropDisplayBounds; // Defaults to CGRectNull
}

@synthesize image = _image;
@synthesize imageModificationBlock = _imageModificationBlock;

#pragma mark - NSObject

+ (void)initialize
{
  [super initialize];
  
  if (self != [ASImageNode class]) {
    // Prevent custom drawing in subclasses
    ASDisplayNodeAssert(!ASSubclassOverridesClassSelector([ASImageNode class], self, @selector(displayWithParameters:isCancelled:)), @"Subclass %@ must not override displayWithParameters:isCancelled: method. Custom drawing in %@ subclass is not supported.", NSStringFromClass(self), NSStringFromClass([ASImageNode class]));
  }
}

- (instancetype)init
{
  if (!(self = [super init]))
    return nil;

  // TODO can this be removed?
  self.contentsScale = ASScreenScale();
  self.contentMode = UIViewContentModeScaleAspectFill;
  self.opaque = NO;
  
  // If no backgroundColor is set to the image node and it's a subview of UITableViewCell, UITableView is setting
  // the opaque value of all subviews to YES if highlighting / selection is happening and does not set it back to the
  // initial value. With setting a explicit backgroundColor we can prevent that change.
  self.backgroundColor = [UIColor clearColor];

  _cropEnabled = YES;
  _forceUpscaling = NO;
  _cropRect = CGRectMake(0.5, 0.5, 0, 0);
  _cropDisplayBounds = CGRectNull;
  _placeholderColor = ASDisplayNodeDefaultPlaceholderColor();
  _animatedImageRunLoopMode = ASAnimatedImageDefaultRunLoopMode;
  
  return self;
}

- (void)dealloc
{
  // Invalidate all components around animated images
  [self invalidateAnimatedImage];
}

- (UIImage *)placeholderImage
{
  // FIXME: Replace this implementation with reusable CALayers that have .backgroundColor set.
  // This would completely eliminate the memory and performance cost of the backing store.
  CGSize size = self.calculatedSize;
  if ((size.width * size.height) < CGFLOAT_EPSILON) {
    return nil;
  }
  
  ASDN::MutexLocker l(__instanceLock__);
  
  UIGraphicsBeginImageContext(size);
  [self.placeholderColor setFill];
  UIRectFill(CGRectMake(0, 0, size.width, size.height));
  UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();
  
  return image;
}

#pragma mark - Layout and Sizing

- (CGSize)calculateSizeThatFits:(CGSize)constrainedSize
{
  __instanceLock__.lock();
  UIImage *image = _image;
  __instanceLock__.unlock();

  if (image == nil) {
    return [super calculateSizeThatFits:constrainedSize];
  }

  return image.size;
}

#pragma mark - Setter / Getter

- (void)setImage:(UIImage *)image
{
  ASDN::MutexLocker l(__instanceLock__);
  [self _locked_setImage:image];
}

- (void)_locked_setImage:(UIImage *)image
{
  if (ASObjectIsEqual(_image, image)) {
    return;
  }
  
  _image = image;
  
  if (image != nil) {
    
    // We explicitly call setNeedsDisplay in this case, although we know setNeedsDisplay will be called with lock held.
    // Therefore we have to be careful in methods that are involved with setNeedsDisplay to not run into a deadlock
    [self setNeedsDisplay];
    
    // For debugging purposes we don't care about locking for now
    if ([ASImageNode shouldShowImageScalingOverlay] && _debugLabelNode == nil) {
      ASPerformBlockOnMainThread(^{
        _debugLabelNode = [[ASTextNode alloc] init];
        _debugLabelNode.layerBacked = YES;
        [self addSubnode:_debugLabelNode];
      });
    }

  } else {
    self.contents = nil;
  }
}

- (UIImage *)image
{
  ASDN::MutexLocker l(__instanceLock__);
  return _image;
}

- (UIImage *)_locked_Image
{
  return _image;
}

- (void)setPlaceholderColor:(UIColor *)placeholderColor
{
  _placeholderColor = placeholderColor;

  // prevent placeholders if we don't have a color
  self.placeholderEnabled = placeholderColor != nil;
}

#pragma mark - Drawing

- (id<NSObject>)drawParametersForAsyncLayer:(_ASDisplayLayer *)layer
{
  NSMutableDictionary *drawParameters = [NSMutableDictionary dictionary];
  [self provideDrawParameters:drawParameters forAsyncLayer:layer];
  return drawParameters;
}

- (void)provideDrawParameters:(NSMutableDictionary *)drawParameters forAsyncLayer:(_ASDisplayLayer *)layer
{
  ASDN::MutexLocker l(__instanceLock__);
    
  // TODO: We can use the boxing stuff that @adlai-holler created for boxing the c++ struct
  ASImageNodeDrawParameters *params = [[ASImageNodeDrawParameters alloc] init];
  params->_image = [self _locked_Image];
  params->_bounds = [self threadSafeBounds];
  params->_opaque = self.opaque;
  params->_contentsScale = _contentsScaleForDisplay;
  params->_backgroundColor = self.backgroundColor;
  params->_contentMode = self.contentMode;
  params->_cropEnabled = _cropEnabled;
  params->_forceUpscaling = _forceUpscaling;
  params->_forcedSize = _forcedSize;
  params->_cropRect = _cropRect;
  params->_cropDisplayBounds = _cropDisplayBounds;
  params->_imageModificationBlock = _imageModificationBlock;
  params->_willDisplayNodeContentWithRenderingContext = _willDisplayNodeContentWithRenderingContext;
  params->_didDisplayNodeContentWithRenderingContext = _didDisplayNodeContentWithRenderingContext;

  drawParameters[@"params"] = params;
  
  // No need to contents key if no image
  ASImageNodeDrawParameters *drawParameter = params;
  UIImage *image = drawParameter->_image;
  if (image == nil) {
    return;
  }
  
  CGRect drawParameterBounds       = drawParameter->_bounds;
  CGSize forcedSize                = drawParameter->_forcedSize;
  BOOL cropEnabled                 = drawParameter->_cropEnabled;
  UIViewContentMode contentMode    = drawParameter->_contentMode;
  CGFloat contentsScale            = drawParameter->_contentsScale;
  CGRect cropDisplayBounds         = drawParameter->_cropDisplayBounds;
  CGRect cropRect                  = drawParameter->_cropRect;
  BOOL forceUpscaling              = drawParameter->_forceUpscaling;

  
  BOOL hasValidCropBounds = cropEnabled && !CGRectIsEmpty(cropDisplayBounds);
  CGRect bounds = (hasValidCropBounds ? cropDisplayBounds : drawParameterBounds);
  
  ASDisplayNodeAssert(contentsScale > 0, @"invalid contentsScale at display time");
  
  // if the image is resizable, bail early since the image has likely already been configured
  BOOL stretchable = !UIEdgeInsetsEqualToEdgeInsets(image.capInsets, UIEdgeInsetsZero);
  
  CGSize imageSize = image.size;
  CGSize imageSizeInPixels = CGSizeMake(imageSize.width * image.scale, imageSize.height * image.scale);
  CGSize boundsSizeInPixels = CGSizeMake(std::floor(bounds.size.width * contentsScale), std::floor(bounds.size.height * contentsScale));
  
  BOOL contentModeSupported = contentMode == UIViewContentModeScaleAspectFill ||
                              contentMode == UIViewContentModeScaleAspectFit ||
                              contentMode == UIViewContentModeCenter;
  
  CGSize backingSize   = CGSizeZero;
  CGRect imageDrawRect = CGRectZero;
  
  if (boundsSizeInPixels.width * contentsScale < 1.0f || boundsSizeInPixels.height * contentsScale < 1.0f ||
      imageSizeInPixels.width < 1.0f                  || imageSizeInPixels.height < 1.0f) {
    // Don't add the cache key if the size is not valid
    return;
  }
  
  
  // If we're not supposed to do any cropping, just decode image at original size
  if (!cropEnabled || !contentModeSupported || stretchable) {
    backingSize = imageSizeInPixels;
    imageDrawRect = (CGRect){.size = backingSize};
  } else {
    if (CGSizeEqualToSize(CGSizeZero, forcedSize) == NO) {
      //scale forced size
      forcedSize.width *= contentsScale;
      forcedSize.height *= contentsScale;
    }
      
    ASCroppedImageBackingSizeAndDrawRectInBounds(imageSizeInPixels,
                                                 boundsSizeInPixels,
                                                 contentMode,
                                                 cropRect,
                                                 forceUpscaling,
                                                 forcedSize,
                                                 &backingSize,
                                                 &imageDrawRect);
  }
  
  // Add cache key
  
  ASImageNodeContentsKey *contentsKey = [[ASImageNodeContentsKey alloc] init];
  contentsKey.image = image;
  contentsKey.backingSize = backingSize;
  contentsKey.imageDrawRect = imageDrawRect;
  contentsKey.opaque = self.isOpaque;
  contentsKey.backgroundColor = self.backgroundColor;
  contentsKey.willDisplayNodeContentWithRenderingContext = self.willDisplayNodeContentWithRenderingContext;
  contentsKey.didDisplayNodeContentWithRenderingContext = self.didDisplayNodeContentWithRenderingContext;
  contentsKey.imageModificationBlock = self.imageModificationBlock;
  
  drawParameters[ASDisplayLayerDrawParameterCacheKey] = contentsKey;
}

- (NSDictionary *)debugLabelAttributes
{
  return @{
    NSFontAttributeName: [UIFont systemFontOfSize:15.0],
    NSForegroundColorAttributeName: [UIColor redColor]
  };
}

- (UIImage *)displayWithParameters:(NSMutableDictionary *)parameter isCancelled:(asdisplaynode_iscancelled_block_t)isCancelled
{
  ASImageNodeDrawParameters *drawParameter = parameter[@"params"];
  UIImage *image = drawParameter->_image;
  if (image == nil) {
    return nil;
  }
  
  //CGRect drawParameterBounds       = drawParameter->_bounds;
  //BOOL cropEnabled                 = drawParameter->_cropEnabled;
  //CGFloat contentsScale            = drawParameter->_contentsScale;
  //CGRect cropDisplayBounds         = drawParameter->_cropDisplayBounds;
  asimagenode_modification_block_t imageModificationBlock                 = drawParameter->_imageModificationBlock;

  
  //BOOL hasValidCropBounds = cropEnabled && !CGRectIsEmpty(cropDisplayBounds);
  //CGRect bounds = (hasValidCropBounds ? cropDisplayBounds : drawParameterBounds);
  
  
  //ASDisplayNodeAssert(contentsScale > 0, @"invalid contentsScale at display time");
  
  // if the image is resizable, bail early since the image has likely already been configured
  BOOL stretchable = !UIEdgeInsetsEqualToEdgeInsets(image.capInsets, UIEdgeInsetsZero);
  if (stretchable) {
    if (imageModificationBlock != NULL) {
      image = imageModificationBlock(image);
    }
    return image;
  }
  
    ASImageNodeContentsKey *contentsKey = parameter[ASDisplayLayerDrawParameterCacheKey];

  if (contentsKey.backingSize.width <= 0.0f        || contentsKey.backingSize.height <= 0.0f ||
      contentsKey.imageDrawRect.size.width <= 0.0f || contentsKey.imageDrawRect.size.height <= 0.0f) {
    return nil;
  }

  if (isCancelled()) {
    return nil;
  }
    
  
  return [self.class createContentsForkey:contentsKey isCancelled:isCancelled];

}

+ (UIImage *)createContentsForkey:(ASImageNodeContentsKey *)key isCancelled:(asdisplaynode_iscancelled_block_t)isCancelled
{
  // The following `UIGraphicsBeginImageContextWithOptions` call will sometimes take take longer than 5ms on an
  // A5 processor for a 400x800 backingSize.
  // Check for cancellation before we call it.
  if (isCancelled()) {
    return nil;
  }

  // Use contentsScale of 1.0 and do the contentsScale handling in boundsSizeInPixels so ASCroppedImageBackingSizeAndDrawRectInBounds
  // will do its rounding on pixel instead of point boundaries
  UIGraphicsBeginImageContextWithOptions(key.backingSize, key.isOpaque, 1.0);
  
  BOOL contextIsClean = YES;
  
  CGContextRef context = UIGraphicsGetCurrentContext();
  if (context && key.willDisplayNodeContentWithRenderingContext) {
    key.willDisplayNodeContentWithRenderingContext(context);
    contextIsClean = NO;
  }
  
  // if view is opaque, fill the context with background color
  if (key.isOpaque && key.backgroundColor) {
    [key.backgroundColor setFill];
    UIRectFill({ .size = key.backingSize });
    contextIsClean = NO;
  }
  
  // iOS 9 appears to contain a thread safety regression when drawing the same CGImageRef on
  // multiple threads concurrently.  In fact, instead of crashing, it appears to deadlock.
  // The issue is present in Mac OS X El Capitan and has been seen hanging Pro apps like Adobe Premiere,
  // as well as iOS games, and a small number of ASDK apps that provide the same image reference
  // to many separate ASImageNodes.  A workaround is to set .displaysAsynchronously = NO for the nodes
  // that may get the same pointer for a given UI asset image, etc.
  // FIXME: We should replace @synchronized here, probably using a global, locked NSMutableSet, and
  // only if the object already exists in the set we should create a semaphore to signal waiting threads
  // upon removal of the object from the set when the operation completes.
  // Another option is to have ASDisplayNode+AsyncDisplay coordinate these cases, and share the decoded buffer.
  // Details tracked in https://github.com/facebook/AsyncDisplayKit/issues/1068
  
  UIImage *image = key.image;
  BOOL canUseCopy = (contextIsClean || ASImageAlphaInfoIsOpaque(CGImageGetAlphaInfo(image.CGImage)));
  CGBlendMode blendMode = canUseCopy ? kCGBlendModeCopy : kCGBlendModeNormal;
  
  @synchronized(image) {
    [image drawInRect:key.imageDrawRect blendMode:blendMode alpha:1];
  }
  
  if (context && key.didDisplayNodeContentWithRenderingContext) {
    key.didDisplayNodeContentWithRenderingContext(context);
  }

  // The following `UIGraphicsGetImageFromCurrentImageContext` call will commonly take more than 20ms on an
  // A5 processor.  Check for cancellation before we call it.
  if (isCancelled()) {
    UIGraphicsEndImageContext();
    return nil;
  }

  UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
  
  UIGraphicsEndImageContext();
  
  if (key.imageModificationBlock != NULL) {
    result = key.imageModificationBlock(result);
  }
  
  return result;
}

- (void)displayDidFinish
{
  [super displayDidFinish];

  __instanceLock__.lock();
    void (^displayCompletionBlock)(BOOL canceled) = _displayCompletionBlock;
    UIImage *image = _image;
    BOOL hasDebugLabel = (_debugLabelNode != nil);
  __instanceLock__.unlock();

  // Update the debug label if necessary
  if (hasDebugLabel) {
    // For debugging purposes we don't care about locking for now
    CGSize imageSize = image.size;
    CGSize imageSizeInPixels = CGSizeMake(imageSize.width * image.scale, imageSize.height * image.scale);
    CGSize boundsSizeInPixels = CGSizeMake(std::floor(self.bounds.size.width * self.contentsScale), std::floor(self.bounds.size.height * self.contentsScale));
    CGFloat pixelCountRatio            = (imageSizeInPixels.width * imageSizeInPixels.height) / (boundsSizeInPixels.width * boundsSizeInPixels.height);
    if (pixelCountRatio != 1.0) {
      NSString *scaleString            = [NSString stringWithFormat:@"%.2fx", pixelCountRatio];
      _debugLabelNode.attributedText   = [[NSAttributedString alloc] initWithString:scaleString attributes:[self debugLabelAttributes]];
      _debugLabelNode.hidden           = NO;
    } else {
      _debugLabelNode.hidden           = YES;
      _debugLabelNode.attributedText   = nil;
    }
  }
  
  // If we've got a block to perform after displaying, do it.
  if (image && displayCompletionBlock) {

    displayCompletionBlock(NO);

    __instanceLock__.lock();
      _displayCompletionBlock = nil;
    __instanceLock__.unlock();
  }
}

- (void)setNeedsDisplayWithCompletion:(void (^ _Nullable)(BOOL canceled))displayCompletionBlock
{
  if (self.displaySuspended) {
    if (displayCompletionBlock)
      displayCompletionBlock(YES);
    return;
  }

  // Stash the block and call-site queue. We'll invoke it in -displayDidFinish.
  {
    ASDN::MutexLocker l(__instanceLock__);
    if (_displayCompletionBlock != displayCompletionBlock) {
      _displayCompletionBlock = displayCompletionBlock;
    }
  }

  [self setNeedsDisplay];
}

#pragma mark Interface State

- (void)clearContents
{
  [super clearContents];
    
//  __instanceLock__.lock();
//    _weakCacheEntry = nil;  // release contents from the cache.
//  __instanceLock__.unlock();
}

#pragma mark - Cropping

- (BOOL)isCropEnabled
{
  ASDN::MutexLocker l(__instanceLock__);
  return _cropEnabled;
}

- (void)setCropEnabled:(BOOL)cropEnabled
{
  [self setCropEnabled:cropEnabled recropImmediately:NO inBounds:self.bounds];
}

- (void)setCropEnabled:(BOOL)cropEnabled recropImmediately:(BOOL)recropImmediately inBounds:(CGRect)cropBounds
{
  __instanceLock__.lock();
  if (_cropEnabled == cropEnabled) {
    __instanceLock__.unlock();
    return;
  }

  _cropEnabled = cropEnabled;
  _cropDisplayBounds = cropBounds;
  
  UIImage *image = _image;
  __instanceLock__.unlock();

  // If we have an image to display, display it, respecting our recrop flag.
  if (image != nil) {
    ASPerformBlockOnMainThread(^{
      if (recropImmediately)
        [self displayImmediately];
      else
        [self setNeedsDisplay];
    });
  }
}

- (CGRect)cropRect
{
  ASDN::MutexLocker l(__instanceLock__);
  return _cropRect;
}

- (void)setCropRect:(CGRect)cropRect
{
  {
    ASDN::MutexLocker l(__instanceLock__);
    if (CGRectEqualToRect(_cropRect, cropRect)) {
      return;
    }

    _cropRect = cropRect;
  }

  // TODO: this logic needs to be updated to respect cropRect.
  CGSize boundsSize = self.bounds.size;
  CGSize imageSize = self.image.size;

  BOOL isCroppingImage = ((boundsSize.width < imageSize.width) || (boundsSize.height < imageSize.height));

  // Re-display if we need to.
  ASPerformBlockOnMainThread(^{
    if (self.nodeLoaded && self.contentMode == UIViewContentModeScaleAspectFill && isCroppingImage)
      [self setNeedsDisplay];
  });
}

- (BOOL)forceUpscaling
{
  ASDN::MutexLocker l(__instanceLock__);
  return _forceUpscaling;
}

- (void)setForceUpscaling:(BOOL)forceUpscaling
{
  ASDN::MutexLocker l(__instanceLock__);
  _forceUpscaling = forceUpscaling;
}

- (CGSize)forcedSize
{
  ASDN::MutexLocker l(__instanceLock__);
  return _forcedSize;
}

- (void)setForcedSize:(CGSize)forcedSize
{
  ASDN::MutexLocker l(__instanceLock__);
  _forcedSize = forcedSize;
}

- (asimagenode_modification_block_t)imageModificationBlock
{
  ASDN::MutexLocker l(__instanceLock__);
  return _imageModificationBlock;
}

- (void)setImageModificationBlock:(asimagenode_modification_block_t)imageModificationBlock
{
  ASDN::MutexLocker l(__instanceLock__);
  _imageModificationBlock = imageModificationBlock;
}

#pragma mark - Debug

- (void)layout
{
  [super layout];
  
  if (_debugLabelNode) {
    CGSize boundsSize        = self.bounds.size;
    CGSize debugLabelSize    = [_debugLabelNode layoutThatFits:ASSizeRangeMake(CGSizeZero, boundsSize)].size;
    CGPoint debugLabelOrigin = CGPointMake(boundsSize.width - debugLabelSize.width,
                                           boundsSize.height - debugLabelSize.height);
    _debugLabelNode.frame    = (CGRect) {debugLabelOrigin, debugLabelSize};
  }
}
@end

#pragma mark - Extras

extern asimagenode_modification_block_t ASImageNodeRoundBorderModificationBlock(CGFloat borderWidth, UIColor *borderColor)
{
  return ^(UIImage *originalImage) {
    UIGraphicsBeginImageContextWithOptions(originalImage.size, NO, originalImage.scale);
    UIBezierPath *roundOutline = [UIBezierPath bezierPathWithOvalInRect:(CGRect){CGPointZero, originalImage.size}];

    // Make the image round
    [roundOutline addClip];

    // Draw the original image
    [originalImage drawAtPoint:CGPointZero blendMode:kCGBlendModeCopy alpha:1];

    // Draw a border on top.
    if (borderWidth > 0.0) {
      [borderColor setStroke];
      [roundOutline setLineWidth:borderWidth];
      [roundOutline stroke];
    }

    UIImage *modifiedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return modifiedImage;
  };
}

extern asimagenode_modification_block_t ASImageNodeTintColorModificationBlock(UIColor *color)
{
  return ^(UIImage *originalImage) {
    UIGraphicsBeginImageContextWithOptions(originalImage.size, NO, originalImage.scale);
    
    // Set color and render template
    [color setFill];
    UIImage *templateImage = [originalImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [templateImage drawAtPoint:CGPointZero blendMode:kCGBlendModeCopy alpha:1];
    
    UIImage *modifiedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    // if the original image was stretchy, keep it stretchy
    if (!UIEdgeInsetsEqualToEdgeInsets(originalImage.capInsets, UIEdgeInsetsZero)) {
      modifiedImage = [modifiedImage resizableImageWithCapInsets:originalImage.capInsets resizingMode:originalImage.resizingMode];
    }

    return modifiedImage;
  };
}
