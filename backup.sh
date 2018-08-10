#!/bin/bash
SCRIPTDIR=$( dirname "$(readlink -f "$0")" )
CONFDIRS=( "$SCRIPTDIR/conf" "/etc/backup" )

# CONSTANTS

ANSI_DIM="\e[2m"
ANSI_BOLD="\e[1m"
ANSI_GREEN="\e[32m"
ANSI_RED="\e[31m"
ANSI_NONE="\e[0m"

# LOAD DEFAULT CONFIG
if [ -r "$SCRIPTDIR/conf/backup.default.conf" ] ; then
    source "$SCRIPTDIR/conf/backup.default.conf"
else
    echo "Default configuration not found or not readable!"
    echo "Expected to find it here: $SCRIPTDIR/conf/backup.default.conf"
    exit 1
fi

# LOAD CONFIG

CONF_NOT_FOUND=1
for CONFDIR in ${CONFDIRS[@]} ; do
    if [ -r "$CONFDIR/backup.conf" ] ; then
        source "$CONFDIR/backup.conf"
        CONF_NOT_FOUND=0
        break
    fi
done

[ $CONF_NOT_FOUND -eq 1 ] && {
    echo "Configuration not found!"
    echo "Searched in: ${CONFDIRS[@]}"
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

# Write to stderr and exit
exitf() {
    errorf "$1"
    exit 1
}

# Checks if script is running already
lock() {

    [ -w $(dirname $FLOCK_FILE)  ] || exitf "File lock $FLOCK_FILE file not writeable!"
    eval "exec $FLOCK_FD>$FLOCK_FILE"
    flock -n $FLOCK_FD \
        && return 0 \
        || return 1
}

# Run command SERVER COMMAND
run_command() {
    if [ "$1" = "" ] ; then
        eval $2
    else
        ssh "$1" "$2" 2> /dev/null
    fi
}

# Look for not readable files and create a file with a list of them
nr() {
    src_server=$1
    src_dir=$2

    [ -w $(dirname $NR_FILE)  ] || exitf "File lock $NR_FILE file not writeable!"
    run_command "$src_server" "find '$src_dir' ! -readable -and \( -type f -or -type d \) -printf '%P\n' 2>/dev/null"  > $NR_FILE
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
    local args=""
    local retries=$RETRIES_ON_ERROR
    local sleep_after_error=$SLEEP_ON_ERROR

    # Load config
    source $1

    # Create escaped name
    local name_escaped=$( echo "$name" | sed 's/[^a-z0-9]/_/gi' )

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
    else
        # Start rsync, just grab the sterr output
        options="$options --link-dest=\"$dst_dir/current/\""
    fi

    # Create non-readable files (and directories) list
    if [[ $NR ]]; then
        echof "  Looking for non-readable files and directories..."
        nr "$src_server" "$src_dir"
        nr_count=$( wc -l $NR_FILE | grep -o --color=never "[0-9]*" )
        if [[ $nr_count > 0 ]]; then
            echof "  Found $nr_count not readable item, see /tmp/${name_escaped}.backup.nr"
            cp "$NR_FILE" "/tmp/${name_escaped}.backup.nr"
            options="$options --exclude-from=\"$NR_FILE\""
        else
            echof "    Perfect. None found"
        fi
    fi

    # Combine all rsync options
    args="$options \"$src\" \"$dst/$TIMESTAMP.incomplete\""

    # Run!
    while true ; do

        error=$(eval "rsync $args 2>&1 >> $RSYNC_LOG")
        error_code=$?

        # Check rsync exit code
        if [ $error_code -ne 0 ] ; then
            errorf "  Job \"$name\" failed. (Rsync error code $error_code)."
            errorf "  $error"
            if [ $retries -gt 0 ] ; then
                echof "  $retries retries left. Waiting for $sleep_after_error seconds."
                sleep $sleep_after_error
                # Update values
                sleep_after_error=$(( $sleep_after_error * 2 ))
                retries=$(($retries-1))
            else
                errorf "  Giving up."
                break
            fi

        else
            # Exit loop if everything is okay
           break
        fi

    done

    # Remove not-readable files list
    rm -f "$NR_FILE"

    # Quit, if configuration says so
    [ $error_code -ne 0 ] && [ $QUIT_ON_ERROR -ne 0 ] && {
        echof "BACKUP FAILED"
        echo >> $LOG_FILE
        exit 1
    }

    if [ $error_code -eq 0 ] ; then

        # Remove ".incomplete" ending from the folder name
        run_command "$dst_server" "mv \"$dst_dir/$TIMESTAMP.incomplete\" \"$dst_dir/$TIMESTAMP\""
        [ $? -eq 0 ] || {
            errorf "Could not move \"$dst_dir/$TIMESTAMP.incomplete\" to \"$dst_dir/$TIMESTAMP\"."
            echof "BACKUP FAILED"
            echo >> $LOG_FILE
            exit 1
        }

        # Hard link a folder with today's date
        # as name to the "current" folder
        run_command "$dst_server" "cd \"$dst_dir/\"; ln -nfs \"$TIMESTAMP\" \"current\""
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

# Check lock
lock || {
    errorf "Script already running. Quitting"
    exit 1
}

# Start
echof "STARTING BACKUP"

if [ -z $1 ] ; then
    # Find jobs
    JOBS=( $(find -L "$JOB_DIR" -type f | grep "\.$JOB_EXT\$") )
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
