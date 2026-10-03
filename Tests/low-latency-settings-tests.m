#import "../Limelight/Stream/LowLatencySettings.h"
#include <stdlib.h>

#define CHECK(value) do { if (!(value)) { NSLog(@"CHECK failed at %d: %s", __LINE__, #value); abort(); } } while (0)

int main(void) {
    @autoreleasepool {
        NSString* suite = [@"MoonlightPresetTests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        CHECK(!MLLowLatencyPresetEnabled(defaults));
        [defaults setBool:YES forKey:@"ExperimentalLatestDecodedFrame"];
        CHECK(!MLLowLatencyPresetEnabled(defaults));
        [defaults setBool:YES forKey:@"ExperimentalLatestPresentationImmediate"];
        CHECK(!MLLowLatencyPresetEnabled(defaults));
        [defaults setBool:YES forKey:@"SnappyGamepadInputExperimental"];
        [defaults setBool:YES forKey:@"ExperimentalAsyncVideoSubmission"];
        [defaults setBool:NO forKey:@"ExperimentalImmediatePresentation"];
        CHECK(MLLowLatencyPresetEnabled(defaults));
        // Async was implicit with latest decoding, even if its old switch was Off.
        [defaults setBool:NO forKey:@"ExperimentalAsyncVideoSubmission"];
        CHECK(MLLowLatencyPresetEnabled(defaults));
        [defaults setBool:YES forKey:@"ExperimentalImmediatePresentation"];
        CHECK(!MLLowLatencyPresetEnabled(defaults));
        [defaults setBool:NO forKey:@"ExperimentalImmediatePresentation"];
        [defaults setBool:NO forKey:MLLowLatencyPresetDefaultsKey];
        CHECK(!MLLowLatencyPresetEnabled(defaults)); // Explicit Off overrides legacy On.
        MLSetLowLatencyPreset(defaults, YES);
        CHECK(MLLowLatencyPresetEnabled(defaults));
        for (NSString* key in @[@"ExperimentalAsyncVideoSubmission", @"ExperimentalImmediatePresentation",
                @"ExperimentalLatestDecodedFrame", @"ExperimentalLatestPresentationImmediate",
                @"SnappyGamepadInputExperimental"]) {
            CHECK([defaults objectForKey:key] == nil);
        }
        MLSetLowLatencyPreset(defaults, NO);
        CHECK(!MLLowLatencyPresetEnabled(defaults));
        [defaults removePersistentDomainForName:suite];
        NSLog(@"Low Latency preference migration and save tests passed");
    }
    return 0;
}
