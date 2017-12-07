# Backup

rsync based incremental backups.

## General information

The script creates folders with the date as name. The newest
backup is symlinked to the folder "current". Duplicate files
get hard linked. So they do not use up disk space (except for
the link information and directory structure).

## Configuration

The general configuration is saved in backup.conf. Adjust
the paths as needed.

### Example job

```sh
# Name of the job. Mainly for logging purposes
name="Example. Backups the home directory."

# Source and destination. Use absolute paths.
# Use [servername]:[path] for remote sources 
# and/or destinations
src="/home/username/"
dst="ssh_host:/home/username/backup"
```

## Run!

To run all defined jobs execute ```backup.sh```. If you want
to run one particular job run ```backup.sh /path/to/job.conf```.