// MagicSwipe: menu bar app that watches the Magic Mouse surface for a two-finger
// horizontal swipe and, when the pointer is on the iPad (Universal Control has
// taken the mouse away from this Mac), asks magicswipe-keyd to press Globe+arrow.
//
// The app runs only while MagicSwipe is on: magicswipe-toggle (run from a
// Control Center shortcut) starts it, and turning it off quits it. Quitting
// disconnects from magicswipe-keyd, which then exits along with Karabiner's
// VirtualHIDDevice daemon, so nothing of MagicSwipe's stays running.
// "Enabled" in its defaults remembers the state; at login it quits at once if off.
//
// Usage:
//   MagicSwipe            run as a menu bar app
//   MagicSwipe --probe    log what would be sent instead of sending it

#import <AppKit/AppKit.h>
#include <notify.h>
#include <sys/socket.h>
#include <sys/un.h>

#pragma mark - MultitouchSupport (private framework)

typedef struct {
  float x, y;
} MTPoint;

typedef struct {
  MTPoint position;
  MTPoint velocity;
} MTVector;

typedef struct {
  int frame;
  double timestamp;
  int identifier;
  int state; // 4 = make touch, 5 = touching
  int fingerID;
  int handID;
  MTVector normalized; // 0..1 across the sensor surface
  float size;
  int unused1;
  float angle;
  float majorAxis;
  float minorAxis;
  MTVector absolute;
  int unused2[2];
  float density;
} MTTouch;

typedef void* MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch*, int, double, int);

extern CFMutableArrayRef MTDeviceCreateList(void);
extern void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallback);
extern void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallback);
extern void MTDeviceStart(MTDeviceRef, int);
extern void MTDeviceStop(MTDeviceRef);
extern int MTDeviceGetFamilyID(MTDeviceRef, int*);
extern int MTDeviceGetDeviceID(MTDeviceRef, uint64_t*);
extern bool MTDeviceIsRunning(MTDeviceRef);

#pragma mark - Tuning

// Distances are fractions of the Magic Mouse touch surface. The surface is short
// front-to-back, so upward swipes travel much less than sideways ones.
static const float kSideTravel = 0.10f; // left/right swipe
static const float kSideRatio = 1.5f;   // |dx| must exceed this times |dy|
static const float kUpTravel = 0.06f;   // upward or downward swipe
static const float kUpRatio = 1.0f;     // |dy| must exceed this times |dx| (fingers drift sideways)
static const double kMaxDuration = 0.8; // seconds from two fingers down to trigger

static const double kTapMaxDuration = 0.25; // a two-finger tap is a short contact...
static const float kTapMaxMove = 0.03f;     // ...that barely moves...
static const double kTapLiftWindow = 0.15;  // ...after which all fingers lift this soon
static const double kDoubleTapWindow = 0.45;

static NSString* const kEnabledKey = @"Enabled";
static NSString* const kReverseKey = @"ReverseDirection";

#pragma mark - State

static bool gProbe = false;
static _Atomic bool gReverse = false;
static NSSet<NSNumber*>* gMouseFamilies; // multitouch family IDs that belong to a Magic Mouse

// Universal Control publishes where input currently goes under this notify(3) name:
// 0x2 = pointer is on another device, 0x1 = keyboard is on another device.
static _Atomic uint64_t gUCState = 0;
static const uint64_t kUCPointerRemote = 0x2;
static const uint64_t kUCKeyboardRemote = 0x1;

// Gesture tracking (touched only from the multitouch callback thread).
static bool gTracking = false;
static bool gFired = false;
static double gStartTime = 0;
static float gStartX = 0, gStartY = 0;
static float gLastX = 0, gLastY = 0;
static float gMaxMove = 0;
static double gTapCandidateEnd = 0; // a tap-like contact ended; confirmed once all fingers lift
static double gLastTap = 0;

#pragma mark - keyd connection

// All socket work happens on this queue so switching off can't race a send.
static dispatch_queue_t gKeydQueue;
static int gKeydSocket = -1;
static _Atomic bool gKeydConnected = false;

static bool keydConnect(void) {
  if (gKeydSocket >= 0) {
    return true;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un addr = {0};
  addr.sun_family = AF_UNIX;
  strlcpy(addr.sun_path, "/var/run/magicswipe.sock", sizeof(addr.sun_path));
  if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
    close(fd);
    gKeydConnected = false;
    return false;
  }
  gKeydSocket = fd;
  gKeydConnected = true;
  return true;
}

