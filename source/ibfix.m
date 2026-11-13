// ibfix: the add-on's core, loaded into Infinity Blade 1 in every build (the owner's own copy, with Epic's permission).
// The sound fix: iOS never sends "interruption ended" after the start-up film, so the game's sound-pause counter sticks
// at 1; once the game is in front, its own listener is called with "ended" (FIXES.md 1). Also more mixer voices (31),
// the sound kept on through pauses and the film (18, 23, 76), and a summary of OpenAL use every 3 seconds.
// Every line starts with "IBFIX" so it can be filtered out of the device log.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <OpenAL/al.h>
#import <OpenAL/alc.h>
#import <OpenAL/oalMacOSX_OALExtensions.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <mach-o/dyld.h>
#import <string.h>
#include "ibfix.h"

// Addresses in Infinity Blade 1 v1.4.3 (7982.136), arm64 slice, before ASLR slide.
#define IB1_SUSPEND_COUNTER 0x100cd56e0ULL   // int, >0 = sound engine paused
#define IB1_INTERRUPT_LISTENER 0x1008f9ad8ULL // AudioSessionInterruptionListener(void *, UInt32)
// First 16 bytes of the listener, checked before calling it (stp/stp/add/sub prologue).
static const uint8_t kListenerPrologue[16] = {0xf4,0x4f,0xbe,0xa9, 0xfd,0x7b,0x01,0xa9, 0xfd,0x43,0x00,0x91, 0xff,0x43,0x00,0xd1};


// Log to the device log and to Documents/ibfix.log (copied to the Mac with devicectl, so no console is needed).
void ibfix_log(NSString *line) {
    NSLog(@"%@", line);
    static NSFileHandle *fh; static dispatch_queue_t q; static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("ibfix.log", DISPATCH_QUEUE_SERIAL);
        NSString *path = [DOCUMENTS stringByAppendingPathComponent:@"ibfix.log"];
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if (!a || [a fileSize] > 2000000) [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path]; [fh seekToEndReturningOffset:nil error:nil];
        df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *stamp = [df stringFromDate:[NSDate date]];
    dispatch_async(q, ^{
        NSData *d = [[NSString stringWithFormat:@"%@ %@\n", stamp, line] dataUsingEncoding:NSUTF8StringEncoding];
        // writeData: raises an Objective-C exception (uncaught on this queue: the game quits) when the disk is full or the
        // file has gone; writeData:error: reports it instead, and a log line that can't be written is simply dropped.
        if (fh) [fh writeData:d error:nil];
    });
}


static ALCcontext *gContext;          // the context the game created
static _Atomic int gPlays, gPlaysNoContext, gBuffers, gGainZero, gGainSet, gErrors;
static _Atomic int gMakeCurrentNull, gSuspends, gProcesses, gListenerUpdates, gStops, gPlaysRefused;
static float gLastGain = -1;

// ---- OpenAL --------------------------------------------------------------------

static ALCdevice *my_alcOpenDevice(const ALCchar *name) {
    ALCdevice *d = alcOpenDevice(name);
    LOG(@"alcOpenDevice(%s) -> %p", name ? name : "default", d);
    return d;
}

#define IBFIX_MIXER_VOICES 64       // the game's 32 sources and our probe, with room for voices still being freed
static ALCcontext *my_alcCreateContext(ALCdevice *dev, const ALCint *attrs) {
    // Apple's extension: the voice count applies to contexts created after it is set.
    alcMacOSXMixerMaxiumumBussesProcPtr setVoices = (alcMacOSXMixerMaxiumumBussesProcPtr)alcGetProcAddress(NULL, "alcMacOSXMixerMaxiumumBusses");
    alcMacOSXGetMixerMaxiumumBussesProcPtr getVoices = (alcMacOSXGetMixerMaxiumumBussesProcPtr)alcGetProcAddress(NULL, "alcMacOSXGetMixerMaxiumumBusses");
    ALint before = getVoices ? getVoices() : -1;
    if (setVoices && before > 0 && before < IBFIX_MIXER_VOICES) setVoices(IBFIX_MIXER_VOICES);
    ALCcontext *c = alcCreateContext(dev, attrs);
    gContext = c;
    LOG(@"alcCreateContext -> %p (error %d) | mixer voices %d -> %d", c, alcGetError(dev), before, getVoices ? getVoices() : -1);
    return c;
}

