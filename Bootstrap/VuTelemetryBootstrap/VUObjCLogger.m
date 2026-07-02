//
//  VUObjCLogger.m
//  VuTelemetryBootstrap
//
//  Unified Objective-C logging framework matching VULogger standards.
//

#import "VUObjCLogger.h"
#import <os/log.h>

static BOOL vu_exportDebugLogsEnabled = NO;
static dispatch_once_t initToken;
static NSMutableDictionary<NSString *, os_log_t> *vu_loggers = nil;
static NSLock *vu_loggerLock = nil;

@implementation VUObjCLogger

+ (os_log_t)getLoggerForSubsystem:(NSString *)subsystem {
    static dispatch_once_t loggerInitToken;
    dispatch_once(&loggerInitToken, ^{
        vu_loggers = [NSMutableDictionary dictionary];
        vu_loggerLock = [[NSLock alloc] init];
    });
    
    [vu_loggerLock lock];
    os_log_t log = vu_loggers[subsystem];
    if (!log) {
        log = os_log_create([subsystem UTF8String], "VunetSDK");
        vu_loggers[subsystem] = log;
    }
    [vu_loggerLock unlock];
    return log;
}

+ (void)initializeIfNeeded {
    dispatch_once(&initToken, ^{
        NSNumber *val = [[NSBundle mainBundle] infoDictionary][@"ExportDebugLogs"];
        if (val) {
            vu_exportDebugLogsEnabled = [val boolValue];
        }
        
        os_log_t bootLog = [self getLoggerForSubsystem:@"com.vunet.telemetry.logger"];
        NSString *timestamp = [self getISO8601Timestamp];
        BOOL isDebug = NO;
#ifdef DEBUG
        isDebug = YES;
#endif
        NSString *environment = isDebug ? @"development" : @"production";
        NSDictionary *payload = @{
            @"level": @"debug",
            @"timestamp": timestamp,
            @"component": @"logger",
            @"event": @"config_read",
            @"sdk_version": @"0.0.1",
            @"environment": environment,
            @"message": [NSString stringWithFormat:@"Read ExportDebugLogs from Info.plist: %@", vu_exportDebugLogsEnabled ? @"YES" : @"NO"]
        };
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:nil];
        if (jsonData) {
            NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            os_log_with_type(bootLog, OS_LOG_TYPE_DEBUG, "%{public}s", [jsonString UTF8String]);
        }
    });
}

+ (void)setExportDebugLogsEnabled:(BOOL)enabled {
    [self initializeIfNeeded];
    vu_exportDebugLogsEnabled = enabled;
}

+ (BOOL)exportDebugLogsEnabled {
    [self initializeIfNeeded];
    return vu_exportDebugLogsEnabled;
}

+ (NSString *)getISO8601Timestamp {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:[NSDate date]];
}

