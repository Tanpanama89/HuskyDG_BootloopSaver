MAGISKTMP="$(magisk --path)"
get_flags
find_boot_image
exit_ui_print(){
    ui_print "$1"
    exit
}

test -z /data/adb/magisk/magiskboot && abort "- Hmmm... Where is magiskboot binary?"

check_ramdisk(){
ui_print "- Checking ramdisk status"
if [ -e ramdisk.cpio ]; then
  /data/adb/magisk/magiskboot cpio ramdisk.cpio test
  STATUS=$?
else
  # Stock A only legacy SAR, or some Android 13 GKIs
  STATUS=0
fi
case $((STATUS & 3)) in
  0 )  # Stock boot
    ui_print "- Stock boot image detected"
    
    ;;
  1 )  # Magisk patched
    ui_print "- Magisk patched boot image detected"
    
    ;;
  2 )  # Unsupported
    ui_print "! Boot image patched by unsupported programs"
    exit_ui_print "! Please restore back to stock boot image"
    ;;
esac
}

uninstall_module(){
( if [ ! -z "$BOOTIMAGE" ]; then
    ui_print "- Target boot image: $BOOTIMAGE"
    rm -rf "$TMPDIR/boot"
    mkdir -p "$TMPDIR/boot"
    if [ -c "$BOOTIMAGE" ]; then
        nanddump -f "$TMPDIR/boot/boot.img" "$BOOTIMAGE"  || exit_ui_print "! Unable to dump boot image"
        BOOTNAND="$BOOTIMAGE"
        BOOTIMAGE="$TMPDIR/boot/boot.img"
    else
        dd if="$BOOTIMAGE" of="$TMPDIR/boot/boot.img"  || exit_ui_print "! Unable to dump boot image"
    fi
    cd "$TMPDIR/boot" || exit 1
    check_ramdisk
    ui_print "- Revert patch from boot image"
    /data/adb/magisk/magiskboot unpack boot.img
     /data/adb/magisk/magiskboot cpio ramdisk.cpio \
"rm overlay.d/safemode.rc" \
"rm -r overlay.d/sbin/bootloopsaver" \
"rm overlay.d/sbin/safemode.sh"
     /data/adb/magisk/magiskboot repack boot.img || abort "! Unable to repack boot image"
    ui_print "- Flashing new boot image"
     flash_image "$TMPDIR/boot/new-boot.img" "$BOOTIMAGE"
     case $? in
        1)
          abort "! Insufficient partition size"
          ;;
        2)
          FILENAME="/sdcard/Download/bootloopsaver-patched-boot-$RANDOM.img"
          cp "$TMPDIR/boot/new-boot.img" "$FILENAME"
          ui_print "! $BOOTIMAGE is read-only"
          ui_print "*****************************************"
          ui_print "    Oops! It seems your boot partition is read-only"
          ui_print "    I have saved your boot image to $FILENAME"
          ui_print "    Please try flashing this boot image from fastboot or recovery"
          ui_print "*****************************************"
          exit_ui_print "! Unable to flash boot image"
          ;;
     esac
    ui_print "- Module is completely remove from boot image!"
fi )
}

