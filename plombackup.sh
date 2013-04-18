#/bin/bash

# Abort with cleaning up if any foreseen error occurs.

function exitclean {
  echo 'Cleaning up.'
  if [[ 1 == $ISMOUNTED ]]; then
    echo "Unmounting: $MOUNT"
    umount $MOUNT
  fi
  if [[ 1 == $ISMAPPED ]]; then
    echo "Closing crypto container: $MAPPING"
    cryptsetup luksClose $MAPPING
  fi
  if [[ 1 == $BUILDMOUNTDIR ]]; then
    echo "Removing: $MOUNT"
    rmdir $MOUNT
  fi
  echo 'Finished.'
  exit
}

# Abort verbosely about cleaning up possibilities if any unforeseen error occurs.

function exitwarning {
  echo "Error occured. Aborting."
  if [[ 1 == $ISMOUNTED ]]; then
    echo "Still to be unmounted: $MOUNT (try 'umount $MOUNT')"
  fi
  if [[ 1 == $ISMAPPED ]]; then
    echo "Crypto container still to be closed: $MAPPING (try 'cryptsetup luksClose $MAPPING')"
  fi
  if [[ 1 == $BUILDMOUNTDIR ]]; then
    echo "Mount dir $MOUNT was created by script, could be deleted (try 'rmdir $MOUNT')"
  fi
  exit
}
trap exitwarning ERR

# First check on command parameters.

MOUNT=/mnt/secret
DIRLIST=$1
BACKUPDEVICE=$2
BACKUPDIR=$MOUNT/$3
if [[ ! $DIRLIST || ! -f $DIRLIST ]]; then
  echo 'File containing a list of files/directories not found.'
  echo 'Usage: plombackup.sh dirlist_file backup_device_path backup_dir_on_backup_device'
  exit
fi
echo "Using list of files/directories to back up: $DIRLIST"
if [[ ! $BACKUPDEVICE ]]; then
  echo 'No backup device declared. Aborting.'
  echo 'Usage: plombackup.sh dirlist_file backup_device_path backup_dir_on_backup_device'
  exit
fi
echo "Using as backup device: $BACKUPDEVICE"
if [[ $3 == "" ]]; then
  echo 'No directory to back up to named. Aborting.'
  echo 'Usage: plombackup.sh dirlist_file backup_device_path backup_dir_on_backup_device'
  exit
fi
echo "Using as backup directory: $BACKUPDIR"

# Ensure valid mount directory.

BUILDMOUNTDIR=0
if [[ ! -d $MOUNT ]]; then
  mkdir $MOUNT
  echo "Building: $MOUNT"
  BUILDMOUNTDIR=1
fi
if [[ 0 == `mountpoint $MOUNT > /dev/null; echo $?` ]]; then
  echo "$MOUNT is already a mountpoint. Aborting."
  exit
fi

# Open encrypted device, mount filesystem.

ISMAPPED=0
ISMOUNTED=0
MAPPING=secret
if [[ -f /dev/mapper/$MAPPING ]]; then
   echo "/dev/mapper/$MAPPING already exists. Aborting."
   exit
fi
echo "Opening $BACKUPDEVICE into '$MAPPING' crypto container, mounting to $MOUNT"
cryptsetup luksOpen $BACKUPDEVICE $MAPPING
ISMAPPED=1
mount /dev/mapper/$MAPPING $MOUNT
ISMOUNTED=1
TEMP=$MOUNT/temp

# Check whether there is enough space left on the backup device.

SPACELEFT=`df /dev/mapper/$MAPPING | tail -1 | awk '{ print $4 }'`
printf "Space left on %s:   %10s kb.\n" $BACKUPDEVICE $SPACELEFT
SPACENEEDED=0
while read LINE; do
    SIZE=`du -s $LINE | awk '{ print $1 }'`
    SPACENEEDED=`expr $SPACENEEDED + $SIZE`
done < "$DIRLIST"
printf "Space needed on %s: %10s kb.\n" $BACKUPDEVICE $SPACENEEDED
if [[ `expr $SPACELEFT - $SPACENEEDED` -le 0 ]]; then
  echo "Not enough space left on $BACKUPDEVICE -- aborting."
  exitclean
fi

# Check for suspiciously pre-existing directories on backup filesystem.

if [[ -d $TEMP ]]; then
  echo 'Suspicious temp dir found. Aborting.'
  exitclean
fi
if [[ -d $BACKUPDIR ]]; then
  echo "Backup directory $BACKUPDIR already exists. Overwrite? y/n"
  read ANSWER
  FIRSTCHARANSWER=`echo $ANSWER | head -c 1`
  if [[ ! $FIRSTCHARANSWER == 'y' && ! $FIRSTCHARANSWER == 'Y' ]]; then
    echo 'Aborting.'
    exitclean
  fi
fi

# Back up to temp dir first. Take care of (improbable) situation that a lastupdate file is backed up too.

echo "Copying everything to $TEMP first."
mkdir $TEMP
echo 'Last update: '`date` > $TEMP/lastupdate
while read LINE; do
  if [[ $LINE == 'lastupdate' ]]; then
    echo 'File lastupdate already exists. Overwrite? y/n'
    read ANSWER
    FIRSTCHARANSWER=`echo $ANSWER | head -c 1`
    if [[ ! $FIRSTCHARANSWER == 'y' && ! $FIRSTCHARANSWER == 'Y' ]]; then
      echo 'Aborting.'
      exitclean
    fi
  fi
  cp -R $LINE $TEMP
done < "$DIRLIST"

# After moving temp dir to backup dir proper, compare result with original (backed-up) file tree.

echo "Moving $TEMP to $BACKUPDIR"
mv $TEMP $BACKUPDIR
echo 'Comparing original and copy.'
DIFFSFOUND=0
while read LINE; do
  FILELIST=`find $LINE -type f`
  CMPFILELIST=`find $BACKUPDIR/$LINE -type f`
  NUMORIG=`echo "$FILELIST" | wc -l`
  NUMCOPY=`echo "$CMPFILELIST" | wc -l`
  if [[ ! $NUMORIG == $NUMCOPY ]]; then
    DIFFSFOUND=1
    echo "Number of files does not match between $LINE/ and $BACKUPDIR/$LINE/"
  fi
  OLDIFS=$IFS
  IFS="
"
  for FILENAME in $FILELIST; do
    trap - ERR
    DIFF=`cmp $FILENAME $BACKUPDIR/$FILENAME 2>&1`
    trap exitwarning ERR
    if [[ ! $DIFF == "" ]]; then
      DIFFSFOUND=1
      echo $DIFF
    fi
  done
  IFS=$OLDIFS
  if [[ $DIFFSFOUND == 1 ]]; then
    echo "$LINE: WARNING! Found differences between original and copy."
  else
    echo "$LINE: No byte differences found between original and copy. Everything's fine!"
  fi
done < "$DIRLIST"

exitclean
