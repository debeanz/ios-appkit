// macOS's own answer to two questions about the shim's AppKit classes, asked of the real AppKit
// on the macOS runner (ipa.yml):
//
//   types: the type encodings of their methods that return a struct or a floating-point value,
//          written next to the shim (AppKitShimCore.framework/mac-method-types.txt). A method the
//          shim doesn't have yet falls back to returning zero (AKForwarding.m); without the real
//          signature that zero lands in x0 while the caller reads an NSRect from d0-d3 or a
//          CGFloat from d0, and gets whatever was there (Unity read its screen as 0x0).
//   audit: the methods each game engine's code sends (engine-gaps.js writes them) that macOS's
//          class has and the shim's doesn't: the methods to write before anyone plays its games.
//
// The shim's methods come from its symbol table (nm): "-[NSView(Cat) frame]" and the like.
//
//   mac-methods types <shim-nm.txt> <out.txt>
//   mac-methods audit <shim-nm.txt> <engine-selectors.json> <out.txt>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// Shim classes that run under another name (AK_SHIM_RUNTIME_NAME, NSFont.m) by their AppKit name.
static NSString *appKitName(NSString *runtime) {
  if ([runtime isEqualToString:@"AKShimFont"]) return @"NSFont";
  if ([runtime hasPrefix:@"AKShim_"]) return [runtime substringFromIndex:7];
  return runtime;
}

// "Class -sel" and "Class +sel" for every method the shim defines, by AppKit class name, and in
// `classes` the classes it defines itself (not iOS's classes it adds a category to).
static NSSet<NSString *> *shimMethods(NSString *nmPath, NSMutableSet<NSString *> *classes) {
  NSString *text = [NSString stringWithContentsOfFile:nmPath encoding:NSUTF8StringEncoding error:nil];
  NSRegularExpression *method = [NSRegularExpression regularExpressionWithPattern:@"([-+])\\[([A-Za-z0-9_]+)(?:\\([^)]*\\))? ([^\\]]+)\\]"
                                                                          options:0 error:nil];
  NSRegularExpression *defined = [NSRegularExpression regularExpressionWithPattern:@"^[0-9a-f]+ [SsDd] _OBJC_CLASS_\\$_([A-Za-z0-9_]+)$"
                                                                           options:NSRegularExpressionAnchorsMatchLines error:nil];
  NSMutableSet *out = [NSMutableSet set];
  [method enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                        usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
    [out addObject:[NSString stringWithFormat:@"%@ %@%@", appKitName([text substringWithRange:[m rangeAtIndex:2]]),
                                              [text substringWithRange:[m rangeAtIndex:1]], [text substringWithRange:[m rangeAtIndex:3]]]];
  }];
  [defined enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                         usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
    [classes addObject:appKitName([text substringWithRange:[m rangeAtIndex:1]])];
  }];
  return out;
}

// macOS's class for a shim class, when macOS has one that isn't the root.
static Class macClass(NSString *name) {
  Class c = objc_getClass(name.UTF8String);
  return c && class_getSuperclass(c) ? c : Nil;
}

static BOOL interestingReturn(Method m) {
  char *r = method_copyReturnType(m);
  // Qualifiers (const, in, out...) come first.
  const char *t = r;
  while (*t && strchr("rnNoORV", *t)) t++;
  BOOL yes = *t == '{' || *t == '(' || *t == 'f' || *t == 'd' || *t == 'D';
  free(r);
  return yes;
}

