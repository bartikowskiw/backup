#!/bin/bash
SCRIPTDIR=$( dirname "$(readlink -f "$0")" )

# CONSTANTS

ANSI_DIM="\e[2m"
ANSI_BOLD="\e[1m"
ANSI_GREEN="\e[32m"
ANSI_RED="\e[31m"
ANSI_NONE="\e[0m"

# LOAD CONFIG
[ -r "/etc/backup.conf" ] && source "/etc/backup.conf" \
|| [ -r "$SCRIPTDIR/backup.conf" ] && source "$SCRIPTDIR/backup.conf" \
|| {
    echo "Configuration not found!"
    exit 1
}

# FUNCTIONS

# Adds timestamps & color to output
echof () {
    echo -e "$ANSI_GREEN+++$ANSI_NONE $ANSI_DIM[`date`]$ANSI_NONE $ANSI_BOLD$1$ANSI_NONE"
    echo "[`date`]  $1" >> $LOG_FILE
}

# Write to stderr
# Adds timestamps & color to output,
errorf() {
    echo -e "$ANSI_BOLD$ANSI_RED!!!$ANSI_NONE $ANSI_DIM[`date`]$ANSI_NONE $ANSI_BOLD$ANSI_RED$1$ANSI_NONE" 1>&2
    echo "[`date`] ERROR: $1" >> $LOG_FILE
}

# Run command SERVER COMMAND
run_command() {
    if [ "$1" = "" ] ; then
        eval $2
    else
        ssh "$1" "$2" 2> /dev/null
    fi
}

# Start backup
backup() {
    local name="[No name]"
    local src=""
    local dst=""
    local last_dest=""
    local options=$RSYNC_DEFAULT_OPTIONS
    local error=""
    local error_code=0
    local initial_run=1
    
    # Load config
    source $1
    
    # Split src and dst
    local src_server=$(echo "$src" | grep ":" | egrep -o "^[^:]*")
    local src_dir=$(echo "$src" | egrep -o "[^:]*$")
    
    local dst_server=$(echo "$dst" | grep ":" | egrep -o "^[^:]*")
    local dst_dir=$(echo "$dst" | egrep -o "[^:]*$")
    
    echof "Starting job \"$name\""
    
    echof "  Source: $src_server $src_dir"
    echof "  Destination: $dst_server $dst_dir"
    
    # Check source dir
    run_command "$src_server" "test -d \"$src_dir\" && test -r \"$src_dir\" && test -x \"$src_dir\""
    [ $? -eq 0 ] || {
        errorf "  Configuration error: Source $src_server$src_dir is invalid."
        exit 1
    }
    
    # Check dest dir
    run_command "$dst_server" "test -d \"$dst_dir\" && test -w \"$dst_dir\" && test -x \"$dst_dir\""
    [ $? -eq 0 ] || {
        errorf "  Configuration error: Destination $dst_server$dst_dir is invalid."
        exit 1
    }
    
    # Checks if the "current" symlink exists,
    # and adds the last_dest option
    run_command "$dst_server" "test -L \"$dst_dir/current\""
    [ $? -eq 0 ] || { initial_run=0; }
    if [ $initial_run -eq 0 ] ; then
        echof "  \"$dst_dir/current/\" does not exist. First run."
        error=$(rsync $options "$src" "$dst/$TIMESTAMP.incomplete" 2>&1 >> $RSYNC_LOG)
    else
        # Start rsync, just grab the sterr output
        error=$(rsync $options --link-dest="$dst_dir/current/" "$src" "$dst/$TIMESTAMP.incomplete" 2>&1 >> $RSYNC_LOG)
    fi
    
    # Check rsync exit code
    if [ $? -ne 0 ] ; then
    
        errorf "  Job \"$name\" failed"
        errorf "  $error"
        
        # Quit, if configuration says so
        [ $QUIT_ON_ERROR -ne 0 ] && {
            echof "BACKUP FAILED"
            echo >> $LOG_FILE
            exit 1
        }
        
    else
        # Remove ".incomplete" ending from the folder name
        run_command "$dst_server" "mv \"$dst_dir/$TIMESTAMP.incomplete\" \"$dst_dir/$TIMESTAMP\""
        [ $? -eq 0 ] || {
            errorf "Could move \"$dst_dir/$TIMESTAMP.incomplete\" to \"$dst_dir/$TIMESTAMP\"."
            echof "BACKUP FAILED"
            echo >> $LOG_FILE
            exit 1
        }
        
        # Hard link a folder with today's date
        # as name to the "current" folder
        run_command "$dst_server" "rm -f \"$dst_dir/current\"; ln -s \"$dst_dir/$TIMESTAMP\" \"$dst_dir/current\""
        [ $? -eq 0 ] || {
            errorf "Could not (soft) link \"$dst_dir/$TIMESTAMP\" to \"$dst_dir/current\"."
            echof "BACKUP FAILED"
            echo >> $LOG_FILE
            exit 1
        }
        
        # We are done
        echof "  Job \"$name\" finished"
    fi
}

#
# HEAD
#

echof "STARTING BACKUP"

if [ -z $1 ] ; then
    # Find jobs
    JOBS=( $(find -L "./jobs-active.d" -type f | grep "\.$JOB_EXT\$") )
    [ ${#JOBS[@]} -ne 0 ] || {
        errorf "No jobs found in \"$JOB_DIR\"!"
        exit 1;
    }
    echof "${#JOBS[@]} job(s) found."
else
    [ -r $1 ] || {
        errorf "Invalid config file: \"$1\""
        exit 1
    }
    JOBS=( $1 )
fi


# Execute them!
for JOB in "${JOBS[@]}" ; do
    backup $JOB
done

# We are done!
echof "BACKUP FINISHED"

# Just add a new line on the end of the log entries
echo >> $LOG_FILE
