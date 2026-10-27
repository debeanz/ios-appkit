// Runtime cross-check for data/ios-gap.json, run on an iOS simulator. The SDK check reads
// Apple's .tbd export lists, but some public frameworks re-export private ones whose lists
// aren't in the SDK, so a symbol can be "missing" there yet exist at runtime. This loads each
// framework the client links and asks dyld / the Objective-C runtime about every symbol the
// SDK check flagged. Anything found is not really missing, and the shim must not define it
// (a second definition is a collision).
//
//   runtime-gap <ios-gap.json> <out.json>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// macOS install name -> the same framework on iOS (no Versions/X), if it exists there.
static NSString *AKIOSPath(NSString *macPath) {
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\.framework/Versions/[^/]+/" options:0 error:nil];
  return [re stringByReplacingMatchesInString:macPath options:0 range:NSMakeRange(0, macPath.length) withTemplate:@".framework/"];
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: runtime-gap <ios-gap.json> <out.json>\n"); return 2; }
    NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
    NSDictionary *libraries = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil][@"libraries"];

    // Load everything first: a symbol may live in any loaded image, not just its own library.
    for (NSString *mac in libraries) dlopen(AKIOSPath(mac).UTF8String, RTLD_LAZY | RTLD_GLOBAL);

    NSMutableDictionary *present = [NSMutableDictionary dictionary];
    NSUInteger flagged = 0, found = 0;
    for (NSString *mac in libraries) {
      NSMutableArray *here = [NSMutableArray array];
      for (NSString *sym in libraries[mac][@"missing"]) {
        flagged++;
        NSString *name = [sym hasPrefix:@"_"] ? [sym substringFromIndex:1] : sym;
        BOOL exists = NO;
        for (NSString *prefix in @[ @"OBJC_CLASS_$_", @"OBJC_METACLASS_$_" ]) {
          if ([name hasPrefix:prefix]) {
            exists = objc_getClass([name substringFromIndex:prefix.length].UTF8String) != Nil;
            goto checked;
          }
        }
        exists = dlsym(RTLD_DEFAULT, name.UTF8String) != NULL;
      checked:
        if (exists) [here addObject:sym];
      }
      if (here.count) {
        present[mac] = @{ @"framework": libraries[mac][@"framework"], @"presentAtRuntime": here };
        found += here.count;
        printf("%4lu present at runtime in %s: %s\n", (unsigned long)here.count,
               [libraries[mac][@"framework"] UTF8String], [[here componentsJoinedByString:@" "] UTF8String]);
      }
    }
    printf("\n%lu of %lu SDK-missing symbols exist at runtime on this simulator.\n", (unsigned long)found, (unsigned long)flagged);
    NSData *out = [NSJSONSerialization dataWithJSONObject:@{ @"libraries": present } options:NSJSONWritingPrettyPrinted error:nil];
    [out writeToFile:@(argv[2]) atomically:YES];
    return 0;
  }
}
