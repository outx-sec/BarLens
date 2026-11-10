//
//  MenuBarPrivate.h
//  BarLens
//
//  The one and only place that touches Apple's private menu bar API.
//  Everything here talks to MenuBarAgent through MBAssessmentModeAssertion,
//  which is an exported Objective-C class in the private MenuBarClientCore
//  framework. Keeping it in a separate target means a future OS change only
//  breaks this file.
//
//  Why Assessment Mode: MenuBarAgent is the sole owner of menu bar layout on
//  macOS 27+ (Darwin 26A+). It exposes several BSService endpoints, but the only one a
//  third-party app may call with a custom allow list is the assessment-mode
//  assertion. The ControlCenter allow list (what System Settings drives) is
//  not reachable from outside Apple.
//
//  The restriction is bound to this process's XPC connection, so it is lifted
//  automatically when the process exits. Nothing is written to disk.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The exclusive upper bound of `MBSystemItemIdentifier`'s raw value space.
///
/// MBSystemItemIdentifier is a Swift enum, not an ObjC class, so its cases
/// cannot be enumerated from here. This is a superset bound rather than the
/// case count: the framework tolerates values that name no case, which is what
/// makes the black-list form below safe and what makes the value sweep in
/// SystemItemDiscovery possible.
FOUNDATION_EXPORT const NSInteger MBSystemItemRawValueCount;

/// Whether the private API is present and callable on this system.
FOUNDATION_EXPORT BOOL MBPrivateAPIAvailable(void);

@interface MBMenuBarAssertion : NSObject

/// Acquire the visibility restriction with the given allow list.
///
/// `allowedBundles` are the bundle identifiers whose menu bar items stay
/// visible. Every *running* application that owns a status item must appear
/// here or its item disappears — the API is a white list, not a black list,
/// and it has no "deny" counterpart.
///
/// Safe to call repeatedly: each call replaces the previous restriction.
/// The handler is invoked on the main queue when MenuBarAgent has answered.
///
/// `hiddenSystemItems` are the raw `MBSystemItemIdentifier` values to suppress;
/// every other value is allowed. Deliberately a black list even though the API
/// underneath takes a white one: the caller cannot enumerate the enum, so a
/// value it has never heard of must default to *visible*. A white list built
/// from a partial table would hide Spotlight the moment the user hid Wi-Fi.
/// An empty array hides nothing, which is the right answer for a user who has
/// not touched the built-in items.
- (void)acquireWithAllowedBundles:(NSArray<NSString *> *)allowedBundles
               hiddenSystemItems:(NSArray<NSNumber *> *)hiddenSystemItems
                completionHandler:(void (^_Nullable)(NSError *_Nullable error))handler;

/// Drop the restriction immediately, restoring every hidden item.
- (void)deactivate;

/// Whether a restriction is currently held by this process.
@property (nonatomic, readonly) BOOL isActive;

@end

NS_ASSUME_NONNULL_END
