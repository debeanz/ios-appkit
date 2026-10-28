// Protobuf (proto2 wire format) for Steam's web-helper messages, schema-driven. See
// HTMLMessages.h.
#import "HTMLMessages.h"

#include "HTMLSchema.inc"

const AKHTMLCommandInfo *AKHTMLCommand(uint32_t command) {
  for (size_t i = 0; i < sizeof kAKHTMLCommands / sizeof kAKHTMLCommands[0]; i++)
    if (kAKHTMLCommands[i].command == command) return &kAKHTMLCommands[i];
  return NULL;
}

uint32_t AKHTMLCommandNamed(const char *name) {
  for (size_t i = 0; i < sizeof kAKHTMLCommands / sizeof kAKHTMLCommands[0]; i++)
    if (strcmp(kAKHTMLCommands[i].name, name) == 0) return kAKHTMLCommands[i].command;
  return 0;
}

int AKHTMLMessageNamed(const char *name) {
  for (int i = 0; i < AKPB_MESSAGE_COUNT; i++)
    if (strcmp(kAKPBMessages[i].name, name) == 0) return i;
  return -1;
}

const char *AKHTMLMessageName(int message) {
  return message >= 0 && message < AKPB_MESSAGE_COUNT ? kAKPBMessages[message].name : "?";
}

#pragma mark Decoding

typedef struct { const uint8_t *p, *end; bool bad; } Reader;

static uint64_t readVarint(Reader *r) {
  uint64_t v = 0;
  for (int shift = 0; shift < 64; shift += 7) {
    if (r->p >= r->end) { r->bad = true; return 0; }
    uint8_t c = *r->p++;
    v |= (uint64_t)(c & 0x7f) << shift;
    if (!(c & 0x80)) return v;
  }
  r->bad = true;
  return 0;
}

static uint64_t readFixed(Reader *r, int bytes) {
  if (r->end - r->p < bytes) { r->bad = true; return 0; }
  uint64_t v = 0;
  for (int i = 0; i < bytes; i++) v |= (uint64_t)r->p[i] << (8 * i);
  r->p += bytes;
  return v;
}

static const AKPBField *fieldNumbered(const AKPBMessage *m, uint32_t number) {
  for (uint16_t i = 0; i < m->count; i++)
    if (m->fields[i].number == number) return &m->fields[i];
  return NULL;
}

// A scalar of the field's type from its raw wire value.
static NSNumber *scalar(uint8_t type, uint64_t v) {
  switch (type) {
    case AKPB_DOUBLE: { double d; memcpy(&d, &v, 8); return @(d); }
    case AKPB_FLOAT: { uint32_t u = (uint32_t)v; float f; memcpy(&f, &u, 4); return @(f); }
    case AKPB_INT32: case AKPB_ENUM: case AKPB_SFIXED32: return @((int32_t)v);
    case AKPB_INT64: case AKPB_SFIXED64: return @((int64_t)v);
    case AKPB_UINT32: case AKPB_FIXED32: return @((uint32_t)v);
    case AKPB_SINT32: return @((int32_t)((v >> 1) ^ -(int64_t)(v & 1)));
    case AKPB_SINT64: return @((int64_t)((v >> 1) ^ -(int64_t)(v & 1)));
    case AKPB_BOOL: return @(v != 0);
    default: return @(v);   // uint64, fixed64
  }
}

static int wireTypeOf(uint8_t type) {
  switch (type) {
    case AKPB_DOUBLE: case AKPB_FIXED64: case AKPB_SFIXED64: return 1;
    case AKPB_FLOAT: case AKPB_FIXED32: case AKPB_SFIXED32: return 5;
    case AKPB_STRING: case AKPB_BYTES: case AKPB_MESSAGE: return 2;
    default: return 0;
  }
}

static void store(NSMutableDictionary *out, NSString *key, id value, bool repeated) {
  if (!repeated) { out[key] = value; return; }
  NSMutableArray *list = out[key];
  if (!list) out[key] = list = [NSMutableArray array];
  [list addObject:value];
}

