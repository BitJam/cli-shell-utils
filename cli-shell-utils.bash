# shell-utils.bash
#
# An integrated collection of utilites for shell scripting.
# The .bash version uses $"..." for translation and one other bashism in cmd().

#==============================================================================
# Reading command-line arguments and options
#
# This is the oldest part of the code base.  Thie idea is to make it was for
# programs that use this library to provide an easy and intuitive and clear
# command line user interface.
#
#   SHORT_STACK               variable, list of single chars that stack
#   fatal(msg)                routine,  fatal([errnum] [errlabel] "error message")
#   takes_param(arg)          routine,  true if arg takes a value
#   eval_argument(arg, [val]) routine,  do whatever you want with $arg and $val
#
#==============================================================================

: ${K_IFS:=|}
: ${MAJOR_DEV_LIST:=3,8,22,179,259}

#------------------------------------------------------------------------------
# Sometimes it's useful to process some arguments (-h --help, for example)
# Before others.  This can let normal users get simple usage.
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

    while [ $# -gt 0 ]; do
        read_params "$@"
        shift $SHIFT
        while [ $# -gt 0 -a ${#1} -gt 0 -a -n "${1##-*}" ]; do
            PARAM_CNT=$((PARAM_CNT + 1))
            assign_parameter $PARAM_CNT "$1"
            shift
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
    local cmd=$1  cmd2=${1%%-*}
    echo "$CMDS" | egrep -q "(^| )($cmd|$cmd2|all)( |$)" || return 1
    Msg "=> $cmd"
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
# Pause execution if $here or "all" are in comma delimited $PAUSE
#------------------------------------------------------------------------------
pause() {
    local here=$1  ans
    case ,$PAUSE, in
        *,$here,*)        ;;
          *,all,*)        ;;
                *) return ;;
    esac

    msg "Paused at '%s'" $here
    quest "Press <Enter> to continue "
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
                   *) fatal $"Unknown %s option: %s" "$type" "$opt" ;;
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
        [ $plus_cnt -gt 1 ] && fatal $"Only one + command allowed"
    done

    [ ${#cmds_out} -gt 0 ] && eval "$cmds_nam=\"$cmds_in \$cmds_out\""
}

#------------------------------------------------------------------------------
# Works like cmd() below but ignores the $PRETEND variable.  This can be useful
# if you want to always run a command but also want to record the call.
#------------------------------------------------------------------------------
always_cmd() { PRETEND= cmd "$@" ;}

#------------------------------------------------------------------------------
# Always send the command line and all output to the log file.  Set the log
# file to /dev/null to disable this feature.  If BE_VERBOSE then also echo
# the command line to the screen.  If PRETEND then don't actually run the
# command.
#------------------------------------------------------------------------------
cmd() {
    echo " > $*" >> $LOG_FILE
    [ "$BE_VERBOSE" ] && echo " >" "$@" | sed "s|$WORK_DIR|.|g"
    [ "$PRETEND"    ] && return 0
    "$@" 2>&1 | tee -a $LOG_FILE
    # Warning: Bashism
    return ${PIPESTATUS[0]}
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

    if [ "$FIFO_MODE" ]; then
        pipe_up "yes-no:$def_entry: $question"
        pipe_dn answer
        echo "answer: $answer"
    else
        local yes=$"yes"  no=$"no"  quit=$"quit"  default=$"default"
        quit="$bold_co$quit"

        local menu def_entry
        case $def_entry in
            1) menu=$(printf "  1) $yes ($default)\n  2) $no\n  0) $quit\n") ;;
            2) menu=$(printf "  1) $yes\n  2) $no (default)\n  0) $quit\n")  ;;
            *) fatal "Internal error in _yes_no()"                           ;;
        esac
        local data=$(printf "1:1\n2:2\n0:0")
        my_select_2 "$quest_co$question$nc_co" answer $def_entry "$data" "$menu\n"
    fi

    case $answer in
        1) return 0 ;;
        2) return 1 ;;
        0) exit 0   ;;
        *) fatal "Should never get here 111" ;;
    esac
}

