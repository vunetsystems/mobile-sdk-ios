//
//  VUSDWebImageBootstrap.m
//  VUSDWebImageBootstrap
//
//  "+load auto-install" for SDWebImage instrumentation.
//
//  When the host app links the `vuTelemetrySDWebImage` product, this class's
//  +load runs automatically before main() — no app-level call required. It
//  forwards to the Swift entry point `VUSDWebImageAutoInstaller.install()` by
//  ObjC runtime lookup, mirroring the pattern PreMainInit.m uses to reach
//  VUInstrumentationHooks. This keeps the Core module free of any compile-time
//  reference to SDWebImage code (clean one-way dependency: SDWebImage -> Core).
//
//  IMPORTANT — host integration:
//  Because this is delivered as a separately-linked static module, the linker
//  will dead-strip this translation unit unless the app force-loads it. Add
//  `-ObjC` (or `-force_load`) to the app target's OTHER_LDFLAGS so this class —
//  and therefore this +load — is retained. This is the standard requirement
//  for link-time auto-install SDKs.
//
//  Timing note: in a static link the whole package lands in the app image, so
//  by the time any +load runs every Swift @objc class is already registered —
//  the NSClassFromString lookup below resolves reliably.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface VUSDWebImageBootstrap : NSObject
@end

@implementation VUSDWebImageBootstrap

+ (void)load {
    // The Swift class is exported to the ObjC runtime as "VUSDWebImageAutoInstaller"
    // via @objc(VUSDWebImageAutoInstaller); fall back to the module-qualified name
    // in case it is registered under the module namespace.
    Class installer = objc_getClass("VUSDWebImageAutoInstaller");
    if (installer == nil) {
        installer = NSClassFromString(@"vuTelemetrySDWebImage.VUSDWebImageAutoInstaller");
    }
    if (installer == nil) {
        return;
    }

    SEL installSel = sel_registerName("install");
    if ([installer respondsToSelector:installSel]) {
        ((void (*)(id, SEL))objc_msgSend)(installer, installSel);
    }
}

@end
