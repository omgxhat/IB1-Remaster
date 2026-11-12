#!/bin/zsh
# build.sh <variant name> [extra clang flags...]   (IBFIX_SRC="ibfix.m capture.m" picks the sources)
# Makes build-<variant>/SwordGame.app: the Community Patch app, arm64 only, with ibfix.dylib
# loaded at start, plus any Info.plist changes listed in tools/plist-<variant>.txt (PlistBuddy commands),
# plus our replacement game files from assets/.
# Two sessions, one folder (kit RULES.md, "Two sessions in one project"; FIXES.md 93, 5 November 2026):
#   IBFIX_TASK=<task> builds into build-<task>.noindex (and stage-<task>) instead, while the variant still picks
#   tools/plist-<variant>.txt; a build from a task's worktree (tools/task.sh start <task>) does so by itself. A build
#   refuses to start while another is writing the same folder (its lock, tools/buildfolder.zsh). In the main folder it
#   stops while ibfix/ has changes that aren't committed (code is changed in a task's worktree). BUILT-FROM.txt in the
#   build folder says which commit the add-on's code came from.
set -euo pipefail
W=${0:A:h:h}; V=$1; shift
source $W/tools/buildfolder.zsh
TASK=$(ibfix_task $W); [[ -z $TASK ]] || ibfix_task_ok $W $TASK
SRC=$W/cp25/Payload/SwordGame.app; SD=$(ibfix_stagedir $W $V); STAGE=$SD/SwordGame.app; OUT=$(ibfix_outdir $W $V)
ibfix_code $W "${IBFIX_SRCDIR:-}" $V   # checked first, so a build it stops touches no folder
# the real app's code passes the lean check as a whole (FIXES.md 107; each commit's change is checked by tools/git/pre-commit)
if [[ $V == final && -z ${IBFIX_SRCDIR:-} ]]; then
  python3 $W/tools/leancheck.py --all $W/ibfix || { print -u2 "STOP: the code isn't lean (each problem above): tidy it in a task's worktree, then build again"; exit 1; }
fi
buildlock_take $OUT "${TASK:+task $TASK, }variant $V"; trap buildlock_release EXIT; trap 'exit 130' INT TERM HUP
print "build folder: ${OUT#$W/}${TASK:+ (task $TASK)}"; print "code: $IBFIX_CODE"
rm -f $OUT/BUILT-FROM.txt
rm -rf $SD; mkdir -p $SD
cp -cR $SRC $STAGE
# Our replacement game files (assets/, e.g. the HD start-up film Default.m4v, FIXES.md 23) go over the
# game's own, so cp25/ itself is never edited.
if [[ -d $W/assets ]]; then for a in $W/assets/*(N); do cp -c "$a" $STAGE/ && print "replaced ${a:t}"; done; fi
# The iPad asks for IPad<name>.m4v first and falls back to <name>.m4v (FIXES.md 77): leave out the Community Patch's own
# IPadDefault.m4v (its credits card and logo) unless assets/ has one, so the iPad plays our Default.m4v, as the iPhone does.
[[ -f $W/assets/IPadDefault.m4v ]] || { rm -f $STAGE/IPadDefault.m4v && print "left out the Community Patch's IPadDefault.m4v"; }
# Changed game files inside the app's folders (assets-cooked/, laid out like the app: since release 9 the settings
# files CookedIPhone/Coalesced_*.bin with the graphics settings, FIXES.md 32): copied over the game's own, with their
# sizes put in the file tables (IPhoneTOC*.txt), in every build.
if [[ -d $W/assets-cooked ]]; then
  (cd $W/assets-cooked && find . -type f ! -name '.*' | sed 's|^\./||') | while IFS= read -r f; do
    cp -c "$W/assets-cooked/$f" "$STAGE/$f" && print "replaced $f"; python3 $W/tools/toc_update.py $STAGE "$f"; done
fi
# Files still being tried out (assets-test/; the HD and bump packs moved to assets/ in release 12) go into test builds only, never
# into the real app's build ("final"), until they are approved and move to assets/.
if [[ $V != final && -d $W/assets-test ]]; then for a in $W/assets-test/*(N); do cp -c "$a" $STAGE/ && print "added (test only) ${a:t}"; done; fi
# A test of changed game files (IBFIX_OVERLAY=<folder>, laid out like the app, e.g. CookedIPhone/Coalesced_INT.bin):
# copied over the app's own and their sizes put in the file tables. Test builds only.
if [[ $V != final && -n ${IBFIX_OVERLAY:-} ]]; then
  (cd $IBFIX_OVERLAY && find . -type f ! -name '.*' ! -name '*.txt' | sed 's|^\./||') | while IFS= read -r f; do
    cp -c "$IBFIX_OVERLAY/$f" "$STAGE/$f" && print "overlay (test only) $f"; python3 $W/tools/toc_update.py $STAGE "$f"; done
fi
# IBFIX_SRCDIR: the add-on's code from another folder, e.g. a release's own source/ to update that release with one fix
# and nothing else that has gone into ibfix/ since (3 November 2026, IB1 Remaster 1.3 with fix 91)
SRCS=(${=${IBFIX_SRC:-ibfix.m capture.m}}); SRCS=(${SRCS/#/${IBFIX_SRCDIR:-$W/ibfix}/})
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -dynamiclib -fobjc-arc -O2 "$@" \
  -framework Foundation -framework UIKit -framework AVFoundation -framework AudioToolbox -framework OpenAL \
  -framework OpenGLES -framework AVKit -framework CoreMedia -framework ImageIO -framework CoreGraphics -framework QuartzCore -framework CoreHaptics \
  -install_name @executable_path/ibfix.dylib -o $STAGE/ibfix.dylib $SRCS
lipo -thin arm64 $SRC/SwordGame -output $SD/SwordGame.thin
python3 $W/tools/insert_dylib.py $SD/SwordGame.thin $STAGE/SwordGame @executable_path/ibfix.dylib
chmod +x $STAGE/SwordGame
[[ -n ${IBFIX_SDK:-} ]] && python3 $W/tools/set_sdk.py $STAGE/SwordGame $IBFIX_SDK
# No list means the game's own Info.plist: letterboxed, with the status bar showing. Say so loudly, since a
# new variant name (a rebuild, a test) silently got no list before (reproducibility audit, 22 October 2026).
[[ -f $W/tools/plist-$V.txt ]] || print -u2 "WARNING: no tools/plist-$V.txt: Info.plist left as the game's own (copy plist-final.txt to use the release's)"
if [[ -f $W/tools/plist-$V.txt ]]; then
  while IFS= read -r c; do [[ -n $c && $c != \#* ]] && /usr/libexec/PlistBuddy -c "$c" $STAGE/Info.plist; done < $W/tools/plist-$V.txt
fi
$W/tools/sign.sh $STAGE $OUT ${IBFIX_BID:-com.example.ib1} "${IBFIX_NAME:-IB1 Test}"
print -l "built: $(date '+%d %B %Y at %H:%M:%S') by tools/build.sh $V${TASK:+ (task $TASK)}, in $W" \
  "app: ${IBFIX_BID:-com.example.ib1} \"${IBFIX_NAME:-IB1 Test}\"" "add-on parts: ${(j: :)${SRCS[@]:t}}${*:+ (flags: $*)}" \
  "code: $IBFIX_CODE" > $OUT/BUILT-FROM.txt
rm -rf $SD
