//
//  MenuBarPrivate.m
//  BarLens
//

#import "MenuBarPrivate.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// Not the case count — a ceiling on the raw value space, and it has to be at
// least as high as the highest addressable case, because the assertion is a
// white list: any value missing from it is hidden.
//
// Small on purpose, because a larger one buys nothing. Measured with 14 built-in
// items on the bar: allowing 0..8, 0..13 and 0..65535 all produce *the same nine
// items*. Values past the addressable range are inert — they do not keep the
// item they might name, and they do not disturb the items that are addressable.
// 64 leaves room for the range to grow without shipping a 65536-element array
// over XPC on every apply.
//
// What this cannot do is keep every item on the bar: some are hidden by the act
// of asserting at all, whatever is in this list. See SystemItemCaveats.
const NSInteger MBSystemItemRawValueCount = 64;

#pragma mark - The private surface we depend on

// These declarations mirror classes that live in MenuBarClientCore.framework.
// They are looked up at runtime, never linked, so a missing framework degrades
// to MBPrivateAPIAvailable() == NO rather than a launch failure.
@interface MBAssessmentModeConfiguration : NSObject
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                   allowedBundleIdentifiers:(NSArray<NSString *> *)bundles;
@end

@interface MBAssessmentModeAssertion : NSObject
- (void)activateWithConfiguration:(id)config completionHandler:(void (^)(NSError *))handler;
- (void)invalidate;
@end

#pragma mark - Framework loading

static void MBLoadFramework(NSString *path) {
    static NSMutableSet<NSString *> *attempted = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ attempted = [NSMutableSet set]; });
    @synchronized (attempted) {
        if ([attempted containsObject:path]) return;
        [attempted addObject:path];
        // These paths have no file on disk — the binaries live in the dyld shared
        // cache — but dlopen resolves them through the cache all the same.
        dlopen(path.UTF8String, RTLD_NOW);
    }
}

static void MBLoadPrivateFrameworks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MBLoadFramework(@"/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices");
        MBLoadFramework(@"/System/Library/PrivateFrameworks/MenuBarClient.framework/MenuBarClient");
        MBLoadFramework(@"/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore");
    });
}

BOOL MBPrivateAPIAvailable(void) {
    MBLoadPrivateFrameworks();
    return objc_getClass("MBAssessmentModeConfiguration") != Nil
        && objc_getClass("MBAssessmentModeAssertion") != Nil;
}

#pragma mark - Assertion

@interface MBMenuBarAssertion ()
@property (nonatomic, strong, nullable) id assertion;
@property (nonatomic, strong, nullable) id pendingAssertion;
@property (nonatomic) NSUInteger generation;
@end

@implementation MBMenuBarAssertion

- (void)acquireWithAllowedBundles:(NSArray<NSString *> *)allowedBundles
               hiddenSystemItems:(NSArray<NSNumber *> *)hiddenSystemItems
                completionHandler:(void (^)(NSError *_Nullable))handler {

    NSAssert([NSThread isMainThread], @"Menu bar assertions must be driven on the main thread");
    NSUInteger generation = ++self.generation;
    [self.pendingAssertion invalidate];
    self.pendingAssertion = nil;

    void (^finish)(NSError *) = ^(NSError *error) {
        if (!handler) return;
        dispatch_async(dispatch_get_main_queue(), ^{ handler(error); });
    };

    MBLoadPrivateFrameworks();

    Class configClass = objc_getClass("MBAssessmentModeConfiguration");
    Class assertionClass = objc_getClass("MBAssessmentModeAssertion");
    if (!configClass || !assertionClass) {
        NSError *e = [NSError errorWithDomain:@"BarLens.PrivateAPI" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
            @"MenuBarAgent's assessment-mode API is not present on this system."}];
        finish(e);
        return;
    }

    // The API underneath is a white list, so invert the caller's black list
    // here. This is the one place that knows the size of the raw value space,
    // and doing it here means a caller can pass a value it has never seen
    // without knowing whether it names a real case.
    NSSet<NSNumber *> *hidden = [NSSet setWithArray:hiddenSystemItems ?: @[]];
    NSMutableArray<NSNumber *> *systemItems =
        [NSMutableArray arrayWithCapacity:MBSystemItemRawValueCount];
    for (NSInteger i = 0; i < MBSystemItemRawValueCount; i++) {
        NSNumber *value = @(i);
        if (![hidden containsObject:value]) { [systemItems addObject:value]; }
    }

    // Note: passing nil here means "allow none", not "allow all" — measured, and
    // it empties the whole bar. That is why this always hands over a full list.
    MBAssessmentModeConfiguration *config =
        [[configClass alloc] initWithAllowedSystemItems:systemItems
                               allowedBundleIdentifiers:allowedBundles ?: @[]];

    MBAssessmentModeAssertion *fresh = [[assertionClass alloc] init];
    self.pendingAssertion = fresh;

    __weak typeof(self) weakSelf = self;
    [fresh activateWithConfiguration:config completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) self_ = weakSelf;
            // A suspend or newer request may have arrived while activation
            // was pending. Its late reply must never hide the bar again.
            if (!self_ || self_.generation != generation) {
                [fresh invalidate];
                finish([NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError
                                        userInfo:nil]);
                return;
            }
            self_.pendingAssertion = nil;
            if (error) { [fresh invalidate]; finish(error); return; }
            // Install the replacement before releasing the old assertion.
            id previous = self_.assertion;
            self_.assertion = fresh;
            [previous invalidate];
            finish(nil);
        });
    }];
}

- (void)deactivate {
    NSAssert([NSThread isMainThread], @"Menu bar assertions must be driven on the main thread");
    self.generation += 1;
    [self.pendingAssertion invalidate];
    self.pendingAssertion = nil;
    id previous = self.assertion;
    self.assertion = nil;
    [previous invalidate];
}

- (BOOL)isActive {
    return self.assertion != nil;
}

@end
