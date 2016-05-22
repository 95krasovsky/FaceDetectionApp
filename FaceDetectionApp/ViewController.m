//
//  ViewController.m
//  FaceDetectionPOC
//
//  Created by Jeroen Trappers on 30/04/12.
//  Copyright (c) 2012 iCapps. All rights reserved.
//

#import "ViewController.h"
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <AssertMacros.h>
#import <AssetsLibrary/AssetsLibrary.h>

static CGFloat DegreesToRadians(CGFloat degrees) {return degrees * M_PI / 180;};

@interface ViewController ()

@property (nonatomic) BOOL isUsingFrontFacingCamera;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property (nonatomic) dispatch_queue_t videoDataOutputQueue;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property (nonatomic, strong) UIImage *borderImage;
@property (nonatomic, strong) CIDetector *faceDetector;

@end

@implementation ViewController

- (void)setupAVCapture
{
	NSError *error = nil;
	
	AVCaptureSession *session = [[AVCaptureSession alloc] init];
	if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone){
	    [session setSessionPreset:AVCaptureSessionPresetHigh];
	} else {
	    [session setSessionPreset:AVCaptureSessionPresetPhoto];
	}
    
    // Select a video device, make an input
	AVCaptureDevice *device;
	
    AVCaptureDevicePosition desiredPosition = AVCaptureDevicePositionFront;
	
   //  find the front facing camera
    for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if ([d position] == desiredPosition) {
            device = d;
            self.isUsingFrontFacingCamera = YES;
            break;
        }
    }
	    // fall back to the default camera.
    if( nil == device )
    {
        self.isUsingFrontFacingCamera = NO;
        device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    
    // get the input device
    AVCaptureDeviceInput *deviceInput = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    
	if( !error ) {
        
        // add the input to the session
        if ( [session canAddInput:deviceInput] ){
            [session addInput:deviceInput];
        }
        
        
        // Make a video data output
        self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
        
        // we want BGRA, both CoreGraphics and OpenGL work well with 'BGRA'
        NSDictionary *rgbOutputSettings = [NSDictionary dictionaryWithObject:
                                           [NSNumber numberWithInt:kCMPixelFormat_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey];
        [self.videoDataOutput setVideoSettings:rgbOutputSettings];
        [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES]; // discard if the data output queue is blocked
        
        // create a serial dispatch queue used for the sample buffer delegate
        // a serial dispatch queue must be used to guarantee that video frames will be delivered in order
        // see the header doc for setSampleBufferDelegate:queue: for more information
        self.videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);
        [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
        
        if ( [session canAddOutput:self.videoDataOutput] ){
            [session addOutput:self.videoDataOutput];
        }
        
        // get the output for doing face detection.
        [[self.videoDataOutput connectionWithMediaType:AVMediaTypeVideo] setEnabled:YES]; 

        self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:session];
        self.previewLayer.backgroundColor = [[UIColor blackColor] CGColor];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        CALayer *rootLayer = [self.previewView layer];
        [rootLayer setMasksToBounds:YES];
        [self.previewLayer setFrame:[rootLayer bounds]];
      //  self.previewLayer.connection.videoOrientation = (AVCaptureVideoOrientation)UIDeviceOrientationLandscapeLeft;

        [rootLayer addSublayer:self.previewLayer];
        [session startRunning];
        
    }
	session = nil;
	if (error) {
		UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:
                            [NSString stringWithFormat:@"Failed with error %d", (int)[error code]]
                                               message:[error localizedDescription]
										      delegate:nil 
								     cancelButtonTitle:@"Dismiss" 
								     otherButtonTitles:nil];
		[alertView show];
		[self teardownAVCapture];
	}
}

// clean up capture setup
- (void)teardownAVCapture
{
	self.videoDataOutput = nil;
	if (self.videoDataOutputQueue) {
//		dispatch_release(self.videoDataOutputQueue);
    }
	[self.previewLayer removeFromSuperlayer];
	self.previewLayer = nil;
}


// utility routine to display error aleart if takePicture fails
- (void)displayErrorOnMainQueue:(NSError *)error withMessage:(NSString *)message
{
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		UIAlertView *alertView = [[UIAlertView alloc] 
                initWithTitle:[NSString stringWithFormat:@"%@ (%d)", message, (int)[error code]]
                      message:[error localizedDescription]
				     delegate:nil 
		    cancelButtonTitle:@"Dismiss" 
		    otherButtonTitles:nil];
        [alertView show];
	});
}


