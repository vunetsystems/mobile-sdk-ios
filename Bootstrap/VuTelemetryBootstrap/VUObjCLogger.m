//
//  VUObjCLogger.m
//  VuTelemetryBootstrap
//
//  Plain-text logger mirroring VULogger.swift. Component maps to os_log category.
//  Output format: "message" or "message — key=value ..." with no JSON wrapping.

#import "VUObjCLogger.h"
#import <os/log.h>

static BOOL vu_exportDebugLogsEnabled = NO;
static volatile int vu_sdk_disabled = 0;
static dispatch_once_t initToken;
static NSMutableDictionary<NSString *, os_log_t> *vu_loggers = nil;
static NSLock *vu_loggerLock = nil;

void vu_mark_sdk_disabled(void) {
    __atomic_store_n(&vu_sdk_disabled, 1, __ATOMIC_SEQ_CST);
}

@implementation VUObjCLogger

+ (os_log_t)loggerForSubsystem:(NSString *)subsystem category:(NSString *)category {
    static dispatch_once_t loggerInitToken;
    dispatch_once(&loggerInitToken, ^{
        vu_loggers = [NSMutableDictionary dictionary];
        vu_loggerLock = [[NSLock alloc] init];
    });

    NSString *key = [NSString stringWithFormat:@"%@/%@", subsystem, category];
    [vu_loggerLock lock];
    os_log_t log = vu_loggers[key];
    if (!log) {
        log = os_log_create([subsystem UTF8String], [category UTF8String]);
        vu_loggers[key] = log;
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

        os_log_t bootLog = [self loggerForSubsystem:@"com.vunet.telemetry.logger" category:@"sdk"];
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

+ (void)logWithLevel:(VULogLevel)level
           component:(NSString *)component
               event:(NSString *)event
             message:(NSString *)message
    additionalFields:(NSDictionary<NSString *, id> *)additionalFields {

    [self initializeIfNeeded];

    if (__atomic_load_n(&vu_sdk_disabled, __ATOMIC_SEQ_CST)) { return; }

    BOOL isDebug = NO;
#ifdef DEBUG
    isDebug = YES;
#endif

    if (!isDebug && level != VULogLevelError) {
        if (!vu_exportDebugLogsEnabled) { return; }
    }

    // Build plain-text line: "message" or "message — key=value key=value"
    NSString *line = message;
    if (additionalFields.count > 0) {
        NSArray *sortedKeys = [[additionalFields allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:sortedKeys.count];
        for (NSString *k in sortedKeys) {
            [pairs addObject:[NSString stringWithFormat:@"%@=%@", k, additionalFields[k]]];
        }
        line = [NSString stringWithFormat:@"%@ — %@", message, [pairs componentsJoinedByString:@" "]];
    }

    // Component maps to subsystem so Xcode's subsystem column acts as a scope label.
    NSString *slug = [[component lowercaseString] stringByReplacingOccurrencesOfString:@"_" withString:@"."];
    NSString *subsystem = [NSString stringWithFormat:@"com.vunet.telemetry.%@", slug];
    os_log_t logObj = [self loggerForSubsystem:subsystem category:@"sdk"];

    os_log_type_t osLevel = OS_LOG_TYPE_DEFAULT;
    switch (level) {
        case VULogLevelDebug:   osLevel = OS_LOG_TYPE_DEBUG;   break;
        case VULogLevelInfo:    osLevel = OS_LOG_TYPE_INFO;    break;
        case VULogLevelWarning: osLevel = OS_LOG_TYPE_DEFAULT; break;
        case VULogLevelError:   osLevel = OS_LOG_TYPE_ERROR;   break;
    }

    os_log_with_type(logObj, osLevel, "%{public}s", [line UTF8String]);
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
            } else if ([lowerComp isEqualToString:@"vutelemetry"] || [lowerComp isEqualToString:@"startuptelemetry"]) {
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

    if (outLevel) *outLevel = level;
    if (outComponent) *outComponent = component;
    if (outEvent) *outEvent = event;
    if (outMessage) *outMessage = msg;
}

@end