static void keydDisconnect(void) {
  if (gKeydSocket >= 0) {
    close(gKeydSocket);
    gKeydSocket = -1;
  }
  gKeydConnected = false;
}

static bool keydSend(char command) {
  for (int attempt = 0; attempt < 2; ++attempt) {
    if (!keydConnect()) {
      return false;
    }
    if (write(gKeydSocket, &command, 1) == 1) {
      return true;
    }
    keydDisconnect();
  }
  return false;
}

#pragma mark - Gesture recognition

static const char* commandName(char command) {
  switch (command) {
    case 'L': return "Globe+Left";
    case 'R': return "Globe+Right";
    case 'U': return "Globe+Up";
    default: return "Globe+H";
  }
}

// command: 'L' / 'R' (Globe+Left/Right, switch apps), 'U' (Globe+Up, App Switcher)
// or 'H' (Globe+H, Home Screen).
static void handleGesture(char command, const char* gesture) {
  uint64_t state = gUCState;
  // Pointer on this Mac: leave the gesture to macOS.
  if (!(state & kUCPointerRemote)) {
    if (gProbe) {
      NSLog(@"MagicSwipe: [probe] %s ignored (pointer is on the Mac)", gesture);
    }
    return;
  }

  // Universal Control types on the last-clicked device. Uppercase asks keyd to click
  // first so keyboard focus follows the pointer; lowercase when focus is already there.
  bool needFocus = !(state & kUCKeyboardRemote);
  char wire = needFocus ? command : (char)(command + ('a' - 'A'));

  if (gProbe) {
    NSLog(@"MagicSwipe: [probe] %s → would send %s%s", gesture, commandName(command),
          needFocus ? " (with focus click)" : "");
    return;
  }

  dispatch_async(gKeydQueue, ^{
    if (!keydSend(wire)) {
      NSLog(@"MagicSwipe: cannot reach magicswipe-keyd (is it installed?)");
    }
  });
}

static void noteTap(double timestamp) {
  if (gLastTap > 0 && timestamp - gLastTap <= kDoubleTapWindow) {
    gLastTap = 0;
    handleGesture('U', "two-finger double-tap");
  } else {
    gLastTap = timestamp;
  }
}

// Two-finger contact just ended (finger count left 2).
static void endTwoFingerContact(int fingers, double timestamp) {
  double duration = timestamp - gStartTime;
  if (gProbe) {
    NSLog(@"MagicSwipe: [probe] 2-finger contact ended (now %d fingers): start=(%.2f, %.2f) "
          @"dx=%+.2f dy=%+.2f %.0f ms %s",
          fingers, gStartX, gStartY, gLastX - gStartX, gLastY - gStartY, duration * 1000,
          gFired ? "FIRED" : "no trigger");
  }
  bool tapLike = !gFired && duration <= kTapMaxDuration && gMaxMove <= kTapMaxMove;
  gTracking = false;
  gFired = false;
  if (tapLike) {
    if (fingers == 0) {
      noteTap(timestamp);
    } else {
      gTapCandidateEnd = timestamp; // wait for the last finger to lift
    }
  }
}

static int contactCallback(MTDeviceRef device, MTTouch* touches, int count, double timestamp, int frame) {
  int family = 0;
  MTDeviceGetFamilyID(device, &family);
  if (![gMouseFamilies containsObject:@(family)]) {
    return 0;
  }

  int fingers = 0;
  float sumX = 0, sumY = 0;
  for (int i = 0; i < count; ++i) {
    if (touches[i].state == 4 || touches[i].state == 5) {
      ++fingers;
      sumX += touches[i].normalized.position.x;
      sumY += touches[i].normalized.position.y;
    }
  }

  // A tap counts only if both fingers come off, not if one stays resting on the mouse.
  if (gTapCandidateEnd > 0) {
    if (fingers == 0 && timestamp - gTapCandidateEnd <= kTapLiftWindow) {
      gTapCandidateEnd = 0;
      noteTap(timestamp);
    } else if (fingers >= 2 || timestamp - gTapCandidateEnd > kTapLiftWindow) {
      gTapCandidateEnd = 0;
    }
  }

  if (fingers != 2) {
    if (gTracking) {
      endTwoFingerContact(fingers, timestamp);
    }
    return 0;
  }

  float x = sumX / 2, y = sumY / 2;
  gLastX = x;
  gLastY = y;
  if (!gTracking) {
    gTracking = true;
    gFired = false;
    gStartTime = timestamp;
    gStartX = x;
    gStartY = y;
    gMaxMove = 0;
    return 0;
  }

  // Normalized y grows toward the top of the mouse, away from the wrist.
  float dx = x - gStartX, dy = y - gStartY;
  gMaxMove = fmaxf(gMaxMove, fmaxf(fabsf(dx), fabsf(dy)));

  if (gFired || timestamp - gStartTime > kMaxDuration) {
    return 0;
  }

  if (fabsf(dx) >= kSideTravel && fabsf(dx) > kSideRatio * fabsf(dy)) {
    gFired = true;
    gLastTap = 0;
    // Fingers moving right reveal the app to the left, like the trackpad gesture.
    handleGesture((dx > 0) != gReverse ? 'L' : 'R', "side swipe");
  } else if (dy >= kUpTravel && dy > kUpRatio * fabsf(dx)) {
    gFired = true;
    gLastTap = 0;
    handleGesture('U', "swipe up");
  } else if (-dy >= kUpTravel && -dy > kUpRatio * fabsf(dx)) {
    gFired = true;
    gLastTap = 0;
    handleGesture('H', "swipe down");
  }
  return 0;
}