static volatile ALCboolean gLastMakeCurrentOK = 1;   // result of the last alcMakeContextCurrent(context)
static ALCboolean my_alcMakeContextCurrent(ALCcontext *c) {
    if (!c) gMakeCurrentNull++;
    ALCboolean r = alcMakeContextCurrent(c);
    if (c) gLastMakeCurrentOK = r;
    LOG(@"alcMakeContextCurrent(%p) -> %d   [thread %@]", c, r, [NSThread isMainThread] ? @"main" : @"other");
    return r;
}

static void my_alcSuspendContext(ALCcontext *c) {
    gSuspends++;
    LOG(@"alcSuspendContext(%p)", c);
    alcSuspendContext(c);
}

static void my_alcProcessContext(ALCcontext *c) {
    gProcesses++;
    LOG(@"alcProcessContext(%p)", c);
    alcProcessContext(c);
}

static _Atomic ALuint gLastSource;   // last source played: if OpenAL's output is dead, it never advances
static void my_alSourcePlay(ALuint s) {
    gPlays++; gLastSource = s;
    BOOL ctx = alcGetCurrentContext() != NULL;
    if (!ctx) gPlaysNoContext++;
    alSourcePlay(s);
    // A refused play leaves the source in its initial state (a played one is playing, or stopped at once if
    // it has nothing to play). Reading its state on a valid source leaves the error the game reads untouched.
    ALint st = 0;
    if (ctx) alGetSourcei(s, AL_SOURCE_STATE, &st);
    if (st == AL_INITIAL) { int n = ++gPlaysRefused; if (n <= 5 || n % 50 == 0) LOG(@"sound refused: no free mixer voice (source %u, #%d)", s, n); }
}

static void my_alListenerfv(ALenum p, const ALfloat *v) { gListenerUpdates++; alListenerfv(p, v); }
static void my_alSourceStop(ALuint s) { gStops++; alSourceStop(s); }

float ibfix_master_volume = 1;        // the Master Volume slider (game.m 7); scales every sound
// The Game Sound (My Music) slider while the player's own music plays, otherwise 1 (game.m 5c sets it on every switch).
float ibfix_with_music_volume = 1;
// Set by game.m 4j around the engine's update of a spoken line's sound (on that thread only): the line's lift times the
// Voice Volume slider, kept to 0.89 or under (the recordings peak at full scale: -1 dB); < 0 for any other sound.
_Thread_local float ibfix_speech_gain = -1;
// Set by game.m 5d around the engine's update of any other sound: less than 1 while skip is held.
_Thread_local float ibfix_effects_gain = 1;
static void my_alSourcef(ALuint s, ALenum p, ALfloat v) {
    if (p == AL_GAIN) {
        gGainSet++; if (v <= 0.0001f) gGainZero++; gLastGain = v;
        if (ibfix_speech_gain >= 0) v = fminf(v * ibfix_speech_gain, fmaxf(v, 0.89f));
        else v *= ibfix_effects_gain;
        v *= ibfix_master_volume * ibfix_with_music_volume;
    }
    alSourcef(s, p, v);
}

static void my_alBufferData(ALuint b, ALenum fmt, const ALvoid *data, ALsizei size, ALsizei freq) {
    int n = ++gBuffers;
    if (n <= 5 || n % 50 == 0)
        LOG(@"alBufferData #%d fmt=0x%x size=%d freq=%d data=%p", n, fmt, size, freq, data);
    alBufferData(b, fmt, data, size, freq);
}

static ALenum my_alGetError(void) {
    ALenum e = alGetError();
    if (e != AL_NO_ERROR) { int n = ++gErrors; if (n <= 10 || n % 100 == 0) LOG(@"alGetError -> 0x%x (#%d)", e, n); }
    return e;
}

// ---- C AudioSession API (deprecated since iOS 7) -------------------------------

