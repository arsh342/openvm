@echo off
rem SetupComplete.cmd - run once by Windows, as SYSTEM, at the end of setup
rem (before the first logon). install.cmd places it in
rem C:\Windows\Setup\Scripts\. It replaced FirstLogonCommands in unattend.xml,
rem which Windows 11 did not process on this VM (UnattendGC logs no trace of them).
set LOG=C:\openvm\setupcomplete.log
echo openvm-setupcomplete: start %DATE% %TIME% > %LOG%
net accounts /maxpwage:unlimited >> %LOG% 2>&1
rem The host owns sleep (openvmd pauses guests before the Mac sleeps). Left on the
rem default plan the guest idles down about 5 minutes after the last input and
rem the agent stops answering the channel in time.
powercfg /change monitor-timeout-ac 0 >> %LOG% 2>&1
powercfg /change standby-timeout-ac 0 >> %LOG% 2>&1
powercfg /change hibernate-timeout-ac 0 >> %LOG% 2>&1
powercfg /hibernate off >> %LOG% 2>&1
rem viogpudo sizes its framebuffer when it starts, from the largest mode it knows, with
rem a 16 MiB floor, and refuses anything bigger. That floor stops at 2560x1600, below a
rem Mac's native Retina sizes. Registering a 5K mode makes room, from the next boot.
powershell -NoProfile -Command "Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | Where-Object { (Get-ItemProperty $_.PSPath).MatchingDeviceId -like '*dev_1050*' } | ForEach-Object { Set-ItemProperty $_.PSPath PersistentDispMode0Width 5120 -Type DWord; Set-ItemProperty $_.PSPath PersistentDispMode0Height 2880 -Type DWord; 'display mode registered at ' + $_.PSChildName }" >> %LOG% 2>&1
rem WinFsp: the file system layer the VirtIO-FS service needs.
msiexec /i C:\openvm\WinFsp.msi /qn /norestart /log C:\openvm\winfsp-install.log
echo openvm-setupcomplete: winfsp exit %ERRORLEVEL% >> %LOG%
rem The VirtIO-FS service mounts the "openvm" virtio-fs tag. Pin it to Z:,
rem where the agent reads shares (the default "*" takes any free letter).
reg add HKLM\Software\VirtIO-FS /v MountPoint /t REG_SZ /d Z: /f >> %LOG% 2>&1
sc create VirtioFsSvc binPath= "C:\openvm\virtiofs\virtiofs.exe" start= auto depend= "WinFsp.Launcher/VirtioFsDrv" DisplayName= "VirtIO-FS Service" >> %LOG% 2>&1
sc start VirtioFsSvc >> %LOG% 2>&1
rem The openVM agent: vsock port 52 through viosock's Winsock provider, which
rem viosock.inf installs as the VirtioSocketWSP service.
sc query VirtioSocketWSP >> %LOG% 2>&1
sc create OpenVMTools binPath= "C:\openvm\openvm-tools-win.exe" start= auto depend= VirtioSocketWSP DisplayName= "openVM guest tools" >> %LOG% 2>&1
sc description OpenVMTools "Clipboard, time, shared folders and file transfer with the openVM host." >> %LOG% 2>&1
sc failure OpenVMTools reset= 86400 actions= restart/5000/restart/5000/restart/30000 >> %LOG% 2>&1
rem The answer file asks for openvm to be an administrator, but a guest has come up where elevation
rem offered no admin to use. Make sure of it, and record the result. By SID: the group's name is
rem translated on other languages of Windows.
powershell -NoProfile -Command "Add-LocalGroupMember -SID S-1-5-32-544 -Member openvm -ErrorAction SilentlyContinue; 'openvm-admins:'; Get-LocalGroupMember -SID S-1-5-32-544 | ForEach-Object { $_.Name }" >> %LOG% 2>&1
echo openvm-setupcomplete: services installed %DATE% %TIME% >> %LOG%
echo ok> C:\openvm\setupcomplete.ok
rem "Send to Mac" in every user's SendTo menu (new profiles are copied from the default one).
set SENDTO=C:\Users\Default\AppData\Roaming\Microsoft\Windows\SendTo
mkdir "%SENDTO%" >> %LOG% 2>&1
> "%SENDTO%\Send to Mac.cmd" echo @"C:\openvm\openvm-tools-win.exe" --send %%*
rem C:\openvm holds what the SYSTEM agent runs, so ordinary users get read only.
rem The spool is the exception: the spooler writes print jobs as the user. This
rem comes last and logs elsewhere: changing the ACL under an open log broke
rem every later ">> %LOG%", and a failed redirect skips its whole command.
set ACL=C:\Windows\Temp\openvm-acl.log
mkdir C:\openvm\spool > %ACL% 2>&1
icacls C:\openvm /inheritance:r /grant:r SYSTEM:(OI)(CI)F Administrators:(OI)(CI)F Users:(OI)(CI)RX >> %ACL% 2>&1
icacls C:\openvm\spool /grant Users:(OI)(CI)M >> %ACL% 2>&1
icacls C:\openvm >> %ACL% 2>&1
icacls C:\openvm\openvm-tools-win.exe >> %ACL% 2>&1
sc start OpenVMTools >> %ACL% 2>&1
