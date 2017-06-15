#==============================================================================
# cli-shell-utils.bash
# An integrated collection of utilites for shell scripting.
# The .bash version uses $"..." for translation and another bashism in cmd().
#
# (C) 2016 -- 2017 Paul Banham <antiX@operamail.com>
# License: GPLv3 or later
#
# Note regarding reading command-line arguments and options:
#
# This is the oldest part of the code base.  Thie idea is to make it easy for
# programs that use this library to provide an easy, intuitive, and clear
# command line user interface.
#
#   SHORT_STACK               variable, list of single chars that stack
#   fatal(msg)                routine,  fatal([errnum] [errlabel] "error message")
#   takes_param(arg)          routine,  true if arg takes a value
#   eval_argument(arg, [val]) routine,  do whatever you want with $arg and $val
#==============================================================================

: ${ME:=${0##*/}}
: ${MY_DIR:=$(dirname "$(readlink -f $0)")}
: ${MY_LIB_DIR:=$(readlink -f "$MY_DIR/../cli-shell-utils")}
: ${LIB_DIR:=/usr/local/lib/cli-shell-utils}
: ${LOCK_FILE:=/run/lock/$ME}
: ${LOG_FILE:=/dev/null}
: ${DATE_FMT:=%Y-%m-%d %H:%M}
: ${DEFAULT_USER:=1000}
: ${K_IFS:=|}
: ${P_IFS:=&}
: ${MAJOR_SD_DEV_LIST:=3,8,22,179,259}
: ${MAJOR_SR_DEV_LIST:=11}
: ${LIVE_MP:=/live/boot-dev}
: ${MIN_ISO_SIZE:=180M}
: ${MENU_PATH:=$MY_LIB_DIR/text-menus/:$LIB_DIR/text-menus}
: ${MIN_LINUXFS_SIZE:=120M}
: ${CONFIG_FILE:=/root/.config/$ME/$ME.conf}
: ${PROG_FILE:=/dev/null}
: ${LOG_FILE:=/dev/null}
: ${SCREEN_WIDTH:=$(stty size 2>/dev/null | cut -d" " -f2)}
: ${SCREEN_WIDTH:=80}
: ${USB_DIRTY_BYTES:=20000000}  # Need this small size for the progress bar to work
: ${PROG_BAR_WIDTH:=100}     # Width of progress bar in percent of screen width
: ${VM_VERSION_PROG:=vmlinuz-version}
: ${PROGRESS_SCALE:=100}

# Make sure these start out empty.  See lib_clean_up()
unset ORIG_DIRTY_BYTES ORIG_DIRTY_RATIO COPY_PPID COPY_PID

FORCE_UMOUNT=true

export TEXTDOMAIN="cli-shell-utils"
domain_dir=$(readlink -f "$MY_DIR/../cli-shell-utils/locale")
test -d "$domain_dir" && export TEXTDOMAINDIR=$domain_dir

#------------------------------------------------------------------------------
# Sometimes it's useful to process some arguments (-h --help, for example)
# before others.  This can let normal users get simple usage.
# This relies on $SHORT_STACK, takes_param(), and eval_early_arguments()
# Only works on flags, not parameters that take options.
#------------------------------------------------------------------------------
read_early_params() {
    local arg

    while [ $# -gt 0 ]; do
        arg=$1 ; shift
        [ ${#arg} -gt 0 -a -z "${arg##-*}" ] || continue
        arg=${arg#-}
        # Expand stacked single-char arguments
        case $arg in
            [$SHORT_STACK][$SHORT_STACK]*)
                if echo "$arg" | grep -q "^[$SHORT_STACK]\+$"; then
                    local old_cnt=$#
                    set -- $(echo $arg | sed -r 's/([a-zA-Z])/ -\1 /g') "$@"
                    continue
                fi;;
        esac
        takes_param "$arg" && shift
        eval_early_argument "$arg"
    done
}

#------------------------------------------------------------------------------
# This will read all command line parameters.  Ones that start with "-" are
# evaluated one at a time by eval_arguments().  All others are evaluated by
# assign_parameter() which is given a count and a value.
#------------------------------------------------------------------------------
read_all_cmdline_mingled() {

    : ${PARAM_CNT:=0}
    SHIFT_2=0

    while [ $# -gt 0 ]; do
        read_params "$@"
        shift $SHIFT
        SHIFT_2=$((SHIFT_2 + SHIFT))
        [ -n "$END_CMDLINE" ] && return
        while [ $# -gt 0 -a ${#1} -gt 0 -a -n "${1##-*}" ]; do
            PARAM_CNT=$((PARAM_CNT + 1))
            assign_parameter $PARAM_CNT "$1"
            shift
            SHIFT_2=$((SHIFT_2 + 1))
        done
    done
}

#-------------------------------------------------------------------------------
# Sets "global" variable SHIFT to the number of arguments that have been read.
# Reads a series of "$@" arguments stacking short parameters and dealing with
# options that take arguments.  Use global SHORT_STACK for stacking and calls
# eval_argument() and takes_param() which should be provided by the calling
# program.  The SHIFT variable tells how many parameters we grabbed.
#-------------------------------------------------------------------------------
read_params() {
    # Most of this code is boiler-plate for parsing cmdline args
    SHIFT=0
    # These are the single-char options that can stack

    local arg val

    # Loop through the cmdline args
    while [ $# -gt 0 -a ${#1} -gt 0 -a -z "${1##-*}" ]; do
        arg=${1#-} ; shift
        SHIFT=$((SHIFT + 1))

        # Expand stacked single-char arguments
        case $arg in
            [$SHORT_STACK][$SHORT_STACK]*)
                if echo "$arg" | grep -q "^[$SHORT_STACK]\+$"; then
                    local old_cnt=$#
                    set -- $(echo $arg | sed -r 's/([a-zA-Z])/ -\1 /g') "$@"
                    SHIFT=$((SHIFT - $# + old_cnt))
                    continue
                fi;;
        esac

        # Deal with all options that take a parameter
        if takes_param "$arg"; then
            [ $# -lt 1 ] && fatal $"Expected a parameter after: %s" "-$arg"
            val=$1
            [ -n "$val" -a -z "${val##-*}" ] \
                && fatal $"Suspicious argument after %s: %s" "-$arg" "$val"
            SHIFT=$((SHIFT + 1))
            shift
        else
            case $arg in
                *=*)  val=${arg#*=} ;;
                  *)  val="???"     ;;
            esac
        fi

        eval_argument "$arg" "$val"
        [ "$END_CMDLINE" ] && return
    done
}

#==============================================================================
# Flow-Control Utilities
#
# These are used for flow-control, not system calls
#==============================================================================
#------------------------------------------------------------------------------
# return true if "$cmd" or "all" are in "$CMDS"
# If true print a small "==> $cmd" message
#------------------------------------------------------------------------------
need() {
    need_q "$1" || return 1
    local cmd=$1  xlat=${2:-$1}
    log_it echo &>/dev/null
    Msg "$(bq "=>") $xlat"
    #echo -e "@ $(date +"%Y-%m-%d %H:%M:%S")\n" >> $LOG_FILE

    return 0
}

#------------------------------------------------------------------------------
# Same as need() but silent _q = quiet
#------------------------------------------------------------------------------
need_q() {
    local cmd=$1  cmd2=${1%%-*}

    echo "$CMDS" | egrep -q "(^| )($cmd|$cmd2|all)( |$)" || return 1
    return 0
}

#------------------------------------------------------------------------------
# Return true if $cmd is in $CMD.  Unlike need(), ignore "all" and don't
# print anything extra.
#------------------------------------------------------------------------------
given_cmd() {
    local cmd=$1
    echo "$CMDS" | egrep -q "(^| )$cmd( |$)" || return 1
    return 0
}

#------------------------------------------------------------------------------
# Returns true if $here or "all" are in the comma delimited list $FORCE
#------------------------------------------------------------------------------
force() {
    local here=$1  option_list=${2:-$FORCE}
    case ,$option_list, in
        *,$here,*|*,all,*) return 0 ;;
    esac
    return 1
}

#------------------------------------------------------------------------------
# See if QUESTION_MODE matches any of the arguments
#------------------------------------------------------------------------------
q_mode() {
    local mode
    for mode; do
        [ "$QUESTION_MODE" = "$mode" ] && return 0
    done
    return 1
}
#------------------------------------------------------------------------------
# Pause execution if $here or "all" are in comma delimited $PAUSE
#------------------------------------------------------------------------------
pause() {
    local here=$1  xlated_here=${2:-$1}
    case ,$PAUSE, in
        *,$here,*)        ;;
          *,all,*)        ;;
                *) return ;;
    esac

    msg $"Paused at '%s'" $xlated_here
    press_enter
}


#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
press_enter() {
    local ans enter=$"Enter"
    quest $"Press <%s> to continue" "$(pqq "$enter")"
    read ans
}

#------------------------------------------------------------------------------
# Make sure all force or pause options are valid
# First param is the name of the list variable so we can transform all spaces
# to commas.  See force() and pause()
#------------------------------------------------------------------------------
check_force() { _check_any force "$@"  ;}
check_pause() { _check_any pause "$@"  ;}

#------------------------------------------------------------------------------
# Shared functionality of two commands above
#------------------------------------------------------------------------------
_check_any() {
    local type=$1  name=$2  all=$3  opt
    eval "local opts=\$$name"

    # Convert spaces to commas
    opts=${opts// /,}
    eval $name=\$opts

    for opt in ${opts//,/ }; do
        case ,$all, in
            *,$opt,*) continue ;;
                   *) fatal "Unknown %s option: %s" "$type" "$opt" ;;
        esac
    done
}

#------------------------------------------------------------------------------
# Test for valid commands and all process cmd+ commands if $ordered is given.
# If $ordered is not given then cmd+ is not allowed.  If it is given then
# "cmd+" will add cmd and everything after it in $ordered to the variable
# named as the first argument.  See need() NOT cmd() which is different (sorry)
#------------------------------------------------------------------------------
check_cmds() {
    local cmds_nam=$1  all=" $2 "  ordered=$3 cmds_in cmds_out

    eval "local cmds_in=\$$cmds_nam"

    local cmd plus_cnt=0 plus
    [ "$ordered" ] && plus="+"

    for cmd in $cmds_in; do

        case $all in
            *" ${cmd%$plus} "*) ;;
            *) fatal $"Unknown command: %s" $cmd ;;
        esac

        [ -z "${cmd%%*+}" ] || continue

        cmd=${cmd%+}
        cmds_out="$cmds_out $(echo "$ORDERED_CMDS" | sed -rn "s/.*($cmd )/\1/p")"
        plus_cnt=$((plus_cnt + 1))
        [ $plus_cnt -gt 1 ] && fatal "Only one + command allowed"
    done

    [ ${#cmds_out} -gt 0 ] && eval "$cmds_nam=\"$cmds_in \$cmds_out\""
}

#------------------------------------------------------------------------------
# Works like cmd() below but ignores the $PRETEND_MODE variable.  This can be
# useful  if you want to always run a command but also want to record the call.
#------------------------------------------------------------------------------
always_cmd() { PRETEND_MODE= cmd "$@" ;}

#------------------------------------------------------------------------------
# Always send the command line and all output to the log file.  Set the log
# file to /dev/null to disable this feature.
# If BE_VERBOSE then send output to the screen as well as the log file.
# If VERY_VERBOSE then send commands to screen was well as the long file.
# If PRETEND_MODE then don't actually run the command.
#------------------------------------------------------------------------------
cmd() {
    local pre=" >"
    [ "$PRETEND_MODE" ] && pre="p>"
    echo "$pre $*" >> $LOG_FILE
    [ "$VERY_VERBOSE" ] && echo "$pre" "$@" | sed "s|$WORK_DIR|.|g"
    [ "$PRETEND_MODE" ] && return 0
    if [ "$BE_VERBOSE" ]; then
        "$@" 2>&1 | tee -a $LOG_FILE
    else
        "$@" 2>&1 | tee -a $LOG_FILE &>/dev/null
    fi
    # Warning: Bashism
    local ret=${PIPESTATUS[0]}
    test -e "$ERR_FILE" && exit 3
    return $ret
}

#==============================================================================
# BASIC TEXT UI ELEMENTS
#
# These are meant to provide easy and consistent text UI elements.  In addition
# the plan is to automatically switch over to letting a GUI control the UI,
# perhaps by sending menus and questions and so on to the GUI.  Ideally one
# set of calls in the script will suffice for both purposes.
#==============================================================================
#------------------------------------------------------------------------------
# The order is weird but it allows the *error* message to work like printf
# The purpose is to make it easy to put questions into the error log.
#------------------------------------------------------------------------------
yes_NO_fatal() {
    local code=$1  question=$2  continuation=$3  fmt=$4
    shift 4
    local msg=$(printf "$fmt" "$@")

    q_mode qui && fatal "$msg"

    [ -n "$continuation" -a -z "${continuation##*%s*}" ] \
        && continuation=$(printf "$continuation" "$(pq "--force=$code")")

    if [ "$AUTO_MODE" ]; then
        FATAL_QUESTION=$question
        fatal "$code" "$fmt" "$@"
    fi
    warn "$fmt" "$@"
    [ ${#continuation} -gt 0 ] && question="$question\n($m_co$continuation$quest_co)"
    yes_NO "$question" && return 0
    fatal "$code" "$fmt" "$@"
}

#------------------------------------------------------------------------------
#  Default to yes if QUESTION_MODE is "expert" otherwise default to no.
#------------------------------------------------------------------------------
expert_YES_no() {
    case $QUESTION_MODE in
    gui|simple) return 1                ;;
        expert) YES_no "$@" ; return $? ;;
             *) yes_NO "$@" ; return $? ;;
    esac
}

#------------------------------------------------------------------------------
#  Always default no
#------------------------------------------------------------------------------
expert_yes_NO() {
    case $QUESTION_MODE in
    gui|simple) return 1                ;;
        expert) yes_NO "$@" ; return $? ;;
             *) yes_NO "$@" ; return $? ;;
    esac
}

#------------------------------------------------------------------------------
# Simple "yes" "no" questions.  Ask a question, wait for a valid response.  The
# responses are all numbers which might be better for internationalizations.
# I'm not sure if we should include the "quit" option or not.  The difference
# between the two routines is the default:
#       yes_NO() default is "no"
#       YES_no() default is "yes"
#------------------------------------------------------------------------------
yes_NO() { _yes_no 1 "$1" ;}
YES_no() { _yes_no 0 "$1" ;}

_yes_no() {
    local answer ret=$1  question=$2  def_entry=$(($1 + 1))

    [ "$AUTO_MODE" ] && return $ret

    local yes=$"yes"  no=$"no"  quit=$"quit"  default=$"default"
    quit="$quit_co$quit"

    local menu def_entry
    case $def_entry in
        1) menu=$(printf "  1) $yes ($default)\n  2) $no\n") ;;
        2) menu=$(printf "  1) $yes\n  2) $no ($default)\n") ;;
        *) fatal "Internal error in _yes_no()"               ;;
    esac

    local data=$(printf "1:1\n2:2\n0:0")
    my_select_2 answer "$quest_co$question$nc_co" $def_entry "$data" "$menu\n"

    case $answer in
        1) return 0 ;;
        2) return 1 ;;
     quit) return 1 ;;
        0) exit 0   ;;
        *) fatal "Should never get here 111" ;;
    esac
}

