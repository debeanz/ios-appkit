// Steam's web-helper protocol messages (htmlmessages.proto), decoded to and encoded from
// Foundation objects through the schema tools/gen-htmlschema.js generates (HTMLSchema.inc).
// A message is an NSDictionary keyed by field name: numbers and bools are NSNumbers, strings
// NSStrings, bytes NSData, nested messages NSDictionaries, repeated fields NSArrays. Fields
// the schema doesn't know decode under "#<field number>".
#import <Foundation/Foundation.h>

typedef enum {
  AKPB_DOUBLE, AKPB_FLOAT, AKPB_INT32, AKPB_INT64, AKPB_UINT32, AKPB_UINT64, AKPB_SINT32,
  AKPB_SINT64, AKPB_FIXED32, AKPB_FIXED64, AKPB_SFIXED32, AKPB_SFIXED64, AKPB_BOOL,
  AKPB_STRING, AKPB_BYTES, AKPB_ENUM, AKPB_MESSAGE,
} AKPBType;

typedef struct {
  uint32_t number;
  const char *name;
  uint8_t type;       // AKPBType
  uint8_t repeated;
  int16_t message;    // AKPB_MESSAGE: index of the nested message
} AKPBField;

typedef struct {
  const char *name;
  const AKPBField *fields;
  uint16_t count;
} AKPBMessage;

enum { AKHTML_TO_HELPER = 1, AKHTML_TO_CLIENT = 2 };

typedef struct {
  uint32_t command;   // eHTMLCommands value
  const char *name;
  int16_t message;    // -1: not known
  uint8_t to;         // AKHTML_TO_HELPER / AKHTML_TO_CLIENT
  uint8_t guessed;    // inferred from the enum's order, not seen in a dispatcher
} AKHTMLCommandInfo;

const AKHTMLCommandInfo *AKHTMLCommand(uint32_t command);   // NULL if unknown
uint32_t AKHTMLCommandNamed(const char *name);               // 0 if unknown
int AKHTMLMessageNamed(const char *name);                     // -1 if unknown
const char *AKHTMLMessageName(int message);

NSDictionary *AKHTMLDecode(int message, const uint8_t *bytes, size_t length);
NSData *AKHTMLEncode(int message, NSDictionary *fields);

// One line for the log, cut off near maxLength characters.
NSString *AKHTMLDescribe(id value, NSUInteger maxLength);
