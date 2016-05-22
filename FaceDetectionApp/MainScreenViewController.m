//
//  MainScreenViewController.m
//  FaceDetectionApp
//
//  Created by Vladislav Krasovsky on 5/17/16.
//
//


@import AVFoundation;
@import Photos;

#import "MainScreenViewController.h"
#import "AAPLPreviewView.h"
#import <MediaPlayer/MediaPlayer.h>

static CGFloat DegreesToRadians(CGFloat degrees) {return degrees * M_PI / 180;};


typedef NS_ENUM( NSInteger, AVCamSetupResult ) {
    AVCamSetupResultSuccess,
    AVCamSetupResultCameraNotAuthorized,
    AVCamSetupResultSessionConfigurationFailed
};

@interface MainScreenViewController() <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, weak) IBOutlet AAPLPreviewView *previewView;
@property (nonatomic) BOOL isUsingFrontFacingCamera;

// Session management.

@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (nonatomic) AVCaptureMovieFileOutput *movieFileOutput;
@property (nonatomic) AVCaptureStillImageOutput *stillImageOutput;

@property (nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property (nonatomic) dispatch_queue_t videoDataOutputQueue;


@property (nonatomic) AVCamSetupResult setupResult;

@property (nonatomic, strong) NSTimer *timer;

@property (nonatomic, strong) NSTimer *innerPhotoRowTimer;
@property (nonatomic) NSUInteger innerPhotoRowCounter;

@property (nonatomic, strong) UIImage *borderImage;
@property (nonatomic, strong) CIDetector *faceDetector;

@property (nonatomic, strong) UIView *boundView;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@end


@implementation MainScreenViewController

- (void)viewDidLoad{
    [super viewDidLoad];
    [[UIApplication sharedApplication] setStatusBarHidden:YES withAnimation:UIStatusBarAnimationNone];
    [[UIApplication sharedApplication] setStatusBarHidden:NO withAnimation:UIStatusBarAnimationNone];

    [self setupCaptureSession];
    self.borderImage = [UIImage imageNamed:@"border"];

    NSDictionary *detectorOptions = [[NSDictionary alloc] initWithObjectsAndKeys:CIDetectorAccuracyLow, CIDetectorAccuracy, nil];
    self.faceDetector = [CIDetector detectorOfType:CIDetectorTypeFace context:nil options:detectorOptions];
    self.boundView = [[UIView alloc] initWithFrame:CGRectMake(100, 100, 100, 100)];
    self.boundView.backgroundColor = [UIColor clearColor];
    self.boundView.layer.borderWidth = 2.0;
    self.boundView.layer.borderColor = [UIColor yellowColor].CGColor;
    [self.previewView addSubview:self.boundView];
}


- (void)viewWillAppear:(BOOL)animated{
    [super viewWillAppear:animated];
    [self tryStartCaptureSession];
   // self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(detectFace) userInfo:nil repeats:YES];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)detectFace{
    [self takePicture];
}

- (void)viewDidDisappear:(BOOL)animated{
    [self.timer invalidate];
    [self stopCaptureSession];
    [super viewDidDisappear:animated];
}

- (void)setupCaptureSession{
    self.session = [[AVCaptureSession alloc] init];
    self.previewView.session = self.session;
    self.sessionQueue = dispatch_queue_create( "session queue", DISPATCH_QUEUE_SERIAL );
    self.setupResult = AVCamSetupResultSuccess;
    switch ( [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] )
    {
        case AVAuthorizationStatusAuthorized:
        {
            break;
        }
        case AVAuthorizationStatusNotDetermined:
        {
            dispatch_suspend( self.sessionQueue );
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^( BOOL granted ) {
                if ( ! granted ) {
                    self.setupResult = AVCamSetupResultCameraNotAuthorized;
                }
                dispatch_resume( self.sessionQueue );
            }];
            break;
        }
        default:
        {
            self.setupResult = AVCamSetupResultCameraNotAuthorized;
            break;
        }
    }
    
    dispatch_async( self.sessionQueue, ^{
        if ( self.setupResult != AVCamSetupResultSuccess ) {
            return;
        }
        NSError *error = nil;
        
        AVCaptureDevice *videoDevice = [MainScreenViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:AVCaptureDevicePositionFront];
        self.isUsingFrontFacingCamera = YES;
        AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
        
        if ( ! videoDeviceInput ) {
            NSLog( @"Could not create video device input: %@", error );
        }
        
        [self.session beginConfiguration];
        
        if ( [self.session canAddInput:videoDeviceInput] ) {
            [self.session addInput:videoDeviceInput];
            self.videoDeviceInput = videoDeviceInput;
            
//            dispatch_async( dispatch_get_main_queue(), ^{
//                UIInterfaceOrientation statusBarOrientation = [UIApplication sharedApplication].statusBarOrientation;
//                AVCaptureVideoOrientation initialVideoOrientation = AVCaptureVideoOrientationPortrait;
//                if ( statusBarOrientation != UIInterfaceOrientationUnknown ) {
//                    initialVideoOrientation = (AVCaptureVideoOrientation)statusBarOrientation;
//                }
//                
//                AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
//                previewLayer.connection.videoOrientation = initialVideoOrientation;
//                previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
//            } );
        }
        else {
            NSLog( @"Could not add video device input to the session" );
            self.setupResult = AVCamSetupResultSessionConfigurationFailed;
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
        
        if ( [self.session canAddOutput:self.videoDataOutput] ){
            [self.session addOutput:self.videoDataOutput];
        }
        
        // get the output for doing face detection.
        [[self.videoDataOutput connectionWithMediaType:AVMediaTypeVideo] setEnabled:YES];

//        AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
//        if ( [self.session canAddOutput:stillImageOutput] ) {
//            stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
//            [self.session addOutput:stillImageOutput];
//            self.stillImageOutput = stillImageOutput;
//        }
//        else {
//            NSLog( @"Could not add still image output to the session" );
//            self.setupResult = AVCamSetupResultSessionConfigurationFailed;
//        }
        self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
        self.previewLayer.backgroundColor = [[UIColor blackColor] CGColor];
        self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        
        CALayer *rootLayer = [self.previewView layer];
        [rootLayer setMasksToBounds:YES];
        [self.previewLayer setFrame:[rootLayer bounds]];
        [rootLayer addSublayer:self.previewLayer];
//        [session startRunning];
        
        [self.session commitConfiguration];
    } );
    
}
- (void)tryStartCaptureSession{
    dispatch_async( self.sessionQueue, ^{
        switch ( self.setupResult )
        {
            case AVCamSetupResultSuccess:
            {
                // Only setup observers and start the session running if setup succeeded.
                [self.session startRunning];
                break;
            }
            case AVCamSetupResultCameraNotAuthorized:
            {
                dispatch_async( dispatch_get_main_queue(), ^{
                    NSString *message = NSLocalizedString( @"AVCam doesn't have permission to use the camera, please change privacy settings", @"Alert message when the user has denied access to the camera" );
                    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
                    [alertController addAction:cancelAction];
                    // Provide quick access to Settings.
                    UIAlertAction *settingsAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"Settings", @"Alert button to open Settings" ) style:UIAlertActionStyleDefault handler:^( UIAlertAction *action ) {
                        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
                    }];
                    [alertController addAction:settingsAction];
                    [self presentViewController:alertController animated:YES completion:nil];
                } );
                break;
            }
            case AVCamSetupResultSessionConfigurationFailed:
            {
                dispatch_async( dispatch_get_main_queue(), ^{
                    NSString *message = NSLocalizedString( @"Unable to capture media", @"Alert message when something goes wrong during capture session configuration" );
                    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
                    [alertController addAction:cancelAction];
                    [self presentViewController:alertController animated:YES completion:nil];
                } );
                break;
            }
        }
    } );
}
- (void)stopCaptureSession{
    dispatch_async( self.sessionQueue, ^{
        if ( self.setupResult == AVCamSetupResultSuccess ) {
            [self.session stopRunning];
        }
    });
}