// find where the video box is positioned within the preview layer based on the video size and gravity
+ (CGRect)videoPreviewBoxForGravity:(NSString *)gravity 
                          frameSize:(CGSize)frameSize 
                       apertureSize:(CGSize)apertureSize
{
    CGFloat apertureRatio = apertureSize.height / apertureSize.width;
//    CGFloat viewRatio = frameSize.width / frameSize.height;
    CGFloat viewRatio = frameSize.height / frameSize.width;
    CGSize size = CGSizeZero;
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        if (viewRatio > apertureRatio) {
            size.width = frameSize.width;
//            size.height = apertureSize.width * (frameSize.width / apertureSize.height);
            size.height = frameSize.height;
        } else {
            size.width = frameSize.width;

//            size.width = apertureSize.height * (frameSize.height / apertureSize.width);
            size.height = frameSize.height;
        }
    } else if ([gravity isEqualToString:AVLayerVideoGravityResizeAspect]) {
        if (viewRatio > apertureRatio) {
            size.width = apertureSize.height * (frameSize.height / apertureSize.width);
            size.height = frameSize.height;
        } else {
            size.width = frameSize.width;
            size.height = apertureSize.width * (frameSize.width / apertureSize.height);
        }
    } else if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
        size.width = frameSize.width;
        size.height = frameSize.height;
    }
	
	CGRect videoBox;
	videoBox.size = size;
	if (size.width < frameSize.width)
		videoBox.origin.x = (frameSize.width - size.width) / 2;
	else
		videoBox.origin.x = (size.width - frameSize.width) / 2;
	
	if ( size.height < frameSize.height )
		videoBox.origin.y = (frameSize.height - size.height) / 2;
	else
		videoBox.origin.y = (size.height - frameSize.height) / 2;
    
	return videoBox;
}