// The game's interruption listener, wrapped so a late "interruption ended" from iOS, after our watchdog has ended the
// interruption itself, can't take the sound-pause counter below zero (FIXES.md 44). Registered before findGameCode runs.
static volatile int *gSuspendCounter;
static AudioSessionInterruptionListener gGameListener;
static void my_listener(void *ud, UInt32 state) {
    gGameListener(ud, state);
    if (state == kAudioSessionEndInterruption && gSuspendCounter && *gSuspendCounter < 0) {
        __atomic_store_n((int *)gSuspendCounter, 0, __ATOMIC_SEQ_CST);
        LOG(@"interruption ended twice: sound pause counter put back to 0");
    }
}
static OSStatus my_AudioSessionInitialize(CFRunLoopRef rl, CFStringRef mode, AudioSessionInterruptionListener l, void *ud) {
    gGameListener = l;
    OSStatus r = AudioSessionInitialize(rl, mode, l ? my_listener : NULL, ud);
    LOG(@"AudioSessionInitialize(listener=%p, wrapped) -> %d", l, (int)r);
    return r;
}

INTERPOSE(interposers) = {
    { (const void *)my_alcOpenDevice,         (const void *)alcOpenDevice },
    { (const void *)my_alcCreateContext,      (const void *)alcCreateContext },
    { (const void *)my_alcMakeContextCurrent, (const void *)alcMakeContextCurrent },
    { (const void *)my_alcSuspendContext,     (const void *)alcSuspendContext },
    { (const void *)my_alcProcessContext,     (const void *)alcProcessContext },
    { (const void *)my_alSourcePlay,          (const void *)alSourcePlay },
    { (const void *)my_alSourcef,             (const void *)alSourcef },
    { (const void *)my_alListenerfv,          (const void *)alListenerfv },
    { (const void *)my_alSourceStop,          (const void *)alSourceStop },
    { (const void *)my_alBufferData,          (const void *)alBufferData },
    { (const void *)my_alGetError,            (const void *)alGetError },
    { (const void *)my_AudioSessionInitialize,(const void *)AudioSessionInitialize },
};

// ---- AVAudioSession (Objective-C, swapped in at load) --------------------------

static IMP origSetActive, origSetCategory, origSetDelegate;

// During the game's applicationWillResignActive: its switch of the audio session off is skipped: current iOS stops
// running audio then and OpenAL doesn't reliably restart (FIXES.md 8, 18). Its switch to the mixing Ambient goes
// through, so the player's own music can start while the game is away (FIXES.md 76).
static BOOL gInResign, gNoPauseFix;
// While the start-up film is on screen (the game's MoviePlayer exists; HideSplashScreen clears it at Start), the game's
// session is left alone both ways: today the film has a session of its own, and either switch pauses it (FIXES.md 23).
// Afterwards the sound fix below switches it on.
static BOOL filmOnScreen(void) {
    id del = [UIApplication sharedApplication].delegate;
    SEL s = NSSelectorFromString(@"MoviePlayer");
    return [del respondsToSelector:s] && ((id (*)(id, SEL))objc_msgSend)(del, s) != nil;
}
static BOOL my_setActive(id self, SEL _cmd, BOOL active, NSError **err) {
    if (!active && gInResign && !gNoPauseFix) { LOG(@"AVAudioSession setActive:0 skipped (a pause keeps the sound on)"); return YES; }
    if (!gNoPauseFix && filmOnScreen()) { LOG(@"AVAudioSession setActive:%d left for later (the start-up film is playing)", active); return YES; }
    BOOL r = ((BOOL (*)(id, SEL, BOOL, NSError **))origSetActive)(self, _cmd, active, err);
    LOG(@"AVAudioSession setActive:%d -> %d %@", active, r, err && *err ? (*err).localizedDescription : @"");
    return r;
}
static NSString *gCategoryAfterFilm;      // the game's own category, put back once the film has gone
static BOOL my_setCategory(id self, SEL _cmd, NSString *cat, NSError **err) {
    if (!gNoPauseFix && filmOnScreen() && ![cat isEqualToString:AVAudioSessionCategoryAmbient]) {
        gCategoryAfterFilm = cat;              // mixing mode until the film has gone
        LOG(@"AVAudioSession setCategory:%@ left for later (the start-up film is playing)", cat);
        return YES;
    }
    BOOL r = ((BOOL (*)(id, SEL, NSString *, NSError **))origSetCategory)(self, _cmd, cat, err);
    LOG(@"AVAudioSession setCategory:%@ -> %d", cat, r);
    return r;
}
// Called by game.m when the start-up film appears: the game set its non-mixing SoloAmbient just before,
// so anything that switches its audio on (OpenAL opening its device, a sound) would interrupt the film.
void ibfix_film_appeared(void) {
    AVAudioSession *a = [AVAudioSession sharedInstance];
    if (gNoPauseFix || gCategoryAfterFilm || [a.category isEqualToString:AVAudioSessionCategoryAmbient]) return;
    gCategoryAfterFilm = a.category;
    BOOL r = ((BOOL (*)(id, SEL, NSString *, NSError **))origSetCategory)(a, @selector(setCategory:error:), AVAudioSessionCategoryAmbient, nil);
    LOG(@"audio: mixing mode (Ambient) while the start-up film plays, %@ afterwards -> %d", gCategoryAfterFilm, r);
}
static void restoreCategoryAfterFilm(void) {
    if (!gCategoryAfterFilm || filmOnScreen()) return;
    AVAudioSession *a = [AVAudioSession sharedInstance];
    BOOL r = ((BOOL (*)(id, SEL, NSString *, NSError **))origSetCategory)(a, @selector(setCategory:error:), gCategoryAfterFilm, nil);
    LOG(@"audio: the film has gone, back to %@ -> %d", gCategoryAfterFilm, r);
    gCategoryAfterFilm = nil;
}
static void my_setDelegate(id self, SEL _cmd, id delegate) {
    LOG(@"AVAudioSession setDelegate:%@", delegate);
    ((void (*)(id, SEL, id))origSetDelegate)(self, _cmd, delegate);
}