#------------------------------------------------------------------------------
# Create a simple yes/no/pretend-mode menu
#------------------------------------------------------------------------------
YES_no_pretend() {
    local question=$1 answer  orig_pretend=$PRETEND_MODE
    [ ${#question} -gt 0 ] || question=$"Shall we begin?"
    local yes=$"yes"  no=$"no"  pretend=$"pretend mode"

    local menu
    if [ "$PRETEND_MODE" ]; then
        menu="pretend$P_IFS$pretend\nno$P_IFS$no\n"
    else
        menu="yes$P_IFS$yes\nno$P_IFS$no\npretend$P_IFS$pretend\n"
    fi

    my_select answer "$question" "$menu"

    case $answer in
             yes) return 0 ;;
              no) return 1 ;;
         pretend) PRETEND_MODE=true ; shout_pretend ; return 0 ;;
               *) fatal "Internal error in YES_no_pretend()"   ;;
        esac
}

#------------------------------------------------------------------------------
# Announce to the world we are in pretend mode
#------------------------------------------------------------------------------
:
shout_pretend() { [ "$PRETEND_MODE" ] && Shout $"PRETEND MODE ENABLED" ;}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
menu_printf() {
    local payload=$1  fmt=$2  ; shift 2
    printf "%s$P_IFS$m_co$fmt$nc_co\n" "$payload" "$@"
}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
menu_printf_plural() {
    local payload=$1  cnt=$2  lab1=$3  lab2=$4

    case $cnt in
        1) printf "%s$P_IFS$lab1\n" "$payload" "$(nq $cnt)" ;;
        *) printf "%s$P_IFS$lab2\n" "$payload" "$(nq $cnt)" ;;
    esac
}

#------------------------------------------------------------------------------
# Generate a simple selection menu based on a data:label data structure.
# The "1)" and so on get added automatically.
#------------------------------------------------------------------------------
my_select() {
    local var=$1  title=$2  list=$3  def_str=$4  default=${5:-1}  orig_ifs=$IFS
    local IFS=$P_IFS
    local cnt=1 dcnt datum label data menu

    while read datum label; do
        if [ ${#datum} -eq 0 ]; then
            [ ${#label} -gt 0 ] && menu="$menu     $label\n"
            continue
        fi
        dcnt=$cnt

        if [ "$datum" = 'quit' ]; then
            dcnt=0
            label="$quit_co$label$nc_co"
        fi

        [ $dcnt = "$default" ] && label=$(printf "%s (%s)" "$label" "$m_co$(cq 'default')")

        data="${data}$dcnt:$datum\n"
        menu="${menu}$(printf "$quest_co%3d$hi_co)$m_co %${width}s" $dcnt "$label")\n"

        cnt=$((cnt+1))
    done<<My_Select
$(echo -e "$list")
My_Select

    [ "$VERBOSE_SELECT" ] && printf "\nMENU: $title\n$menu" | strip_color >> $LOG_FILE

    IFS=$orig_ifs
    my_select_2 $var "$title" "$default" "$data" "$menu" "$def_str"

}

#------------------------------------------------------------------------------
# This is the workhorse for several of my menu systems (in other codes).
#
#   $var:      the name of the variable the answer goes in
#   $title:    the question asked
#   $default:  the default selection (a number)
#   $data:     A string of lines of $NUM:$VALUE
#              The number select by the user gets converted to the value
#              The third field is used to mimic the value in the menu
#              for the initrd text menus but that may not be used here.
#   $menu      A multi-line string that is the menu to be displayed.  It
#              The callers job to make sure it is properly aligned with
#              the contents of $data.
#   $def_str   A string to indicate the default answer
#------------------------------------------------------------------------------
my_select_2() {
    local var=$1  title=$2  default=$3  data=$4  menu=$5  def_str=$6

    if [ -n "$def_str" ]; then
        def_str="($(pqq $def_str))"
    else
        def_str=$"selection"
    fi

    # Press <Enter> for the default selection
    local enter=$"Enter"
    # Press <Enter> for the default selection
    local p2 def_prompt=$(printf $"Press <%s> for the default %s" "$(pqq "$enter")" "$def_str")

    local quit=$"quit"
    [ -n "$BACK_TO_MAIN" ] && quit=$BACK_TO_MAIN
    local quit_str=$(printf $"Use '%s' to %s" "$(pqq q)" "$quit")

    if [ "$HAVE_MAN" ]; then
        local man_str=$(printf $"Use '%s' for help" "$(pqq h)")
        p2=$(printf "%s, %s" "$man_str" "$quit_str")
    else
        p2=$quit_str
    fi

    echo

    local val input_1 input err_msg
    while [ -z "$val" ]; do

        echo -e "$quest_co$title$nc_co"

        echo -en "$menu" | colorize_menu
        [ "$err_msg" ] && printf "$err_co%s$nc_co\n" "$err_msg"
        [ "$default" ] && printf "$m_co%s$nc_co\n" "$quest_co$def_prompt$nc_co"
        [ "$p2" ]      && quest "$p2\n"

        local  input= input_1=

        while true; do
            err_msg=
            local orig_IFS=$IFS
            local IFS=
            read -n1 input_1
            IFS=$orig_IFS
            case $input_1 in
                "") input=         ; break  ;;
              [qQ]) input=$input_1 ; break  ;;
              [hH]) input=$input_1 ; break  ;;
             [0-9]) echo -ne "\b"
                    read -ei "$input_1" input
                    break  ;;
                 *) quest " %s\n" $"Opps.  Please try again" ;;
            esac

        done

        # Evaluate again in case of backspacing
        case $input in
             [qQ]*) if [ -n "$BACK_TO_MAIN" ]; then
                        eval $var=quit
                        echo
                        return
                    else
                        final_quit ; continue
                    fi ;;
             [hH]*) if [ "$HAVE_MAN" ]; then
                        man "$MAN_PAGE" ; echo ; continue
                    fi;;
        esac

        [ -z "$input" -a -n "$default" ] && input=$default
        if ! echo "$input" | grep -q "^[0-9]\+$"; then
            err_msg=$"You must enter a number"
            [ "$default" ] && err_msg=$"You must enter a number or press <Enter>"
            continue
        fi

        # Note the initrd text menus assume no : in the payload hence the cut
        #val=$(echo -e "$data" | sed -n "s/^$input://p" | cut -d: -f1)
        val=$(echo -e "$data" | sed -n "s/^$input://p")

        if [ -z "$val" ]; then
            err_msg=$(printf $"The number '%s' is out of range" "$(pqe $input)")
            continue
        fi
        # FIXME!  is this always right?
        [ "$val" = 'default' ] && val=
        eval $var=\$val

        [ "$VERBOSE_SELECT" ] && printf "ANS: $input: $val\n" >> $LOG_FILE
        break
    done
}

#------------------------------------------------------------------------------
#  See if a man page exists.  Search locally first then try the man commmand.
#------------------------------------------------------------------------------
find_man_page() {

    local man_page  dir  me  me2=$(basename $0 .sh)
    [ "$me2" = "$ME" ] && me2=""

    HAVE_MAN=
    for me in $ME $me2; do
        for dir in "$MY_DIR/" "$MY_DIR/man/" ""; do
            man_page=$dir$me$ext.1
            test -r "$man_page" || continue
            HAVE_MAN=true
            break
        done

        [ "$HAVE_MAN" ] && break
        man -w $me &>/dev/null || continue
        HAVE_MAN=true
        break
    done

    if [ "$HAVE_MAN" ]; then
        MAN_PAGE=$man_page
        echo "Found man page: $man_page" >> $LOG_FILE
    else
        echo "No man page found" >> $LOG_FILE
    fi
}

#------------------------------------------------------------------------------
# The final quit menu after a 'q' has been detected
#------------------------------------------------------------------------------
final_quit() {
    local input
    echo
    quest $"Press '%s' again to quit" "$(pqq q)"
    echo -n " "
    read -n1 input
    echo
    [ "$input" = 'q' ] && exit 0
}

