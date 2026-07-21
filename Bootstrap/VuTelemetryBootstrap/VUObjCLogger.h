//
//  VUObjCLogger.h
//  VuTelemetryBootstrap
//
//  Unified Objective-C logging framework matching VULogger standards.
//

#ifndef VUObjCLogger_h
#define VUObjCLogger_h

#import <Foundation/Foundation.h>

// C-level disabled flag — set by vu_mark_sdk_disabled() and checked by VUObjCLogger.
// Callable from Swift via the VuTelemetryBootstrap module's public headers.
#ifdef __cplusplus
extern "C" {
#endif
void vu_mark_sdk_disabled(void);
#ifdef __cplusplus
}
#endif

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
