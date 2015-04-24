//
//  ViewController.m
//  VideoApp
//
//  Created by Christophe Prakash on 11/20/14.
//  Copyright (c) 2014 Christophe Prakash. All rights reserved.
//

#import "ViewController.h"
#import "CamPreviewView.h"
#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import "AFHTTPRequestOperationManager.h"
#import "INTULocationManager.h"

static void * CapturingStillImageContext = &CapturingStillImageContext;
static void * RecordingContext = &RecordingContext;
static void * SessionRunningAndDeviceAuthorizedContext = &SessionRunningAndDeviceAuthorizedContext;


@interface ViewController () <AVCaptureFileOutputRecordingDelegate, NSURLConnectionDelegate>

- (IBAction)toggleRecord:(id)sender;

//Preview of Camera feed
@property (weak, nonatomic) IBOutlet CamPreviewView *camView;
@property (weak, nonatomic) IBOutlet UIButton *recordButton;


//Session Management
@property (nonatomic) AVCaptureSession *session; //The capture session
@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput; //Camera pipes its output to this, which is the video input for the preview
@property (nonatomic) AVCaptureMovieFileOutput *movieFileOutput;
@property (nonatomic) AVCaptureStillImageOutput *stillImageOutput;

@property (nonatomic) NSString *movieFilePath;

@property (nonatomic) dispatch_queue_t sessionQueue; // Communicate with the session and other session objects on this queue, asynchronous to main queue
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID; //Used to manage background tasks
@property (nonatomic, readonly, getter = isSessionRunningAndDeviceAuthorized) BOOL sessionRunningAndDeviceAuthorized;
@property (nonatomic) id runtimeErrorHandlingObserver;
@property (nonatomic) BOOL isRecording;

//Device Authorization Status
@property (nonatomic, getter = isDeviceAuthorized) BOOL deviceAuthorized;

//
@property (nonatomic, strong) AFHTTPRequestOperationManager *operationManager;


@end

@implementation ViewController


- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Create the AVCaptureSession
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    [self setSession:session];
    
    // Setup the preview view
    [[self camView] setSession:session];
    
    // Check for device authorization
    [self checkDeviceAuthorizationStatus];
    
    // In general it is not safe to mutate an AVCaptureSession or any of its inputs, outputs, or connections from multiple threads at the same time.
    // Why not do all of this on the main queue?
    // -[AVCaptureSession startRunning] is a blocking call which can take a long time. We dispatch session setup to the sessionQueue so that the main queue isn't blocked (which keeps the UI responsive).
    dispatch_queue_t sessionQueue = dispatch_queue_create("session queue", DISPATCH_QUEUE_SERIAL);
    [self setSessionQueue:sessionQueue];
    
    dispatch_async(sessionQueue, ^{
        //No background task yet
        [self setBackgroundRecordingID:UIBackgroundTaskInvalid];
        
        //Error pointer
        NSError *error = nil;
        
        
        // Add iPhone camera as input device to session
        AVCaptureDevice *videoDevice = [ViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:AVCaptureDevicePositionBack];
        AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];
        
        if (error)
        {
            NSLog(@"%@", error);
        }
        
        if ([session canAddInput:videoDeviceInput])
        {
            [session addInput:videoDeviceInput];
            [self setVideoDeviceInput:videoDeviceInput];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Why are we dispatching this to the main queue?
                // Because AVCaptureVideoPreviewLayer is the backing layer for AVCamPreviewView and UIView can only be manipulated on main thread.
                // Note: As an exception to the above rule, it is not necessary to serialize video orientation changes on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
                
                [[(AVCaptureVideoPreviewLayer *)[[self camView] layer] connection] setVideoOrientation:(AVCaptureVideoOrientation)[[UIApplication sharedApplication] statusBarOrientation]];
            });
        }
        // Add iPhone camera as input device to session
        
        
        // Add iPhone microphone as input device to session
        AVCaptureDevice *audioDevice = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio] firstObject];
        AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];
        
        if (error)
        {
            NSLog(@"%@", error);
        }
        
        if ([session canAddInput:audioDeviceInput])
        {
            [session addInput:audioDeviceInput];
        }
        // Add iPhone microphone as input device to session
        
        
        // Add Move Output File to session
        AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
        if ([session canAddOutput:movieFileOutput])
        {
            [session addOutput:movieFileOutput];
            AVCaptureConnection *connection = [movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
            if ([connection isVideoStabilizationSupported])
                [connection setEnablesVideoStabilizationWhenAvailable:YES];
            [self setMovieFileOutput:movieFileOutput];
        }
        // Add Move Output File to session
        
        
        // Add Still Image Output File to session
        AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
        if ([session canAddOutput:stillImageOutput])
        {
            [stillImageOutput setOutputSettings:@{AVVideoCodecKey : AVVideoCodecJPEG}];
            [session addOutput:stillImageOutput];
            [self setStillImageOutput:stillImageOutput];
        }
        // Add Still Image Output File to session
        
    });
    [self.recordButton.layer setBorderColor:[[UIColor colorWithRed:76/255.0
                                                           green:222/255.0
                                                            blue:190/255.0
                                                            alpha:1.0] CGColor]];
    [self.recordButton.layer setBorderWidth:2.0];
    self.isRecording = NO;
    self.movieFilePath = nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    dispatch_async([self sessionQueue], ^{
        [self addObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:SessionRunningAndDeviceAuthorizedContext];
        [self addObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:CapturingStillImageContext];
        [self addObserver:self forKeyPath:@"movieFileOutput.recording" options:(NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew) context:RecordingContext];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
        
        __weak ViewController *weakSelf = self;
        [self setRuntimeErrorHandlingObserver:[[NSNotificationCenter defaultCenter] addObserverForName:AVCaptureSessionRuntimeErrorNotification object:[self session] queue:nil usingBlock:^(NSNotification *note) {
            ViewController *strongSelf = weakSelf;
            dispatch_async([strongSelf sessionQueue], ^{
                // Manually restarting the session since it must have been stopped due to an error.
                [[strongSelf session] startRunning];
//                [[strongSelf recordButton] setTitle:NSLocalizedString(@"Record", @"Recording button record title") forState:UIControlStateNormal];
            });
        }]];
        [[self session] startRunning];
    });
}

- (void)viewDidDisappear:(BOOL)animated
{
    dispatch_async([self sessionQueue], ^{
        [[self session] stopRunning];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:[[self videoDeviceInput] device]];
        [[NSNotificationCenter defaultCenter] removeObserver:[self runtimeErrorHandlingObserver]];
        
        [self removeObserver:self forKeyPath:@"sessionRunningAndDeviceAuthorized" context:SessionRunningAndDeviceAuthorizedContext];
        [self removeObserver:self forKeyPath:@"stillImageOutput.capturingStillImage" context:CapturingStillImageContext];
        [self removeObserver:self forKeyPath:@"movieFileOutput.recording" context:RecordingContext];
    });
}

