//
//  OtelBootstrap.m
//  VuTelemetryBootstrap
//
//  Registers a lightweight launch observer that defers SDK init until the app
//  has finished launching, while keeping pre-main work limited to timestamp capture.
//

#import <Foundation/Foundation.h>
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#endif
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdio.h>
#import "StartupTelemetry.h"

@interface VuTelemetryObjCBootstrap : NSObject
@end

@implementation VuTelemetryObjCBootstrap

+ (void)load {
#if __has_include(<UIKit/UIKit.h>)
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(applicationDidFinishLaunching:)
												 name:UIApplicationDidFinishLaunchingNotification
											   object:nil];
#endif
}

#if __has_include(<UIKit/UIKit.h>)
+ (void)applicationDidFinishLaunching:(NSNotification *)notification {
	(void)notification;
	vu_dispatch_bootstrap_selector(NSSelectorFromString(@"initializeFromInfoPlist"), "launch-observer");

	[[NSNotificationCenter defaultCenter] removeObserver:self
													name:UIApplicationDidFinishLaunchingNotification
												  object:nil];
}
#endif

@end

