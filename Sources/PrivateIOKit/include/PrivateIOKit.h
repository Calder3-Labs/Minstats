#pragma once
#include <CoreFoundation/CoreFoundation.h>

/*
 * Private IOHIDFamily event-system API, used to read Apple Silicon
 * temperature sensors without root. Typedef'd as CFTypeRef (they are
 * genuine CF objects at runtime) so Swift manages their lifetimes.
 */

typedef CFTypeRef IOHIDEventSystemClientRef;
typedef CFTypeRef IOHIDServiceClientRef;
typedef CFTypeRef IOHIDEventRef;

#pragma clang arc_cf_code_audited begin
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service,
                                          int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
#pragma clang arc_cf_code_audited end

#define kAppleVendorUsagePage 0xff00
#define kAppleVendorTemperatureUsage 5
#define kIOHIDEventTypeTemperature 15
#define kTemperatureEventField (15 << 16) /* IOHIDEventFieldBase(kIOHIDEventTypeTemperature) */