- (void)subjectAreaDidChange:(NSNotification *)notification
{
    
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == CapturingStillImageContext)
    {
//        BOOL isCapturingStillImage = [change[NSKeyValueChangeNewKey] boolValue];
//        
//        if (isCapturingStillImage)
//        {
//            [self runStillImageCaptureAnimation];
//        }
    }
    else if (context == RecordingContext)
    {
//        BOOL isRecording = [change[NSKeyValueChangeNewKey] boolValue];
//        
//        dispatch_async(dispatch_get_main_queue(), ^{
//            if (isRecording)
//            {
//                [[self cameraButton] setEnabled:NO];
//                [[self recordButton] setTitle:NSLocalizedString(@"Stop", @"Recording button stop title") forState:UIControlStateNormal];
//                [[self recordButton] setEnabled:YES];
//            }
//            else
//            {
//                [[self cameraButton] setEnabled:YES];
//                [[self recordButton] setTitle:NSLocalizedString(@"Record", @"Recording button record title") forState:UIControlStateNormal];
//                [[self recordButton] setEnabled:YES];
//            }
//        });
    }
    else if (context == SessionRunningAndDeviceAuthorizedContext)
    {
//        BOOL isRunning = [change[NSKeyValueChangeNewKey] boolValue];
//        
//        dispatch_async(dispatch_get_main_queue(), ^{
//            if (isRunning)
//            {
//                [[self cameraButton] setEnabled:YES];
//                [[self recordButton] setEnabled:YES];
//                [[self stillButton] setEnabled:YES];
//            }
//            else
//            {
//                [[self cameraButton] setEnabled:NO];
//                [[self recordButton] setEnabled:NO];
//                [[self stillButton] setEnabled:NO];
//            }
//        });
    }
    else
    {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


- (IBAction)toggleRecord:(id)sender
{
    
    if (self.isRecording) {
        [self.recordButton.layer setBorderColor:[[UIColor colorWithRed:76/255.0
                                                                 green:222/255.0
                                                                  blue:190/255.0
                                                                 alpha:1.0] CGColor]];
        [self.recordButton setImage:[UIImage imageNamed:@"TealCameraSuperMini.png"] forState:UIControlStateNormal];
    }
    else
    {
        [self.recordButton.layer setBorderColor:[[UIColor redColor] CGColor]];
        [self.recordButton setImage:nil forState:UIControlStateNormal];
    }
    
    dispatch_async([self sessionQueue], ^{
        if (![[self movieFileOutput] isRecording])
        {
            if ([[UIDevice currentDevice] isMultitaskingSupported])
            {
                // Setup background task. This is needed because the captureOutput:didFinishRecordingToOutputFileAtURL: callback is not received until AVCam returns to the foreground unless you request background execution time. This also ensures that there will be time to write the file to the assets library when AVCam is backgrounded. To conclude this background execution, -endBackgroundTask is called in -recorder:recordingDidFinishToOutputFileURL:error: after the recorded file has been saved.
                [self setBackgroundRecordingID:[[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil]];
            }
            
            // Update the orientation on the movie file output video connection before starting recording.
            [[[self movieFileOutput] connectionWithMediaType:AVMediaTypeVideo] setVideoOrientation:[[(AVCaptureVideoPreviewLayer *)[[self camView] layer] connection] videoOrientation]];
            
            // Turning OFF flash for video recording
            [ViewController setFlashMode:AVCaptureFlashModeOff forDevice:[[self videoDeviceInput] device]];
            
            // Start recording to a temporary file.
            self.movieFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"movie" stringByAppendingPathExtension:@"mov"]];
            [[self movieFileOutput] startRecordingToOutputFileURL:[NSURL fileURLWithPath:self.movieFilePath] recordingDelegate:self];
        }
        else
        {
            [[self movieFileOutput] stopRecording];
        }
    });

    
    self.isRecording = !self.isRecording;
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput
        didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL
        fromConnections:(NSArray *)connections
        error:(NSError *)error
{
    if (error)
        NSLog(@"%@", error);
    
    // Note the backgroundRecordingID for use in the ALAssetsLibrary completion handler to end the background task associated with this recording. This allows a new recording to be started, associated with a new UIBackgroundTaskIdentifier, once the movie file output's -isRecording is back to NO — which happens sometime after this method returns.
    UIBackgroundTaskIdentifier backgroundRecordingID = [self backgroundRecordingID];
    [self setBackgroundRecordingID:UIBackgroundTaskInvalid];
    [self postOutPutFile:outputFileURL];
    
//    [[[ALAssetsLibrary alloc] init] writeVideoAtPathToSavedPhotosAlbum:outputFileURL completionBlock:^(NSURL *assetURL, NSError *error) {
//        if (error)
//            NSLog(@"%@", error);
//        
//        [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
//        
//        if (backgroundRecordingID != UIBackgroundTaskInvalid)
//            [[UIApplication sharedApplication] endBackgroundTask:backgroundRecordingID];
//    }];
}


//Checks that the app is authorized to access video from the camera
- (void)checkDeviceAuthorizationStatus
{
    NSString *mediaType = AVMediaTypeVideo;
    
    [AVCaptureDevice requestAccessForMediaType:mediaType completionHandler:^(BOOL granted) {
        if (granted)
        {
            //Granted access to mediaType
            [self setDeviceAuthorized:YES];
        }
        else
        {
            //Not granted access to mediaType
            dispatch_async(dispatch_get_main_queue(), ^{
                [[[UIAlertView alloc] initWithTitle:@"AVCam!"
                                            message:@"AVCam doesn't have permission to use Camera, please change privacy settings"
                                           delegate:self
                                  cancelButtonTitle:@"OK"
                                  otherButtonTitles:nil] show];
                [self setDeviceAuthorized:NO];
            });
        }
    }];
}

+ (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device
{
    if ([device hasFlash] && [device isFlashModeSupported:flashMode])
    {
        NSError *error = nil;
        if ([device lockForConfiguration:&error])
        {
            [device setFlashMode:flashMode];
            [device unlockForConfiguration];
        }
        else
        {
            NSLog(@"%@", error);
        }
    }
}

+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
    AVCaptureDevice *captureDevice = [devices firstObject];
    
    for (AVCaptureDevice *device in devices)
    {
        if ([device position] == position)
        {
            captureDevice = device;
            break;
        }
    }
    
    return captureDevice;
}


- (void)postOutPutFile:(NSURL *)outputFileURL
{
    NSDictionary *defaultParams = @{@"userName"     : @"tophe",
                             @"userEmail"    : @"christopheprakash@gmail.com",
                             @"userPassword" : @"password"};
    NSMutableDictionary *params = [defaultParams mutableCopy];
    
    INTULocationManager *locMgr = [INTULocationManager sharedInstance];
    [locMgr requestLocationWithDesiredAccuracy:INTULocationAccuracyCity
                                       timeout:10.0
                          delayUntilAuthorized:YES  // This parameter is optional, defaults to NO if omitted
                                         block:^(CLLocation *currentLocation, INTULocationAccuracy achievedAccuracy, INTULocationStatus status) {
                                             if (status == INTULocationStatusSuccess) {
                                                 [params setObject:[NSNumber numberWithDouble:currentLocation.coordinate.latitude] forKey:@"latitude"];
                                                 [params setObject:[NSNumber numberWithDouble:currentLocation.coordinate.longitude] forKey:@"longitude"];
                                                 [self sendPostRequestForFile:outputFileURL withParameters:params];
                                             }
                                             else if (status == INTULocationStatusTimedOut) {
                                                 // Wasn't able to locate the user with the requested accuracy within the timeout interval.
                                                 // However, currentLocation contains the best location available (if any) as of right now,
                                                 // and achievedAccuracy has info on the accuracy/recency of the location in currentLocation.
                                                NSLog(@"Finding location timed out");
                                             }
                                             else {
                                                 // An error occurred, more info is available by looking at the specific status returned.
                                                 NSLog(@"Error finding location");
                                             }
                                         }];
    
    
    
}

- (void)sendPostRequestForFile:(NSURL *)outputFileURL withParameters:(NSMutableDictionary *)params
{
    self.operationManager = [AFHTTPRequestOperationManager manager];
    self.operationManager.responseSerializer = [AFHTTPResponseSerializer serializer]; // only needed if the server is not returning JSON; if web service returns JSON, remove this line
    AFHTTPRequestOperation *operation = [self.operationManager POST:@"http://192.168.1.7:3000/upload" parameters:params
                                          constructingBodyWithBlock:
                                         ^(id<AFMultipartFormData> formData) {
                                             NSError *error;
                                             if (![formData appendPartWithFileURL:outputFileURL name:@"testvid" fileName:@"testvid lol.mp4" mimeType:@"video/mp4" error:&error]) {
                                                 NSLog(@"error appending part: %@", error);
                                             }
                                         } success:^(AFHTTPRequestOperation *operation, id responseObject) {
                                             NSLog(@"Success");
                                         } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
                                             NSLog(@"error = %@", error);
                                         }];
    
    if (!operation) {
        NSLog(@"Creation of operation failed.");
    }
}

- (NSUInteger)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate
{
    return NO;
}

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

@end