// ---- The sound fix ---------------------------------------------------------------

static void (*gListener)(void *, UInt32);
static _Atomic int gResumes;
// The game's own sound-engine pause and resume (see "Coming back from a pause").
#define IB1_SOUND_PAUSE  0x1008da0b4ULL
#define IB1_SOUND_RESUME 0x1008da078ULL
static const uint8_t kPausePrologue[8]  = {0xfd,0x7b,0xbf,0xa9, 0xfd,0x03,0x00,0x91};
static const uint8_t kResumePrologue[8] = {0xf4,0x4f,0xbe,0xa9, 0xfd,0x7b,0x01,0xa9};
static void (*gSoundPause)(void), (*gSoundResume)(void);

static BOOL findGameCode(void) {
    const char *name = _dyld_get_image_name(0);
    if (!name || !strstr(name, "/SwordGame")) { LOG(@"fix OFF: image 0 is %s", name); return NO; }
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const void *listener = (const void *)(IB1_INTERRUPT_LISTENER + slide);
    if (memcmp(listener, kListenerPrologue, sizeof kListenerPrologue) != 0) {
        LOG(@"fix OFF: the interruption listener isn't where expected (different game build?)");
        return NO;
    }
    gSuspendCounter = (volatile int *)(IB1_SUSPEND_COUNTER + slide);
    gListener = (void (*)(void *, UInt32))listener;
    const void *pause = (const void *)(IB1_SOUND_PAUSE + slide), *resume = (const void *)(IB1_SOUND_RESUME + slide);
    if (memcmp(pause, kPausePrologue, 8) == 0 && memcmp(resume, kResumePrologue, 8) == 0) {
        gSoundPause = (void (*)(void))pause; gSoundResume = (void (*)(void))resume;
    } else LOG(@"pause fix OFF: the game's sound pause/resume aren't where expected");
    LOG(@"fix ON: slide 0x%lx, counter now %d", (long)slide, *gSuspendCounter);
    return YES;
}

// YES while the game's own start-up/story film is on screen (it owns the audio then).
static BOOL filmPlaying(void) {
    id del = [UIApplication sharedApplication].delegate;
    SEL movieSel = NSSelectorFromString(@"MoviePlayer"), stateSel = NSSelectorFromString(@"playbackState");
    if (![del respondsToSelector:movieSel]) return NO;
    id mp = ((id (*)(id, SEL))objc_msgSend)(del, movieSel);
    if (!mp) return NO;
    if ([mp respondsToSelector:stateSel])
        return ((NSInteger (*)(id, SEL))objc_msgSend)(mp, stateSel) == 1; // MPMoviePlaybackStatePlaying
    return YES;
}