static NSDictionary *decode(int message, const uint8_t *bytes, size_t length, int depth) {
  const AKPBMessage *m = (message >= 0 && message < AKPB_MESSAGE_COUNT) ? &kAKPBMessages[message] : NULL;
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  Reader r = { bytes, bytes + length, false };
  while (r.p < r.end && !r.bad) {
    uint64_t tag = readVarint(&r);
    uint32_t number = (uint32_t)(tag >> 3);
    int wire = (int)(tag & 7);
    const AKPBField *f = m ? fieldNumbered(m, number) : NULL;
    NSString *key = f ? @(f->name) : [NSString stringWithFormat:@"#%u", number];
    uint64_t v = 0;
    if (wire == 0) v = readVarint(&r);
    else if (wire == 1) v = readFixed(&r, 8);
    else if (wire == 5) v = readFixed(&r, 4);
    else if (wire == 2) {
      uint64_t n = readVarint(&r);
      if (r.bad || n > (uint64_t)(r.end - r.p)) { r.bad = true; break; }
      const uint8_t *body = r.p;
      r.p += n;
      if (!f) { store(out, key, [NSData dataWithBytes:body length:(NSUInteger)n], false); continue; }
      if (f->type == AKPB_MESSAGE) {
        if (depth < 32) store(out, key, decode(f->message, body, (size_t)n, depth + 1), f->repeated);
      } else if (f->type == AKPB_STRING) {
        NSString *s = [[NSString alloc] initWithBytes:body length:(NSUInteger)n encoding:NSUTF8StringEncoding];
        store(out, key, s ?: [NSData dataWithBytes:body length:(NSUInteger)n], f->repeated);
      } else if (f->type == AKPB_BYTES) {
        store(out, key, [NSData dataWithBytes:body length:(NSUInteger)n], f->repeated);
      } else {
        // A packed repeated scalar.
        Reader pr = { body, body + n, false };
        int inner = wireTypeOf(f->type);
        while (pr.p < pr.end && !pr.bad) {
          uint64_t pv = inner == 1 ? readFixed(&pr, 8) : inner == 5 ? readFixed(&pr, 4) : readVarint(&pr);
          if (!pr.bad) store(out, key, scalar(f->type, pv), true);
        }
      }
      continue;
    } else {
      r.bad = true;   // groups (3/4) aren't used by this protocol
      break;
    }
    if (r.bad) break;
    if (f && wireTypeOf(f->type) == wire) store(out, key, scalar(f->type, v), f->repeated);
    else store(out, key, @(v), false);
  }
  if (r.bad) out[@"#malformed"] = @YES;
  return out;
}

NSDictionary *AKHTMLDecode(int message, const uint8_t *bytes, size_t length) {
  return decode(message, bytes, length, 0);
}

#pragma mark Encoding

static void putVarint(NSMutableData *d, uint64_t v) {
  uint8_t buf[10];
  int n = 0;
  do {
    buf[n] = v & 0x7f;
    v >>= 7;
    if (v) buf[n] |= 0x80;
    n++;
  } while (v);
  [d appendBytes:buf length:n];
}

static void putFixed(NSMutableData *d, uint64_t v, int bytes) {
  uint8_t buf[8];
  for (int i = 0; i < bytes; i++) buf[i] = (uint8_t)(v >> (8 * i));
  [d appendBytes:buf length:bytes];
}

static NSData *encode(int message, NSDictionary *fields, int depth);