#------------------------------------------------------------------------------
# An interface to the text menus developed for live-init.  Each menu has .menu
# and .data files.  The format of the .data files is slightly different here.
#------------------------------------------------------------------------------
cli_text_menu() {
    local d dir  path=$MENU_PATH

    local orig_IFS=$IFS  IFS=:
    for d in $MENU_PATH; do
        test -d "$d" || continue
        dir=$d
        break
    done
    IFS=$orig_IFS

    if [ -z "$dir" ]; then
        warn "Could not find text menus"
        return 2
    fi

    local var=$1  name=$2  title=$3  blurb=$4  text_menu_val
    local dfile="$dir/$name.data"  mfile="$dir/$name.menu"

    local file
    for file in "$dfile" "$mfile"; do
        [ -r "$file" ] && continue
        warn "Missing file %s" "$file"
        return 2
    done
    [ "$blurb" ] && title="$title\n$blurb"

    local data=$(cat $dfile)
    local menu=$(cat $mfile)
    my_select_2 text_menu_val "$title" 1 "$data" "$menu\n"
    # FIXME: maybe a char other than : would be better for 2nd delimiter
    local val=${text_menu_val%%:*}
    local lab=${text_menu_val##*:}
    msg $"You chose %s" "$(pq $lab)"
    eval $var=\$val

    return 0
}

#------------------------------------------------------------------------------
# Return false if no boot dir is found so caller can handle error message
#------------------------------------------------------------------------------
find_live_boot_dir() {
    local var=$1  mp=$2  fname=$3  title=$4  min_size=${5:-$MIN_LINUXFS_SIZE}
    [ ${#title} -eq 0 ] && title=$"Please select the live boot directory"

    local find_opts="-maxdepth 2 -mindepth 2 -type f -name $fname -size +$MIN_LINUXFS_SIZE"

    local list=$(find $mp $find_opts | sed -e "s|^$mp||" -e "s|/$fname$||")
    case $(count_lines "$list") in
        0) return 1 ;;
        1) eval $var=\$list
           return 0 ;;
    esac
    local dir menu
    while read dir; do
        menu="$menu$dir$P_IFS$dir\n"
    done<<Live_Boot_Dir
$(echo "$list")
Live_Boot_Dir

    if ! q_mode gui; then
        my_select $var "$title" "$menu"
        return 0
    fi

    # Try to find the directory that has our running kernel

    need_prog "$VM_VERSION_PROG"

    local cnt=0 the_dir
    while read dir; do
       $VM_VERSION_PROG -c "$mp$dir" &>/dev/null || continue
       cnt=$((cnt + 1))
       the_dir=$dir
    done<<Live_Boot_Dir
$(echo "$list")
Live_Boot_Dir

    case $cnt in
        0) return 2 ;;
        1) eval $var=\$the_dir ;;
        *) return 3 ;;
    esac
}

#==============================================================================
# USE FIND COMMAND TO MAKE A MENU OF .iso files
# Experiemental and currently not used
#==============================================================================