static int writeTypes(NSString *nmPath, NSString *outPath) {
  NSMutableSet<NSString *> *classes = [NSMutableSet set];
  shimMethods(nmPath, classes);
  NSMutableSet<NSString *> *lines = [NSMutableSet set];
  NSMutableSet<NSString *> *done = [NSMutableSet set];
  NSUInteger methods = 0;
  for (NSString *name in classes) {
    for (Class c = macClass(name); c && class_getSuperclass(c); c = class_getSuperclass(c)) {
      NSString *cname = @(class_getName(c));
      if ([done containsObject:cname]) break;   // its superclasses are done too
      [done addObject:cname];
      Class sup = class_getSuperclass(c);
      if (sup && class_getSuperclass(sup)) [lines addObject:[NSString stringWithFormat:@"^ %@ %s", cname, class_getName(sup)]];
      for (int meta = 0; meta < 2; meta++) {
        unsigned count = 0;
        Method *list = class_copyMethodList(meta ? object_getClass(c) : c, &count);
        for (unsigned i = 0; i < count; i++) {
          const char *sel = sel_getName(method_getName(list[i]));
          const char *enc = method_getTypeEncoding(list[i]);
          if (sel[0] == '_' || !enc || !interestingReturn(list[i])) continue;
          [lines addObject:[NSString stringWithFormat:@"%@ %c%s %s", cname, meta ? '+' : '-', sel, enc]];
          methods++;
        }
        free(list);
      }
    }
  }
  NSArray *sorted = [lines.allObjects sortedArrayUsingSelector:@selector(compare:)];
  NSString *text = [[sorted componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
  if (![text writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 1;
  printf("%lu methods returning a struct or floating-point value, of %lu macOS classes behind %lu shim classes: %s\n",
         (unsigned long)methods, (unsigned long)done.count, (unsigned long)classes.count, outPath.UTF8String);
  return 0;
}

// Does the shim answer `sel` for macOS class `c`: a method of its own class or of one it inherits
// from (by macOS's lineage, which the shim's follows).
static BOOL shimHas(NSSet<NSString *> *shim, Class c, char kind, const char *sel) {
  for (; c && class_getSuperclass(c); c = class_getSuperclass(c))
    if ([shim containsObject:[NSString stringWithFormat:@"%@ %c%s", appKitName(@(class_getName(c))), kind, sel]]) return YES;
  return NO;
}

static int writeAudit(NSString *nmPath, NSString *selectorsPath, NSString *outPath) {
  NSMutableSet<NSString *> *classes = [NSMutableSet set];
  NSSet<NSString *> *shim = shimMethods(nmPath, classes);
  NSDictionary<NSString *, NSArray<NSString *> *> *engines =
      [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:selectorsPath] options:0 error:nil];
  if (![engines isKindOfClass:NSDictionary.class]) { fprintf(stderr, "unreadable: %s\n", selectorsPath.UTF8String); return 1; }
  Class root = NSObject.class;
  NSArray *names = [classes.allObjects sortedArrayUsingSelector:@selector(compare:)];
  NSMutableString *out = [NSMutableString string];
  NSMutableDictionary<NSString *, NSMutableSet *> *everywhere = [NSMutableDictionary dictionary];
  for (NSString *engine in [engines.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *selName in engines[engine]) {
      SEL sel = sel_registerName(selName.UTF8String);
      for (NSString *name in names) {
        Class c = macClass(name);
        if (!c) continue;
        for (int meta = 0; meta < 2; meta++) {
          Method m = meta ? class_getClassMethod(c, sel) : class_getInstanceMethod(c, sel);
          // Not macOS's, or one NSObject has too (-init, -dealloc, -description, key-value
          // observing...: iOS's NSObject has them, and AppKit's overrides change nothing a game sees).
          if (!m || (meta ? class_getClassMethod(root, sel) : class_getInstanceMethod(root, sel))) continue;
          // Defined by a class of iOS's (the shim's CAOpenGLLayer is a CALayer): iOS has it.
          Class owner = c;
          for (Class k = c; k && class_getSuperclass(k); k = class_getSuperclass(k)) {
            Class up = class_getSuperclass(k);
            Method above = meta ? class_getClassMethod(up, sel) : class_getInstanceMethod(up, sel);
            owner = k;
            if (above != m) break;
          }
          if (![classes containsObject:appKitName(@(class_getName(owner)))]) continue;
          char kind = meta ? '+' : '-';
          if (shimHas(shim, c, kind, sel_getName(sel))) continue;
          NSString *line = [NSString stringWithFormat:@"%@ %c%@  %s%@", name, kind, selName, method_getTypeEncoding(m) ?: "",
                                                      interestingReturn(m) ? @"  [struct or float: garbage without it]" : @""];
          [found addObject:line];
          NSMutableSet *who = everywhere[line] ?: (everywhere[line] = [NSMutableSet set]);
          [who addObject:engine];
        }
      }
    }
    [out appendFormat:@"== %@: %lu methods its code sends that macOS's class has and the shim's lacks\n", engine, (unsigned long)found.count];
    for (NSString *l in [found sortedArrayUsingSelector:@selector(compare:)]) [out appendFormat:@"  %@\n", l];
    [out appendString:@"\n"];
  }
  [out appendFormat:@"== all engines: %lu\n", (unsigned long)everywhere.count];
  for (NSString *l in [everywhere.allKeys sortedArrayUsingSelector:@selector(compare:)])
    [out appendFormat:@"  %@  (%@)\n", l, [[everywhere[l].allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "]];
  if (![out writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 1;
  fputs(out.UTF8String, stdout);
  return 0;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY | RTLD_GLOBAL);
    if (argc == 4 && !strcmp(argv[1], "types")) return writeTypes(@(argv[2]), @(argv[3]));
    if (argc == 5 && !strcmp(argv[1], "audit")) return writeAudit(@(argv[2]), @(argv[3]), @(argv[4]));
    fprintf(stderr, "usage: mac-methods types <shim-nm.txt> <out.txt>\n"
                    "       mac-methods audit <shim-nm.txt> <engine-selectors.json> <out.txt>\n");
    return 2;
  }
}
