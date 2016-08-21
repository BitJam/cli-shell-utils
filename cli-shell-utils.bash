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

: ${ME:=${0##*/}}
: ${MY_DIR:=$(dirname "$(readlink -f $0)")}

: ${DATE_FMT:=%Y-%m-%d %H:%M}
: ${DEFAULT_USER:=1000}
: ${K_IFS:=|}
: ${P_IFS:=&}
: ${MAJOR_SD_DEV_LIST:=3,8,22,179,259}
: ${MAJOR_SR_DEV_LIST:=11}
: ${LIVE_MP:=/live/boot-dev}
: ${MIN_ISO_SIZE:=180M}
: ${MENU_PATH:=/usr/local/share/text-menus/}
: ${MIN_LINUXFS_SIZE:=120M}
: ${CONFIG_FILE:=/root/.config/$ME/$ME.conf}

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
    quest "Press <%s> to continue " "$(pqq $Enter)"
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
# Works like cmd() below but ignores the $PRETEND_MODE variable.  This can be
# useful  if you want to always run a command but also want to record the call.
#------------------------------------------------------------------------------
always_cmd() { PRETEND_MODE= cmd "$@" ;}

#------------------------------------------------------------------------------
# Always send the command line and all output to the log file.  Set the log
# file to /dev/null to disable this feature.  If BE_VERBOSE then also echo
# the command line to the screen.  If PRETEND_MODE then don't actually run
# the command.
#------------------------------------------------------------------------------
cmd() {
    echo " > $*" >> $LOG_FILE
    [ "$BE_VERBOSE"   ] && echo " >" "$@" | sed "s|$WORK_DIR|.|g"
    [ "$PRETEND_MODE" ] && return 0
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
        quit="$quit_co$quit"

        local menu def_entry
        case $def_entry in
            1) menu=$(printf "  1) $yes ($default)\n  2) $no\n") ;;
            2) menu=$(printf "  1) $yes\n  2) $no (default)\n")  ;;
            *) fatal "Internal error in _yes_no()"               ;;
        esac

        [ "$NO_QUIT" ] || menu="$menu  0) $quit\n"
        local data=$(printf "1:1\n2:2\n0:0")
        my_select_2 answer "$quest_co$question$nc_co" $def_entry "$data" "$menu\n"
    fi

    case $answer in
        1) return 0 ;;
        2) return 1 ;;
        0) exit 0   ;;
        *) fatal "Should never get here 111" ;;
    esac
}

YES_no_pretend() {
    local question=$1 answer  orig_pretend=$PRETEND_MODE
    [ ${#question} -gt 0 ] || question=$"Shall we begin?"
    local yes=$"yes"  no=$"no"  pretend=$"pretend mode"
    local menu="yes$P_IFS$yes\nno$P_IFS$no\npretend$P_IFS$pretend\n"

    my_select answer "$question" "$menu"

    case $answer in
             yes) return 0 ;;
              no) return 1 ;;
         pretend) PRETEND_MODE=true ; shout_pretend ; return 0 ;;
               *) fatal "Internal error in YES_no_pretend()"   ;;
        esac
}

shout_pretend() { [ "$PRETEND_MODE" ] && Shout $"PRETEND MODE ENABLED" ;}

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

        if [ "$datum" = "quit" ]; then
            dcnt=0
            label="$quit_co$label$nc_co"
        fi

        [ $dcnt = "$default" ] && label=$(printf "%s (%s)" "$label" "$m_co$(cq "default")")

        data="${data}$dcnt:$datum\n"
        menu="${menu}$(printf "$quest_co%3d$hi_co)$m_co %${width}s" $dcnt "$label")\n"

        cnt=$((cnt+1))
    done<<My_Select
$(echo -e "$list")
My_Select

    IFS=$orig_ifs
    my_select_2 $var "$title" "$default" "$data" "$menu" "$def_str"
}

