// Steam's interface fonts. sp.css asks for https://steamloopback.host/custom_fonts/
// clientui.uifont?MotivaSans-Regular, which Steam Helper answers itself from
// <clientui>/fonts/clientui.uifont: a CUIFontFilePackagePB {1 package_version = 1,
// 2 encrypted_font_files [{1 encrypted_contents}]}. Each entry is Valve's SymmetricDecrypt
// (AES-256: the IV ECB-encrypted in the first block, then CBC with PKCS#7) of a CUIFontFilePB
// {1 font_file_name, 2 opentype_font_data}; the answer is the first entry whose file name
// contains "<query>." in any case, as application/font-sfnt.
//
// The key is Valve's and isn't copied into this project: it's read from the Steam Helper
// binary that ships next to clientui. Steam Helper keeps it at the start of __DATA,__data;
// rather than trust that across updates, every 8-byte-aligned 32 bytes of its data sections
// is tried on the package's first entry, and the one that decrypts it into a font file name
// is the key (the first section holds it, so this takes a few thousand tries, milliseconds).
#import <CommonCrypto/CommonCryptor.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import "WebHelper.h"

static NSString *gClientUI, *gHelperBinary;
static NSData *gKey;
static NSMutableDictionary<NSString *, NSArray<NSData *> *> *gPackages;   // package path -> entries
static NSCache<NSString *, NSData *> *gFonts;                               // "<package>?<name>" -> font

static NSObject *pathsLock(void) {
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  return lock;
}

void AKWHFontsSetPaths(NSString *clientUI, NSString *helperBinary) {
  @synchronized(pathsLock()) {
    gClientUI = [clientUI copy];
    gHelperBinary = [helperBinary copy];
  }
}

#pragma mark Protobuf

static BOOL readVarint(const uint8_t *p, size_t n, size_t *o, uint64_t *v) {
  *v = 0;
  for (int shift = 0; *o < n && shift < 64; shift += 7) {
    uint8_t c = p[(*o)++];
    *v |= (uint64_t)(c & 0x7f) << shift;
    if (!(c & 0x80)) return YES;
  }
  return NO;
}

// Calls back with each field: its number, and its bytes (length-delimited) or value (varint).
static BOOL eachField(NSData *message, void (^field)(uint32_t number, NSData *bytes, uint64_t value)) {
  const uint8_t *p = message.bytes;
  size_t n = message.length, o = 0;
  while (o < n) {
    uint64_t key, v;
    if (!readVarint(p, n, &o, &key)) return NO;
    switch (key & 7) {
      case 0:
        if (!readVarint(p, n, &o, &v)) return NO;
        field((uint32_t)(key >> 3), nil, v);
        break;
      case 2:
        if (!readVarint(p, n, &o, &v) || v > n - o) return NO;
        field((uint32_t)(key >> 3), [message subdataWithRange:NSMakeRange(o, (NSUInteger)v)], 0);
        o += (size_t)v;
        break;
      case 1: if (n - o < 8) return NO; o += 8; break;
      case 5: if (n - o < 4) return NO; o += 4; break;
      default: return NO;
    }
  }
  return YES;
}

#pragma mark Decrypting

static BOOL decryptIV(const uint8_t *key, const uint8_t *entry, uint8_t iv[16]) {
  size_t moved = 0;
  return CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionECBMode, key, 32, NULL, entry, 16, iv, 16, &moved) == kCCSuccess && moved == 16;
}

// Whether a key turns the start of an entry into field 1, a printable file name.
static BOOL keyFits(const uint8_t *key, NSData *entry) {
  if (entry.length < 48) return NO;
  uint8_t iv[16], out[32];
  size_t moved = 0;
  if (!decryptIV(key, entry.bytes, iv)) return NO;
  if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, 0, key, 32, iv, (const uint8_t *)entry.bytes + 16, 32, out, 32, &moved) != kCCSuccess)
    return NO;
  if (out[0] != 0x0a || out[1] < 5 || out[1] > 30) return NO;
  for (int i = 2; i < 2 + out[1]; i++)
    if (out[i] < 0x20 || out[i] > 0x7e) return NO;
  return YES;
}

static NSData *decryptEntry(NSData *key, NSData *entry) {
  if (entry.length < 32 || entry.length % 16) return nil;
  uint8_t iv[16];
  if (!decryptIV(key.bytes, entry.bytes, iv)) return nil;
  NSMutableData *plain = [NSMutableData dataWithLength:entry.length];
  size_t moved = 0;
  if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.bytes, 32, iv, (const uint8_t *)entry.bytes + 16,
              entry.length - 16, plain.mutableBytes, plain.length, &moved) != kCCSuccess)
    return nil;
  plain.length = moved;
  return plain;
}

#pragma mark Finding the key

// The arm64 slice of a Mach-O file (thin or universal).
static NSData *arm64Slice(NSData *file) {
  if (file.length < sizeof(struct mach_header_64)) return nil;
  const uint8_t *p = file.bytes;
  uint32_t magic = *(const uint32_t *)p;
  if (magic == MH_MAGIC_64) return file;
  if (magic != FAT_CIGAM) return nil;
  const struct fat_header *fat = (const void *)p;
  uint32_t count = OSSwapBigToHostInt32(fat->nfat_arch);
  for (uint32_t i = 0; i < count && sizeof *fat + (i + 1) * sizeof(struct fat_arch) <= file.length; i++) {
    const struct fat_arch *a = (const void *)(p + sizeof *fat + i * sizeof(struct fat_arch));
    if ((cpu_type_t)OSSwapBigToHostInt32(a->cputype) != CPU_TYPE_ARM64) continue;
    uint32_t off = OSSwapBigToHostInt32(a->offset), size = OSSwapBigToHostInt32(a->size);
    if ((uint64_t)off + size <= file.length) return [file subdataWithRange:NSMakeRange(off, size)];
  }
  return nil;
}