#pragma mark Orientation

//- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator{
//    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
//    
//    // Note that the app delegate controls the device orientation notifications required to use the device orientation.
//    UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
//    if ( UIDeviceOrientationIsPortrait( deviceOrientation ) || UIDeviceOrientationIsLandscape( deviceOrientation ) ) {
//        AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
//        previewLayer.connection.videoOrientation = (AVCaptureVideoOrientation)deviceOrientation;
//    }
//    if (UIDeviceOrientationIsLandscape(deviceOrientation)){
//        [self.navigationController setNavigationBarHidden:NO animated:YES];
//    } else{
//        [self.navigationController setNavigationBarHidden:NO animated:YES];
//    }
//}


#pragma mark Actions

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    // get the image
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
    CIImage *ciImage = [[CIImage alloc] initWithCVPixelBuffer:pixelBuffer
                                                      options:(__bridge NSDictionary *)attachments];
    if (attachments) {
        CFRelease(attachments);
    }
    
    // make sure your device orientation is not locked.
    UIDeviceOrientation curDeviceOrientation = [[UIDevice currentDevice] orientation];
    
    NSDictionary *imageOptions = nil;
    
    imageOptions = [NSDictionary dictionaryWithObject:[self exifOrientation:curDeviceOrientation]
                                               forKey:CIDetectorImageOrientation];
    
    NSArray *features = [self.faceDetector featuresInImage:ciImage
                                                   options:imageOptions];
    
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