static void encodeOne(NSMutableData *d, const AKPBField *f, id value, int depth) {
  int wire = wireTypeOf(f->type);
  if (f->type == AKPB_MESSAGE && ![value isKindOfClass:NSDictionary.class]) return;
  if ((f->type == AKPB_STRING || f->type == AKPB_BYTES) && ![value isKindOfClass:NSString.class] && ![value isKindOfClass:NSData.class]) return;
  if (wire != 2 && ![value isKindOfClass:NSNumber.class]) return;
  putVarint(d, ((uint64_t)f->number << 3) | (uint64_t)wire);
  NSNumber *num = value;
  switch (f->type) {
    case AKPB_DOUBLE: { double x = num.doubleValue; uint64_t u; memcpy(&u, &x, 8); putFixed(d, u, 8); break; }
    case AKPB_FLOAT: { float x = num.floatValue; uint32_t u; memcpy(&u, &x, 4); putFixed(d, u, 4); break; }
    case AKPB_FIXED32: case AKPB_SFIXED32: putFixed(d, (uint32_t)num.unsignedIntValue, 4); break;
    case AKPB_FIXED64: case AKPB_SFIXED64: putFixed(d, num.unsignedLongLongValue, 8); break;
    case AKPB_INT32: case AKPB_ENUM: putVarint(d, (uint64_t)(int64_t)num.intValue); break;   // negative: 10 bytes
    case AKPB_INT64: putVarint(d, (uint64_t)num.longLongValue); break;
    case AKPB_UINT32: putVarint(d, num.unsignedIntValue); break;
    case AKPB_UINT64: putVarint(d, num.unsignedLongLongValue); break;
    case AKPB_SINT32: { int32_t x = num.intValue; putVarint(d, ((uint32_t)x << 1) ^ (uint32_t)(x >> 31)); break; }
    case AKPB_SINT64: { int64_t x = num.longLongValue; putVarint(d, ((uint64_t)x << 1) ^ (uint64_t)(x >> 63)); break; }
    case AKPB_BOOL: putVarint(d, num.boolValue ? 1 : 0); break;
    case AKPB_STRING: case AKPB_BYTES: {
      NSData *bytes = [value isKindOfClass:NSString.class] ? [(NSString *)value dataUsingEncoding:NSUTF8StringEncoding] : value;
      putVarint(d, bytes.length);
      [d appendData:bytes];
      break;
    }
    case AKPB_MESSAGE: {
      NSData *body = depth < 32 ? encode(f->message, value, depth + 1) : [NSData data];
      putVarint(d, body.length);
      [d appendData:body];
      break;
    }
  }
}

static NSData *encode(int message, NSDictionary *fields, int depth) {
  NSMutableData *d = [NSMutableData data];
  if (message < 0 || message >= AKPB_MESSAGE_COUNT) return d;
  const AKPBMessage *m = &kAKPBMessages[message];
  for (uint16_t i = 0; i < m->count; i++) {
    const AKPBField *f = &m->fields[i];
    id value = fields[@(f->name)];
    if (!value || value == NSNull.null) continue;
    if (f->repeated && [value isKindOfClass:NSArray.class]) {
      for (id item in (NSArray *)value) encodeOne(d, f, item, depth);
    } else {
      encodeOne(d, f, value, depth);
    }
  }
  return d;
}

NSData *AKHTMLEncode(int message, NSDictionary *fields) { return encode(message, fields, 0); }

#pragma mark Describing

static void describe(NSMutableString *out, id v, NSUInteger maxLength) {
  if (out.length > maxLength) return;
  if ([v isKindOfClass:NSDictionary.class]) {
    [out appendString:@"{"];
    NSArray *keys = [[(NSDictionary *)v allKeys] sortedArrayUsingSelector:@selector(compare:)];
    BOOL first = YES;
    for (NSString *k in keys) {
      if (out.length > maxLength) break;
      [out appendFormat:@"%@%@=", first ? @"" : @", ", k];
      describe(out, ((NSDictionary *)v)[k], maxLength);
      first = NO;
    }
    [out appendString:@"}"];
  } else if ([v isKindOfClass:NSArray.class]) {
    NSArray *a = v;
    [out appendString:@"["];
    for (NSUInteger i = 0; i < a.count && out.length <= maxLength; i++) {
      if (i) [out appendString:@", "];
      if (i == 12 && a.count > 13) { [out appendFormat:@"...+%lu", (unsigned long)(a.count - 12)]; break; }
      describe(out, a[i], maxLength);
    }
    [out appendString:@"]"];
  } else if ([v isKindOfClass:NSString.class]) {
    NSString *s = v;
    if (s.length > 240) s = [[s substringToIndex:240] stringByAppendingFormat:@"...(%lu chars)", (unsigned long)[v length]];
    s = [[s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    [out appendFormat:@"\"%@\"", s];
  } else if ([v isKindOfClass:NSData.class]) {
    [out appendFormat:@"<%lu bytes>", (unsigned long)[(NSData *)v length]];
  } else {
    [out appendFormat:@"%@", v];
  }
}

NSString *AKHTMLDescribe(id value, NSUInteger maxLength) {
  NSMutableString *out = [NSMutableString string];
  describe(out, value, maxLength);
  if (out.length > maxLength + 40) {
    [out deleteCharactersInRange:NSMakeRange(maxLength, out.length - maxLength)];
    [out appendString:@"..."];
  }
  return out;
}