static NSData *findKey(NSData *entry) {
  NSString *path;
  @synchronized(pathsLock()) { path = gHelperBinary; }
  NSData *file = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] : nil;
  NSData *image = arm64Slice(file);
  if (!image) {
    AKWHLog(YES, @"fonts: can't read Steam Helper at %@; Steam's fonts fall back to the system's", path);
    return nil;
  }
  // The sections to search, most likely first.
  static const char *const wanted[][2] = {
    {"__DATA", "__data"}, {"__DATA", "__const"}, {"__DATA_CONST", "__const"}, {"__TEXT", "__const"},
  };
  const uint8_t *base = image.bytes;
  const struct mach_header_64 *mh = (const void *)base;
  CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  unsigned tries = 0;
  for (size_t w = 0; w < sizeof wanted / sizeof *wanted; w++) {
    size_t o = sizeof *mh;
    for (uint32_t i = 0; i < mh->ncmds && o + sizeof(struct load_command) <= image.length; i++) {
      const struct load_command *lc = (const void *)(base + o);
      if (lc->cmdsize < sizeof *lc || o + lc->cmdsize > image.length) break;
      if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *seg = (const void *)lc;
        const struct section_64 *sect = (const void *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects && (const uint8_t *)(sect + s + 1) <= base + o + lc->cmdsize; s++) {
          if (strncmp(sect[s].segname, wanted[w][0], 16) || strncmp(sect[s].sectname, wanted[w][1], 16)) continue;
          uint64_t start = sect[s].offset, end = start + sect[s].size;
          if (!start || end > image.length) continue;
          for (uint64_t k = start; k + 32 <= end; k += 8) {
            tries++;
            if (!keyFits(base + k, entry)) continue;
            AKWHLog(NO, @"fonts: found Steam Helper's font key in %s,%s after %u tries, %.0f ms", wanted[w][0], wanted[w][1],
                    tries, (CFAbsoluteTimeGetCurrent() - started) * 1000);
            return [NSData dataWithBytes:base + k length:32];
          }
        }
      }
      o += lc->cmdsize;
    }
  }
  AKWHLog(YES, @"fonts: no key in Steam Helper decrypts Steam's fonts (%u tried); they fall back to the system's", tries);
  return nil;
}

#pragma mark Serving

static NSArray<NSData *> *packageEntries(NSString *path) {
  NSArray<NSData *> *entries = gPackages[path];
  if (entries) return entries;
  NSData *package = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  __block uint64_t version = 0;
  NSMutableArray<NSData *> *found = [NSMutableArray array];
  BOOL ok = package && eachField(package, ^(uint32_t number, NSData *bytes, uint64_t value) {
    if (number == 1 && !bytes) version = value;
    if (number == 2 && bytes)
      eachField(bytes, ^(uint32_t n, NSData *b, uint64_t v) {
        if (n == 1 && b) [found addObject:b];
      });
  });
  if (!ok || version != 1 || !found.count) {
    AKWHLog(YES, @"fonts: %@ isn't a font package this helper knows (version %llu, %lu fonts)", path, version,
            (unsigned long)found.count);
    found = [NSMutableArray array];
  }
  if (!gPackages) gPackages = [NSMutableDictionary dictionary];
  gPackages[path] = found;
  return found;
}

// The font a /custom_fonts/<package>.uifont?<name> URL asks for, or nil. Any thread.
NSData *AKWHFontForURL(NSURL *url) {
  NSString *package = url.path.lastPathComponent;
  NSString *name = url.query.stringByRemovingPercentEncoding;
  if (!package.length || [package hasPrefix:@"."] || !name.length) return nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ gFonts = [NSCache new]; });
  NSString *cacheKey = [NSString stringWithFormat:@"%@?%@", package.lowercaseString, name.lowercaseString];
  NSData *font = [gFonts objectForKey:cacheKey];
  if (font) return font;

  @synchronized(gFonts) {
    if ((font = [gFonts objectForKey:cacheKey])) return font;
    NSString *dir;
    @synchronized(pathsLock()) { dir = gClientUI; }
    if (!dir.length) return nil;
    NSArray<NSData *> *entries = packageEntries([[dir stringByAppendingPathComponent:@"fonts"] stringByAppendingPathComponent:package]);
    if (!entries.count) return nil;
    static BOOL searched;
    if (!searched) {
      searched = YES;
      gKey = findKey(entries.firstObject);
    }
    if (!gKey) return nil;
    NSString *wanted = [name stringByAppendingString:@"."];
    for (NSData *entry in entries) {
      NSData *plain = decryptEntry(gKey, entry);
      __block NSString *file;
      __block NSData *data;
      if (plain) eachField(plain, ^(uint32_t number, NSData *bytes, uint64_t value) {
        if (number == 1 && bytes) file = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
        if (number == 2 && bytes) data = bytes;
      });
      if (!file || !data) continue;
      if ([file rangeOfString:wanted options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
      [gFonts setObject:data forKey:cacheKey cost:data.length];
      return data;
    }
    AKWHLog(NO, @"fonts: %@ has no font named %@", package, name);
    return nil;
  }
}
