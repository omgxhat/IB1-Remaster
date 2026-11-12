# buildfolder.zsh: which folder a build goes into, the lock that keeps two builds out of one folder, and what code a
# build was made from (kit RULES.md, "Two sessions in one project", 5 November 2026; FIXES.md
# 93). Sourced by tools/build.sh, install-wait.sh, task.sh and trial.sh.
#
#   ibfix_task <work folder>               the task: IBFIX_TASK if set, else a task worktree's own name
#                                          (worktrees/<task>/, made by tools/task.sh), else none
#   ibfix_task_ok <work folder> <task>     fails, saying why, on a name that isn't safe or is a variant's own name
#   ibfix_outdir <work folder> <variant>   build-<task>.noindex with a task, else build-<variant> as before
#   ibfix_stagedir <work folder> <variant> stage-<task>, else stage-<variant>
#   buildlock_take <folder> <what>         takes <folder>/.building for this process, or stops (exit 4) naming the
#                                          build that holds it; clears a lock left by a build that is no longer running.
#                                          The caller then sets, in the script itself (zsh runs an EXIT trap set inside
#                                          a function when that function ends):
#                                            trap buildlock_release EXIT; trap 'exit 130' INT TERM HUP
#   buildlock_owner <folder>               prints who holds the folder's lock; succeeds only while that build runs
#   ibfix_code <work folder> [source dir] [variant]
#                                          sets IBFIX_CODE (the commit the add-on's code comes from, for
#                                          BUILT-FROM.txt); the source dir (IBFIX_SRCDIR) may be another checkout's ibfix/
#                                          (a task started from a release's tag). It fails in the main folder while
#                                          ibfix/ has changes that aren't committed, as another session may be part-way
#                                          through them, and for the real app ("final") wherever the code has any
#
# The lock is a symbolic link, made in one step (two builds can't both make it), holding "<process id>|<the process's
# start time>|<what>|<when>": the start time tells a running build from a new process that reuses an old build's number.

ibfix_task() {
  local t=${IBFIX_TASK:-}
  [[ -z $t && ${1:h:t} == worktrees ]] && t=${1:t}
  print -r -- $t
}

ibfix_task_ok() {
  local w=$1 t=$2
  [[ $t =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] || { print -u2 "STOP: the task name \"$t\": letters, digits, dots, dashes and underscores only"; return 1; }
  if [[ -f $w/tools/plist-$t.txt || $t == plain || $t == diag || $t == final ]]; then
    print -u2 "STOP: \"$t\" is a variant's name, and its folder may be another session's: pick a task name of its own"; return 1
  fi
}

ibfix_outdir() {
  local t; t=$(ibfix_task $1)
  # a task's build lives in its worktree (tools/task.sh); asked from the main folder with IBFIX_TASK, look there
  # (5 November 2026: trial.sh from the main folder looked for build-menuedge.noindex beside it, found nothing to install)
  if [[ -n $t && -d $1/worktrees/$t ]]; then print -r -- $1/worktrees/$t/build-$t.noindex
  elif [[ -n $t ]]; then print -r -- $1/build-$t.noindex; else print -r -- $1/build-$2; fi
}

ibfix_stagedir() {
  local t; t=$(ibfix_task $1)
  print -r -- $1/stage-${t:-$2}
}

_buildlock_start() { local s; s=(${=$(ps -o lstart= -p $1 2>/dev/null)}); print -r -- ${(j: :)s}; }

buildlock_owner() {
  local t pid st rest
  t=$(readlink $1/.building 2>/dev/null) || return 1
  pid=${t%%|*}; st=${${t#*|}%%|*}; rest=${t#*|*|}
  [[ $pid == <-> ]] && kill -0 $pid 2>/dev/null && [[ $(_buildlock_start $pid) == $st ]] || return 1
  print -r -- "${rest%|*}, process $pid, started ${t##*|}"
}

buildlock_take() {
  local d=$1 me who old
  me="$$|$(_buildlock_start $$)|$2|$(date '+%d %b %H:%M:%S')"
  mkdir -p $d
  if ! ln -s "$me" $d/.building 2>/dev/null; then
    if who=$(buildlock_owner $d); then
      print -u2 "STOP: another build ($who) is writing ${d:t} right now: wait for it to finish, or build into a folder of your own (IBFIX_TASK=<task>, or from a task's worktree: tools/task.sh start <task>)"
      exit 4
    fi
    old=$(readlink $d/.building 2>/dev/null) && rm -f $d/.building && print "cleared ${d:t}'s lock, left by a build that is no longer running (${${old#*|*|}%|*}, process ${old%%|*})"
    ln -s "$me" $d/.building 2>/dev/null || { print -u2 "STOP: another build took ${d:t} just now"; exit 4; }
  fi
  BUILDLOCK_HELD=$d/.building; BUILDLOCK_ME=$me
}

buildlock_release() {
  [[ -n ${BUILDLOCK_HELD:-} && $(readlink $BUILDLOCK_HELD 2>/dev/null) == ${BUILDLOCK_ME:-} ]] && rm -f $BUILDLOCK_HELD
  return 0
}

ibfix_code() {
  local w=$1 srcdir=${2:-} v=${3:-} gd cd br desc where=""
  local -a dirty
  if [[ -n $srcdir && ${srcdir:A} != ${w:A}/ibfix ]]; then
    # from git only when it is the ibfix/ of a checkout (a release's source/ lies inside the main folder, left out of git)
    if ! git -C $srcdir rev-parse --git-dir >/dev/null 2>&1 || [[ ${srcdir:A} != $(git -C $srcdir rev-parse --show-toplevel)/ibfix ]]; then
      [[ $v == final ]] && print -u2 "note: the real app's code from $srcdir, a folder outside git: its commit can't be recorded"
      IBFIX_CODE="from $srcdir (not from git)"; return 0
    fi
    w=$(git -C $srcdir rev-parse --show-toplevel); where=" in ${w}"
  fi
  if ! git -C $w rev-parse --git-dir >/dev/null 2>&1; then IBFIX_CODE="not in git (no repository here)"; return 0; fi
  gd=$(git -C $w rev-parse --path-format=absolute --git-dir); cd=$(git -C $w rev-parse --path-format=absolute --git-common-dir)
  dirty=(${(f)"$(git -C $w status --porcelain -- ibfix)"}); dirty=(${dirty#???})
  if [[ $v == final ]] && (( ${#dirty} )); then
    print -u2 "STOP: the real app is built only from committed code, and ibfix/${where} has changes that aren't (${dirty}): commit them (in a task's worktree), then build again"
    return 1
  fi
  if [[ $gd == $cd ]] && (( ${#dirty} )); then
    print -u2 "STOP: the main folder's ibfix/ has changes that aren't committed (${dirty}): another session may be part-way through them, and this build would take them in. The add-on's code is changed in a task's own worktree (tools/task.sh start <task>; FIXES.md 93)."
    return 1
  fi
  br=$(git -C $w symbolic-ref --short -q HEAD || print "no branch")
  desc=$(git -C $w describe --tags --always 2>/dev/null)
  IBFIX_CODE="commit $(git -C $w rev-parse --short HEAD) on $br ($desc)${where}${dirty:+, with changes not yet committed in ${dirty}}"
}
