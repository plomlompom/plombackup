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
  echo "Unforeseen error occured. Aborting WITHOUT CLEANING UP."
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

# Abort with usage info if no proper arguments given.

function exitusage {
  echo 'Usage: plombackup.sh -i DIRLIST -d BACKUPDEVICE -o BACKUPDIR [-c]
Options:
  -h                  display this help
  -i DIRLIST          set path of file to read files/dirs to backup from
  -d BACKUPDEVICE     set path of backup device
  -o BACKUPDIR        set path to backup to inside backup device filesystem
  -c                  check for corrupted copies by comparing files byte by byte'
  exit
}

# Read answer to y/n question, cleanly abort on y.

function exitquestion {
  read ANSWER
  FIRSTCHARANSWER=`echo $ANSWER | head -c 1`
  if [[ ! $FIRSTCHARANSWER == 'y' && ! $FIRSTCHARANSWER == 'Y' ]]; then
    echo 'Aborting.'
    exitclean
  fi
}

# Get and check on command parameters.

MOUNT=/mnt/secret
while getopts ':hi:d:o:c' OPT; do
  case $OPT in
    h)
      exitusage
      ;;
    i)
      DIRLIST=$OPTARG
      ;;
    d)
      BACKUPDEVICE=$OPTARG
      ;;
    o)
      BACKUPDIR=$OPTARG
      ;;
    c)
      CHECK=1
      ;;
    ?)
      echo 'Bad syntax.'
      exitusage
  esac
done
if [[ ! $DIRLIST || ! -f $DIRLIST ]]; then
  echo 'File containing a list of files/directories not found. Aborting.'
  exitusage
fi
echo "Using list of files/directories to back up: $DIRLIST"
if [[ ! $BACKUPDEVICE ]]; then
  echo 'No backup device declared. Aborting.'
  exitusage
fi
echo "Using as backup device: $BACKUPDEVICE"
if [[ $BACKUPDIR == "" ]]; then
  echo 'No directory to back up to named. Aborting.'
  exitusage
else
  BACKUPDIR=$MOUNT/$BACKUPDIR
fi
echo "Using as backup directory: $BACKUPDIR"
if [[ 1 == $CHECK ]]; then
  echo "Will check for corrupted copies."
else
  echo "Won't check for corrupted copies."
fi

# Check for lastupdate file conflict.

CHECKLASTUPDATE=`cat $DIRLIST | grep lastupdate | sed 's/ *$//g'`
if [[ 'lastupdate' == $CHECKLASTUPDATE ]]; then
  echo "$DIRLIST lists a file 'lastupdate' to back up into $BACKUPDIR, in conflict with the lastupdate file plombackup.sh is supposed to write there."
  exitclean
fi

# Check if all files/dirs to back up exist.

echo "Checking for existence of all files/dirs named in $DIRLIST."

UNFOUND=0
while read LINE; do
  if [[ ! -f $LINE && ! -d $LINE ]]; then
    UNFOUND=1
    echo "File/directory $LINE not found."
  fi
done < "$DIRLIST"
if [[ 1 == $UNFOUND ]]; then
  exitclean
fi

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
if [[ -e /dev/mapper/$MAPPING ]]; then
   echo "/dev/mapper/$MAPPING already exists. Aborting."
   exitclean
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
  echo 'Suspicious temp dir found. Delete y/n?'
  exitquestion
  rm -rf $TEMP
fi
if [[ -d $BACKUPDIR ]]; then
  echo "Backup directory $BACKUPDIR already exists. Delete? y/n"
  exitquestion
  rm -rf $BACKUPDIR
fi

# Back up to temp dir first.

echo "Copying everything to $TEMP first."
mkdir $TEMP
echo 'Last update: '`date` > $TEMP/lastupdate
while read LINE; do
  cp -R $LINE $TEMP
done < "$DIRLIST"

# After moving temp dir to backup dir proper, compare result with original (backed-up) file tree.

echo "Moving $TEMP to $BACKUPDIR"
mv $TEMP $BACKUPDIR

if [[ 1 == $CHECK ]]; then
  echo 'Comparing original and copy.'
  DIFFSFOUND=0
  while read LINE; do
    FILELIST=`find $LINE -type f | sort`
    LINEBASE=`basename $LINE`
    CMPFILELIST=`find $BACKUPDIR/$LINEBASE -type f | sort`
    NUMORIG=`echo "$FILELIST" | wc -l`
    NUMCOPY=`echo "$CMPFILELIST" | wc -l`
    if [[ ! $NUMORIG == $NUMCOPY ]]; then
      DIFFSFOUND=1
      echo "Number of files does not match between $LINE/ and $BACKUPDIR/$LINEBASE/"
    fi
    OLDIFS=$IFS
    IFS="
"
    LLINE=1
    for FILENAME in $FILELIST; do
      trap - ERR
      CMPFILENAME=`echo "$CMPFILELIST" 2>&1 | head -$LLINE | tail -1`
      DIFF=`cmp $FILENAME $CMPFILENAME 2>&1`
      trap exitwarning ERR
      if [[ ! $DIFF == "" ]]; then
        DIFFSFOUND=1
        echo $DIFF
      fi
      LLINE=`expr $LLINE + 1`
    done
    IFS=$OLDIFS
    if [[ $DIFFSFOUND == 1 ]]; then
      echo "$LINE: WARNING! Found differences between original and copy."
    else
      echo "$LINE: No byte differences found between original and copy. Everything's fine!"
    fi
  done < "$DIRLIST"
fi

exitclean