patch_bootimg(){
( if [ ! -z "$BOOTIMAGE" ]; then
    ui_print "- Target boot image: $BOOTIMAGE"
    [ "$RECOVERYMODE" == "true" ] && ui_print "- Recovery mode is present, the script might patch recovery image..."
    mkdir "$TMPDIR/boot"
    if [ -c "$BOOTIMAGE" ]; then
        nanddump -f "$TMPDIR/boot/boot.img" "$BOOTIMAGE" || exit_ui_print "! Unable to dump boot image"
        BOOTNAND="$BOOTIMAGE"
        BOOTIMAGE="$TMPDIR/boot/boot.img"
    else
        dd if="$BOOTIMAGE" of="$TMPDIR/boot/boot.img" || exit_ui_print "! Unable to dump boot image"
    fi
    ui_print "- Unpack boot image"
    cd "$TMPDIR/boot" || exit 1
    /data/adb/magisk/magiskboot unpack boot.img
    check_ramdisk
    ui_print "- Add bootloop protector script"
    cat <<EOF > safemode.rc
# safe mode trigger
on post-fs
    exec u:r:magisk:s0 root root -- /system/bin/sh \${MAGISKTMP}/safemode.sh

on post-fs-data
    exec u:r:magisk:s0 root root -- /system/bin/sh \${MAGISKTMP}/safemode.sh --post-fs-data

# if boot completed, remove file to tell script that previous boot is successful
on property:sys.boot_completed=1
    rm /cache/.system_booting
    rm /data/unencrypted/.system_booting
    rm /metadata/.system_booting
    rm /persist/.system_booting
    rm /mnt/vendor/persist/.system_booting

EOF
    cat <<EOF >safemode.sh
MAGISKTMP="\${0%/*}"
post_fs_dir(){
  unset POSTFSDIR
  if [ -d /data/unencrypted ] && ! grep ' /data ' /proc/mounts | grep -qE 'dm-|f2fs'; then
    POSTFSDIR="/data/unencrypted/${MODPATH##*/}"
  elif grep ' /cache ' /proc/mounts | grep -q 'ext4' ; then
    POSTFSDIR="/cache/${MODPATH##*/}"
  elif grep ' /metadata ' /proc/mounts | grep -q 'ext4' ; then
    POSTFSDIR="/metadata/${MODPATH##*/}"
  elif grep ' /persist ' /proc/mounts | grep -q 'ext4' ; then
    POSTFSDIR="/persist/${MODPATH##*/}"
  elif grep ' /mnt/vendor/persist ' /proc/mounts | grep -q 'ext4' ; then
    POSTFSDIR="/mnt/vendor/persist/${MODPATH##*/}"
  elif [ ! -z "\$MAGISKTMP" ]; then
    POSTFSDIR="\$MAGISKTMP/.magisk/${MODPATH##*/}"
  else
    POSTFSDIR="/dev/${MODPATH##*/}"
  fi
  [ ! -z "\$POSTFSDIR" ] && mkdir -p "\$POSTFSDIR/magisk"
}
post_fs_dir
if [ "\$1" == "--post-fs-data" ]; then
    cp -af /data/adb/magisk/magiskboot "\$POSTFSDIR/magisk/magiskboot"
    cp -af /data/adb/magisk/util_functions.sh "\$POSTFSDIR/magisk/util_functions.sh"
    mkdir -p "\$MAGISKTMP/.magisk/${MODPATH##*/}"
    # do not disable bootloop protector
    rm -rf "/data/adb/modules/${MODPATH##*/}/disable"

    # always sync module
    if [ -e "\$POSTFSDIR/${MODPATH##*/}/remove" ]; then
        touch "/data/adb/modules/${MODPATH##*/}/remove"
    else
        mkdir -p "/data/adb/modules/${MODPATH##*/}"
        cp -af "\$MAGISKTMP/bootloopsaver/"* "/data/adb/modules/${MODPATH##*/}"
        cp -af "\$MAGISKTMP/bootloopsaver/"* "\$POSTFSDIR"
    fi
else
    for dir in /cache /data/unencrypted /metadata /mnt/vendor/persist; do
        if [ -e "\$dir/disable_magisk" ]; then
            DISABLE=true
            rm -rf "\$dir/disable_magisk"
        fi
        # reboot while in boot animation will boot into safe mode
        # this feature is only enabled when new_safemode is created
        if [ -e "\$dir/new_safemode" ] && [ -e "\$dir/.system_booting" ]; then
            # if we found ".system_booting" that's mean previous boot is not completed
            DISABLE=true
            rm -rf "\$dir/.system_booting"
        fi
        # tell that system is booting
        touch "\$dir/.system_booting"
    done
    if [ ! -f "\$POSTFSDIR/count" ]; then
        rm -rf "\$POSTFSDIR/count"
        echo "0" >"\$POSTFSDIR/count"
    fi
    
    if [ "\$DISABLE" == "true" ]; then 
        echo "\$(( \$(cat "\$POSTFSDIR/count" | head -c4) + 1 ))" >"\$POSTFSDIR/count"
        setprop persist.sys.safemode 1
        [ ! -z "\$POSTFSDIR" ] && echo "I have triggered Safe Mode for \$(cat "\$POSTFSDIR/count" | head -c4) time(s)" >"\$POSTFSDIR/note.txt"
    fi
fi


EOF
    
     

     /data/adb/magisk/magiskboot cpio ramdisk.cpio \
"mkdir 0750 overlay.d" \
"mkdir 0750 overlay.d/sbin" \
"rm -r overlay.d/sbin/bootloopsaver" \
"mkdir 0750 overlay.d/sbin/bootloopsaver" \
"rm overlay.d/safemode.rc" \
"rm overlay.d/sbin/safemode.sh" \
"add 0750 overlay.d/safemode.rc safemode.rc" \
"add 0750 overlay.d/sbin/bootloopsaver/post-fs-data.sh $MODPATH/post-fs-data.sh" \
"add 0750 overlay.d/sbin/bootloopsaver/service.sh $MODPATH/service.sh" \
"add 0750 overlay.d/sbin/bootloopsaver/utils.sh $MODPATH/utils.sh" \
"add 0750 overlay.d/sbin/bootloopsaver/module.prop $MODPATH/module.prop" \
"add 0750 overlay.d/sbin/safemode.sh safemode.sh"
     ui_print "- Repack boot image"
     /data/adb/magisk/magiskboot repack boot.img || exit_ui_print "! Unable to repack boot image"
     [ -e "$BOOTNAND" ] && BOOTIMAGE="$BOOTNAND"
     ui_print "- Flashing new boot image"
     flash_image "$TMPDIR/boot/new-boot.img" "$BOOTIMAGE"
     case $? in
        1)
          exit_ui_print "! Insufficient partition size"
          ;;
        2)
          FILENAME="/sdcard/Download/bootloopsaver-patched-boot-$RANDOM.img"
          cp "$TMPDIR/boot/new-boot.img" "$FILENAME"
          ui_print "! $BOOTIMAGE is read-only"
          ui_print "*****************************************"
          ui_print "    Oops! It seems your boot partition is read-only"
          ui_print "    I have saved your boot image to $FILENAME"
          ui_print "    Please try flashing this boot image from fastboot or recovery"
          ui_print "*****************************************"
          exit_ui_print "! Unable to flash boot image"
          ;;
     esac
     ui_print "- All done!"


     ui_print "*****************************************"
     ui_print "  Remember to reinstall module"
     ui_print "      when you flash custom kernel/boot image"
     ui_print "*****************************************"