#------------------------------------------------------------------------------
# Same as my_select but with a "quit" entry added to bottom of the menu
#------------------------------------------------------------------------------
my_select_quit() {
    if [ "$NO_QUIT" ]; then
        my_select "$@"
        return
    fi
    local var=$1  title=$2  menu=$3  def_str=$4
    menu=$(printf "%s\nquit$P_IFS%s\n" "$menu" $"quit")
    local ans
    my_select ans "$title" "$menu" "$def_str"
    [ "$ans" = "quit" ] && my_exit
    eval $var=\$ans
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

    local man_page="$MY_DIR/$ME.1"

    if [ -n "$def_str" ]; then
        def_str="($(pqq $def_str))"
    else
        def_str="selection"
    fi

    local p2 have_man def_prompt=$(printf $"Press <%s> for the default %s" "$(pqq $"Enter")" "$def_str")

    if test -r "$man_page"; then
        have_man=true
        p2=$(printf $"Use '%s' for help.  Use '%s' to quit" "$(pqq h)" "$(pqq q)")
    else
        p2=$(printf $"Use '%s' to quit" "$(pqq q)")
    fi

    echo

    local val input_1 input err_msg
    while [ -z "$val" ]; do

        echo -e "$quest_co$title$nc_co"

        echo -en "$menu" | colorize_menu
        [ "$err_msg" ] && printf "$err_co%s$nc_co\n" "$err_msg"
        [ "$default" ] && printf "$m_co%s$nc_co\n" "$quest_co$def_prompt$nc_co"
        [ "$p2" ]      && quest "$p2\n"
        # quest "> "

        read -n1 input_1
        err_msg=
        if [ ${#input_1} -eq 0 ]; then
            input=$input_1
        elif [ "$input_1" = "q" ]; then
            final_quit
            continue
        elif [ -n "$have_man" -a "$input_1" = "h" ]; then
            man "$man_page"
            continue
        else
            echo -ne "\b"
            read -ei "$input_1" input
        fi

        # Evaluate again in case of backspacing
        case $input in
            q*) final_quit ; continue ;;
            h*) [ "$have_man" ] && man "$man_page" ; continue ;;
        esac

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
            err_msg=$(printf $"The number '%s' is out of range" "$(pqe $input)")
            continue
        fi
        # FIXME!  is this always right?
        [ "$val" = "default" ] && val=
        eval $var=\$val
        break
    done
}

#------------------------------------------------------------------------------
# The final quit menu after a 'q' has been detected
#------------------------------------------------------------------------------
final_quit() {
    local input
    echo
    quest $"Press '%s' again to quit " "$(pqq q)"
    read -n1 input
    echo
    [ "$input" = "q" ] && my_exit
}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
cli_text_menu() {
    local dir=$MENU_DIR
    local var=$1  name=$2  title=$3  blurb=$4  text_menu_val
    local dfile="$dir/$name.data"  mfile="$dir/$name.menu"

    local file
    for file in "$dfile" "$mfile"; do
        [ -r "$file" ] && continue
        warn "Missing file %s" "$file"
        return
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

    my_select_quit $var "$title" "$menu"
    return 0
}

#------------------------------------------------------------------------------
#
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

cli_search_file() {
    local var=$1  spec=$2  dir_list=$3  max_depth=$4  max_found=${5:-20}  min_size=${6:-$MIN_ISO_SIZE}

    local _sf_input title dir_cnt invalid
    while true; do
        dir_list=$(expand_directories $dir_list)
        dir_cnt=$(echo "$dir_list" | wc -w)

        title=$(
        if [ $dir_cnt -eq 1 ]; then
            quest $"Will search %s directory: %s\n"                          "$(pnq $dir_cnt)"   "$(pqq $dir_list)"
        else
            quest $"Will search %s directories: %s\n"                        "$(pnq $dir_cnt)"   "$(pqq $dir_list)"
        fi
            quest $"for files matching '%s' with a size of %s or greater\n"  "$(pqq $spec)"      "$(pq $min_size)"
            quest $"Will search down %s directories"                         "$(pqq $max_depth)"
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

        my_select_quit _sf_input "$title" "$(select_file_menu $invalid)"
        invalid=

        # FIXME: need to make some of these entries more specfic
        case $_sf_input in
            search) ;;
              dirs) cli_get_text dir_list  "Enter directories"          ; continue ;;
             depth) cli_get_text max_depth "Enter maximum depth (1-9)"  ; continue ;;
              spec) cli_get_text spec      "Enter file specfication"    ; continue ;;
        esac

        local depth=1 dir f found found_cnt
        echo -n "depth:"
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
#
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
#
#------------------------------------------------------------------------------
_file_date() { date "+${DATE_FMT#+}" -d @$(stat -c %Y "$1") ;}
_file_size() { echo "$(( $(stat -c %s "$1") /1024 /1024))M" ;}

