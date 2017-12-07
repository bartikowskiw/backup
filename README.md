# Backup

rsync based incremental backups.

## General information

The script creates folders with the date as name. The newest
backup is symlinked to the folder "current". Duplicate files
get hard linked. So the do not use up disk space (except for
the link information.)

Logs get saved to $LOG_FILE.

## Configuration

Set up backup jobs first. The are stored in $JOB_DIR.

### Example job

```
# Name of the job. Mainly for logging purposes
name="Example. Backups the home directory."

# Source and destination. Use absolute paths.
# Use [servername]:[path] for remote sources 
# and/or destinations
src="/home/username/"
dst="ssh_host:/home/username/backup"
```