// called asynchronously as the capture output is capturing sample buffers, this method asks the face detector
// to detect features and for each draw the green border in a layer and set appropriate orientation
- (void)drawFaces:(NSArray *)features 
      forVideoBox:(CGRect)clearAperture 
      orientation:(UIDeviceOrientation)orientation
{
	NSArray *sublayers = [NSArray arrayWithArray:[self.previewLayer sublayers]];
	NSInteger sublayersCount = [sublayers count], currentSublayer = 0;
	NSInteger featuresCount = [features count], currentFeature = 0;
	
	[CATransaction begin];
	[CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
	
	// hide all the face layers
	for ( CALayer *layer in sublayers ) {
		if ( [[layer name] isEqualToString:@"FaceLayer"] )
			[layer setHidden:YES];
	}	
	
	if ( featuresCount == 0 ) {
		[CATransaction commit];
		return; // early bail.
	}
    
	CGSize parentFrameSize = [self.previewView frame].size;
	NSString *gravity = [self.previewLayer videoGravity];
	BOOL isMirrored = [self.previewLayer isMirrored];
	CGRect previewBox = [ViewController videoPreviewBoxForGravity:gravity 
                                                        frameSize:parentFrameSize 
                                                     apertureSize:clearAperture.size];
	
	for ( CIFaceFeature *ff in features ) {
		// find the correct position for the square layer within the previewLayer
		// the feature box originates in the bottom left of the video frame.
		// (Bottom right if mirroring is turned on)
		CGRect faceRect = [ff bounds];
        NSLog(@"%@", NSStringFromCGRect(faceRect));
		 //flip preview width and height
        
        switch (orientation) {
            case UIDeviceOrientationPortrait:{
                CGFloat temp = faceRect.size.width;
                faceRect.size.width = faceRect.size.height;
                faceRect.size.height = temp;
                temp = faceRect.origin.x;
                faceRect.origin.x = faceRect.origin.y;
                faceRect.origin.y = temp;
                
                // scale coordinates so they fit in the preview box, which may be scaled
                CGFloat widthScaleBy = previewBox.size.width / clearAperture.size.height;
                CGFloat heightScaleBy = previewBox.size.height / clearAperture.size.width;
                faceRect.size.width *= widthScaleBy;
                faceRect.size.height *= heightScaleBy;
                faceRect.origin.x *= widthScaleBy;
                faceRect.origin.y *= heightScaleBy;
                
                if ( isMirrored )
                    //			faceRect = CGRectOffset(faceRect, previewBox.origin.x + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y);
                    faceRect = CGRectOffset(faceRect, previewBox.origin.x  + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y);
                
                else
                    faceRect = CGRectOffset(faceRect, previewBox.origin.x, previewBox.origin.y);

            }
                break;
            case UIDeviceOrientationLandscapeLeft:{
                // scale coordinates so they fit in the preview box, which may be scaled
                CGFloat widthScaleBy = previewBox.size.width / clearAperture.size.width;
                CGFloat heightScaleBy = previewBox.size.height / clearAperture.size.height;
                faceRect.size.width *= widthScaleBy;
                faceRect.size.height *= heightScaleBy;
                faceRect.origin.x *= widthScaleBy;
                faceRect.origin.y *= heightScaleBy;
                
                if ( isMirrored )
                    //			faceRect = CGRectOffset(faceRect, previewBox.origin.x + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y);
                    faceRect = CGRectOffset(faceRect, previewBox.origin.x, previewBox.origin.y);
                
                else
                    faceRect = CGRectOffset(faceRect, previewBox.origin.x, previewBox.origin.y + previewBox.size.height - faceRect.size.height - (faceRect.origin.y * 2));
                
            }
                
                break; // leave the layer in its last known orientation
            case UIDeviceOrientationLandscapeRight:{
                // scale coordinates so they fit in the preview box, which may be scaled
                CGFloat widthScaleBy = previewBox.size.width / clearAperture.size.width;
                CGFloat heightScaleBy = previewBox.size.height / clearAperture.size.height;
                faceRect.size.width *= widthScaleBy;
                faceRect.size.height *= heightScaleBy;
                faceRect.origin.x *= widthScaleBy;
                faceRect.origin.y *= heightScaleBy;
                
                if ( isMirrored )
                    //			faceRect = CGRectOffset(faceRect, previewBox.origin.x + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y);
                    faceRect = CGRectOffset(faceRect, previewBox.origin.x  + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y + previewBox.size.height - faceRect.size.height - (faceRect.origin.y * 2));
                
                else
                    faceRect = CGRectOffset(faceRect, previewBox.origin.x+ previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y);
                
            }
                
                break; // leave the layer in its last known orientation

            case UIDeviceOrientationFaceUp:
            case UIDeviceOrientationFaceDown:
            default: break;
        }
		
		
				
		CALayer *featureLayer = nil;
		
		// re-use an existing layer if possible
		while ( !featureLayer && (currentSublayer < sublayersCount) ) {
			CALayer *currentLayer = [sublayers objectAtIndex:currentSublayer++];
			if ( [[currentLayer name] isEqualToString:@"FaceLayer"] ) {
				featureLayer = currentLayer;
				[currentLayer setHidden:NO];
			}
		}
		
		// create a new one if necessary
		if ( !featureLayer ) {
			featureLayer = [[CALayer alloc]init];
			featureLayer.contents = (id)self.borderImage.CGImage;
            featureLayer.borderColor = [UIColor yellowColor].CGColor;
            featureLayer.borderWidth = 2.0;
			[featureLayer setName:@"FaceLayer"];
			[self.previewLayer addSublayer:featureLayer];
			featureLayer = nil;
		}
		[featureLayer setFrame:faceRect];
//		
//		switch (orientation) {
//			case UIDeviceOrientationPortrait:
//				[featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(0.))];
//				break;
//			case UIDeviceOrientationPortraitUpsideDown:
//				[featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(180.))];
//				break;
//			case UIDeviceOrientationLandscapeLeft:
//				[featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(90.))];
//				break;
//			case UIDeviceOrientationLandscapeRight:
//				[featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(-90.))];
//				break;
//			case UIDeviceOrientationFaceUp:
//			case UIDeviceOrientationFaceDown:
//			default:
//				break; // leave the layer in its last known orientation
//		}
		currentFeature++;
	}
	
	[CATransaction commit];
}

- (NSNumber *) exifOrientation: (UIDeviceOrientation) orientation
{
	int exifOrientation;
    /* kCGImagePropertyOrientation values
     The intended display orientation of the image. If present, this key is a CFNumber value with the same value as defined
     by the TIFF and EXIF specifications -- see enumeration of integer constants. 
     The value specified where the origin (0,0) of the image is located. If not present, a value of 1 is assumed.
     
     used when calling featuresInImage: options: The value for this key is an integer NSNumber from 1..8 as found in kCGImagePropertyOrientation.
     If present, the detection will be done based on that orientation but the coordinates in the returned features will still be based on those of the image. */
    
	enum {
		PHOTOS_EXIF_0ROW_TOP_0COL_LEFT			= 1, //   1  =  0th row is at the top, and 0th column is on the left (THE DEFAULT).
		PHOTOS_EXIF_0ROW_TOP_0COL_RIGHT			= 2, //   2  =  0th row is at the top, and 0th column is on the right.  
		PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT      = 3, //   3  =  0th row is at the bottom, and 0th column is on the right.  
		PHOTOS_EXIF_0ROW_BOTTOM_0COL_LEFT       = 4, //   4  =  0th row is at the bottom, and 0th column is on the left.  
		PHOTOS_EXIF_0ROW_LEFT_0COL_TOP          = 5, //   5  =  0th row is on the left, and 0th column is the top.  
		PHOTOS_EXIF_0ROW_RIGHT_0COL_TOP         = 6, //   6  =  0th row is on the right, and 0th column is the top.  
		PHOTOS_EXIF_0ROW_RIGHT_0COL_BOTTOM      = 7, //   7  =  0th row is on the right, and 0th column is the bottom.  
		PHOTOS_EXIF_0ROW_LEFT_0COL_BOTTOM       = 8  //   8  =  0th row is on the left, and 0th column is the bottom.  
	};
	
	switch (orientation) {
		case UIDeviceOrientationPortraitUpsideDown:  // Device oriented vertically, home button on the top
			exifOrientation = PHOTOS_EXIF_0ROW_LEFT_0COL_BOTTOM;
			break;
		case UIDeviceOrientationLandscapeLeft:       // Device oriented horizontally, home button on the right
			if (self.isUsingFrontFacingCamera)
				exifOrientation = PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT;
			else
				exifOrientation = PHOTOS_EXIF_0ROW_TOP_0COL_LEFT;
			break;
		case UIDeviceOrientationLandscapeRight:      // Device oriented horizontally, home button on the left
			if (self.isUsingFrontFacingCamera)
				exifOrientation = PHOTOS_EXIF_0ROW_TOP_0COL_LEFT;
			else
				exifOrientation = PHOTOS_EXIF_0ROW_BOTTOM_0COL_RIGHT;
			break;
		case UIDeviceOrientationPortrait:            // Device oriented vertically, home button on the bottom
		default:
			exifOrientation = PHOTOS_EXIF_0ROW_RIGHT_0COL_TOP;
			break;
	}
    return [NSNumber numberWithInt:exifOrientation];
}

- (UIImage *) imageFromSampleBuffer:(CMSampleBufferRef) sampleBuffer
{
    // Get a CMSampleBuffer's Core Video image buffer for the media data
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    // Lock the base address of the pixel buffer
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    // Get the number of bytes per row for the pixel buffer
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    
    // Get the number of bytes per row for the pixel buffer
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    // Get the pixel buffer width and height
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    // Create a device-dependent RGB color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    // Create a bitmap graphics context with the sample buffer data
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8,
                                                 bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    // Create a Quartz image from the pixel data in the bitmap graphics context
    CGImageRef quartzImage = CGBitmapContextCreateImage(context);
    // Unlock the pixel buffer
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    
    // Free up the context and color space
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    // Create an image object from the Quartz image
    UIImage *image = [UIImage imageWithCGImage:quartzImage];
    
    // Release the Quartz image
    CGImageRelease(quartzImage);
    
    return (image);
}
- (void)captureOutput:(AVCaptureOutput *)captureOutput 
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer 
       fromConnection:(AVCaptureConnection *)connection
{
    UIDeviceOrientation curDeviceOrientation = [[UIDevice currentDevice] orientation];

	// get the image
	CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
	CIImage *ciImage = [[CIImage alloc] initWithCVPixelBuffer:pixelBuffer 
                                                      options:(__bridge NSDictionary *)attachments];
//    UIImage *image = [UIImage imageWithCIImage:ciImage];
    UIImage *image = [self imageFromSampleBuffer:sampleBuffer];
    
	if (attachments) {
		CFRelease(attachments);
    }
    
    // make sure your device orientation is not locked.
    
	NSDictionary *imageOptions = nil;
    
	imageOptions = [NSDictionary dictionaryWithObject:[self exifOrientation:curDeviceOrientation] 
                                               forKey:CIDetectorImageOrientation];
    
	NSArray *features = [self.faceDetector featuresInImage:ciImage 
                                                   options:imageOptions];
    

//    dispatch_async(dispatch_get_main_queue(), ^{
//        self.faceImageView.image = image;
//
//    });
//    self.faceImageView.backgroundColor = [UIColor redColor];
//    self.faceImageView.image = [UIImage imageNamed:@"background.png"];
    for ( CIFaceFeature *ff in features ) {
        // find the correct position for the square layer within the previewLayer
        // the feature box originates in the bottom left of the video frame.
        // (Bottom right if mirroring is turned on)
        CGRect faceRect = [ff bounds];
//        CGRect faceRect = CGRectMake(0,0, 100, 100);
        int r = 0;
        faceRect = CGRectMake(faceRect.origin.x-r, image.size.height - faceRect.size.height - faceRect.origin.y-r , faceRect.size.width+2*r, faceRect.size.height+2*r);

        CGImageRef imageRef = CGImageCreateWithImageInRect(image.CGImage, faceRect);
        
        UIImageOrientation imageOrientation;
        switch ((curDeviceOrientation)) {
            case UIDeviceOrientationPortrait:
                imageOrientation = UIImageOrientationLeftMirrored;
                break;
            case UIDeviceOrientationLandscapeLeft:
                imageOrientation = UIImageOrientationDownMirrored;
                break;
            case UIDeviceOrientationLandscapeRight:
                imageOrientation = UIImageOrientationUpMirrored;
                break;
            default:
                break;
        }
        
        // or use the UIImage wherever you like
        UIImage *croppedImage = [UIImage imageWithCGImage:imageRef scale:1.0 orientation:imageOrientation];
       // croppedImage.imageOrientation =
        CGImageRelease(imageRef);
              dispatch_async(dispatch_get_main_queue(), ^{
                    self.faceImageView.image = croppedImage;
            
                });

     //   self.faceImageView.image = image;
    }

	
    // get the clean aperture
    // the clean aperture is a rectangle that defines the portion of the encoded pixel dimensions
    // that represents image data valid for display.
	CMFormatDescriptionRef fdesc = CMSampleBufferGetFormatDescription(sampleBuffer);
	CGRect cleanAperture = CMVideoFormatDescriptionGetCleanAperture(fdesc, false /*originIsTopLeft == false*/);
	
	dispatch_async(dispatch_get_main_queue(), ^(void) {
		[self drawFaces:features 
            forVideoBox:cleanAperture 
            orientation:curDeviceOrientation];
	});
}


#pragma mark - View lifecycle

- (void)viewDidLoad{
    [super viewDidLoad];
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter]
     addObserver:self selector:@selector(orientationChanged:)
     name:UIDeviceOrientationDidChangeNotification
     object:[UIDevice currentDevice]];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
	// Do any additional setup after loading the view, typically from a nib.
    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationNone];

    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    
	[self setupAVCapture];
	self.borderImage = [UIImage imageNamed:@"border"];

	NSDictionary *detectorOptions = [[NSDictionary alloc] initWithObjectsAndKeys:CIDetectorAccuracyLow, CIDetectorAccuracy, nil];
	self.faceDetector = [CIDetector detectorOfType:CIDetectorTypeFace context:nil options:detectorOptions];
}