#------------------------------------------------------------------------------
#
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
#
#------------------------------------------------------------------------------
select_file_menu() {
    local invalid=$1
    [ "$invalid" ] || printf "%s$P_IFS%s\n" "search" "Begin search"
    printf "%s$P_IFS%s\n" "dirs"   "Change directories"
    printf "%s$P_IFS%s\n" "depth"  "Change search depth"
    printf "%s$P_IFS%s\n" "spec"   "Change file specification"
}

#------------------------------------------------------------------------------
#
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

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
cli_get_filename() {
    local var=$1  title=$2  preamb=$(sub_user_home "$3")
    local file

    while true; do
        quest "$title$nc_co\n$quest_co%s" "(tab completion is enabled)"
        read -e -i "$preamb" input
        preamb=$input
        if ! test -f "$file"; then
            warn "%s does not appear to be a file" "$file"
            YES_no "Try again?" && continue
        fi
        quest $"You entered: %s" "$(cq "$input")"
        YES_no $"Is this correct?" && break
    done
    eval $var=\$input
}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
cli_live_usb_src_menu() {
    local exclude=$1
    local dev_width=$(get_lsblk_field_width name --include="$MAJOR_SD_DEV_LIST,$MAJOR_SR_DEV_LIST")

    local live_dev
    if its_alive; then
        live_dev=$(get_live_dev)
        is_mountpoint $LIVE_MP && printf "clone$P_IFS%s (%s)\n" $"Clone this live system" "$(pq $live_dev)"
    fi

    printf "iso-file$P_IFS%s\n" $"Copy from an ISO file"
    menu=$(cli_cdrom_menu $dev_width "dev=" ; cli_partition_menu $dev_width "clone=" $live_dev $exclude)
    if [ $(count_lines "$menu") -gt 0 ]; then
        local fmt="$P_IFS$head_co%-${dev_width}s %6s %8s %-16s %s$nc_co\n"
        printf "$fmt" "dev" $"size" $"fstype" $"label" $"model"
        echo -e "$menu"
    fi
}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
cli_cdrom_menu() {
    local dev_width=${1:-4}  prefix=$2
    local opts="--nodeps --include=$MAJOR_SR_DEV_LIST"
    local fmt="%s$P_IFS$dev_co%-${dev_width}s$num_co %6s$bold_co %8s$lab_co %-16s$nc_co %-16s\n"
    local model=$(bq cd/dvd disc)
    local NAME SIZE FSTYPE LABEL
    while read line; do
        eval "$line"
        [ ${#LABEL} -gt 0 ] || continue
        printf "$fmt" "$prefix$NAME" "$NAME" "$SIZE" "$FSTYPE" "$LABEL" "$model"
    done<<Cdrom_Menu
$(lsblk -no name,size,fstype,label --pairs $opts)
Cdrom_Menu
}

#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
cli_partition_menu() {
    local dev_width=$1  preamb=$2 exclude=$(get_drive ${3##*/}) exclude2=$(get_drive ${4##*/})
    local dev_list=$(lsblk -lno name --include="$MAJOR_SD_DEV_LIST")
    local fmt="$preamb%s$P_IFS$dev_co%-${dev_width}s$num_co %6s$bold_co %8s$lab_co %-16s$nc_co %16s\n"
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
            printf "$fmt" "$part" "$part" "$SIZE" "$FSTYPE" "$(rpad 16 "$label")" "$(echo $dev_info)"
        done
    done
}

#------------------------------------------------------------------------------
#
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
#
#------------------------------------------------------------------------------
check_md5() {
    local file=$1 md5_file="$1.md5"
    test -f "$md5_file" || return
    yes_NO $"Check md5 of the file %s?" "$(basename "$file")" || return
    Msg $"Checking md5 ..."
    (cd "$(dirname "$md5_file")" && md5sum -c "$(basename "$md5_file")") && return
    yes_NO $"Keep going anyway?" || my_exit
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
    local title=$1 var=$2 list=$3  ifs=${4:-$K_IFS} orig_ifs=$IFS
    IFS=$ifs

    # Get field widths
    local f1 f2 f3  w1=5
    while read f1 f2 f3; do
        [ $w1 -lt ${#f1} ] && w1=${#f1}
    done<<Widths
$(echo "$list")
Widths

    local fmt="$version_co%-${w1}s $date_co%s$nc_co\n"
    local hfmt="$head_co%-${w1}s %s$nc_co\n"
    local data="$P_IFS$(printf "$hfmt" $"Version" $"Date")\n"

    local payload
    while read f1 f2 f3; do
        [ ${#f1} -gt 0 ] || continue
        payload="$f1$IFS$f2$IFS$f3"
        data="$data$payload$P_IFS$(printf "$fmt" "$f1" "$f3")\n"
    done<<Print
$(echo "$list")
Print

    IFS=$orig_ifs

    my_select_quit $var "$title" "$data"
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

    local fmt="$fname_co%-${w2}s $version_co%-${w1}s $date_co%-s$nc_co"
    local hfmt="$head_co%-${w2}s %-${w1}s %-s$nc_co\n"
    local data="$P_IFS$(printf "$hfmt" $"File" $"Version" $"Date")\n"
    local payload
    while read f1 f2 f3; do
        [ ${#f1} -gt 0 ] || continue
        payload="$f1$IFS$f2$IFS$f3"
        data="$data$payload$P_IFS$(printf "$fmt" "$f2" "$f1" "$f3")\n"
    done<<Print
$(echo "$list")
Print

    IFS=$orig_ifs

    my_select_quit $var "$title" "$data" "$menu"
}

#------------------------------------------------------------------------------
# Display a 2-Column table (version, date) of a list of kernels
#------------------------------------------------------------------------------
show_kernel_2() {
    local title=$1  list=$2  ifs=${3:-$K_IFS}  orig_ifs=$IFS
    IFS=$ifs

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
    local hfmt=" $head_co%-${w1}s %s$nc_co\n"
    printf "$hfmt" $"Version" $"Date"
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
    local title=$1  list=$2  ifs=${3:-$K_IFS} orig_ifs=$IFS
    IFS=$ifs

    echo
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
    local hfmt=" $head_co%-${w2}s %-${w1}s %-s$nc_co\n"
    printf "$hfmt" $"File" $"Version" $"Date"
    while read f1 f2 f3; do
        [ ${#f1} -gt 0 ] || continue
        printf "$fmt" "$f2" "$f1" "$f3"
    done<<Print
$(echo "$list")
Print

    IFS=$orig_ifs
}

#------------------------------------------------------------------------------
# Show a  specical 5-column list of kernels:
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

    local version=$"Version" date=$"Date"  from=$"From"  to=$"To"
    local w1=5  w2=${#version}  w3=${#date}  w4=${#from}
    # Get field widths
    local f1 f2 f3 f4 f5
    while read f1 f2 f3 f4 f5; do
        [ ${#f1} -gt 0 ] || continue
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

old_kernel_stats() {
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

    local hfmt=" $head_co%s %s  %s  %s %s$nc_co\n"
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


#------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------
usb_stats() {
    local ifs=$K_IFS  orig_ifs=$IFS
    IFS=$ifs

    local list
    while [ $# -ge 4 ]; do
        list="$list$1$IFS$2$IFS$3$IFS$4\n"
        shift 4
    done

    local total=$"Total"  used=$"Used"  extra=$"Extra"
    local w1=5 w2=${#total} w3=${#used} w4=${#extra}
    # Get field widths
    local f1 f2 f3 f4
    while read f1 f2 f3 f4; do
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
    f2=$(rpad $w2 "$total")
    f3=$(rpad $w3 "$used")
    f4=$(rpad $w4 "$extra")

    printf "$hfmt" "$f1" "$f2" "$f3" "$f4"

    while read f1 f2 f3 f4; do
        [ ${#f1} -gt 0 ] || continue
        f1=$(lpad $w1 "$f1")
        f2=$(lpad $w2 "$f2")
        f3=$(lpad $w3 "$f3")
        f4=$(lpad $w4 "$f4")
        printf "$fmt" "$f1" "$f2" "$f3" "$f4"
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
    local param=${1:-high}

    case $param in
        high) ;;
         low) ;;
         off) ;;
           *) fatal color $"Unknown color parameter '%s'.  Expected high, low, or off" "$param" ;;
    esac
    local e=$(printf "\e")

    if [ "$param" = "off" ]; then

         black=  ;    blue=  ;    green=  ;    cyan=  ;
           red=  ;  purple=  ;    brown=  ; lt_gray=  ;
       dk_gray=  ; lt_blue=  ; lt_green=  ; lt_cyan=  ;
        lt_red=  ; magenta=  ;   yellow=  ;   white=  ;
         nc_co=  ;

    else

         black="$e[0;30m" ;    blue="$e[0;34m" ;    green="$e[0;32m" ;    cyan="$e[0;36m" ;
           red="$e[0;31m" ;  purple="$e[0;35m" ;    brown="$e[0;33m" ; lt_gray="$e[0;37m" ;
       dk_gray="$e[1;30m" ; lt_blue="$e[1;34m" ; lt_green="$e[1;32m" ; lt_cyan="$e[1;36m" ;
        lt_red="$e[1;31m" ; magenta="$e[1;35m" ;   yellow="$e[1;33m" ;   white="$e[1;37m" ;
         nc_co="$e[0m"    ;

    fi

         head_co=$white    ;   dev_co=$lt_green  ; quit_co=$yellow    ;
        fname_co=$white    ;  date_co=$lt_cyan   ;  lab_co=$lt_cyan   ;  version_co=$magenta   ;
        cheat_co=$white    ;   err_co=$red       ;   hi_co=$white     ;    quest_co=$lt_green  ;
          cmd_co=$white    ;  from_co=$lt_green  ;   mp_co=$magenta   ;      num_co=$magenta   ;
          dev_co=$magenta  ;     m_co=$lt_cyan   ;   ok_co=$lt_green  ;
           to_co=$lt_green ;  warn_co=$yellow    ; bold_co=$yellow    ;

    # FIXME: set more low colors!
    if [ "$param" = "low" ]; then

        from_co=$brown ;       bold_co=$white ;  dev_co=$white ;
          hi_co=$white ;    version_co=$white ;
           m_co=$nc_co ;      fname_co=$nc_co ;
         num_co=$white ;      date_co=$nc_co  ;
    fi
}

#------------------------------------------------------------------------------
# These are designed to "quote" strings with colors so there is always a
# leading color, all the args, and then a trailing color.  This is easier and
# more compact that using colors as strings.
#------------------------------------------------------------------------------
pq()  { echo "$hi_co$*$m_co"           ;}
vq()  { echo "$version_co$*$m_co"      ;}
pqq() { echo "$hi_co$*$quest_co"       ;}
pnq() { echo "$num_co$*$quest_co"      ;}
pqw() { echo "$warn_co$*$hi_co"        ;}
pqe() { echo "$hi_co$*$err_co"         ;}
pqh() { echo "$m_co$*$hi_co"           ;}
pqb() { echo "$m_co$*$bold_co"         ;}
bq()  { echo "$bold_co$*$m_co"         ;}
cq()  { echo "$cheat_co$*$m_co"        ;}
nq()  { echo "$num_co$*$m_co"          ;}

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
Shout() {
    local fmt=$1 ; shift
    printf "$fmt\n" "$@" | strip_color >> $LOG_FILE
    printf "$bold_co$fmt$nc_co\n" "$@"
}

#------------------------------------------------------------------------------
# Like msg() but in bold
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
    printf "${err_co}%s:$hi_co $fmt$nc_co\n" $"Error" "$@" >&2
    printf "Error: $fmt\n" "$@" | strip_color >> $LOG_FILE
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
    printf "${warn_co}%s:$hi_co $fmt$nc_co\n" $"Warning" "$@" >&2
    printf "${warn_co}%s:$hi_co $fmt$nc_co\n" $"Warning" "$@" | strip_color >> $LOG_FILE
    pipe_up "warn: $fmt" "$@"
}

#------------------------------------------------------------------------------
# Write an error message without exiting
#------------------------------------------------------------------------------
error() {
    local fmt=$1 ; shift
    printf "${err_co}%s:$hi_co $fmt$nc_co\n" $"Error" "$@" >&2
    printf "${err_co}%s:$hi_co $fmt$nc_co\n" $"Error" "$@" | strip_color >> $LOG_FILE
    pipe_up "error: $fmt" "$@"
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
        touch "$fifo"
        #mkfifo "$fifo"  || fatal "Could not create fifo ''" "$fifo"
    done
}

#------------------------------------------------------------------------------
# send a message through one pipe
#------------------------------------------------------------------------------
pipe_up() {
    [ "$FIFO_MODE" ] || return

    local fmt=$1 ; shift
    [ ${#FIFO_UP} -gt 0 ] && printf "$fmt\n" "$@" >> $FIFO_UP
    return


    if [ ${#FIFO_UP} -gt 0 ] && test -e "$FIFO_UP" ; then
        echo pipe_up 2
        printf "$fmt\n" "$@" | strip_color >> $FIFO_UP
    else
        exit 117
    fi
}

#------------------------------------------------------------------------------
# Read a message from the other pipe
#------------------------------------------------------------------------------
pipe_dn() {
    name=$1
    return
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
#
#------------------------------------------------------------------------------
reset_config() {
    local file=${1:-$CONFIG_FILE}
    mkdir -p $(dirname "$file") || fatal $"Could not create directory for config file"
    sed -rn "/^#=+\s*BEGIN_CONFIG/,/^#=+\s*END_CONFIG/p" "$0" \
        | egrep -v "^#=+[ ]*(BEGIN|END)_CONFIG" > $file
    msg $"Reset config file %s" "$(pq $file)"
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
        reset_config "$file"
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
    test -f "$temp" || return 1
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
    local dir=$LIVE_MP
    test -d $dir || return 1
    is_writable "$dir"
    return $?
}

get_live_dev() {
    local live_dev=$(sed -rn "s|^([^ ]+) $LIVE_MP .*|\1|p" /proc/mounts)
    echo ${live_dev##*/}
}

show_distro_version()  {
    local dir=$1
    [ ${#dir} -gt 0 ]                            || return 1
    local iso_version version_file=$dir/version
    test -r $version_file                        || return 1
    iso_version=$(cat $version_file 2>/dev/null) || return 1
    [ ${#iso_version} -gt 0 ]                    || return 1
    msg $"Distro: %s" "$(pq $iso_version)"
    return 0
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

get_user_home() {
    local user=${1:-$DEFAULT_USER}
    getent passwd $user | cut -d: -f6
}

sub_user_home() {
    local user_home=$(get_user_home)
    echo "$1" | sed "s|%USER_HOME%|$user_home|g"
}

need_root() { [ $UID -eq 0 ] || fatal 099 $"This script must be run as root" ;}

#==============================================================================
#===== END ====================================================================
#==============================================================================
