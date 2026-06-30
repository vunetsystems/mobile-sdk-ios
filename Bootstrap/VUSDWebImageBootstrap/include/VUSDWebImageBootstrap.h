//
//  VUSDWebImageBootstrap.h
//  VUSDWebImageBootstrap
//
//  Pre-main auto-install shim for the vuTelemetrySDWebImage module.
//  This target deliberately exposes no public API — its only job is to run
//  an Objective-C +load at launch that arms SDWebImage instrumentation.
//  See VUSDWebImageBootstrap.m for details.
//

#import <Foundation/Foundation.h>