else
     ui_print "! Cannot detect target boot image"
fi ) }

. $MODPATH/addon/Volume-Key-Selector/install.sh

    ui_print "- Do you want to patch boot image with this module?"
    ui_print " 1. DON'T patch my boot image!"
    ui_print "    Basic function only: Auto mode and Disable from Recovery"
    ui_print " 2. Yes, patch my boot image!"
    ui_print "    Basic function + New way to reboot to Safe Mode"
    ui_print "    Survive after wipe data or factory reset"
    ui_print " 3. Completely remove this module"
    ui_print ""
    ui_print "Volume up (+) to change selection"
    ui_print "Volume down (-) to decide"
    sleep 0.5
    
    A=1
    while true; do
        case $A in
            1 ) TEXT="Don't patch my boot image";;
            2 ) TEXT="Yes, patch my boot image!";;
            3 ) TEXT="Completely remove this module";;
        esac
        ui_print "$A - $TEXT"
        if $VKSEL; then
            A=$((A + 1))
        else
            break
        fi
        if [ $A -gt 3 ]; then
            A=1
        fi
    done
    ui_print ""
    ui_print "You have selected: $A - $TEXT"
    

    case $A in
            2 ) patch_bootimg;;
            3 ) uninstall_module; touch "$MODPATH/remove"; ui_print "- Module will be removed in next boot";;
    esac

    sleep 1

if [ "$A" != 3 ]; then
( . "$MODPATH/utils.sh"
MODULEDIR="$MODPATH"
post_fs_dir
ui_print "- Module directory is $POSTFSDIR"
rm -rf "$POSTFSDIR/remove"
)
if [ ! -z "$MAGISKTMP" ]; then
    cat "$MODPATH/module.prop" >"$MAGISKTMP/saver.prop"
    sed -Ei "s/^description=(\[.*][[:space:]]*)?/description=[ ✔ Module has been updated ] /g" "$MAGISKTMP/saver.prop"
fi
fi
