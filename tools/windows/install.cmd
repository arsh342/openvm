@echo off
rem install.cmd - openVM's unattended Windows install, run by WinPE instead of Setup.
rem
rem Windows Setup cannot install on this VM: it hard-blocks on the missing TPM and,
rem with that bypassed, fails creating its own system partition. So WinPE runs this
rem script (winpeshl.ini) and installs the way Setup would underneath: load the
rem virtio storage driver, partition the empty disk, apply the image with DISM, add
rem the virtio drivers offline, write the boot files, and shut down. The result is
rem recorded on the install media for the host to read.
rem
rem Inputs, all inside boot.wim under X:\openvm (tools/build/mk-windows-media.sh):
rem   drivers\<name>\*.inf      virtio-win ARM64 drivers (viostor, NetKVM, viosock, ...)
rem   efi\BOOTAA64.EFI          openVM's chainloader (loads the framebuffer driver)
rem   efi\OPENVM-FB.EFI         the boot-service framebuffer driver
rem   unattend.xml              the OOBE answer file (local account, autologon)
rem   SetupComplete.cmd         end-of-setup tasks, run as SYSTEM (WinFsp, VirtIO-FS)
rem   payload\                  copied to C:\openvm (WinFsp, the VirtIO-FS service)
rem   image-index.txt           the install.wim index to apply (Windows 11 Pro)
rem The media volume is found by its tag file \openvm\media.tag next to install.wim.

setlocal EnableExtensions EnableDelayedExpansion
set LOG=X:\openvm\install.log
echo openvm-install: start %DATE% %TIME% > %LOG%

rem 1. WinPE has no virtio storage driver; without it neither disk is visible.
for /r X:\openvm\drivers\viostor %%f in (*.inf) do (
    echo openvm-install: drvload %%f >> %LOG%
    drvload "%%f" >> %LOG% 2>&1
)
rem PnP needs a moment to enumerate the disks and mount their volumes.
ping -n 8 127.0.0.1 > nul

rem 2. The media volume carries install.wim and our tag file.
set MEDIA=
for %%d in (C D E F G H I J K L M N O P Q R T U V Y Z) do (
    if exist %%d:\openvm\media.tag if not defined MEDIA set MEDIA=%%d:
)
if not defined MEDIA (
    echo openvm-install: FAIL no media volume with \openvm\media.tag >> %LOG%
    goto fail
)
echo openvm-install: media is %MEDIA% >> %LOG%

rem 3. The target is the disk that has no volumes at all.
set TARGET=
for %%n in (0 1 2 3 4) do (
    rem Redirection first: "disk 1>" would be read as handle 1 and drop the number.
    > X:\openvm\probe.txt echo select disk %%n
    >> X:\openvm\probe.txt echo detail disk
    diskpart /s X:\openvm\probe.txt > X:\openvm\probe.out 2>&1
    find /i "There are no volumes" X:\openvm\probe.out > nul
    if !ERRORLEVEL! EQU 0 if not defined TARGET set TARGET=%%n
)
if not defined TARGET (
    echo openvm-install: FAIL no empty target disk >> %LOG%
    goto fail
)
echo openvm-install: target is disk %TARGET% >> %LOG%

rem 4. GPT: EFI system partition, MSR, Windows.
(
    echo select disk %TARGET%
    echo clean
    echo convert gpt
    echo create partition efi size=260
    echo format quick fs=fat32 label=System
    echo assign letter=S
    echo create partition msr size=16
    echo create partition primary
    echo format quick fs=ntfs label=Windows
    echo assign letter=W
) > X:\openvm\partition.txt
diskpart /s X:\openvm\partition.txt >> %LOG% 2>&1
if errorlevel 1 (
    echo openvm-install: FAIL diskpart >> %LOG%
    goto fail
)

rem 5. Apply the image, then add every virtio driver offline so the first boot
rem    can see its own disk (no driver means INACCESSIBLE_BOOT_DEVICE).
set /p INDEX=<X:\openvm\image-index.txt
echo openvm-install: applying install.wim index %INDEX% >> %LOG%
dism /English /Apply-Image /ImageFile:%MEDIA%\sources\install.wim /Index:%INDEX% /ApplyDir:W:\ >> %LOG% 2>&1
if errorlevel 1 (
    echo openvm-install: FAIL dism apply >> %LOG%
    goto fail
)
dism /English /Image:W:\ /Add-Driver /Driver:X:\openvm\drivers /Recurse >> %LOG% 2>&1
if errorlevel 1 (
    echo openvm-install: FAIL dism add-driver >> %LOG%
    goto fail
)

rem 6. Boot files. bcdboot writes \EFI\Microsoft\Boot and the removable-media
rem    fallback \EFI\BOOT\BOOTAA64.EFI; the fallback is replaced with openVM's
rem    chainloader, which loads the framebuffer driver before Boot Manager
rem    (Apple's firmware has no framebuffer of its own).
bcdboot W:\Windows /s S: /f UEFI >> %LOG% 2>&1
if errorlevel 1 (
    echo openvm-install: FAIL bcdboot >> %LOG%
    goto fail
)
if not exist S:\EFI\BOOT mkdir S:\EFI\BOOT
copy /y X:\openvm\efi\BOOTAA64.EFI S:\EFI\BOOT\BOOTAA64.EFI >> %LOG% 2>&1
copy /y X:\openvm\efi\OPENVM-FB.EFI S:\EFI\BOOT\OPENVM-FB.EFI >> %LOG% 2>&1
if not exist S:\EFI\BOOT\OPENVM-FB.EFI (
    echo openvm-install: FAIL could not place the boot chain >> %LOG%
    goto fail
)

rem 7. The OOBE answer file and the first-logon payload.
if not exist W:\Windows\Panther mkdir W:\Windows\Panther
copy /y X:\openvm\unattend.xml W:\Windows\Panther\unattend.xml >> %LOG% 2>&1
xcopy /e /i /y X:\openvm\payload W:\openvm >> %LOG% 2>&1
if not exist W:\Windows\Setup\Scripts mkdir W:\Windows\Setup\Scripts
copy /y X:\openvm\SetupComplete.cmd W:\Windows\Setup\Scripts\SetupComplete.cmd >> %LOG% 2>&1

echo openvm-install: OK %DATE% %TIME% >> %LOG%
copy /y %LOG% %MEDIA%\openvm\install.log > nul
echo OK> %MEDIA%\openvm\result
wpeutil shutdown
goto :eof

:fail
echo openvm-install: FAILED %DATE% %TIME% >> %LOG%
if defined MEDIA (
    copy /y %LOG% %MEDIA%\openvm\install.log > nul
    echo FAIL> %MEDIA%\openvm\result
)
rem Leave the log on screen briefly for a host-side screenshot, then stop.
type %LOG%
ping -n 30 127.0.0.1 > nul
wpeutil shutdown