// find where the video box is positioned within the preview layer based on the video size and gravity
+ (CGRect)videoPreviewBoxForGravity:(NSString *)gravity
                          frameSize:(CGSize)frameSize
                       apertureSize:(CGSize)apertureSize
{
    CGFloat apertureRatio = apertureSize.height / apertureSize.width;
    CGFloat viewRatio = frameSize.width / frameSize.height;
    
    CGSize size = CGSizeZero;
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        if (viewRatio > apertureRatio) {
            size.width = frameSize.width;
            size.height = apertureSize.width * (frameSize.width / apertureSize.height);
        } else {
            size.width = apertureSize.height * (frameSize.height / apertureSize.width);
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
    CGRect previewBox = [MainScreenViewController videoPreviewBoxForGravity:gravity
                                                        frameSize:parentFrameSize
                                                     apertureSize:clearAperture.size];
    
    for ( CIFaceFeature *ff in features ) {
        // find the correct position for the square layer within the previewLayer
        // the feature box originates in the bottom left of the video frame.
        // (Bottom right if mirroring is turned on)
        CGRect faceRect = [ff bounds];
        
        // flip preview width and height
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
            faceRect = CGRectOffset(faceRect, previewBox.origin.x + previewBox.size.width - faceRect.size.width - (faceRect.origin.x * 2), previewBox.origin.y);
        else
            faceRect = CGRectOffset(faceRect, previewBox.origin.x, previewBox.origin.y);
        
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
            [featureLayer setName:@"FaceLayer"];
            [self.previewView.layer addSublayer:featureLayer];
            featureLayer = nil;
        }
        [featureLayer setFrame:faceRect];
        
        switch (orientation) {
            case UIDeviceOrientationPortrait:
                [featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(0.))];
                break;
            case UIDeviceOrientationPortraitUpsideDown:
                [featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(180.))];
                break;
            case UIDeviceOrientationLandscapeLeft:
                [featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(90.))];
                break;
            case UIDeviceOrientationLandscapeRight:
                [featureLayer setAffineTransform:CGAffineTransformMakeRotation(DegreesToRadians(-90.))];
                break;
            case UIDeviceOrientationFaceUp:
            case UIDeviceOrientationFaceDown:
            default:
                break; // leave the layer in its last known orientation
        }
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
- (void)takePicture{
   // NSLog(@"WILL CAPTURE");
    dispatch_async( self.sessionQueue, ^{
        AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
        AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
        
        // Update the orientation on the still image output video connection before capturing.
        connection.videoOrientation = previewLayer.connection.videoOrientation;
        
        // Flash set to Auto for Still Capture.
        [MainScreenViewController setFlashMode:AVCaptureFlashModeAuto forDevice:self.videoDeviceInput.device];
        static SystemSoundID soundID = 0;
        if (soundID == 0) {
            NSString *path = [[NSBundle mainBundle] pathForResource:@"photoShutter2" ofType:@"caf"];
            NSURL *filePath = [NSURL fileURLWithPath:path isDirectory:NO];
            AudioServicesCreateSystemSoundID((__bridge CFURLRef)filePath, &soundID);
        }
        AudioServicesPlaySystemSound(soundID);
        // Capture a still image.
        [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler:^( CMSampleBufferRef imageDataSampleBuffer, NSError *error ) {
            if ( imageDataSampleBuffer ) {
                // The sample buffer is not retained. Create image data before saving the still image to the photo library asynchronously.
                NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                UIImage *image = [UIImage imageWithData:imageData];
                CIImage *ciImage = [CIImage imageWithData:imageData];
                
                // make sure your device orientation is not locked.
                UIDeviceOrientation curDeviceOrientation = [[UIDevice currentDevice] orientation];
                double scale = self.previewView.bounds.size.width/image.size.width;
                
                NSDictionary *imageOptions = nil;
                
//                imageOptions = [NSDictionary dictionaryWithObject:[self exifOrientation:curDeviceOrientation]
//                                                           forKey:CIDetectorImageOrientation];
                imageOptions = @{ CIDetectorImageOrientation :
                              [[ciImage properties] valueForKey:kCGImagePropertyOrientation] };
                NSArray *features = [self.faceDetector featuresInImage:ciImage
                                                               options:imageOptions];
                self.boundView.hidden = !features.count;
                for (CIFaceFeature *f in features) {
                    NSLog(@"%@", NSStringFromCGRect(f.bounds));
                    CGPoint center = CGPointMake((f.bounds.origin.x + f.bounds.size.width/2)*scale, (f.bounds.origin.y + f.bounds.size.height/2)*scale);
                    CGSize size = CGSizeMake(f.bounds.size.width*scale, f.bounds.size.height*scale);
                    self.boundView.frame = CGRectMake(center.x-size.width/2, self.previewView.bounds.size.height - ( center.y + size.height/2)+ 20, size.width, size.height);
                    NSLog(@"b: %@", NSStringFromCGRect(self.boundView.frame));

//                    if (f.hasLeftEyePosition) {
//                        NSLog(@"Left eye %g %g", f.leftEyePosition.x, f.leftEyePosition.y);
//                    }
//                    if (f.hasRightEyePosition) {
//                        NSLog(@"Right eye %g %g", f.rightEyePosition.x, f.rightEyePosition.y);
//                    }
//                    if (f.hasMouthPosition) {
//                        NSLog(@"Mouth %g %g", f.mouthPosition.x, f.mouthPosition.y);
//                    }
                }
           
            }
            else {
                NSLog( @"Could not capture still image: %@", error );
            }
        }];
    } );
}

#pragma mark Device Configuration

+ (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device{
    if ( device.hasFlash && [device isFlashModeSupported:flashMode] ) {
        NSError *error = nil;
        if ( [device lockForConfiguration:&error] ) {
            device.flashMode = flashMode;
            [device unlockForConfiguration];
        }
        else {
            NSLog( @"Could not lock device for configuration: %@", error );
        }
    }
}
+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
    AVCaptureDevice *captureDevice = devices.firstObject;
    
    for ( AVCaptureDevice *device in devices ) {
        if ( device.position == position ) {
            captureDevice = device;
            break;
        }
    }
    
    return captureDevice;
}

@end