void ibfix_follow_other_audio(NSString *why);   // game.m 5b
static void unstickIfNeeded(NSString *why) {
    restoreCategoryAfterFilm();
    if (!gSuspendCounter || *gSuspendCounter <= 0) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    if (filmOnScreen()) return;                       // the film plays with its own audio session
    // Only when iOS will give the audio back: during a call (the game can still be in front) activation fails.
    NSError *err = nil;
    if (![[AVAudioSession sharedInstance] setActive:YES error:&err]) {
        static CFAbsoluteTime lastNote;
        if (CFAbsoluteTimeGetCurrent() - lastNote > 10) { lastNote = CFAbsoluteTimeGetCurrent(); LOG(@"waiting: audio not available yet (%@)", err.localizedDescription); }
        return;
    }
    int before = *gSuspendCounter;
    gListener(NULL, kAudioSessionEndInterruption);   // the game's own "interruption ended" path
    gResumes++;
    LOG(@"RESUMED sound (%@): counter %d -> %d", why, before, *gSuspendCounter);
}

// ---- Coming back from a pause --------------------------------------------------------
// The game's delegate switches the audio session off as it stops being active; on current iOS that stops OpenAL and the
// music player for good (FIXES.md 8, 18). That switch-off is now skipped (my_setActive, above); the restart here is
// the fallback for when the output stops anyway. It uses the game's own sound pause (0x1008da0b4: counter + 1, no
// current context, suspend), then its resume (0x1008da078: context current, process, counter - 1).

static BOOL gWasInactive;
// gNoPauseFix (declared above): test builds, "nopausefix" in Documents/ibfix-settings.txt, to compare
static IMP origWillResign, origDidBecomeActive;

// Restart OpenAL's output with the game's own pause + resume. Right after the session comes back,
// alcMakeContextCurrent can be refused, so a refusal is retried every 0.3 s for up to 3 s.
static void restartEffects(NSString *why, int attempt) {
    if (!gSoundPause || !gSoundResume || !gContext) return;
    if (*gSuspendCounter > 0) return;                     // the game has paused its sound on purpose
    int before = *gSuspendCounter;
    gSoundPause(); gSoundResume();
    BOOL ok = gLastMakeCurrentOK;
    LOG(@"RESTARTED sound effects (%@, try %d): counter %d -> %d, context %@", why, attempt + 1, before, *gSuspendCounter, ok ? @"ok" : @"REFUSED");
    if (!ok && attempt < 10)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 3 / 10), dispatch_get_main_queue(), ^{ restartEffects(why, attempt + 1); });
}


static void checkAfterReturn(void);
static void my_willResign(id self, SEL _cmd, id app) {
    gWasInactive = YES;
    gInResign = YES;
    ((void (*)(id, SEL, id))origWillResign)(self, _cmd, app);
    gInResign = NO;
}
void ibfix_game_music_back(NSString *why);   // game.m 5b
void ibfix_with_music_refresh(void);         // game.m 5c
void ibfix_music_after_background(void);     // game.m 5b
static void my_didBecomeActive(id self, SEL _cmd, id app) {
    SEL bg = NSSelectorFromString(@"bUsingBackgroundMusic");
    BOOL hadOwn = [self respondsToSelector:bg] && ((BOOL (*)(id, SEL))objc_msgSend)(self, bg);
    ((void (*)(id, SEL, id))origDidBecomeActive)(self, _cmd, app);
    // the devs' switch back from the player's music plays the track the game noted; when it noted none, its record
    if (hadOwn && !((BOOL (*)(id, SEL))objc_msgSend)(self, bg)) ibfix_game_music_back(@"back to the front");
    ibfix_with_music_refresh();                                        // the game's sound under the player's music, or not
    ibfix_music_after_background();                                    // the game's music again, if it was paused for the trip
    if (!gWasInactive) return;
    gWasInactive = NO;
    if (gNoPauseFix) { LOG(@"pause fix skipped (test setting)"); return; }
    checkAfterReturn();
}

