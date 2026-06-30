//
//  VUObjCLogger.h
//  VuTelemetryBootstrap
//
//  Unified Objective-C logging framework matching VULogger standards.
//

#ifndef VUObjCLogger_h
#define VUObjCLogger_h

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VULogLevel) {
    VULogLevelDebug,
    VULogLevelInfo,
    VULogLevelWarning,
    VULogLevelError
};

@interface VUObjCLogger : NSObject

+ (void)setExportDebugLogsEnabled:(BOOL)enabled;
+ (BOOL)exportDebugLogsEnabled;

+ (void)logWithLevel:(VULogLevel)level
           component:(NSString *)component
               event:(NSString *)event
             message:(NSString *)message
    additionalFields:(NSDictionary<NSString *, id> *)additionalFields;

+ (void)logWithFormat:(const char *)format, ... NS_FORMAT_FUNCTION(1, 2);

@end

#define VU_LOG(fmt, ...) [VUObjCLogger logWithFormat:(fmt), ##__VA_ARGS__]

#endif /* VUObjCLogger_h */