#pragma mark - Universal Control state

static NSString* const kUCStateChanged = @"MagicSwipeUniversalControlStateChanged";

static void watchUniversalControlState(void) {
  NSString* name = [NSString stringWithFormat:@"user.uid.%d.com.apple.universalcontrol.inputstate", getuid()];
  static int token;
  notify_register_dispatch(name.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
    uint64_t state = 0;
    notify_get_state(t, &state);
    gUCState = state;
    if (gProbe) {
      NSLog(@"MagicSwipe: [probe] Universal Control input state = 0x%llx", state);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:kUCStateChanged object:nil];
  });
  uint64_t state = 0;
  notify_get_state(token, &state);
  gUCState = state;
}

#pragma mark - App

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic) NSStatusItem* statusItem;
@property(nonatomic) NSMenuItem* statusLine;
@property(nonatomic) NSMenuItem* reverseItem;
@property(nonatomic) NSMutableDictionary<NSNumber*, NSValue*>* devices; // device ID -> retained MTDeviceRef
@property(nonatomic) NSTimer* rescanTimer;
@property(nonatomic) BOOL running;
@property(nonatomic) dispatch_source_t termSource;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
  self.devices = [NSMutableDictionary dictionary];
  [NSUserDefaults.standardUserDefaults registerDefaults:@{kEnabledKey : @YES, kReverseKey : @NO}];
  gReverse = [NSUserDefaults.standardUserDefaults boolForKey:kReverseKey];

  // Started at login while switched off: nothing to do.
  if (!gProbe && ![NSUserDefaults.standardUserDefaults boolForKey:kEnabledKey]) {
    [NSApp terminate:nil];
    return;
  }

  // magicswipe-toggle quits the app with SIGTERM; shut down cleanly so keyd exits too.
  signal(SIGTERM, SIG_IGN);
  self.termSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(self.termSource, ^{
    [NSApp terminate:nil];
  });
  dispatch_resume(self.termSource);

  self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];

  NSMenu* menu = [[NSMenu alloc] init];
  menu.delegate = self;
  self.statusLine = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
  self.statusLine.enabled = NO;
  [menu addItem:NSMenuItem.separatorItem];
  self.reverseItem = [menu addItemWithTitle:@"Reverse Swipe Direction" action:@selector(toggleReverse:) keyEquivalent:@""];
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItemWithTitle:@"Turn Off MagicSwipe" action:@selector(turnOff:) keyEquivalent:@""];
  self.statusItem.menu = menu;

  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(universalControlStateChanged:)
                                             name:kUCStateChanged
                                           object:nil];
  [self start];
  [self refreshUI];
}

// Read Magic Mouse touches only while the pointer is on the iPad, so MagicSwipe
// does no work at all while you use the mouse on the Mac.
- (void)universalControlStateChanged:(NSNotification*)notification {
  [self updateTracking];
}

- (void)updateTracking {
  if (self.running && (gUCState & kUCPointerRemote)) {
    [self startDevices];
  } else {
    [self stopDevices];
  }
}

- (void)applicationWillTerminate:(NSNotification*)notification {
  [self stop];
}

#pragma mark Menu

