//
//  CamPreviewView.m
//  VideoApp
//
//  Created by Christophe Prakash on 11/20/14.
//  Copyright (c) 2014 Christophe Prakash. All rights reserved.
//

#import "CamPreviewView.h"
#import <AVFoundation/AVFoundation.h>

@implementation CamPreviewView

+ (Class)layerClass
{
    return [AVCaptureVideoPreviewLayer class];
}

- (AVCaptureSession *)session
{
    return [(AVCaptureVideoPreviewLayer *)[self layer] session];
}

- (void)setSession:(AVCaptureSession *)session
{
    [(AVCaptureVideoPreviewLayer *)[self layer] setSession:session];
}

@end
