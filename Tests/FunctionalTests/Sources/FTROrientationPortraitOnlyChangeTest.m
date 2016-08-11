//
// Copyright 2016 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <EarlGrey/GREYSwizzler.h>

#import "FTRBaseIntegrationTest.h"

@implementation UIApplication (Test)

- (NSUInteger)grey_supportedInterfaceOrientationsForWindow:(UIWindow *)window {
  return UIInterfaceOrientationMaskPortrait;
}

@end

GREYSwizzler *gSwizzler;

@interface FTROrientationPortraitOnlyChangeTest : FTRBaseIntegrationTest
@end

@implementation FTROrientationPortraitOnlyChangeTest

- (void)setUp {
  [super setUp];

  // Swizzle UIApplication supportedInterfaceOrientationsForWindow: to make orientations other than
  // portrait unsupported by the app.
  [EarlGrey executeBlock:^{
    gSwizzler = [[GREYSwizzler alloc] init];
    BOOL swizzle = [gSwizzler swizzleClass:[UIApplication class]
                     replaceInstanceMethod:@selector(supportedInterfaceOrientationsForWindow:)
                                withMethod:@selector(grey_supportedInterfaceOrientationsForWindow:)];
    GREYAssert(swizzle, @"Cannot swizzle UIApplication supportedInterfaceOrientationsForWindow:");
  }];
}

- (void)tearDown {
  // Tear down before undoing swizzling.
  [super tearDown];

  // Undo swizzling.
  [EarlGrey executeBlock:^{
    BOOL swizzle1 =
        [gSwizzler resetInstanceMethod:@selector(supportedInterfaceOrientationsForWindow:)
                                 class:[UIApplication class]];
    BOOL swizzle2 =
        [gSwizzler resetInstanceMethod:@selector(grey_supportedInterfaceOrientationsForWindow:)
                                 class:[UIApplication class]];
    GREYAssert(swizzle1 && swizzle2, @"Failed to undo swizzling of UIApplication methods");
  }];
}

- (void)testRotateToUnsupportedOrientation {
  [EarlGrey rotateDeviceToOrientation:UIDeviceOrientationLandscapeLeft errorOrNil:nil];
  [EarlGrey executeBlock:^{
    GREYAssertEqual([UIDevice currentDevice].orientation, UIDeviceOrientationLandscapeLeft,
                    @"Device orientation should now be landscape left");
    UIApplication *sharedApp = [UIApplication sharedApplication];
    GREYAssertEqual(sharedApp.statusBarOrientation, UIInterfaceOrientationPortrait,
                    @"Interface orientation should remain portrait");
  }];
}

- (void)testDeviceChangeWithoutInterfaceChange {
  [EarlGrey rotateDeviceToOrientation:UIDeviceOrientationLandscapeLeft errorOrNil:nil];
  [EarlGrey executeBlock:^{
    UIApplication *sharedApp = [UIApplication sharedApplication];
    GREYAssertEqual(sharedApp.statusBarOrientation, UIInterfaceOrientationPortrait,
                    @"Interface orientation should be portrait.");
  }];

  [EarlGrey rotateDeviceToOrientation:UIDeviceOrientationPortrait errorOrNil:nil];
  [EarlGrey executeBlock:^{
    GREYAssertEqual([UIDevice currentDevice].orientation, UIDeviceOrientationPortrait,
                    @"Device orientation should now be portrait");
    UIApplication *sharedApp = [UIApplication sharedApplication];
    GREYAssertEqual(sharedApp.statusBarOrientation, UIInterfaceOrientationPortrait,
                    @"Interface orientation should remain portrait");
  }];
}

@end