- (void)viewDidUnload
{
    [super viewDidUnload];
    // Release any retained subviews of the main view.
    // e.g. self.myOutlet = nil;
    [self teardownAVCapture];
	self.faceDetector = nil;
	self.borderImage = nil;
}

//- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
//{
//    // We support only Portrait.
//	return (interfaceOrientation == UIInterfaceOrientationPortrait);
//}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    // Note that the app delegate controls the device orientation notifications required to use the device orientation.
    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
//    if ( UIDeviceOrientationIsPortrait( deviceOrientation ) || UIDeviceOrientationIsLandscape( deviceOrientation ) ) {
//        AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
//        self.previewLayer.connection.videoOrientation = (AVCaptureVideoOrientation)deviceOrientation;
//        CALayer *rootLayer = [self.previewView layer];
//        [rootLayer setMasksToBounds:YES];
//        [self.previewLayer setFrame:[rootLayer bounds]];
//
//    }
    if (UIDeviceOrientationIsLandscape(deviceOrientation)){
        [self.navigationController setNavigationBarHidden:NO animated:YES];
    } else{
        [self.navigationController setNavigationBarHidden:NO animated:YES];
    }

}
- (BOOL)prefersStatusBarHidden{
    return  NO;
}

- (void) orientationChanged:(NSNotification *)note
{
    UIDevice * device = note.object;
    if ( UIDeviceOrientationIsPortrait( device.orientation ) || UIDeviceOrientationIsLandscape( device.orientation ) ) {
        AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
        self.previewLayer.connection.videoOrientation = (AVCaptureVideoOrientation)device.orientation;
        CALayer *rootLayer = [self.previewView layer];
        [rootLayer setMasksToBounds:YES];
        [self.previewLayer setFrame:[rootLayer bounds]];
        
    }
}


@end
