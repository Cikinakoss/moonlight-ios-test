// One preference for the tested video and physical-gamepad pipeline.
#pragma once
#import <Foundation/Foundation.h>

static NSString* const MLLowLatencyPresetDefaultsKey = @"LowLatencyPreset";

static inline BOOL MLLowLatencyPresetAvailable(void) {
    if (@available(iOS 17.0, tvOS 17.0, *)) { return YES; }
    return NO;
}

static inline BOOL MLLowLatencyPresetEnabled(NSUserDefaults* defaults) {
    if (!MLLowLatencyPresetAvailable()) { return NO; }
    // An explicit Off must override any preferences left by previous builds.
    if ([defaults objectForKey:MLLowLatencyPresetDefaultsKey] != nil) {
        return [defaults boolForKey:MLLowLatencyPresetDefaultsKey];
    }
    // Preserve the tested legacy combination without activating partial setups.
    // Latest decoding already forced async submission, regardless of its toggle.
    return [defaults boolForKey:@"ExperimentalLatestDecodedFrame"] &&
        [defaults boolForKey:@"ExperimentalLatestPresentationImmediate"] &&
        [defaults boolForKey:@"SnappyGamepadInputExperimental"] &&
        ![defaults boolForKey:@"ExperimentalImmediatePresentation"];
}

static inline void MLSetLowLatencyPreset(NSUserDefaults* defaults, BOOL enabled) {
    [defaults setBool:enabled && MLLowLatencyPresetAvailable() forKey:MLLowLatencyPresetDefaultsKey];
    for (NSString* key in @[@"ExperimentalAsyncVideoSubmission", @"ExperimentalImmediatePresentation",
            @"ExperimentalLatestDecodedFrame", @"ExperimentalLatestPresentationImmediate",
            @"SnappyGamepadInputExperimental"]) {
        [defaults removeObjectForKey:key];
    }
}