#------------------------------------------------------------------------------
# Expand ~/ to the actual user's home directory (we run as root).
#------------------------------------------------------------------------------
expand_directories() {
    local dir
    for dir; do

        # Fudge ~/ so it becomes the default users' home, not root's
        case $dir in
            ~/*)  dir=$(get_user_home)/${dir#~/} ;;
        esac

        eval "dir=$dir"
        if test -d $dir; then
            echo $dir
        else
            warn "Not a directory %s" "$dir"
        fi
    done
}

#------------------------------------------------------------------------------
# Use "find" command to provide a list of .iso files.  WORK IN PROGRESS.
#------------------------------------------------------------------------------
cli_search_file() {
    local var=$1  spec=$2  dir_list=$3  max_depth=$4  max_found=${5:-20}  min_size=${6:-$MIN_ISO_SIZE}

    local _sf_input title dir_cnt invalid
    while true; do
        dir_list=$(expand_directories $dir_list)
        dir_cnt=$(echo "$dir_list" | wc -w)

        title=$(
        if [ $dir_cnt -eq 1 ]; then
            quest "Will search %s directory: %s\n"                          "$(pnq $dir_cnt)"   "$(pqq $dir_list)"
        else
            quest "Will search %s directories: %s\n"                        "$(pnq $dir_cnt)"   "$(pqq $dir_list)"
        fi
            quest "for files matching '%s' with a size of %s or greater\n"  "$(pqq $spec)"      "$(pq $min_size)"
            quest "Will search down %s directories"                         "$(pqq $max_depth)"
        )

        if [ $dir_cnt -le 0 ]; then
            while [ $dir_cnt -le 0 ]; do
                warn "No directories were found in the list.  Please try again"
                cli_get_text dir_list "Enter directories"
                dir_list=$(expand_directories $dir_list)
                dir_cnt=$(echo "$dir_list" | wc -w)
            done
            continue
        fi

        my_select _sf_input "$title" "$(select_file_menu $invalid)"
        invalid=

        # FIXME: need to make some of these entries more specfic
        case $_sf_input in
            search) ;;
              dirs) cli_get_text dir_list  "Enter directories"          ; continue ;;
             depth) cli_get_text max_depth "Enter maximum depth (1-9)"  ; continue ;;
              spec) cli_get_text spec      "Enter file specfication"    ; continue ;;
        esac

        local depth=1 dir f found found_cnt
        echo -n 'depth:'
        while [ $depth -le $max_depth ]; do
            echo -n " $depth"
            for dir in $dir_list; do
                test -d "$dir" || continue
                local args="-maxdepth $depth -mindepth $depth -type f -size +$MIN_ISO_SIZE"
                f=$(find "$dir" $args -iname "$spec" -print0 | tr '\000' '\t')
                [ ${#f} -gt 0 ] && found="$found$f"
                found_cnt=$(count_tabs "$found")
                echo -n "($found_cnt)"
                [ $found_cnt -ge $max_found ] && break
            done
            [ $found_cnt -ge $max_found ] && break
            depth=$((depth + 1))
        done
        echo

        if [ $found_cnt -eq 0 ]; then
            warn "No '%s' files were found.  Please try again" "$(pqw "$spec")"
            invalid=true
            continue
        fi
        if [ $found_cnt -gt $max_found ]; then
            warn "Found %s files at depth %s.  Only showing the %s most recent." \
                $(pqh $found_cnt) $(pqh $depth) $(pqh $max_found)
        fi

        found=$(echo "$found" | tr '\t' '\000' | xargs -0 ls -dt1  2>/dev/null | head -n$max_found)

        cli_choose_file _sf_input "Please select a file" "$found" "$dir_list"
        case $_sf_input in
            retry) continue ;;
        esac

        eval $var=\$_sf_input
        return
    done
}

#------------------------------------------------------------------------------
# Present a menu of files to choose from include, name, size, and date
#------------------------------------------------------------------------------
cli_choose_file() {
    local var=$1  title=$2  file_list=$3  dir_list=$4  one_dir orig_IFS=$IFS
    [ -n "${dir_list##* *}" ] && one_dir="$dir_list/"
    local ifmt="%s$K_IFS%s$K_IFS%s$K_IFS%s"
    local file name size date w1=5  w2=5  data  first
    while read file; do
        [ ${#file} -gt 0 ] || continue
        test -f "$file"    || continue
        : ${first:=$(basename "$file")}

        name=$(_file_name "$file" "$one_dir")
        size=$(_file_size "$file")
        date=$(_file_date "$file")
        [ $w1 -lt ${#name} ] && w1=${#name}
        [ $w2 -lt ${#size} ] && w2=${#size}
        data="$data$(printf "$ifmt" "$file" "$name" "$size" "$date")\n"
    done<<File_Menu
$(echo -e "$file_list")
File_Menu

    local fmt="%s$P_IFS$fname_co%-${w1}s$num_co %${w2}s$date_co %s$nc_co"
    local IFS=$K_IFS menu
    while read file name size date; do
        menu="$menu$(printf "$fmt" "$file" "$name" "$size" "$date")\n"
    done <<File_Menu_2
$(echo -e "$data")
File_Menu_2
    IFS=$orig_ifs

    menu="${menu}retry$P_IFS${quit_co}try again$nc_co\n"
    my_select $var "$title" "$menu" "$first"
}

#------------------------------------------------------------------------------
# Used to fill in the file date and size in a menu of files.
#------------------------------------------------------------------------------
_file_date() { date "+${DATE_FMT#+}" -d @$(stat -c %Y "$1") ;}
_file_size() { echo "$(( $(stat -c %s "$1") /1024 /1024))M" ;}

#------------------------------------------------------------------------------
# Used to fill in the file name in a menu. Try to keep it compact.
#------------------------------------------------------------------------------
_file_name() {
    local file=$1  one_dir=$2
    [ ${#one_dir} -gt 0 ] && file=$(echo "$file" | sed "s|^$one_dir||")
    file=$(echo "$file" | sed "s|^/home/|~|")

    if [ ${#file} -le 80 ]; then
        echo "$file"
        return
    fi
    local base=$(basename "$file")  path=$(dirname "$file")

    echo "$(echo "$path" | cut -d/ -f1,2)/.../$base"
}

#------------------------------------------------------------------------------
# A menu of options for the select file menu
#------------------------------------------------------------------------------
select_file_menu() {
    local invalid=$1
    [ "$invalid" ] || printf "%s$P_IFS%s\n" "search" "Begin search"
    printf "%s$P_IFS%s\n" "dirs"   "Change directories"
    printf "%s$P_IFS%s\n" "depth"  "Change search depth"
    printf "%s$P_IFS%s\n" "spec"   "Change file specification"
}


#------------------------------------------------------------------------------
# Simple input of strings
#------------------------------------------------------------------------------
cli_get_text() {
    local var=$1  title=$2
    local input prompt=$(quest "> ")

    while true; do
        quest "$title"
        echo -en "\n$prompt"
        read -r input
        quest $"You entered: %s" "$(cq "$input")"
        YES_no $"Is this correct?" && break
    done
    eval $var=\$input
}

#==============================================================================
# End of experimental file menu section
#==============================================================================

#------------------------------------------------------------------------------
# Allow user to enter a filename with tab completion
#------------------------------------------------------------------------------
cli_get_filename() {
    local var=$1  title=$2  preamb=$(sub_user_home "$3")
    local file

    while true; do
        quest "$title$nc_co\n$quest_co%s\n" $"(tab completion is enabled)"
        read -e -i "$preamb" file
        preamb=$file
        if ! test -f "$file"; then
            warn $"%s does not appear to be a file" "$file"
            YES_no $"Try again?" && continue
        fi
        quest $"You entered: %s" "$(cq "$file")"
        YES_no $"Is this correct?" && break
    done
    eval $var=\$file
}

#------------------------------------------------------------------------------
# Create the source menu for live-usb-maker
# Contains an entry for cloning running live-usb (if applicable)
# Next an entry for entering file name
# Then lists of live-usbs to clone and live-cd/dvds to copy
#------------------------------------------------------------------------------
cli_live_usb_src_menu() {
    local exclude=$1
    local dev_w=$(get_lsblk_field_width name  --include="$MAJOR_SD_DEV_LIST,$MAJOR_SR_DEV_LIST")
    local lab_w=$(get_lsblk_field_width label --include="$MAJOR_SD_DEV_LIST,$MAJOR_SR_DEV_LIST")
    local size_w=6  fs_w=8

    # Japanese: Please don't translate these: Device, Size, Filesystem, Label, Model
    local dev_str=$"Device"  size_str=$"Size"  fs_str=$"Filesystem" lab_str=$"Label" mod_str=$"Model"
    [ $dev_w  -lt ${#dev_str}  ] &&  dev_w=${#dev_str}
    [ $fs_w   -lt ${#fs_str}   ] &&   fs_w=${#fs_str}
    [ $size_w -lt ${#size_str} ] && size_w=${#size_str}

    local live_dev
    if its_alive; then
        live_dev=$(get_live_dev)
        # [A clone is different from a copy, with clone we make a fresh new system]
        is_mountpoint $LIVE_MP && printf "clone$P_IFS%s (%s)\n" $"Clone this live system" "$(pq $live_dev)"
    fi

    printf "iso-file$P_IFS%s\n" $"Copy from an ISO file"
    local  fmt="%s$P_IFS$dev_co%-${dev_w}s$num_co %${size_w}s$fs_co %${fs_w}s$lab_co %-${lab_w}s$nc_co %s\n"
    local hfmt="%s$P_IFS$head_co%s %s %s %s %s$nc_co\n"

    menu=$(cli_cdrom_menu "dev=$fmt" $lab_w ; cli_partition_menu "clone=$fmt" $lab_w "$live_dev" $exclude)
    if [ $(count_lines "$menu") -gt 0 ]; then
        printf "$hfmt" "" "$(rpad $dev_w "$dev_str")" "$(lpad $size_w "$size_str")" \
            "$(lpad $fs_w "$fs_str")" "$(rpad $lab_w "$lab_str")" "$mod_str"

        echo -e "$menu"
    fi
}

#------------------------------------------------------------------------------
# Menu items of cdroms and dvds
#------------------------------------------------------------------------------
cli_cdrom_menu() {
    local fmt=$1  lab_w=$2
    local opts="--nodeps --include=$MAJOR_SR_DEV_LIST"
    local model=$(bq cd/dvd disc)
    local NAME SIZE FSTYPE LABEL
    while read line; do
        eval "$line"
        [ ${#LABEL} -gt 0 ] || continue
        printf "$fmt" "$prefix$NAME" "$NAME" "$SIZE" "$FSTYPE" "$(rpad $lab_w "$LABEL")" "$model"
    done<<Cdrom_Menu
$(lsblk -no name,size,fstype,label --pairs $opts)
Cdrom_Menu
}

#------------------------------------------------------------------------------
# Menu items of usb partitions to clone
#------------------------------------------------------------------------------
cli_partition_menu() {
    local fmt=$1  lab_w=$2  exclude=$(get_drive ${3##*/}) exclude2=$(get_drive ${4##*/})
    local dev_list=$(lsblk -lno name --include="$MAJOR_SD_DEV_LIST")
    local range=1
    force partition && range=$(seq 1 20)

    local SIZE MODEL VENDOR FSTYPE label dev_info part_num
    for dev in $dev_list; do
        [ "$dev" = "$exclude" -o "$dev" = "$exclude2" ] && continue
        force usb || is_usb_or_removable "$dev" || continue
        local dev_info=$(lsblk -no vendor,model /dev/$dev)
        for part_num in $range; do
            local part=$(get_partition "$dev" $part_num)
            local device=/dev/$part
            test -b $device || continue
            local line=$(lsblk -no size,model,vendor,label,fstype --pairs $device)
            eval "$line"
            label=$(lsblk -no label $device)
            printf "$fmt" "$part" "$part" "$SIZE" "$FSTYPE" "$(rpad $lab_w "$label")" "$(echo $dev_info)"
        done
    done
}

#------------------------------------------------------------------------------
# Menu of usb drives
#------------------------------------------------------------------------------
cli_drive_menu() {
    local exclude=$(get_drive ${1##*/}) exclude_2=$(get_drive ${2##*/})

    local opts="--nodeps --include=$MAJOR_SD_DEV_LIST"
    local dev_width=$(get_lsblk_field_width name $opts)

    local fmt="%s$P_IFS$dev_co%-${dev_width}s$num_co %6s $m_co%s$nc_co\n"
    local NAME SIZE MODEL VENDOR dev
    while read line; do
        [ ${#line} -eq 0 ] && continue
        eval "$line"
        dev=/dev/$NAME

        force usb || is_usb_or_removable "$dev" || continue
        [ "$NAME" = "$exclude"   ] && continue
        [ "$NAME" = "$exclude_2" ] && continue

        printf "$fmt" "$NAME" "$NAME" "$SIZE" "$(echo $VENDOR $MODEL)"
    done<<Ls_Blk
$(lsblk -no name,size,model,vendor --pairs $opts)
Ls_Blk
}

#------------------------------------------------------------------------------
# Offer to check the md5sum if $file.md5 exists.
#------------------------------------------------------------------------------
check_md5() {
    local file=$1 md5_file="$1.md5"
    test -f "$md5_file" || return
    q_mode gui && return
    yes_NO $"Check md5 of the file %s?" "$(basename "$file")" || return
    Msg $"Checking md5 ..."
    (cd "$(dirname "$md5_file")" && md5sum -c "$(basename "$md5_file")") && return
    yes_NO $"Keep going anyway?" || my_exit 0
}

#------------------------------------------------------------------------------
# Get the width of a single lsblk output.  Used for making things line up
# in neat columns.
#------------------------------------------------------------------------------
get_lsblk_field_width() {
    local name=$1  field fwidth width=0 ; shift
    while read field; do
        fwidth=${#field}
        [ $width -lt $fwidth ] && width=$fwidth
    done<<Get_Field_Width
$(lsblk --output $name --list $*)
Get_Field_Width
    echo $width
}

#==============================================================================
# Kernel Tables!
#==============================================================================
#===============================================================================
# Kernel utilities
#
# These create and work with lists of kernels of the form:
#
#   version|fname|date
#
#===============================================================================

#------------------------------------------------------------------------------
# get_all_kernel      construct a list of all kernel files in a directory
#
# get_kernel_version  extract a list of versions, fnames, or dates from a
# get_kernel_fname    list of kernels
# get_kernel_date
#
# count_lines         Count lines in a variable, number of kernels in a list
#------------------------------------------------------------------------------

get_all_kernel() {
    local  var=$1 temp ; shift
    temp=$($VM_VERSION_PROG -nsr --delimit="$K_IFS" "$@") \
        || fatal $"The %s program failed!" "$VM_VERSION_PROG"

    eval $var=\$temp
}

get_kernel_version()  { echo "$1" | cut -d"$K_IFS" -f1                      ;}
get_kernel_fname()    { echo "$1" | cut -d"$K_IFS" -f2                      ;}
get_kernel_date()     { echo "$1" | cut -d"$K_IFS" -f"1,2" --complement     ;}
count_lines()         { echo "$1" | grep -c .                               ;}
count_nulls()         { echo "$1" | tr -cd '\000' | tr '\000' 'x' | wc -c   ;}
count_tabs()          { echo "$1" | tr -cd '\t'   | tr '\t' 'x'   | wc -c   ;}

#------------------------------------------------------------------------------
# Get kernels from a list that match the version expression
# FIXME: escape escape escape!
#------------------------------------------------------------------------------
find_kernel_version() {
    local version=$1  list=$2 ;  shift 2
    echo "$list" | egrep "$@" "^($version)[$K_IFS]"
}

#------------------------------------------------------------------------------
# Get kernels from a list that match the fname expression
#------------------------------------------------------------------------------
find_kernel_fname()   {
    local fname=$1  list=$2 ; shift 2
    echo "$list" | egrep "$@" "^[^$K_IFS]*[$K_IFS]($fname)[$K_IFS]"
}

#------------------------------------------------------------------------------
# Throw a fatal error if there are zero lines in "$1"
#------------------------------------------------------------------------------
fatal_k0() {
    local cnt=$(count_lines "$1") ; shift
    fatal_0 $cnt "$@"
}

#------------------------------------------------------------------------------
# Present a menu for user to select a kernel.  the list input should be the
# output of: "vmlinuz-version -nsd : <files>" or something like that.  You
# can set the delimiter with a 4th argument but it must be a single character
#
# This is the two column version:  Version  Date
#------------------------------------------------------------------------------
select_kernel_2() {
    local title=$1 var=$2 list=$3  orig_ifs=$IFS
    IFS=$K_IFS

    # Get field widths
    local f1 f2 f3  w1=5
    while read f1 f2 f3; do
        [ $w1 -lt ${#f1} ] && w1=${#f1}
    done<<Widths
$(echo "$list")
Widths

    local fmt="$version_co%-${w1}s $date_co%s$nc_co\n"
    local hfmt="$head_co%s %s$nc_co\n"
    local data="$P_IFS$(printf "$hfmt" "$(rpad $w1 $"Version")" $"Date")\n"

    local payload
    while read f1 f2 f3; do
        [ ${#f1} -gt 0 ] || continue
        payload="$f1$IFS$f2$IFS$f3"
        data="$data$payload$P_IFS$(printf "$fmt" "$f1" "$f3")\n"
    done<<Print
$(echo "$list")
Print

    IFS=$orig_ifs

    my_select $var "$title" "$data"
}

#------------------------------------------------------------------------------
# This is the three column version:  Fname Version  Date
# NOTE: not used, therefore not recently tested
#------------------------------------------------------------------------------
select_kernel_3() {
    local title=$1 var=$2 list=$3  orig_ifs=$IFS
    IFS=$K_IFS

    # Japanese: please do not translate: File, Version, Date
    local file=$"File"  version=$"Version"  date=$"Date"
    # Get field widths
    local file_w=${#files}  ver_w=${#version}
    local f1 f2 f3  w1=5 w2=5

    while read f1 f2 f3; do
        [ $ver_w -lt ${#f1}  ] &&  ver_w=${#f1}
        [ $file_w -lt ${#f2} ] && file_w=${#f2}
    done<<Widths
$(echo "$list")
Widths

    local fmt="$fname_co%-${file_w}s $version_co%-${ver_w}s $date_co%-s$nc_co"
    local hfmt="$head_co%s %s %-s$nc_co\n"
    local data="$P_IFS$(printf "$hfmt" "$(rpad $"File")" "$(rpad $"Version")" $"Date")\n"
    local payload
    while read f1 f2 f3; do
        [ ${#f1} -gt 0 ] || continue
        payload="$f1$IFS$f2$IFS$f3"
        data="$data$payload$P_IFS$(printf "$fmt" "$f2" "$f1" "$f3")\n"
    done<<Print
$(echo "$list")
Print

    IFS=$orig_ifs

    my_select $var "$title" "$data"
}

#------------------------------------------------------------------------------
# Display a 2-Column table (version, date) of a list of kernels
#------------------------------------------------------------------------------
show_kernel_2() {
    local title=$1  list=$2  orig_ifs=$IFS
    IFS=$K_IFS

    echo
    [ "$title" ] && echo "$m_co$title$nc_co"

    # Get field widths
    local  f1 f2 f3  w1=5
    while read f1 f2 f3; do
        [ $w1 -lt ${#f1} ] && w1=${#f1}
    done<<Widths
$(echo "$list")
Widths

    local  fmt=" $version_co%-${w1}s $date_co%s$nc_co\n"
    local hfmt=" $head_co%s %s$nc_co\n"
    printf "$hfmt" "$(rpad $w1 $"Version")" $"Date"
    while read  f1 f2 f3; do
        [ ${#f1} -gt 0 ] || continue
        printf "$fmt" "$f1" "$f3"
    done<<Print
$(echo "$list")
Print
    IFS=$orig_ifs
}

#------------------------------------------------------------------------------
# Show a 3-column table of a list of kernels (fname, version, date)
#------------------------------------------------------------------------------
show_kernel_3() {
    local title=$1  list=$2  orig_ifs=$IFS
    IFS=$K_IFS

    local file=$"File"  version=$"Version"  date=$"Date"
    local file_w=${#file}  ver_w=${#version}

    echo
    [ "$title" ] && echo "$m_co$title$nc_co"

    # Get field widths
    local f1 f2 f3  w1=5 w2=5
    while read f1 f2 f3; do
        [ $ver_w  -lt ${#f1} ] &&  ver_w=${#f1}
        [ $file_w -lt ${#f2} ] && file_w=${#f2}
    done<<Widths
$(echo "$list")
Widths

    local fmt=" $fname_co%-${file_w}s $version_co%-${ver_w}s $date_co%-s$nc_co\n"
    local hfmt=" $head_co%s %s %-s$nc_co\n"
    printf "$hfmt" "$(rpad $file_w $"File")" "$(rpad $ver_w $"Version")" $"Date"
    while read f1 f2 f3; do
        [ ${#f1} -gt 0 ] || continue
        printf "$fmt" "$f2" "$f1" "$f3"
    done<<Print
$(echo "$list")
Print

    IFS=$orig_ifs
}

#------------------------------------------------------------------------------
# Show a  special 5-column list of kernels:
#  label, version, date, from-fname, to-fname
#------------------------------------------------------------------------------
kernel_stats() {
    local ifs=$K_IFS orig_ifs=$IFS
    IFS=$ifs

    local list
    while [ $# -ge 5 ]; do
        list="$list$1$IFS$2$IFS$3$IFS$4$IFS$5\n"
        shift 5
    done

    # [We will convert from kernel "From" to kernel "To"]
    # Japanese: please don't translate: Version, Date, From, To
    local version=$"Version" date=$"Date"  from=$"From"  to=$"To"
    local w1=5  w2=${#version}  w3=${#date}  w4=${#from}
    # Get field widths
    local f1 f2 f3 f4 f5
    while read f1 f2 f3 f4 f5; do
        [ ${#f1} -gt 0   ] || continue
        [ $w1 -lt ${#f1} ] && w1=${#f1}
        [ $w2 -lt ${#f2} ] && w2=${#f2}
        [ $w3 -lt ${#f3} ] && w3=${#f3}
        [ $w4 -lt ${#f4} ] && w4=${#f4}
    done<<Widths
$(echo -e "$list")
Widths

    local hfmt=" $head_co%s %s  %s  %s %s$nc_co\n"
    local  fmt=" $lab_co%s $version_co%s  $date_co%s  $fname_co%s %s$nc_co\n"
    f1=$(lpad $w1 "")
    f2=$(rpad $w2 "$version")
    f3=$(rpad $w3 "$date")
    f4=$(rpad $w4 "$from")
    printf "$hfmt" "$f1" "$f2" "$f3" "$f4" "$to"

    while read f1 f2 f3 f4 f5; do
        [ ${#f1} -gt 0 ] || continue
        f1=$(lpad $w1 "$f1")
        f2=$(rpad $w2 "$f2")
        f3=$(rpad $w3 "$f3")
        f4=$(rpad $w4 "$f4")
        printf "$fmt" "$f1" "$f2" "$f3" "$f4" "$f5"
    done<<Print
$(echo -e "$list")
Print

    IFS=$orig_ifs
}

#------------------------------------------------------------------------------
# Make a table of values for displaying the partitions on a target usb device
#------------------------------------------------------------------------------
usb_stats() {
    local orig_ifs=$IFS
    local IFS=$K_IFS

    local list
    while [ $# -ge 4 ]; do
        list="$list$1$IFS$2$IFS$3$IFS$4\n"
        shift 4
    done

    # Space in a drive or partition: Total = Used + Extra
    # Japanese: please don't translate: Total, Used, Extra
    local total=$"Total"  allocated=$"Used"  extra=$"Extra"
    local w1=5 w2=${#total} w3=${#allocated} w4=${#extra}
    # Get field widths
    local f1 f2 f3 f4
    while read f1 f2 f3 f4; do
        f2=$(add_commas $f2)
        f3=$(add_commas $f3)
        f4=$(add_commas $f4)

        [ ${#f1} -gt 0 ] || continue
        [ $w1 -lt ${#f1} ] && w1=${#f1}
        [ $w2 -lt ${#f2} ] && w2=${#f2}
        [ $w3 -lt ${#f3} ] && w3=${#f3}
        [ $w4 -lt ${#f4} ] && w4=${#f4}
    done<<Widths
$(echo -e "$list")
Widths

    local hfmt=" $head_co%s  %s  %s  %s$nc_co\n"
    local  fmt=" $lab_co%s  $num_co%s  %s  %s$m_co  MiB$nc_co\n"
    f1=$(lpad $w1 "")
    f2=$(lpad $w2 "$total")
    f3=$(lpad $w3 "$allocated")
    f4=$(lpad $w4 "$extra")

    printf "$hfmt" "$f1" "$f2" "$f3" "$f4"

    while read f1 f2 f3 f4; do
        f2=$(add_commas $f2)
        f3=$(add_commas $f3)
        f4=$(add_commas $f4)

        [ ${#f1} -gt 0 ] || continue
        f1=$(lpad $w1 "$f1")
        f2=$(lpad $w2 "$f2")
        f3=$(lpad $w3 "$f3")
        f4=$(lpad $w4 "$f4")
        printf "$fmt" "$f1" "$f2" "$f3" "$f4" | color_commas
    done<<Print
$(echo -e "$list")
Print

    IFS=$orig_ifs
}

#------------------------------------------------------------------------------
# NOT USED.  See below.
#------------------------------------------------------------------------------
free_space_menu() {
    local min_percent=$1  total_size=$2  comma_size=$(add_commas $2)
    local w2=${#comma_size}
    local fmt="%s$P_IFS$hi_co %3s%%$num_co %${w2}s $m_co%s$nc_co\n"
    local size=100 free_size free_percent
    while [ $size -ge $min_percent ]; do
        free_percent=$((100 - size))
        free_size=$((free_percent * total_size / 100))
        printf "$fmt" "$size" "$free_percent" "$(add_commas $free_size)" MiB | color_commas
        [ $size -eq $min_percent ] && break
        size=$((size - 5))
        [ $size -lt $min_percent ] && size=$min_percent
    done
}

#------------------------------------------------------------------------------
# Create a menu of sizes if user wants to use lees than all of a usb device
#------------------------------------------------------------------------------
partition_size_menu() {
    local min_percent=$1  total_size=$2  comma_size=$(add_commas $2)
    local w2=${#comma_size}
    local fmt="%s$P_IFS$hi_co %3s%%$num_co %${w2}s $m_co%s$nc_co\n"
    local percent=100 size
    while [ $percent -ge $min_percent ]; do
        size=$((percent * total_size / 100))
        printf "$fmt" "$percent" "$percent" "$(add_commas $size)" MiB | color_commas
        [ $percent -eq $min_percent ] && break
        percent=$((percent - 5))
        [ $percent -lt $min_percent ] && percent=$min_percent
    done
}

#==============================================================================
# Fun with Colors!  (and align unicode test)
#
#==============================================================================
#------------------------------------------------------------------------------
# Defines a bunch of (lowercase!) globals for colors.  In some versions, $noco
# and $loco are used to control what colors get assigned, if any.
#------------------------------------------------------------------------------
set_colors() {
    local color=${1:-high}

    local e=$(printf "\e")

    if [ "$color" = 'off' ]; then

         black=  ;    blue=  ;    green=  ;    cyan=  ;
           red=  ;  purple=  ;    brown=  ; lt_gray=  ;
       dk_gray=  ; lt_blue=  ; lt_green=  ; lt_cyan=  ;
        lt_red=  ; magenta=  ;   yellow=  ;   white=  ;
         nc_co=  ;   brown=  ;   rev_co=


         inst_co=            ;  mark_co=           ;     grep_co=
         bold_co=            ;    fs_co=           ;      num_co=            ;
         date_co=            ;  head_co=           ;    quest_co=            ;
          dev_co=            ;    hi_co=           ;     quit_co=            ;
          err_co=            ;   lab_co=           ;  version_co=            ;
        fname_co=            ;     m_co=           ;     warn_co=            ;
         return
     fi

         black="$e[0;30m" ;    blue="$e[0;34m" ;    green="$e[0;32m" ;    cyan="$e[0;36m" ;
           red="$e[0;31m" ;  purple="$e[0;35m" ;    brown="$e[0;33m" ; lt_gray="$e[0;37m" ;
       dk_gray="$e[1;30m" ; lt_blue="$e[1;34m" ; lt_green="$e[1;32m" ; lt_cyan="$e[1;36m" ;
        lt_red="$e[1;31m" ; magenta="$e[1;35m" ;   yellow="$e[1;33m" ;   white="$e[1;37m" ;
         nc_co="$e[0m"    ;   brown="$e[0;33m" ;   rev_co="$e[7m"

    case $color in
        high)
         inst_co=$lt_cyan    ;  mark_co=$rev_co    ;     grep_co="1;35"
         bold_co=$yellow     ;    fs_co=$lt_blue   ;      num_co=$magenta    ;
         date_co=$lt_cyan    ;  head_co=$white     ;    quest_co=$lt_green   ;
          dev_co=$white      ;    hi_co=$white     ;     quit_co=$yellow     ;
          err_co=$red        ;   lab_co=$lt_cyan   ;  version_co=$white      ;
        fname_co=$white      ;     m_co=$lt_cyan   ;     warn_co=$yellow     ; ;;

        dark)
         inst_co=$cyan    ;  mark_co=$rev_co       ;     grep_co="1;34"
         bold_co=$brown      ;    fs_co=$lt_blue   ;      num_co=$brown   ;
         date_co=$cyan       ;  head_co=$nc_co     ;    quest_co=$green   ;
          dev_co=$nc_co      ;    hi_co=$nc_co     ;     quit_co=$brown   ;
          err_co=$red        ;   lab_co=$cyan      ;  version_co=$nc_co   ;
        fname_co=$nc_co      ;     m_co=$cyan      ;     warn_co=$brown   ; ;;

        low)
         inst_co=$cyan    ;  mark_co=$rev_co       ;     grep_co="1;34"
         bold_co=$white      ;    fs_co=$nc_co     ;      num_co=$white      ;
         date_co=$nc_co      ;  head_co=$white     ;    quest_co=$lt_green   ;
          dev_co=$white      ;    hi_co=$white     ;     quit_co=$lt_green   ;
          err_co=$red        ;   lab_co=$nc_co     ;  version_co=$white      ;
        fname_co=$white      ;     m_co=$nc_co     ;     warn_co=$yellow     ; ;;

        low2)
         inst_co=$cyan       ;  mark_co=$rev_co    ;     grep_co="1"
         bold_co=$white      ;    fs_co=$nc_co     ;      num_co=$white      ;
         date_co=$nc_co      ;  head_co=$white     ;    quest_co=$green      ;
          dev_co=$white      ;    hi_co=$white     ;     quit_co=$green      ;
          err_co=$red        ;   lab_co=$nc_co     ;  version_co=$white      ;
        fname_co=$white      ;     m_co=$nc_co     ;     warn_co=$yellow     ; ;;

        bw)
         inst_co=$white      ;  mark_co=$rev_co    ;     grep_co="1;37"
         bold_co=$white      ;    fs_co=$nc_co     ;      num_co=$white      ;
         date_co=$nc_co      ;  head_co=$white     ;    quest_co=$white      ;
          dev_co=$white      ;    hi_co=$white     ;     quit_co=$white      ;
          err_co=$white      ;   lab_co=$lt_gray   ;  version_co=$lt_gray    ;
        fname_co=$white      ;     m_co=$nc_co     ;     warn_co=$white      ; ;;

        *)
            error "Unknown color parameter: %s" "$color"
            fatal "Expected high, low. low2, bw, dark, or off" ;;
    esac
}

#------------------------------------------------------------------------------
# These are designed to "quote" strings with colors so there is always a
# leading color, all the args, and then a trailing color.  This is easier and
# more compact that using colors as strings.
#------------------------------------------------------------------------------
pq()  { echo "$hi_co$*$m_co"      ;}
vq()  { echo "$version_co$*$m_co" ;}
pqq() { echo "$hi_co$*$quest_co"  ;}
bqq() { echo "$bold_co$*$quest_co";}
pnq() { echo "$num_co$*$quest_co" ;}
pnh() { echo "$num_co$*$hi_co"    ;}
pqw() { echo "$warn_co$*$hi_co"   ;}
pqe() { echo "$hi_co$*$err_co"    ;}
pqh() { echo "$m_co$*$hi_co"      ;}
pqb() { echo "$m_co$*$bold_co"    ;}
bq()  { echo "$bold_co$*$m_co"    ;}
hq()  { echo "$bold_co$*$m_co"    ;}
cq()  { echo "$hi_co$*$m_co"      ;}
nq()  { echo "$num_co$*$m_co"     ;}

#------------------------------------------------------------------------------
# Intended to add colors to menus used by my_select_2() menus.
#------------------------------------------------------------------------------
colorize_menu() {
    sed -r -e "s/(^| )([0-9]+)\)/\1$quest_co\2$hi_co)$m_co/g" \
        -e "s/\(([^)]+)\)/($hi_co\1$m_co)/g" -e "s/\*/$bold_co*$m_co/g" -e "s/$/$nc_co/"
}

#------------------------------------------------------------------------------
# Pad a (possibly unicode) string on the RIGHT so it is total length $width.
# Unfortunately printf is problem with multi-byte unicode but wc -m is not.
#------------------------------------------------------------------------------
rpad() {
    local width=$1  str=$2
    local pad=$((width - ${#str}))
    [ $pad -le 0 ] && pad=0
    printf "%s%${pad}s" "$str" ""
}

#------------------------------------------------------------------------------
# Same as above but pad on the LEFT.
#------------------------------------------------------------------------------
lpad() {
    local width=$1  str=$2
    local pad=$((width - ${#str}))
    [ $pad -le 0 ] && pad=0
    printf "%${pad}s%s" "" "$str"
}

#------------------------------------------------------------------------------
# Remove all ANSI color escape sequences that are created in set_colors().
# This is NOT a general purpose routine for removing all ANSI escapes.
#------------------------------------------------------------------------------
strip_color() {
    local e=$(printf "\e")
    sed -r -e "s/$e\[[0-9;]+[mK]//g"
}

#==============================================================================
# Messages, Warnings and Errors
#
#==============================================================================

#------------------------------------------------------------------------------
# Show and log a message string.  Disable display if QUIET
#------------------------------------------------------------------------------
msg() {
    local fmt=$1 ; shift
    prog_log "$fmt" "$@"
    [ -z "$QUIET" ] && printf "$m_co$fmt$nc_co\n" "$@"
}

#------------------------------------------------------------------------------
# Convenience routine: show message if cnt is 1.
#------------------------------------------------------------------------------
msg_1() {
    local cnt=$1 ; shift
    [ "$cnt" -eq 1 ] || return
    msg "$@"
}

#------------------------------------------------------------------------------
# Like msg() but not disabled by QUIET
#------------------------------------------------------------------------------
Msg() {
    local fmt=$1 ; shift
    prog_log_echo "$m_co$fmt$nc_co" "$@"
}

#------------------------------------------------------------------------------
# Like Msg() but in bold
#------------------------------------------------------------------------------
Shout() {
    local fmt=$1 ; shift
    prog_log_echo "$bold_co$fmt$nc_co" "$@"
}

#------------------------------------------------------------------------------
# Convenience routine for printing a pretty title
#------------------------------------------------------------------------------
shout_title() {
    local title=$1
    echo "$m_co$BAR_80$nc_co"
    printf "\n=====> " >>$LOG_FILE
    shout "$title"
    echo "$m_co$BAR_80$nc_co"
}

#------------------------------------------------------------------------------
# Convenience routine for printing a pretty sub-title
#------------------------------------------------------------------------------
shout_subtitle() {
    local title=$1
    echo "$m_co$SBAR_80$nc_co"
    printf "\n=====> " >>$LOG_FILE
    shout "$title"
    echo "$m_co$SBAR_80$nc_co"
}

#------------------------------------------------------------------------------
# Like msg() but in bold
#------------------------------------------------------------------------------
shout() {
    local fmt=$1 ; shift
    prog_log "$fmt" "$@"
    [ -z "$QUIET" ] && printf "$bold_co$fmt$nc_co\n" "$@"
}

#------------------------------------------------------------------------------
# Run a command and send output to screen and log file
#------------------------------------------------------------------------------
log_it() {
    local msg=$("$@")
    echo "$msg"
    echo "$msg" 2>&1 | strip_color >> $LOG_FILE
}

#------------------------------------------------------------------------------
# Run a command and send output to log file.  Only send to screen if not quiet
#------------------------------------------------------------------------------
log_it_q() {
    local msg=$("$@")
    [ -z "$QUIET" ] && echo "$msg"
    echo "$msg" 2>&1 | strip_color >> $LOG_FILE
}

#------------------------------------------------------------------------------
# Throw a fatal error.  There is some funny business to include a question in
# the error log that may need to be tweaked or changed.
#------------------------------------------------------------------------------
fatal() {
    local code

    if echo "$1" | grep -q "^[0-9]\+$"; then
        EXIT_NUM=$1 ; shift
    fi

    if echo "$1" | grep -q "^[a-z-]*$"; then
        code=$1 ; shift
    fi

    local fmt=$1 ; shift

    prog_log_echo "${err_co}%s:$hi_co $fmt$nc_co"   $"Error" "$@" >&2
    fmt=$(echo "$fmt" | sed 's/\\n/ /g')
    if [ -n "$ERR_FILE" ]; then
        printf "$code:$fmt\n" "$@" | strip_color >> $ERR_FILE
        [ -n "$FATAL_QUESTION" ] && echo "Q:$FATAL_QUESTION" >> $ERR_FILE
    fi

    case $(type -t my_exit) in
        function) my_exit ${EXIT_NUM:-100} ;;
    esac

    exit ${EXIT_NUM:-100}
}

#------------------------------------------------------------------------------
# Convenience routines to throw a fatal error or warning if a variable is
# zero-length or numerically 0.
#------------------------------------------------------------------------------
fatal_z() { [ ${#1} -gt 0 ] && return;  shift;  fatal "$@" ;}
fatal_0() { [ $1    -ne 0 ] && return;  shift;  fatal "$@" ;}
warn_z()  { [ ${#1} -gt 0 ] && return;  shift;  warn  "$@" ;}
warn_0()  { [ $1    -ne 0 ] && return;  shift;  warn  "$@" ;}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
internal_error() {
    local where=$1  ;  shift
    fatal "Internal error at %s: %s" "$where" "$*"
}

#------------------------------------------------------------------------------
# Throw a warning.
#------------------------------------------------------------------------------
warn() {
    local fmt=$1 ; shift
    prog_log_echo "${warn_co}%s:$hi_co $fmt$nc_co" $"Warning" "$@" >&2
}

#------------------------------------------------------------------------------
# Only warn if we are not in pretend mode
#------------------------------------------------------------------------------
pwarn() { [ -z "$PRETEND_MODE" ] && warn "$@" ; }

#------------------------------------------------------------------------------
# Write an error message without exiting
#------------------------------------------------------------------------------
error() {
    local fmt=$1 ; shift
    prog_log_echo "${err_co}%s:$hi_co $fmt$nc_co" $"Error" "$@" >&2
}

#------------------------------------------------------------------------------
# Display a question
#------------------------------------------------------------------------------
quest() {
    local fmt=$1 ; shift
    printf "$quest_co$fmt$nc_co" "$@"
}


#------------------------------------------------------------------------------
# Same as quest() but with trailing \n
#------------------------------------------------------------------------------
questn() {
    local fmt=$1 ; shift
    printf "$quest_co$fmt$nc_co\n" "$@"
}

#------------------------------------------------------------------------------
# Progress, log, and echo.
# printf a string then send it on to be output to the log file and to the
# progress file.
#------------------------------------------------------------------------------
prog_log_echo()  {
    local fmt="$1" ;  shift;
    printf "$fmt\n" "$@"
    prog_log "$fmt" "$@"
}


#------------------------------------------------------------------------------
# Printf a string to the log file and maybe to the progress file.
# Note: $PROG_FILE is set to /dev/null to disable the progress file.
#------------------------------------------------------------------------------
prog_log()  {
    local fmt="$1\n" ;  shift;
    printf "$fmt" "$@" | strip_color >> $LOG_FILE
    printf "$fmt" "$@" | strip_color >> $PROG_FILE
}

#==============================================================================
# TIME KEEPING AND REPORTING
#
# Very little bang for the coding buck here.  The plural() routine can't
# be easily translated. Expect some changes.
#==============================================================================
#------------------------------------------------------------------------------
# Show the time elapsed since START_T if it is greatr than 10 seconds
#------------------------------------------------------------------------------
show_elapsed() {
    [ ${#START_T} -eq 0 ] && return
    [ $START_T    -eq 0 ] && return
    local dt=$(($(date +%s) - START_T))
    [ $dt -gt 10 ] && msg "\n$ME took $(elapsed $START_T)."
    echo >> $LOG_FILE
}

#------------------------------------------------------------------------------
# Show time elapsed since time passed in as first arg
#------------------------------------------------------------------------------
elapsed() {
    local sec min hour ans

    sec=$((-$1 + $(date +%s)))

    if [ $sec -lt 60 ]; then
        plural $sec "%n second%s"
        return
    fi

    min=$((sec / 60))
    sec=$((sec - 60 * min))
    if [ $min -lt 60 ]; then
        ans=$(plural $min "%n minute%s")
        [ $sec -gt 0 ] && ans="$ans and $(plural $sec "%n second%s")"
        echo -n "$ans"
        return
    fi

    hour=$((min / 60))
    min=$((min - 60 * hour))

    plural $hour "%n hour%s"
    if [ $min -gt 0 ]; then
        local min_str=$(plural $min "%n minute%s")
        if [ $sec -gt 0 ]; then
            echo -n ", $min_str,"
        else
            echo -n " and $min_str"
        fi
    fi
    [ $sec -gt 0 ] && plural $sec " and %n second%s"
}

#------------------------------------------------------------------------------
# Get time in 1/100ths of a second since kernel booted.  The 2nd one puts the
# result in the START_TIME global which is use in msg_elapased_t() below.
#------------------------------------------------------------------------------
get_time() { cut -d" " -f22 /proc/self/stat ; }
start_timer() { START_TIME=$(cut -d" " -f22 /proc/self/stat) ; }

#------------------------------------------------------------------------------
# Not used.
#------------------------------------------------------------------------------
show_delta_t() {
    local dt=$(($(get_time) - $1))
    printf "%03d" $dt | sed -r 's/(..)$/.\1/'
}

#------------------------------------------------------------------------------
# Show MM:SS if time is 1 minute or greater, otherwise show fractional seconds
# Usg msg() to put the result in the log file, color, it etc.
#------------------------------------------------------------------------------
msg_elapsed_t() {
    local label=$1  min  sec
    local dt=$(($(get_time) - ${2:-$START_TIME}))

    if [ $dt -ge 6000 ]; then
        min=$((dt / 6000))
        sec=$(((dt - 6000 * min)/ 100))
        msg "%s took $num_co%d$m_co:$num_co%02d$m_co mm:ss" "$(pq $label)" "$min" "$sec"
        return
    fi

    sec=$(printf "%03d" $dt | sed -r 's/(..)$/.\1/')
    msg "%s took %s seconds" "$(pq $label)" "$(nq $sec)"
}

#------------------------------------------------------------------------------
# Pluralize words in English.  WILL NOT WORK WITH TRANSLATION.
#------------------------------------------------------------------------------
plural() {
    local n=$1 str=$2
    case $n in
        1) local s=  ies=y   are=is   were=was  es= num=one;;
        *) local s=s ies=ies are=are  were=were es=es num=$n;;
    esac

    case $n in
        0) num=no ;;
    esac

    echo -n "$str" | sed -e "s/%s\>/$s/g" -e "s/%ies\>/$ies/g" \
        -e "s/%are\>/$are/g" -e "s/%n\>/$num/g" -e "s/%were\>/$were/g" \
        -e "s/%es\>/$es/g" -e "s/%3d\>/$(printf "%3d" $n)/g"
}

#==============================================================================
# Special Utilities
# These are more integrated into the overall scheme
#==============================================================================

#------------------------------------------------------------------------------
# Umount all partitions on a disk device
#------------------------------------------------------------------------------
umount_all() {
    local dev=$1  mounted

    mounted=$(mount | egrep "^$dev[^ ]*" | cut -d" " -f3 | grep .) || return 0

    # fatal "One or more partitions on device %s are mounted at: %s"
    # This makes it easier on the translators (and my validation)
    local msg="One or more partitions on device %s are mounted at"
     [ "$FORCE_UMOUNT" ] || force umount || yes_NO_fatal "umount" \
        "Do you want those partitions unmounted?" \
        "Use %s to always have us unmount mounted target partitions" \
        "$msg:\n  %s" "$dev" "$(echo $mounted)"

    sync ; sync

    local i part
    for part in $(mount | egrep -o "^$dev[^ ]*"); do
        umount --all-targets $part 2>/dev/null
    done

    mount | egrep -q "^$dev[^ ]*" || return 0

    for i in $(seq 1 10); do
        for part in $(mount | egrep -o "^$dev[^ ]*"); do
            umount $part 2>/dev/null
        done
        mount | egrep -q "^$dev[^ ]*" || return 0
        sleep .1
    done

    # Make translation and validation easier
    msg="One or more partitions on device %s are in use at"
    mounted=$(mount | egrep "^$dev[^ ]*" | cut -d" " -f3 | grep .) || return 0
    fatal "$msg:\n  %s"  "$dev" "$(echo $mounted)"
    return 1
}

#------------------------------------------------------------------------------
# Start file locking with appropriate error messages to let someone go ahead
# if the flock program is missing
#------------------------------------------------------------------------------
do_flock() {
    file=${1:-$LOCK_FILE}  me=${2:-$ME}

    HAVE_FLOCK=
    force flock && return

    if ! hash flock &> /dev/null; then
        yes_NO_fatal "flock" \
        "Do you want to continue without locking?" \
        "Use %s to always ignore this warning"     \
        "The %s program was not found." "flock" && return
        exit
    fi

    exec 18>> $file

    local pid
    while true; do

        flock -n 18 && break

        sleep 0.1

        pid=$(flock_pid $file)

        if [ ${#pid} -gt 0 ]; then
            error     $"A %s process (using PID %s) is already running" "$me" "$pid"
            fatal 101 $"Please close that process before starting a new one"
        fi

        warn "Deleting stale lock file %s" $file
        rm -f $file
        flock -n 18 && break

        fatal 101 $"Failed to obtain lock on %s" "$file"
    done

    HAVE_FLOCK=true
    echo $$ > "$file"
    return
}

#------------------------------------------------------------------------------
# Print the contents of the lock file if it is a PID of an active process.
#------------------------------------------------------------------------------
flock_pid() {
    file=${1:-$LOCK_FILE}
    local pid
    read pid >/dev/null <$file
    [ ${#pid} -gt 0 ] || return
    test -d /proc/$pid || return
    echo $pid
}

#------------------------------------------------------------------------------
# A flock routine to be called by a gui wrapper.
#------------------------------------------------------------------------------
gui_flock() {
    file=${1:-$LOCK_FILE}  me=${2:-$ME}
    HAVE_FLOCK=
    exec 18> $file
    flock -n 18 || return 1
    HAVE_FLOCK=true
    echo $$ >&18
    return 0
}

#------------------------------------------------------------------------------
# Release the flock unless we are running with --force=flock.
#------------------------------------------------------------------------------
unflock() {
    local file=${1:-$LOCK_FILE}
    force flock && return
    [ "$HAVE_FLOCK" ] && rm -f $file &>/dev/null
}

#------------------------------------------------------------------------------
# Create a nice header for the .config file.
#------------------------------------------------------------------------------
config_header() {
    local file=${1:-$CONFIG_FILE}  me=${2:-$ME}
    cat<<Config_Header
#----------------------------------------------------------------------
# Configuration file for $me
# File: $file
# Created: $(date +"$DATE_FMT")
#
# Config file options:
#
#   -R --reset-config   Write fresh config file with default values
#   -W --write-config   Write config file with current (cli) options
#   -I --ignore-config  Ignore this file
#----------------------------------------------------------------------

Config_Header
}

#------------------------------------------------------------------------------
# Create a one-line footer for the confiig file
#------------------------------------------------------------------------------
config_footer() {
    echo  "#--- End of config file -----------------------------------------------"
}

#------------------------------------------------------------------------------
# Use a fancy sed command to reset the config file to the default options but
# reading directly from "$0".
#------------------------------------------------------------------------------
reset_config() {
    local file=${1:-$CONFIG_FILE}  msg=$2

    [ -n "$msg" ] || msg="Resetting config file %s"
    msg "$msg" "$(pq $file)"

    mkdir -p $(dirname "$file") || fatal "Could not create directory for config file"
    (config_header "$file" "$ME"
    sed -rn "/^#=+\s*BEGIN_CONFIG/,/^#=+\s*END_CONFIG/p" "$0" \
        | egrep -v "^#=+[ ]*(BEGIN|END)_CONFIG"
        config_footer ) > $file
    return 0
}

#------------------------------------------------------------------------------
# Do nothing if --ignore-config
# Otherwise if --reset-config or no existing config then reset config and exit
# Otherwise source the existing config file (if readable)
#------------------------------------------------------------------------------
read_reset_config_file() {
    local file=${1:-$CONFIG_FILE}

    [ "$IGNORE_CONFIG" ] && return

    if [ "$RESET_CONFIG" -o ! -e "$file" ]; then
        reset_config "$file" $"Creating new config file %s"
        [ "$RESET_CONFIG" ] || return
        pause exit $"Exit"
        exit 0
    else
        test -r "$file" && . "$file"
    fi
}

#==============================================================================
# General System Utilities
#
# These usually either provide a useful feature or wrap a bunch of error checks
# around standard system calls.  Some of them are for convenience.
#==============================================================================

#------------------------------------------------------------------------------
# The normal mountpoint command can fail on symlinks and in other situations.
# This is intended to be more robust. (sorry Jerry and Gaer Boy!)
#------------------------------------------------------------------------------
is_mountpoint() {
    local file=$1
    cut -d" " -f2 /proc/mounts | grep -q "^$(readlink -f $file 2>/dev/null)$"
    return $?
}

#------------------------------------------------------------------------------
# Return true if the device shows up in /proc/mounts
#------------------------------------------------------------------------------
is_mounted() {
    local dev=$1
    cut -d" " -f1 /proc/mounts | grep -q "^$dev$"
    return $?
}

#------------------------------------------------------------------------------
# Needs a better name.  Requires all the programs on the list to be on the PATH
# or returns false and says it is Skipping $stage.
#------------------------------------------------------------------------------
require() {
    local stage=$1  prog ret=0 ; shift;
    for prog; do
        which $prog &>/dev/null && continue
        warn $"Could not find program %s.  Skipping %s." "$(pqh $prog)" "$(pqh $stage)"
        ret=2
    done
    return $ret
}

#------------------------------------------------------------------------------
# Throw a fatal error if any of the programs are missing.  Again, need better
# naming.
#------------------------------------------------------------------------------
need_prog() {
    local prog
    for prog; do
        which $prog &>/dev/null && continue
        fatal $"Could not find required program '%s'" "$(pqh $prog)"
    done
}

#------------------------------------------------------------------------------
# Test if a directory is writable by making a temporary file in it.  May not
# be elegant but it is pretty darned robust IMO.
#------------------------------------------------------------------------------
is_writable() {
    local dir=$1
    test -d "$dir" || fatal "Directory %s does not exist" "$dir"
    local temp=$(mktemp -p $dir 2> /dev/null) || return 1
    test -f "$temp" || return 1
    rm -f "$temp"
    return 0
}

#------------------------------------------------------------------------------
# A nice wrapper around is_writable()
#------------------------------------------------------------------------------
check_writable() {
    local dir=$1  type=$2
    test -e "$dir"     || fatal  "The %s directory '%s' does not exist"     "$type" "$dir"
    test -d "$dir"     || fatal  "The %s directory '%s' is not a directory" "$type" "$dir"
    # The <type> directory <dir-name> is not writable
    is_writable "$dir" || fatal $"The %s directory '%s' is not writable"    "$type" "$dir"
}

#------------------------------------------------------------------------------
# Only used in conjunction with cmd() which does not handle io-redirect well.
# Using write_file() allows both PRETEND_MODE and BE_VERBOSE to work.
#------------------------------------------------------------------------------
write_file() {
    local file=$1 ; shift
    echo "$*" > "$file"
}

#------------------------------------------------------------------------------
# Slightly heuristic way of trying to see if a drive or partition is usb or
# is removable.  This information has never been 100% reliable across all
# hardware.  This is my best shot.  Maybe there will be something better someday.
#------------------------------------------------------------------------------
is_usb_or_removable() {
    local dev=$(expand_device $1)
    test -b $dev || return 1
    local drive=$(get_drive $dev)
    local dir=/sys/block/${drive##*/} flag
    read flag 2>/dev/null < $dir/removable
    [ "$flag" = 1 ] && return 0
    local devpath=$(readlink -f $dir/device)
    [ "$devpath" ] || return 1
    echo $devpath | grep -q /usb
    return $?
}

#------------------------------------------------------------------------------
# Mount dev at dir or know the reason why.  All failures are fatal
#------------------------------------------------------------------------------
my_mount() {
    local dev=$1  dir=$2 ; shift 2
    is_mountpoint "$dir"              && fatal "Directory '%s' is already a mountpoint" "$dir"
    always_cmd mkdir -p "$dir"        || fatal "Failed to create directory '%s'" "$dir"
    always_cmd mount "$@" $dev "$dir" || fatal "Could not mount %s at %s" "$dev" "$dir"
    is_mountpoint "$dir"              || fatal "Failed to mount %s at %s" "$dev" "$dir"
}

#------------------------------------------------------------------------------
# mount_if_needed $dev $mp  [options]
#------------------------------------------------------------------------------
mount_if_needed() {
    local dev=$1  mp=$2 ; shift 2
    test -e "$mp" && ! test -d "$mp" && fatal "Mountpoint %s is not a directory"
    test -d "$mp" || always_cmd mkdir -p "$mp"

    grep -q -- "^$dev $mp " /proc/mounts && return

    local exist_mp=$(get_mp $dev)
    if [ -n "$exist_mp" ]; then
        always_cmd mount --bind "$exist_mp" "$mp" \
            || fatal "Could not bind mount %s to %s" "$exist_mp" "$mp"
    else
        always_cmd mount "$dev" "$mp" "$@" \
            || fatal "Could not mount device %s" "$dev"
    fi
    is_mountpoint "$mp" || fatal "Failed to mount %s at %s" "$dev" "$mp"
    cleanup_mp "$mp"
}

get_mp() { grep "^$1 " /proc/mounts | head -n1 | cut -d" " -f2 ;}

cleanup_mp() { CLEANUP_MPS="$*${CLEANUP_MPS:+ }$CLEANUP_MPS" ;}

#------------------------------------------------------------------------------
# Mount an iso file
#------------------------------------------------------------------------------
mount_iso_file() {
    local file=$1  dir=$2

    test -e "$file" || fatal $"Could not find iso file %s" "$file"
    test -r "$file" || fatal $"Could not read iso file %s" "$file"

    local type
    for type in iso9660 udf; do
        mount -t $type -o loop,ro "$file" $dir 2>/dev/null
        is_mountpoint $dir && return 0
    done

    fatal $"Could not mount iso file %s" "$file"
}

#------------------------------------------------------------------------------
# Returns true on a live antiX/MX system, returns false otherwise.  May work
# correctly on other live systems but has not been tested.
#------------------------------------------------------------------------------
its_alive() {
    # return 0
    local root_fstype=$(df -PT / | tail -n1 | awk '{print $2}')
    case $root_fstype in
        aufs|overlay) return 0 ;;
                   *) return 1 ;;
    esac
}

#------------------------------------------------------------------------------
# Return true if running live and we can write to $LIVE_MP (/live/boot-dev)
# FIXME: Can this be easily fooled by "toram"?
#------------------------------------------------------------------------------
its_alive_usb() {
    its_alive || return 1
    local dir=$LIVE_MP
    test -d $dir || return 1
    is_writable "$dir"
    return $?
}

#------------------------------------------------------------------------------
# Get the device mounted at $LIVE_MP (usually /live/boot-dev)
#------------------------------------------------------------------------------
get_live_dev() {
    local live_dev=$(sed -rn "s|^([^ ]+) $LIVE_MP .*|\1|p" /proc/mounts)
    echo ${live_dev##*/}
}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
read_initrd_config() {
    file=${1:-/live/config/initrd.out}  pre=${2:-INITRD_}
    test -r "$file" || fatal "Could not find/read file %s" "$file"
    eval $(sed -r -n "s/^\s*([A-Z0-9_]+=)/$pre\1/p" $file)
}

#------------------------------------------------------------------------------
# Way overly complicated way to show the distro of a live system mounted at
# at directory.  I tried to cram in extra information.  FIXME
#------------------------------------------------------------------------------
show_distro_version()  {
    local dir=$1  dev=${2##*/}

    [ ${#dir} -gt 0 ]                            || return 1

    sync

    local iso_version version_file=$dir/version
    test -r $version_file                        || return 1
    iso_version=$(cat $version_file 2>/dev/null) || return 1

    if [ ${#dev} -eq 0 ]; then
        [ ${#iso_version} -gt 0 ]                || return 1
        # Which distro we are going to copy or clone
        msg $"Distro: %s" "$(pq $iso_version)"
        return 0
    fi

    if [ ${#iso_version} -gt 0 ]; then
        # Distro X on device Y
        msg $"Distro: %s on %s" "$(pq $iso_version)" "$(pq $dev)"
    else
        warn "No version file found on %s" "$(pqw "$dev")"
    fi
    return 0
}

#------------------------------------------------------------------------------
# Read "version" file and get leading letters from first line
#------------------------------------------------------------------------------
get_distro_name()  {
    local file=$1  version

    [ ${#file} -gt 0 ]                     || return 1
    test -r $file                          || return 1
    read version 2>/dev/null < $file

    [ ${#version} -gt 0 ]                  || return 1
    [ -z "${version%%[a-zA-Z]*}" ]         || return 1

    echo "$version" | sed -r "s/^([A-Za-z]+).*/\1/"
    return 0
}

#------------------------------------------------------------------------------
# Make a partition label of length less than or equal to $max by combinining
# the parts with $sep as glue.
#------------------------------------------------------------------------------
make_label() {
    local max=$1  sep=$2  lab=$3 ; shift 3

    local part len
    for part; do
        len=${#lab}
        [ $len -ge $max ] && break
        part="$sep$part"
        [ $(($len + ${#part})) -le $max ] && lab="$lab$part"
    done
    echo ${lab:0:$max}
}

#------------------------------------------------------------------------------
# Given a partition, echo the canonical name for the drive.
#------------------------------------------------------------------------------
get_drive() {
    local drive part=$1
    case $part in
        mmcblk*) echo ${part%p[0-9]}                       ;;
              *) drive=${part%[0-9]} ; echo ${drive%[0-9]} ;;
    esac
}

#------------------------------------------------------------------------------
# Allow users to use abbreviations like sdd1 or /sdd1 or dev/sdd1
#------------------------------------------------------------------------------
expand_device() {
    case $1 in
        /dev/*)  [ -b "$1"      ] && echo "$1"      ;;
         dev/*)  [ -b "/$1"     ] && echo "/$1"     ;;
            /*)  [ -b "/dev$1"  ] && echo "/dev$1"  ;;
             *)  [ -b "/dev/$1" ] && echo "/dev/$1" ;;
    esac
}

#------------------------------------------------------------------------------
# echo the canonical name for the Nth partition on a drive.
#------------------------------------------------------------------------------
get_partition() {
    local dev=$1  num=$2

    case $dev in
       *mmcblk*) echo  ${dev}p$num  ;;
              *) echo  ${dev}$num   ;;
    esac
}

#------------------------------------------------------------------------------
# Not currently used
#------------------------------------------------------------------------------
device_str() {
    local file=$1  file_type=${2:-"file"}
    local dev=$(expand_device "$file")
    case $(stat -c %t "${dev:-$file}") in
                 0) echo "$file_type"      ;;
                 b) echo "cd/dvd disc"    ;;
                b3) echo "mmc device"     ;;
        3|8|22|103) echo "disk device"    ;;
                 *) echo "unknown device" ;;
    esac
}

#------------------------------------------------------------------------------
# Simple mkdir -p with simple error checking.  If it is likely that a directory
# cannot be made then check it yourself explicitly instead of using this
# routine.  This is to provide some breadcrumbs but I don't expect it to fail
# very often.  If we cannot make a directory then usually something is very
# wrong.
#------------------------------------------------------------------------------
my_mkdir() {
    dir=$1
    mkdir -p "$dir" || fatal "Could not make directory '%s'" "$dir"
}

#------------------------------------------------------------------------------
# Report the size of all the directories and files give in MiB.
#------------------------------------------------------------------------------
du_size() { du -scm "$@" 2>/dev/null | tail -n1 | cut -f1 ; }


#------------------------------------------------------------------------------
# Report the APPARENT size of all the directories and files give in MiB.
# This includes the space allocated by not used by sparse files.
#------------------------------------------------------------------------------
du_ap_size() {
    du --apparent-size -scm "$@" 2>/dev/null | tail -n 1 | cut -f1
}

#------------------------------------------------------------------------------
# Find apparent sizes based on a directory name and a single variable that
# allows file globs, etc.
#------------------------------------------------------------------------------
du_ap_size_spec() {
    dir=$1  spec=$2
    (cd $dir; eval du --apparent-size -scm $spec 2>/dev/null) | tail -n 1 | cut -f1
}

#------------------------------------------------------------------------------
# All the mounted partitions of a give device
#------------------------------------------------------------------------------
mounted_partitions() {
    mount | egrep "^$1[^ ]*" | cut -d" " -f3 | grep .
    return $?
}

#------------------------------------------------------------------------------
# The home directory of the "default user".
#------------------------------------------------------------------------------
get_user_home() {
    local user=${1:-$DEFAULT_USER}
    getent passwd $user | cut -d: -f6
}

#------------------------------------------------------------------------------
# Substitute the "default user's" home direcotry for %USER_HOME%
#------------------------------------------------------------------------------
sub_user_home() {
    local user_home=$(get_user_home)
    echo "$1" | sed "s|%USER_HOME%|$user_home|g"
}

#------------------------------------------------------------------------------
# Issue a simple fatal error if we are not running as root
#------------------------------------------------------------------------------
need_root() {
    [ $UID -eq 0 ] || fatal 099 $"This script must be run as root"
}

#------------------------------------------------------------------------------
# Insert commas into number like: 123,456.  We colorize separately because
# fixed width printf gets confused by ANSI escapes.
#------------------------------------------------------------------------------
add_commas()   { echo "$1" | sed ":a;s/\B[0-9]\{3\}\>/,&/;ta" ;}
color_commas() { sed "s/,/$m_co,$num_co/g" ;}

#------------------------------------------------------------------------------
# Use awk to perform simple arithmetic
#------------------------------------------------------------------------------
x2() { awk "BEGIN{ printf \"%4.2f\n\", $*; }" ; }

#------------------------------------------------------------------------------
# Copy a directory while sending percentage done to an external program
# So that program can draw a progress bar.
#------------------------------------------------------------------------------
copy_with_progress() {
    local from=$1  to=$2  err_msg=$3  prog=$4 ; shift 3

    hide_cursor

    printf "Using progress %s: $*\n" "$(my_type $1)" >> $LOG_FILE

    local pre=" >"
    [ "$PRETEND_MODE" ] && pre="p>"
    echo $pre cp -a $from/* $to/                     >> $LOG_FILE

    if [ "$PRETEND_MODE" ]; then
        pretend_progress "$@" 2>/dev/null
        restore_cursor
        return 0
    fi

    local final_size=$(du_size $from/*)
    local base_size=$(du_size $to)

    local cur_size=$base_size  cur_pct=0  last_pct=0

    ORIG_DIRTY_RATIO=$(sysctl -n vm.dirty_ratio)
    ORIG_DIRTY_BYTES=$(sysctl -n vm.dirty_bytes)
    sysctl vm.dirty_bytes=$USB_DIRTY_BYTES >> $LOG_FILE

    (cp -a $from/* $to/ || fatal "$err_msg") &
    COPY_PPID=$!
    sleep 0.01
    COPY_PID=$(pgrep -P $COPY_PPID)

    echo "copy pids: $(echo $COPY_PPID $COPY_PID)" >> $LOG_FILE

    while true; do
        if ! test -d /proc/$COPY_PPID; then
            echo $PROGRESS_SCALE
            break
        fi
        sleep 0.1

        cur_size=$(du_size $to)
        cur_pct=$((cur_size * $PROGRESS_SCALE / final_size))
        [ $cur_pct -gt $last_pct ] || continue
        echo $cur_pct
        last_pct=$cur_pct

    done | "$@"

    wait $COPY_PPID

    restore_cursor
    sync ; sync

    sysctl vm.dirty_bytes=$ORIG_DIRTY_BYTES >> $LOG_FILE
    sysctl vm.dirty_ratio=$ORIG_DIRTY_RATIO >> $LOG_FILE

    unset ORIG_DIRTY_BYTES ORIG_DIRTY_RATIO

    # Use ERR_FILE as a semaphore from (...)& process
    test -e "$ERR_FILE" && exit 2

    test -d /proc/$COPY_PPID && wait $COPY_PPID
    unset COPY_PPID COPY_PID
}

#------------------------------------------------------------------------------
# Hide cursor and prepare restore_cursor() to work just once
#------------------------------------------------------------------------------
hide_cursor() {
    RESTORE_CURSOR="\e[?25h\n"

    # Disable cursor
    printf "\e[?25l"
}

#------------------------------------------------------------------------------
# Only works once after hide_cursor() runs.  This allows me to call it in the
# normal flow and at clean up.
#------------------------------------------------------------------------------
restore_cursor() {
    printf "$RESTORE_CURSOR"
    RESTORE_CURSOR=
}

#------------------------------------------------------------------------------
# This acts like an external program to draw a progress bar on the screen.
# It expects integer percentages as input on stdin to move the bar.
#------------------------------------------------------------------------------
text_progress_bar() {
    local abs_max_x=$((SCREEN_WIDTH * PROG_BAR_WIDTH / 100))

    # length of ">|100%" plus one = 7
    max_x=$((abs_max_x - 7))

    # Create end-points and save our location on the screen
    printf "\e[s$green|$nc_co"
    #printf "\e[u\e[$((max_x + 1))C$green|$nc_co\e[u"

    local input cur_x last_x=0
    while read input; do
        case $input in
            [0-9]|[0-9][0-9]|[0-9][0-9][0-9]) ;;
                        [0-9][0-9][0-9][0-9]) ;;
            *) break;;
        esac

        [ $input -gt $PROGRESS_SCALE ] && input=$PROGRESS_SCALE
        cur_x=$((max_x * input / $PROGRESS_SCALE))
        [ $cur_x -le $last_x ] && continue

        # Draw the bar
        # Note we always draw entire bar to avoid problems when switching
        # virtual terminals while the bar is being drawn
        printf "\e[u\e[0C$m_co%${cur_x}s$bold_co>$nc_co\e[u" | tr ' ' '='
        # Show the percentage
        printf "\e[$((max_x + 2))C%3s%%" "$((100 * input / $PROGRESS_SCALE))"

        last_x=$cur_x
        [ $input -ge $PROGRESS_SCALE ] && break
    done
}

#------------------------------------------------------------------------------
# Just show the percentage completed
#------------------------------------------------------------------------------
percent_progress() {
    local input
    while read input; do
        case $input in
            [0-9]|[0-9][0-9]|[0-9][0-9][0-9]) ;;
                        [0-9][0-9][0-9][0-9]) ;;
            *) break ;;
        esac
        printf "\e[10D\e[K%3s%%" "$((100 * input / $PROGRESS_SCALE))"
        [ $input -ge $PROGRESS_SCALE ] && break
    done
}

#------------------------------------------------------------------------------
# Replace "file" with "command".
#------------------------------------------------------------------------------
my_type() {
    local prog=$1
    local type=$(type -t $prog)
    case $type in
        file) echo "command" ;;
    function) echo $type     ;;
           *) echo $type     ;;
    esac
}

#------------------------------------------------------------------------------
# Exercise external/internal progress bar when in pretend mode
#------------------------------------------------------------------------------
pretend_progress() {
    local step=$((PROGRESS_SCALE/50))
    for i in $(seq 0 $step $PROGRESS_SCALE); do
        echo $i
        sleep 0.05
    done | "$@"
}

#------------------------------------------------------------------------------
# Try to kill off a list of PIDs in a way that does not cause any problems or
# create extra output to stderr.
#------------------------------------------------------------------------------
kill_pids() {
    local pid
    for pid; do
        test -z "$pid"     && continue
        test -d /proc/$pid || continue

        pkill -P $pid 2>/dev/null
        disown   $pid 2>/dev/null
        kill     $pid 2>/dev/null
    done
}

#------------------------------------------------------------------------------
# Possible cleanup need by this library
# Enable the cursor, kill off bg processes, and restore dirty settings.
# Most of these are only needed if we are interrupted during progbar_copy().
#------------------------------------------------------------------------------
lib_clean_up() {

    restore_cursor

    # Kill off background copy process
    kill_pids $COPY_PPID $COPY_PID

    [ "$ORIG_DIRTY_BYTES" ] && sysctl vm.dirty_bytes=$ORIG_DIRTY_BYTES >> $LOG_FILE
    [ "$ORIG_DIRTY_RATIO" ] && sysctl vm.dirty_ratio=$ORIG_DIRTY_RATIO >> $LOG_FILE
}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
mp_cleanup() {
    local dir  i  busy

    for i in $(seq 1 10); do
        busy=
        for dir in $CLEANUP_MPS "$@" ; do
            [ ${#dir} -eq 0 ] && continue
            is_mountpoint "$dir" || continue
            busy=true
            umount --recursive "$dir" &>/dev/null
            #is_mountpoint "$dir" || rmdir "$dir"
        done
        sleep 0.1
        [ "$busy" ] && continue
        printf "umount done at iteration %s\n" $i >> $LOG_FILE
        return
    done
}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
luks_close() {
    local name=$1
    [ -z "$name" ] && return
    test -e /dev/mapper/$name || return
    cryptsetup close $name
}

#==============================================================================
#===== END ====================================================================
#==============================================================================