// ---- Effects output watchdog -------------------------------------------------------
// A safety net for every way OpenAL's output can stop (a pause, Siri, a call, a route change): a looping, inaudible
// source of our own whose position moves on only while the output runs, checked once a second (FIXES.md 18).
static ALuint gProbeSrc;
static void watchOutput(void) {
    if (!gContext || alcGetCurrentContext() != gContext) return;
    if (filmOnScreen()) return;                // its silent test sound would switch the audio on and interrupt the film
    // Not before the game's first sound: UALAudioDevice::Init (0x1008da0e4) gives up on sound if it finds an OpenAL
    // error waiting, and the iPad, with no start-up film, could make the probe while it runs (FIXES.md 44).
    if (!gProbeSrc && gPlays == 0) return;
    if (!gProbeSrc) {
        static int16_t silence[4410]; ALuint buf = 0;
        alGenBuffers(1, &buf); alBufferData(buf, AL_FORMAT_MONO16, silence, sizeof silence, 44100);
        alGenSources(1, &gProbeSrc); alSourcei(gProbeSrc, AL_BUFFER, (ALint)buf);
        alSourcei(gProbeSrc, AL_LOOPING, AL_TRUE); alSourcef(gProbeSrc, AL_GAIN, 0.0001f); alSourcePlay(gProbeSrc);
        ALenum e = alGetError();
        LOG(@"output watchdog: probe source %u%@", gProbeSrc, e ? [NSString stringWithFormat:@" (error %#x)", e] : @"");
        return;
    }
    if (!alIsSource(gProbeSrc)) return;
    static ALint last = -1; static int still; static CFAbsoluteTime lastRestart;
    ALint pos = 0, st = 0;
    alGetSourcei(gProbeSrc, AL_SAMPLE_OFFSET, &pos); alGetSourcei(gProbeSrc, AL_SOURCE_STATE, &st);
    if (st != AL_PLAYING) { alSourcePlay(gProbeSrc); last = -1; return; }
    BOOL moving = pos != last; last = pos;
#ifdef IBFIX_TEST_TOOLS
    LOG(@"output probe: %@ (offset %d)", moving ? @"running" : @"STOPPED", pos);
#endif
    if (moving) { still = 0; return; }
    if (++still < 2) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive || filmOnScreen()) return;
    if (!gSuspendCounter || *gSuspendCounter > 0) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastRestart < 3) return;
    lastRestart = now; still = 0;
    LOG(@"output watchdog: effects output stopped, restarting it");
    restartEffects(@"output stopped", 0);
}

// Back from a pause or a trip to the background: the session normally stayed on, so nothing is
// restarted unless it has to be. 0.4 s later: if our probe source hasn't moved, restart the effects
// output; if the music says it's playing but hasn't moved, nudge it (pause + play).
static void checkAfterReturn(void) {
    ALint pos0 = -1;
    if (gProbeSrc && alcGetCurrentContext() == gContext && alIsSource(gProbeSrc)) alGetSourcei(gProbeSrc, AL_SAMPLE_OFFSET, &pos0);
    id del = [UIApplication sharedApplication].delegate;
    SEL mpSel = NSSelectorFromString(@"MusicPlayer");
    AVAudioPlayer *p = [del respondsToSelector:mpSel] ? ((id (*)(id, SEL))objc_msgSend)(del, mpSel) : nil;
    NSTimeInterval t0 = [p isKindOfClass:[AVAudioPlayer class]] ? p.currentTime : -1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 4 / 10), dispatch_get_main_queue(), ^{
        ALint pos1 = -1;
        if (gProbeSrc && alcGetCurrentContext() == gContext && alIsSource(gProbeSrc)) alGetSourcei(gProbeSrc, AL_SAMPLE_OFFSET, &pos1);
        BOOL effectsOK = pos0 < 0 || pos1 != pos0;
        if (!effectsOK) restartEffects(@"back from a pause, output stopped", 0);
        AVAudioPlayer *q = [del respondsToSelector:mpSel] ? ((id (*)(id, SEL))objc_msgSend)(del, mpSel) : nil;
        BOOL musicStuck = q == p && [q isKindOfClass:[AVAudioPlayer class]] && q.playing && fabs(q.currentTime - t0) < 0.05;
        if (musicStuck) { [q pause]; [q play]; LOG(@"RESTARTED music (back from a pause): %@ at %.1f s", q.url.lastPathComponent, q.currentTime); }
        LOG(@"back from a pause: effects %@, music %@", effectsOK ? @"running" : @"restarted", musicStuck ? @"restarted" : @"fine");
    });
}

// ---- Screen-fit support ------------------------------------------------------------
// With the SDK field raised (so iOS gives the game the full screen), iOS enforces that UIKit
// is used from the main thread. The game toggles the idle timer ("DisableSleep") from its
// game thread, which then aborts. Hop such calls onto the main thread.

static IMP origSetIdleTimerDisabled;
static void my_setIdleTimerDisabled(id self, SEL _cmd, BOOL disabled) {
    if ([NSThread isMainThread]) { ((void (*)(id, SEL, BOOL))origSetIdleTimerDisabled)(self, _cmd, disabled); return; }
    dispatch_async(dispatch_get_main_queue(), ^{ ((void (*)(id, SEL, BOOL))origSetIdleTimerDisabled)(self, _cmd, disabled); });
}