+ (void)parseMessage:(NSString *)rawMessage
             outLevel:(VULogLevel *)outLevel
        outComponent:(NSString **)outComponent
            outEvent:(NSString **)outEvent
          outMessage:(NSString **)outMessage {
    
    NSString *trimmed = [rawMessage stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    VULogLevel level = VULogLevelInfo;
    NSString *component = @"sdk";
    NSString *event = @"generic_log";
    NSString *msg = trimmed;
    
    if ([trimmed containsString:@"⚠️"] || [trimmed rangeOfString:@"warning" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        level = VULogLevelWarning;
    } else if ([trimmed rangeOfString:@"BUG" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [trimmed rangeOfString:@"failed" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [trimmed rangeOfString:@"error" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        level = VULogLevelError;
    } else if ([trimmed rangeOfString:@"debug" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        level = VULogLevelDebug;
    }
    
    if ([trimmed hasPrefix:@"["]) {
        NSRange closingBracket = [trimmed rangeOfString:@"]"];
        if (closingBracket.location != NSNotFound && closingBracket.location > 1) {
            NSString *compPart = [trimmed substringWithRange:NSMakeRange(1, closingBracket.location - 1)];
            NSString *lowerComp = [compPart lowercaseString];
            if ([lowerComp isEqualToString:@"dylibprofiler"]) {
                component = @"dylib_profiler";
            } else if ([lowerComp isEqualToString:@"vutelemetry"] || [lowerComp isEqualToString:@"vutelemetry"] || [lowerComp isEqualToString:@"startuptelemetry"]) {
                component = @"startup";
            } else if ([lowerComp isEqualToString:@"vulifecycleswizzler"]) {
                component = @"lifecycle";
            } else {
                component = lowerComp;
            }
            
            msg = [[trimmed substringFromIndex:closingBracket.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            if ([msg hasPrefix:@"["]) {
                NSRange subClosingBracket = [msg rangeOfString:@"]"];
                if (subClosingBracket.location != NSNotFound && subClosingBracket.location > 1) {
                    NSString *subCompPart = [msg substringWithRange:NSMakeRange(1, subClosingBracket.location - 1)];
                    msg = [[msg substringFromIndex:subClosingBracket.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    event = [[subCompPart lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
                }
            }
        }
    }
    
    msg = [msg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if ([event isEqualToString:@"generic_log"]) {
        NSString *lowerMsg = [msg lowercaseString];
        if ([lowerMsg hasPrefix:@"started at tick"]) {
            event = @"profiler_started";
        } else if ([lowerMsg isEqualToString:@"dylib profiler enabled"]) {
            event = @"profiler_enabled";
        } else if ([lowerMsg hasPrefix:@"dyld image callback registered"]) {
            event = @"dyld_callback_registered";
        } else if ([lowerMsg hasPrefix:@"main() hook installed"]) {
            event = @"main_hook_installed";
        } else if ([lowerMsg hasPrefix:@"uiapplication setdelegate hook installed"]) {
            event = @"delegate_hook_installed";
        } else if ([lowerMsg hasPrefix:@"dylib_loaded_end captured"]) {
            event = @"dylib_loaded_end";
        } else if ([lowerMsg hasPrefix:@"constructor(101) captured"]) {
            event = @"constructor_101";
        } else if ([lowerMsg hasPrefix:@"constructor(199) captured"]) {
            event = @"constructor_199";
        } else if ([lowerMsg hasPrefix:@"constructor(201) marked"]) {
            event = @"constructor_201";
        } else if ([lowerMsg hasPrefix:@"initialized:"]) {
            event = @"initialized";
        } else if ([lowerMsg hasPrefix:@"vuinstrumentationhooks.installall() completed"]) {
            event = @"hooks_installed";
        } else if ([lowerMsg hasPrefix:@"willfinish captured"]) {
            event = @"will_finish_captured";
        } else if ([lowerMsg isEqualToString:@"didfinish entered"]) {
            event = @"did_finish_entered";
        } else if ([lowerMsg hasPrefix:@"didfinish captured"]) {
            event = @"did_finish_captured";
        } else if ([lowerMsg hasPrefix:@"didfinish exiting"]) {
            event = @"did_finish_exited";
        } else if ([lowerMsg hasPrefix:@"scene:willconnect captured"]) {
            event = @"scene_will_connect_captured";
        } else if ([lowerMsg hasPrefix:@"installed on"]) {
            event = @"lifecycle_tracker_installed";
        } else {
            NSArray *words = [msg componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSMutableArray *cleanWords = [NSMutableArray array];
            for (NSString *w in words) {
                NSString *clean = [[w lowercaseString] stringByTrimmingCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]];
                if (clean.length > 0) {
                    [cleanWords addObject:clean];
                }
                if (cleanWords.count >= 3) break;
            }
            if (cleanWords.count > 0) {
                event = [cleanWords componentsJoinedByString:@"_"];
            }
        }
    }
    
    if (outLevel) *outLevel = level;
    if (outComponent) *outComponent = component;
    if (outEvent) *outEvent = event;
    if (outMessage) *outMessage = msg;
}

+ (void)logWithLevel:(VULogLevel)level
           component:(NSString *)component
               event:(NSString *)event
             message:(NSString *)message
    additionalFields:(NSDictionary<NSString *, id> *)additionalFields {
    
    [self initializeIfNeeded];
    
    BOOL isDebug = NO;
#ifdef DEBUG
    isDebug = YES;
#endif
    
    if (!isDebug && level != VULogLevelError) {
        if (!vu_exportDebugLogsEnabled) {
            return;
        }
    }
    
    NSString *levelString = @"info";
    switch (level) {
        case VULogLevelDebug: levelString = @"debug"; break;
        case VULogLevelInfo: levelString = @"info"; break;
        case VULogLevelWarning: levelString = @"warning"; break;
        case VULogLevelError: levelString = @"error"; break;
    }
    
    NSString *timestamp = [self getISO8601Timestamp];
    NSString *environment = isDebug ? @"development" : @"production";
    
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"level"] = levelString;
    payload[@"timestamp"] = timestamp;
    payload[@"component"] = component;
    payload[@"event"] = event;
    payload[@"sdk_version"] = @"0.0.1";
    payload[@"environment"] = environment;
    payload[@"message"] = message;
    
    if (additionalFields) {
        [payload addEntriesFromDictionary:additionalFields];
    }
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingSortedKeys error:nil];
    if (!jsonData) return;
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    NSString *resolvedSubsystem;
    if ([[component lowercaseString] isEqualToString:@"vuplugin"]) {
        resolvedSubsystem = @"com.vunet.telemetry.VuPlugin";
    } else {
        NSString *subComponent = [component lowercaseString];
        subComponent = [subComponent stringByReplacingOccurrencesOfString:@"_" withString:@"."];
        resolvedSubsystem = [NSString stringWithFormat:@"com.vunet.telemetry.%@", subComponent];
    }
    
    os_log_t logObj = [self getLoggerForSubsystem:resolvedSubsystem];
    
    os_log_type_t osLogLevel = OS_LOG_TYPE_DEFAULT;
    switch (level) {
        case VULogLevelDebug: osLogLevel = OS_LOG_TYPE_DEBUG; break;
        case VULogLevelInfo: osLogLevel = OS_LOG_TYPE_INFO; break;
        case VULogLevelWarning: osLogLevel = OS_LOG_TYPE_DEFAULT; break;
        case VULogLevelError: osLogLevel = OS_LOG_TYPE_ERROR; break;
    }
    os_log_with_type(logObj, osLogLevel, "%{public}s", [jsonString UTF8String]);
}

+ (void)logWithFormat:(const char *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *rawMessage = [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:format] arguments:args];
    va_end(args);
    
    VULogLevel level;
    NSString *component;
    NSString *event;
    NSString *msg;
    
    [self parseMessage:rawMessage outLevel:&level outComponent:&component outEvent:&event outMessage:&msg];
    [self logWithLevel:level component:component event:event message:msg additionalFields:nil];
}

@end