- (void)turnOff:(id)sender {
  [NSUserDefaults.standardUserDefaults setBool:NO forKey:kEnabledKey];
  [NSApp terminate:nil];
}

- (void)toggleReverse:(id)sender {
  gReverse = !gReverse;
  [NSUserDefaults.standardUserDefaults setBool:gReverse forKey:kReverseKey];
  [self refreshUI];
}

- (void)menuWillOpen:(NSMenu*)menu {
  [self refreshUI];
}

- (void)refreshUI {
  self.reverseItem.state = gReverse ? NSControlStateValueOn : NSControlStateValueOff;

  NSString* status;
  if (!gKeydConnected) {
    status = @"Key sender not reachable — run install.sh";
  } else {
    if (!(gUCState & kUCPointerRemote)) {
      status = @"On — idle while the pointer is on the Mac";
    } else {
      status = self.devices.count ? @"On — two-finger gestures go to the iPad" : @"On — waiting for Magic Mouse";
    }
  }
  self.statusLine.title = status;

  NSImage* image = [NSImage imageWithSystemSymbolName:@"hand.draw.fill" accessibilityDescription:@"MagicSwipe"];
  image.template = YES;
  self.statusItem.button.image = image;
  self.statusItem.button.appearsDisabled = !self.running;
}

#pragma mark Start / stop

- (void)start {
  self.running = YES;
  // Connecting makes launchd start magicswipe-keyd, which warms up the virtual keyboard.
  dispatch_async(gKeydQueue, ^{
    keydConnect();
  });
  [self updateTracking];
  // Pick up the Magic Mouse again after it sleeps or reconnects, and reconnect to keyd if needed.
  self.rescanTimer = [NSTimer scheduledTimerWithTimeInterval:10
                                                     repeats:YES
                                                       block:^(NSTimer* timer) {
                                                         [self updateTracking];
                                                         dispatch_async(gKeydQueue, ^{
                                                           keydConnect();
                                                         });
                                                       }];
}

- (void)stop {
  self.running = NO;
  [self.rescanTimer invalidate];
  self.rescanTimer = nil;

  [self stopDevices];

  // Disconnecting lets magicswipe-keyd and the Karabiner daemon exit.
  dispatch_sync(gKeydQueue, ^{
    keydDisconnect();
  });
}

- (void)stopDevices {
  if (self.devices.count == 0) {
    return;
  }
  for (NSValue* value in self.devices.allValues) {
    MTDeviceRef device = value.pointerValue;
    MTUnregisterContactFrameCallback(device, contactCallback);
    MTDeviceStop(device);
    CFRelease(device);
  }
  [self.devices removeAllObjects];
  gTracking = false;
  gTapCandidateEnd = 0;
  gLastTap = 0;
  if (gProbe) {
    NSLog(@"MagicSwipe: [probe] touch tracking stopped (pointer on the Mac)");
  }
}

- (void)startDevices {
  CFArrayRef list = MTDeviceCreateList();
  for (CFIndex i = 0; i < CFArrayGetCount(list); ++i) {
    MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
    int family = 0;
    uint64_t deviceID = 0;
    MTDeviceGetFamilyID(device, &family);
    MTDeviceGetDeviceID(device, &deviceID);
    if (![gMouseFamilies containsObject:@(family)]) {
      continue;
    }

    MTDeviceRef existing = self.devices[@(deviceID)].pointerValue;
    if (existing && MTDeviceIsRunning(existing)) {
      continue;
    }
    if (existing) {
      MTUnregisterContactFrameCallback(existing, contactCallback);
      CFRelease(existing);
    }

    CFRetain(device);
    self.devices[@(deviceID)] = [NSValue valueWithPointer:device];
    MTRegisterContactFrameCallback(device, contactCallback);
    MTDeviceStart(device, 0);
    if (gProbe) {
      NSLog(@"MagicSwipe: [probe] touch tracking started for Magic Mouse %llx", deviceID);
    }
  }
  CFRelease(list);
}

@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    for (int i = 1; i < argc; ++i) {
      gProbe |= strcmp(argv[i], "--probe") == 0;
    }
    gMouseFamilies = [NSSet setWithArray:@[ @112, @113 ]];

    watchUniversalControlState();
    gKeydQueue = dispatch_queue_create("magicswipe.keyd", DISPATCH_QUEUE_SERIAL);
    signal(SIGPIPE, SIG_IGN);

    NSApplication* app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyAccessory;
    AppDelegate* delegate = [[AppDelegate alloc] init];
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
