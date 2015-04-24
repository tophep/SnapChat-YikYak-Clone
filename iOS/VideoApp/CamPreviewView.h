//
//  CamPreviewView.h
//  VideoApp
//
//  Created by Christophe Prakash on 11/20/14.
//  Copyright (c) 2014 Christophe Prakash. All rights reserved.
//

#import <UIKit/UIKit.h>

@class AVCaptureSession;

@interface CamPreviewView : UIView

@property (nonatomic) AVCaptureSession *session;

@end
