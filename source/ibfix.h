// ibfix.h: what every file of the add-on shares. The log (ibfix.m writes it; every line starts "IBFIX", so it can be
// picked out of the device's log), an object's name (game.m), the Documents folder, the interpose table that swaps
// Apple's functions for ours, and swapping in our version of a method (FIXES.md 106).
#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // the game's 2010 APIs (OpenGL ES, the old audio session)

void ibfix_log(NSString *line);
#define LOG(fmt, ...) ibfix_log([NSString stringWithFormat:@"IBFIX " fmt, ##__VA_ARGS__])
NSString *ibfix_objname(const void *obj);
#define DOCUMENTS NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject   // the app's Documents folder
// dyld's interpose table: each pair swaps one of Apple's functions for ours throughout the app
typedef struct { const void *replacement, *replacee; } interpose_t;
#define INTERPOSE(table) __attribute__((used)) static const interpose_t table[] __attribute__((section("__DATA,__interpose")))

// Replace -sel on class c with repl and return what it was. A method c only inherits is overridden on c alone (added
// to c, calling the inherited one), never changed in the superclass that every other class shares (FIXES.md 35).
__attribute__((unused)) static IMP hookMethod(Class c, SEL s, IMP repl) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL; if (!m) return NULL;
    IMP prev = method_getImplementation(m);
    if (class_addMethod(c, s, repl, method_getTypeEncoding(m))) return prev;
    return method_setImplementation(m, repl);
}