#------------------------------------------------------------------------------
# Generate a simple selection menu based on a data:label data structure.
# The "1)" and so on get added automatically.
#------------------------------------------------------------------------------
my_select() {
    local var=$1  title=$2  list=$3  default=${4:-1} orig_ifs=$IFS
    local IFS=":"
    local cnt=1 dcnt datum label data menu
    while read datum label; do
        [ ${#datum} -eq 0 ] && continue
        dcnt=$cnt

        if [ "$datum" = "quit" ]; then
            dcnt=0
            label="$bold_co$label$nc_co"
        fi

        [ $dcnt = "$default" ] && label=$(printf "%s (%s)" "$label" "$m_co$(cq "default")")

        data="${data}$dcnt:$datum\n"
        menu="${menu}$(printf "$quest_co%2d$white)$lt_cyan %${width}s" $dcnt "$label")\n"

        cnt=$((cnt+1))
    done<<My_Select
$(echo -e "$list")
My_Select

    IFS=$orig_ifs
    my_select_2 "$title" "$var" "$default" "$data" "$menu"
}

#------------------------------------------------------------------------------
# Same as my_select but with a "quit" entry added to bottom of the menu
#------------------------------------------------------------------------------
my_select_quit() {
    local var=$1  title=$2  menu=$3  default=$4
    menu=$(printf "%s\nquit:%s\n" "$menu" $"quit")
    local ans
    my_select ans "$title" "$menu" "$default"
    [ "$ans" = "quit" ] && my_exit
    eval $var=\$ans
}

#------------------------------------------------------------------------------
# This is the workhorse for several of my menu systems (in other codes).
#
#   $title:    the question asked
#   $var:      the name of the variable the answer goes in
#   $default:  the default selection (a number)
#   $data:     A string of lines of $NUM:$VALUE:$menu_value
#              The number select by the user gets converted to the value
#              The third field is used to mimic the value in the menu
#              for the initrd text menus but that may not be used here.
#   $menu      A multi-line string that is the menu to be displayed.  It
#              The callers job to make sure it is properly aligned with
#              the contents of $data.
#------------------------------------------------------------------------------
my_select_2() {
    local title=$1  var=$2  default=$3  data=$4  menu=$5  def_str=$6

    if [ -n "$def_str" ]; then
        def_str="($bold_co$def_str$quest_co)"
    else
        def_str="selection"
    fi

    local def_prompt=$(printf $"Press <%s> for the default %s" "$(cq "enter")" "$def_str")

    local val input err_msg
    while [ -z "$val" ]; do

        echo -e "$hi_co$title$nc_co"

        echo -en "$menu" | colorize_menu
        [ "$err_msg" ] && printf "$err_co%s$nc_co\n" "$err_msg"
        [ "$default" ] && printf "$m_co%s$nc_co\n" "$def_prompt"
        echo -n "$quest_co>$nc_co "

        read input
        err_msg=
        [ -z "$input" -a -n "$default" ] && input=$default

        if ! echo "$input" | grep -q "^[0-9]\+$"; then
            err_msg=$"You must enter a number"
            [ "$default" ] && err_msg=$"You must enter a number or press <enter>"
            continue
        fi

        # Note the initrd text menus assume no : in the payload hence the cut
        #val=$(echo -e "$data" | sed -n "s/^$input://p" | cut -d: -f1)
        val=$(echo -e "$data" | sed -n "s/^$input://p")

        if [ -z "$val" ]; then
            err_msg=$(printf $"The number <%s> is out of range" "$(pqe $input)")
            continue
        fi

        eval $var=\$val
        break
    done
}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
drive_menu() {
    local all=$1

    local opts="--nodeps --include=$MAJOR_DEV_LIST"
    local dev_width=$(get_lsblk_field_width name $opts)

    local fmt="%s:$lt_green%-${dev_width}s$magenta %6s $lt_cyan%s$nc_co\n"
    local NAME SIZE MODEL VENDOR dev
    while read line; do
        eval "$line"
        dev=/dev/$NAME
        [ "$all" ] || is_usb_or_removable "$dev" || continue
        printf "$fmt\n" "$NAME" "$NAME" "$SIZE" "$(echo $VENDOR $MODEL)"
    done<<Ls_Blk
$(lsblk -no name,size,model,vendor --pairs $opts)
Ls_Blk
}

#------------------------------------------------------------------------------
#
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
#------------------------------------------------------------------------------
# Present a menu for user to select a kernel.  the list input should be the
# output of: "vmlinuz-version -nsd : <files>" or something like that.  You
# can set the delimiter with a 4th argument but it must be a single character
#
# This is the two column version:  Version  Date
#------------------------------------------------------------------------------
select_kernel_2() {
    local title=$1 var=$2 list=$3  ifs=${4:-$K_IFS} orig_ifs=$IFS
    IFS=$ifs

    # Get field widths
    local f1 f2 f3  w1=5
    while read f1 f2 f3; do
        [ $w1 -lt ${#f1} ] && w1=${#f1}
    done<<Widths
$(echo "$list")
Widths

    local fmt=" %2s) $version_co%-${w1}s $date_co%s$nc_co\n"
    local hfmt=" %3s $hfmt_co%-${w1}s %s$nc_co\n"
    local menu=$(printf "$hfmt" "" $"Version" $"Date")
    local data="0:quit"
    local cnt=1 default
    while read f1 f2 f3; do
        menu="$menu\n$(printf "$fmt" "$cnt" "$f1" "$f3")"
        data="$data\n$cnt:$f1$IFS$f2$IFS$f3"
        [ $cnt -eq 1 ] && default=$f1
        cnt=$((cnt + 1))
    done<<Print
$(echo "$list")
Print

    IFS=$orig_ifs
    menu="$menu\n$(printf " %2s) $bold_co%s$nc_co\n" 0 "quit")"
    my_select_2 "$title" $var 1 "$data" "$menu" "$default"

    eval "local ans=\$$var"
    [ "$ans" = 'quit' ] && my_exit

}

#------------------------------------------------------------------------------
# This is the three column version:  Fname Version  Date
#------------------------------------------------------------------------------
select_kernel_3() {
    local title=$1 var=$2 list=$3  ifs=${4:-$K_IFS}  orig_ifs=$IFS
    IFS=$ifs

    # Get field widths
    local f1 f2 f3  w1=5 w2=5
    while read f1 f2 f3; do
        [ $w1 -lt ${#f1} ] && w1=${#f1}
        [ $w2 -lt ${#f2} ] && w2=${#f2}
    done<<Widths
$(echo "$list")
Widths

    local fmt=" %2s) $fname_co%-${w2}s $version_co%-${w1}s $date_co%-s$nc_co\n"
    local hfmt=" %3s $hfmt_co%-${w2}s %-${w1}s %-s$nc_co\n"
    local menu=$(printf "$hfmt" "" $"File" $"Version" $"Date")
    local data="0:quit"
    local cnt=1 default
    while read f1 f2 f3; do
        menu="$menu\n$(printf "$fmt" "$cnt" "$f2" "$f1" "$f3")"
        data="$data\n$cnt:$f1$IFS$f2$IFS$f3"
        [ $cnt -eq 1 ] && default=$f2
        cnt=$((cnt + 1))
    done<<Print
$(echo "$list")
Print

    IFS=$orig_ifs

    menu="$menu\n$(printf " %2s) $bold_co%s$nc_co\n" 0 "quit")"
    my_select_2 "$title" $var 1 "$data" "$menu" "$default"

    eval "local ans=\$$var"
    [ "$ans" = 'quit' ] && my_exit
}

#------------------------------------------------------------------------------
# Display a 2-Column table (version, date) of a list of kernels
#------------------------------------------------------------------------------
show_kernel_2() {
    local title=$1  list=$2  ifs=${3:-$K_IFS}  orig_ifs=$IFS
    IFS=$ifs

    [ "$title" ] && echo "$m_co$title$nc_co"

    # Get field widths
    local  f1 f2 f3  w1=5
    while read f1 f2 f3; do
        [ $w1 -lt ${#f1} ] && w1=${#f1}
    done<<Widths
$(echo "$list")
Widths

    local  fmt=" $version_co%-${w1}s $date_co%s$nc_co\n"
    local hfmt=" $hfmt_co%-${w1}s %s$nc_co\n"
    printf "$hfmt" $"Version" $"Date"
    while read  f1 f2 f3; do
        printf "$fmt" "$f1" "$f3"
    done<<Print
$(echo "$list")
Print
    IFS=$orig_ifs
    echo
}

#------------------------------------------------------------------------------
# Show a 3-column table of a list of kernels (fname, version, date)
#------------------------------------------------------------------------------
show_kernel_3() {
    local title=$1  list=$2  ifs=${3:-$K_IFS} orig_ifs=$IFS
    IFS=$ifs

    [ "$title" ] && echo "$m_co$title$nc_co"

    # Get field widths
    local f1 f2 f3  w1=5 w2=5
    while read f1 f2 f3; do
        [ $w1 -lt ${#f1} ] && w1=${#f1}
        [ $w2 -lt ${#f2} ] && w2=${#f2}
    done<<Widths
$(echo "$list")
Widths

    local fmt=" $fname_co%-${w2}s $version_co%-${w1}s $date_co%-s$nc_co\n"
    local hfmt=" $hfmt_co%-${w2}s %-${w1}s %-s$nc_co\n"
    printf "$hfmt" $"File" $"Version" $"Date"
    while read f1 f2 f3; do
        printf "$fmt" "$f2" "$f1" "$f3"
    done<<Print
$(echo "$list")
Print

    IFS=$orig_ifs
    echo
}

#------------------------------------------------------------------------------
# Show a  specical 5-column list of kernels:
#  label, version, date, from-fname, to-fname
#------------------------------------------------------------------------------
kernel_stats() {
    local list=$1  ifs=${2:-$K_IFS} orig_ifs=$IFS
    IFS=$ifs

    # Get field widths
    local f1 f2 f3 f4 f5 f6 w1=5 w2=5 w3=5 w4=5 w6=5
    while read f1 f2 f3 f4 f5 f6; do
        [ ${#f1} -gt 0 ] || continue
        [ $w1 -lt ${#f1} ] && w1=${#f1}
        [ $w2 -lt ${#f2} ] && w2=${#f2}
        [ $w3 -lt ${#f3} ] && w3=${#f3}
        [ $w4 -lt ${#f4} ] && w4=${#f4}
        [ $w6 -lt ${#f6} ] && w6=${#f6}
    done<<Widths
$(echo -e "$list")
Widths

    #echo "$w1:$w4:$w6:$w2"

    local hfmt=" $hfmt_co%s %s  %s  %s %s$nc_co\n"
    local  fmt=" $lab_co%s $version_co%s  $date_co%s  $fname_co%s %s$nc_co\n"
    f1=$(lpad $w1 "")
    f4=$(rpad $w4 $"Version")
    f6=$(rpad $w6 $"Date")
    f2=$(rpad $w2 $"From")
    printf "$hfmt" "$f1" "$f4" "$f6" "$f2" $"To"

    while read f1 f2 f3 f4 f5 f6; do
        [ ${#f1} -gt 0 ] || continue
        f1=$(lpad $w1 "$f1")
        f2=$(rpad $w2 "$f2")
        f4=$(rpad $w4 "$f4")
        f6=$(rpad $w6 "$f6")
        printf "$fmt" "$f1" "$f4" "$f6" "$f2" "$f3"
    done<<Print
$(echo -e "$list")
Print

    IFS=$orig_ifs
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
    local noco=$1  loco=$2

    local e=$(printf "\e")
     black="$e[0;30m";    blue="$e[0;34m";    green="$e[0;32m";    cyan="$e[0;36m";
       red="$e[0;31m";  purple="$e[0;35m";    brown="$e[0;33m"; lt_gray="$e[0;37m";
   dk_gray="$e[1;30m"; lt_blue="$e[1;34m"; lt_green="$e[1;32m"; lt_cyan="$e[1;36m";
    lt_red="$e[1;31m"; magenta="$e[1;35m";   yellow="$e[1;33m";   white="$e[1;37m";
     nc_co="$e[0m";

     hfmt_co=$white;
    fname_co=$lt_green;  date_co=$lt_cyan;  lab_co=$lt_blue; version_co=$magenta;
    cheat_co=$white;      err_co=$red;       hi_co=$white;     quest_co=$lt_green;
      cmd_co=$white;     from_co=$lt_green;  mp_co=$magenta;     num_co=$magenta;
      dev_co=$magenta;   head_co=$yellow;     m_co=$lt_cyan;      ok_co=$lt_green;
       to_co=$lt_green;  warn_co=$yellow;  bold_co=$yellow;
}

#------------------------------------------------------------------------------
# These are designed to "quote" strings with colors so there is always a
# leading color, all the args, and then a trailing color.  This is easier and
# more compact that using colors as strings.
#------------------------------------------------------------------------------
pq()  { echo "$hi_co$*$m_co"           ;}
pqw() { echo "$warn_co$*$hi_co"        ;}
pqe() { echo "$hi_co$*$err_co"         ;}
pqh() { echo "$m_co$*$hi_co"           ;}
bq()  { echo "$yellow$*$m_co"          ;}
cq()  { echo "$cheat_co$*$m_co"        ;}
nq()  { echo "$num_co$*$m_co"          ;}

#------------------------------------------------------------------------------
# Intended to add colors to menus used by my_select_2() menus.
#------------------------------------------------------------------------------
colorize_menu() {
    sed -r -e "s/(^| )([0-9]+)\)/\1$quest_co\2$white)$lt_cyan/g" \
        -e "s/\(([^)]+)\)/($white\1$lt_cyan)/g" -e "s/$/$nc_co/"
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
    printf "$fmt\n" "$@" | strip_color >> $LOG_FILE
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
    printf "$fmt\n" "$@" | strip_color >> $LOG_FILE
    printf "$m_co$fmt$nc_co\n" "$@"
    pipe_up "info: $fmt" "$@"
}

#------------------------------------------------------------------------------
# Like Msg() but in bold
#------------------------------------------------------------------------------
shout() {
    local fmt=$1 ; shift
    printf "$fmt\n" "$@" | strip_color >> $LOG_FILE
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
    printf "${err_co}Fatal error:$hi_co $fmt$nc_co\n" "$@" >&2
    printf "Fatal error: $fmt\n" "$@" | strip_color >> $LOG_FILE
    fmt=$(echo "$fmt" | sed 's/\\n/ /g')
    printf "$code:$fmt\n" "$@"        | strip_color >> $ERR_FILE
    [ -n "$FATAL_QUESTION" ] && echo "Q:$FATAL_QUESTION" >> $ERR_FILE
    pipe_up "fatal: $fmt" "$@"
    FIFO_MODE=
    my_exit ${EXIT_NUM:-100}
}

#------------------------------------------------------------------------------
# Convenience routines to throw a fatal error if a variable is zero-length
# or numerically 0.
#------------------------------------------------------------------------------
fatal_z() { [ ${#1} -gt 0 ] && return; shift; fatal "$@" ;}
fatal_0() { [ $1 -ne 0    ] && return; shift; fatal "$@" ;}

#------------------------------------------------------------------------------
# Throw a warning.
#------------------------------------------------------------------------------
warn() {
    local fmt=$1 ; shift
    printf "${warn_co}Warning:$hi_co $fmt$nc_co\n" "$@" >&2
    printf "${warn_co}Warning:$hi_co $fmt$nc_co\n" "$@" | strip_color >> $LOG_FILE
    pipe_up "warn: $fmt" "$@"
}

#------------------------------------------------------------------------------
# Display a question
#------------------------------------------------------------------------------
quest() {
    local fmt=$1; shift
    printf "$quest_co$fmt$nc_co" "$@"
}

#==============================================================================
# Pipes
# (needs work)
#==============================================================================
#------------------------------------------------------------------------------
# Create the pipes (work in progress ATM)
#------------------------------------------------------------------------------
start_fifo() {
    local fifo
    my_mkdir $WORK_DIR
    FIFO_UP="$WORK_DIR/to-gui"
    FIFO_DN="$WORK_DIR/to-cli"
    for fifo in $FIFO_UP $FIFO_DN; do
        mkfifo "$fifo"   || fatal "Could not create fifo ''" "$fifo"
    done
}

#------------------------------------------------------------------------------
# send a message through one pipe
#------------------------------------------------------------------------------
pipe_up() {
    [ "$FIFO_MODE" ] || return
    local fmt=$1 ; shift
    if [ ${#FIFO_UP} -gt 0 ] && test -p "$FIFO_UP" ; then
        printf "$fmt\n" "$@" | strip_color > $FIFO_UP
    else
        exit 117
    fi
}

#------------------------------------------------------------------------------
# Read a message from the other pipe
#------------------------------------------------------------------------------
pipe_dn() {
    name=$1
    [ "$FIFO_MODE" ] || return
    read $name < $FIFO_DN
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
    local msg=$"One or more partitions on device %s are mounted at"
    force umount || yes_NO_fatal "umount" \
        $"Do you want those partitions unmounted?" \
        $"Use %s to always have us unmount mounted target partitions" \
        "$msg:\n  %s" "$dev" "$(echo $mounted)"

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
    msg=$"One or more partitions on device %s are in use at"
    mounted=$(mount | egrep "^$dev[^ ]*" | cut -d" " -f3 | grep .) || return 0
    fatal "$msg:\n  %s"  "$dev" "$(echo $mounted)"
    return 1
}

#------------------------------------------------------------------------------
# Start file locking with appropriate error messages to let someone go ahead
# if the flock program is missing
#------------------------------------------------------------------------------
do_flock() {
    file=$1  me=$2
    unset FLOCK_FAILED

    if which flock &> /dev/null; then
        exec 18> $file
        flock -n 18 || fatal 101 $"A %s process is running.  If you think this is an error, remove %s" "$me" "$file"
        echo $$ >&18
        return
    fi

    force flock && return

    yes_NO_fatal "flock" \
        $"Do you want to continue without locking?" \
        $"Use %s to always ignore this warning"     \
        $"The %s program was not found." "flock"

    FLOCK_FAILED=true
}

#------------------------------------------------------------------------------
# Create a temp file from the current program between "#= BEGIN_CONFIG" and
# "#= END_CONFIG" and then source that file and delete it.  With those
# comments properly placed this allows us to reset the config file *after*
# sourcing it.  This allows people to change the config file with command
# line arguments.
#------------------------------------------------------------------------------
reset_conf() {
    local temp_file=$(mktemp /tmp/$ME-config-XXXXXX) \
        || fatal $"Could not make a temporary file under %s" "/tmp"

    sed -rn "/^#=+\s*BEGIN_CONFIG/,/^#=+\s*END_CONFIG/p" "$0" > $temp_file
    source $temp_file
    rm -f $temp_file || fatal $"Could not remove temporary file %s" "$temp_file"
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
    cut -d" " -f2 /proc/mounts | grep -q "^$(readlink -f $file)$"
    return $?
}

#------------------------------------------------------------------------------
# Needs a better name.  Requires all the programs on the list to be on the PATH
# or use returns false and says it is Skipping $stage.
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
    test -d "$dir" || fatal $"Directory %s does not exist" "$dir"
    local temp=$(mktemp -p $dir 2> /dev/null) || return 1
    rm -f "$temp"
    return 0
}

#------------------------------------------------------------------------------
# A nice wrapper around is_writable()
#------------------------------------------------------------------------------
check_writable() {
    local dir=$1  type=$2
    test -e "$dir"     || fatal $"The %s directory '%s' does not exist"     "$type" "$dir"
    test -d "$dir"     || fatal $"The %s directory '%s' is not a directory" "$type" "$dir"
    is_writable "$dir" || fatal $"The %s directory '%s' is not writable"    "$type" "$dir"
}

#------------------------------------------------------------------------------
# Only used in conjunction with cmd() which does not handle io-redirect well.
# Using write_file() allows both PRETEND and BE_VERBOSE to work.
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
    is_mountpoint "$dir"              && fatal $"Directory '%s' is already a mountpoint" "$dir"
    always_cmd mkdir -p "$dir"        || fatal $"Failed to create directory '%s'" "$dir"
    always_cmd mount "$@" $dev "$dir" || fatal $"Could not mount %s at %s" "$dev" "$dir"
    is_mountpoint "$dir"              || fatal $"Failed to mount %s at %s" "$dev" "$dir"
}

#------------------------------------------------------------------------------
# Returns true on a live antiX/MX system, returns false otherwise.  May work
# correctly on other live systems but has not been tested.
#------------------------------------------------------------------------------
its_alive() {
    local root_fstype=$(sed -rn "s|^([a-z]+) / .*|\1|p" /proc/mounts | head -n1)
    case $root_fstype in
        aufs|overlay) return 0 ;;
                   *) return 1 ;;
    esac
}

its_alive_usb() {
    its_alive || return 1
    local dir=/live/boot-dev/antiX
    test -d $dir || return 1
    is_writable "$dir"
    return $?
}
#------------------------------------------------------------------------------
# Create a work directory with mktemp. Not used!  The idea was that we might
# be able to avoid some conflicts with this if flock is not available.  It
# may just be a bad idea.
#------------------------------------------------------------------------------
random_work_dir() {
    [ ${#WORK_DIR} -gt 0 ] || return
    local temp_dir=$(mktemp -d "$WORK_DIR"-XXXXXX)
    [ ${#temp_dir} -gt 0 ] \
        || fatal $"Could not create a temporary directory in '%s'" "$(dirname "$WORK_DIR")"

    WORK_DIR=$temp_dir
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
        *mmcbk*) echo  ${dev}p$num  ;;
              *) echo  ${dev}$num   ;;
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
    mkdir -p "$dir" || fatal $"Could not make directory '%s'" "$dir"
}

#------------------------------------------------------------------------------
#  Report the size of all the directories and files give in MiB.
#------------------------------------------------------------------------------
du_size() {
    du --apparent-size -scm "$@" 2>/dev/null | tail -n 1 | cut -f1
}

mounted_partitions() {
    mount | egrep "^$1[^ ]*" | cut -d" " -f3 | grep .
    return $?
}
#==============================================================================
#===== END ====================================================================
#==============================================================================
