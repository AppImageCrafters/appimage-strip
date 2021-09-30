#!/bin/bash

set -e
WORKDIR=/tmp

if [ -a $TARGET ]; then
    TARGET=$(realpath $1)
else
    echo "ERROR: You need to provide an AppImage path as input"
    exit 1
fi

echo "                      ****** WARNING ****** "
echo "This script will remove all the files that are not required at runtime in THIS SYSTEM"
echo "some files may be required in other system, therefore you should be carefull to not"
echo "remove then, otherwise the AppImage will not run there!"
echo ""
echo ""


echo "INFO: Droping QML cache"
find $HOME/.cache -name '*.qmlc' -exec rm -- '{}' +

echo "WARNING: If your program uses other cache they should be also droped before running this script!"
echo ""

cd $WORKDIR

echo "INFO: Extracting AppImage"
$TARGET --appimage-extract | sort -u > $WORKDIR/bundled_file_list_sorted.txt

echo "Launching the application to trace which files are really required at runtime"
echo "Please make sure to test all the features of the application, including plugins"
strace -ff -e trace=openat,execve --status=successful $WORKDIR/squashfs-root/AppRun 2> $WORKDIR/trace_log.txt

rm -rf $WORKDIR/required_files
mkdir -p $WORKDIR/required_files

echo "INFO: Filtering access traces"
grep -o \".*\", $WORKDIR/trace_log.txt  | cut -d\" -f 2 | grep "$WORKDIR/squashfs-root/" > $WORKDIR/required_files/traced_files.txt

# include link targets
for FILE_PATH in $(cat $WORKDIR/required_files/traced_files.txt); do
    if [ -L $FILE_PATH ] ; then
        realpath $FILE_PATH >> $WORKDIR/required_files/link_targets.txt
    fi
done

# include AppImage metadata files
find $WORKDIR/squashfs-root/ -maxdepth 1 >> $WORKDIR/required_files/extra.txt
find $WORKDIR/squashfs-root/usr/share/applications/ -maxdepth 1 >> $WORKDIR/required_files/extra.txt
find $WORKDIR/squashfs-root/usr/share/metainfo/ -maxdepth 1 >> $WORKDIR/required_files/extra.txt

# include glibc files
find $WORKDIR/squashfs-root/opt/libc >> $WORKDIR/required_files/extra.txt


cat $WORKDIR/required_files/*.txt | sed 's|//|/|g' | sort -u | cut -d/ -f 3- > accessed_files_sorted.txt

echo "INFO: Droping unused files"

# drop only the files unique to bundled_file_list_sorted.txt
rm $WORKDIR/dropped_files.txt
INITIAL_DROP_LIST=$(comm -1 -3 $WORKDIR/accessed_files_sorted.txt $WORKDIR/bundled_file_list_sorted.txt)
for FILE_PATH in $INITIAL_DROP_LIST; do
    # don't drop symlinks they don't appear in the access log but are required
    if [ ! -L $FILE_PATH ] && [ ! -d $FILE_PATH ]; then
        echo "$FILE_PATH" >> $WORKDIR/dropped_files.txt
        rm $FILE_PATH
    fi
done

echo "Strip process completed!"
echo "The list of dropped files can be found at: $WORKDIR/dropped_files.txt"

echo "Testing the resulting AppDir"
if [ ! squashfs-root/AppRun ]; then
    echo "ERROR: Something we just removed too many things. This tool needs a fix!"
    exit 1
fi

echo "Re-pack the AppImage"
appimagetool squashfs-root

# we should ask if this is required
echo "Resolve deb packages, this will take some time"
DROP_LIST_NO_PREFIX=$(cat $WORKDIR/dropped_files.txt | cut -d/ -f 2- | sort -u)
for FILE_PATH in ${DROP_LIST_NO_PREFIX}; do
    pkg_name=$(dpkg-query -S /$FILE_PATH 2>/dev/null | cut -d: -f1 | cut -d, -f1)
    pkg_files=$(dpkg-query -L kcalc 2>/dev/null | cut -d/ -f 2- | sort)
    echo $pkg_files | comm -1 -2 - /tmp/accessed_files_sorted.txt
    echo $pkg_name
done