// A method c only inherits is overridden on c alone (added to c, calling the inherited one), never changed in the
// superclass that every other class shares (FIXES.md 35).
static void swap(Class c, SEL s, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) { LOG(@"no method %@", NSStringFromSelector(s)); return; }
    IMP prev = method_getImplementation(m);
    *orig = class_addMethod(c, s, repl, method_getTypeEncoding(m)) ? prev : method_setImplementation(m, repl);
}

__attribute__((constructor)) static void ibfix_init(void) {
    LOG(@"loaded (sound fix + diagnosis)");
    Class c = [AVAudioSession class];
    swap(c, @selector(setActive:error:), (IMP)my_setActive, &origSetActive);
    swap(c, @selector(setCategory:error:), (IMP)my_setCategory, &origSetCategory);
    swap(c, NSSelectorFromString(@"setDelegate:"), (IMP)my_setDelegate, &origSetDelegate);
    swap([UIApplication class], @selector(setIdleTimerDisabled:), (IMP)my_setIdleTimerDisabled, &origSetIdleTimerDisabled);
#ifdef IBFIX_TEST_TOOLS
    NSString *docs = DOCUMENTS;
    gNoPauseFix = [[NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"ibfix-settings.txt"]
                                             encoding:NSUTF8StringEncoding error:nil] containsString:@"nopausefix"];
#endif
    Class appDel = NSClassFromString(@"IPhoneAppDelegate");
    swap(appDel, @selector(applicationWillResignActive:), (IMP)my_willResign, &origWillResign);
    swap(appDel, @selector(applicationDidBecomeActive:), (IMP)my_didBecomeActive, &origDidBecomeActive);

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        LOG(@"interruption %@ (session %p)", [n.userInfo[AVAudioSessionInterruptionTypeKey] integerValue] == AVAudioSessionInterruptionTypeBegan ? @"BEGAN" : @"ENDED", n.object);
    }];
    for (NSString *name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification]) {
        [nc addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) { LOG(@"%@", n.name); }];
    }

    BOOL fixOn = findGameCode();

    // Watchdog on the main thread: once a second, un-stick the sound if it's stuck.
    if (fixOn) {
        dispatch_source_t w = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(w, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(w, ^{ ibfix_follow_other_audio(@"each second"); unstickIfNeeded(@"watchdog"); watchOutput(); });   // your music first (game.m 5b)
        dispatch_resume(w);
        static dispatch_source_t keepW; keepW = w;
    }

    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(t, ^{
        LOG(@"summary: listener updates=%d stops=%d plays=%d (no context: %d, refused: %d) buffers=%d gains=%d (zero %d, last %.2f) ALerr=%d | suspends=%d processes=%d resumes-by-fix=%d counter=%d film=%d | ctx %p cur %p | %@",
            gListenerUpdates, gStops, gPlays, gPlaysNoContext, gPlaysRefused, gBuffers, gGainSet, gGainZero, gLastGain, gErrors,
            gSuspends, gProcesses, gResumes, gSuspendCounter ? *gSuspendCounter : -99, filmPlaying(),
            gContext, alcGetCurrentContext(), [AVAudioSession sharedInstance].category);
        // Is OpenAL really producing sound? A playing source's position moves on only while its
        // output runs. (alIsSource first, so the probe never leaves an error for the game to read.)
        ALuint src = gLastSource;
        if (src && alcGetCurrentContext() && alIsSource(src)) {
            ALint state = 0; ALfloat off1 = 0; alGetSourcei(src, AL_SOURCE_STATE, &state); alGetSourcef(src, AL_SEC_OFFSET, &off1);
            if (state == AL_PLAYING) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
                ALint st2 = 0; ALfloat off2 = 0;
                if (!alIsSource(src)) return;
                alGetSourcei(src, AL_SOURCE_STATE, &st2); alGetSourcef(src, AL_SEC_OFFSET, &off2);
                LOG(@"sfx probe: source %u %.2f s -> %.2f s %@", src, off1, off2,
                    st2 != AL_PLAYING ? @"(finished: output running)" : off2 != off1 ? @"(moving: output running)" : @"(STUCK: no output)");
            });
        }
    });
    dispatch_resume(t);
    static dispatch_source_t keep; keep = t;
}
