# sound.ps1 - turns Windows sound on and off for this guest.
# Virtualization.framework offers only a virtio sound device, and no Microsoft-signed
# driver exists for one. This installs a test-signed third-party driver, so it is
# opt-in: `openvmctl audio enable <vm> --test-mode`, as SYSTEM through the agent.
# See docs/windows-guests.md.
#
# The driver goes in on the boot after enable, because pnputil refuses a test-signed
# package in the boot that turned test signing on. The last output line is what the
# agent reads: state|detail, where state is off, pending, on or failed. `audio status`
# does not come here: the agent reads the service and the files this leaves.
param([ValidateSet('enable', 'install', 'disable', 'status')][string]$Op = 'status')
$ErrorActionPreference = 'Stop'
$dir = 'C:\openvm\sound'
$log = "$dir\sound.log"
$failed = "$dir\sound.failed"
$pending = "$dir\sound.pending"
$tone = "$dir\tone.wav"
$cert = "$dir\DroidVM_Test.cer"
$task = 'OpenVMSound'

function Note([string]$text) { "$(Get-Date -Format s) $text" | Out-File -Append -Encoding ascii $log }

# Native tools write to stderr on ordinary paths, which Stop would turn into a throw.
function Run([string]$exe, [string[]]$arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & $exe @arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    Note "$exe $($arguments -join ' ') -> $code`r`n$out"
    return $code
}

function Device { Get-PnpDevice | Where-Object InstanceId -like '*DEV_1059*' | Select-Object -First 1 }

function TaskExists {
    $ErrorActionPreference = 'Continue'
    & schtasks /query /tn $task 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

function Thumbprint { (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $cert).Thumbprint }

# A 3 second 440 Hz stereo tone for `audio test`, quiet enough not to startle.
function WriteTone {
    $rate = 48000
    $frames = $rate * 3
    $data = New-Object byte[] ($frames * 4)
    for ($i = 0; $i -lt $frames; $i++) {
        $bytes = [BitConverter]::GetBytes([int16](6000 * [math]::Sin(2 * [math]::PI * 440 * $i / $rate)))
        $at = $i * 4
        $data[$at] = $bytes[0]; $data[$at + 1] = $bytes[1]
        $data[$at + 2] = $bytes[0]; $data[$at + 3] = $bytes[1]
    }
    $stream = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $stream
    $ascii = [Text.Encoding]::ASCII
    $w.Write($ascii.GetBytes('RIFF')); $w.Write([int](36 + $data.Length))
    $w.Write($ascii.GetBytes('WAVEfmt ')); $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]2)
    $w.Write([int]$rate); $w.Write([int]($rate * 4)); $w.Write([int16]4); $w.Write([int16]16)
    $w.Write($ascii.GetBytes('data')); $w.Write([int]$data.Length); $w.Write($data); $w.Flush()
    [IO.File]::WriteAllBytes($tone, $stream.ToArray())
}

function Status {
    $device = Device
    $service = Get-Service viosnd -ErrorAction SilentlyContinue
    if ($device -and $device.Status -eq 'OK' -and $service -and $service.Status -eq 'Running') {
        return "on|$($device.FriendlyName)"
    }
    if (Test-Path $failed) { return "failed|$((Get-Content $failed -Raw).Trim())" }
    if (TaskExists) { return 'pending|' }
    return 'off|'
}

function Enable {
    if (-not (Test-Path "$dir\viosnd.inf")) { throw 'this guest was installed without the sound driver' }
    Remove-Item $failed -ErrorAction SilentlyContinue
    if ((Run 'certutil' @('-addstore', '-f', 'Root', $cert)) -ne 0) { throw 'could not trust the driver certificate' }
    if ((Run 'certutil' @('-addstore', '-f', 'TrustedPublisher', $cert)) -ne 0) { throw 'could not trust the driver publisher' }
    if ((Run 'bcdedit' @('/set', 'testsigning', 'on')) -ne 0) { throw 'could not turn test signing on' }
    $action = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $dir\sound.ps1 -Op install"
    $made = Run 'schtasks' @('/create', '/tn', $task, '/sc', 'onstart', '/ru', 'SYSTEM', '/rl', 'highest', '/f', '/tr', $action)
    if ($made -ne 0) { throw 'could not schedule the driver install' }
    New-Item -ItemType File -Force $pending | Out-Null
}

function Install {
    $code = Run 'pnputil' @('/add-driver', "$dir\viosnd.inf", '/install')
    # 3010 is success with a reboot wanted.
    if ($code -ne 0 -and $code -ne 3010) { throw "pnputil could not install the driver ($code)" }
    WriteTone
    Start-Sleep 5
    $device = Device
    if ($device -and $device.Status -ne 'OK') { Run 'pnputil' @('/restart-device', $device.InstanceId) | Out-Null }
    Remove-Item $failed, $pending -ErrorAction SilentlyContinue
    Run 'schtasks' @('/delete', '/tn', $task, '/f') | Out-Null
}

function Disable {
    if (TaskExists) { Run 'schtasks' @('/delete', '/tn', $task, '/f') | Out-Null }
    Get-WindowsDriver -Online | Where-Object OriginalFileName -like '*\viosnd.inf' | ForEach-Object {
        if ((Run 'pnputil' @('/delete-driver', $_.Driver, '/uninstall', '/force')) -ne 0) { throw "could not remove $($_.Driver)" }
    }
    $print = Thumbprint
    Run 'certutil' @('-delstore', 'TrustedPublisher', $print) | Out-Null
    Run 'certutil' @('-delstore', 'Root', $print) | Out-Null
    if ((Run 'bcdedit' @('/deletevalue', 'testsigning')) -ne 0) { throw 'could not turn test signing off' }
    Remove-Item $tone, $failed, $pending -ErrorAction SilentlyContinue
}

try {
    switch ($Op) {
        'enable' { Enable }
        'install' { Install }
        'disable' { Disable }
    }
    Status
    exit 0
} catch {
    Note "failed: $_"
    if ($Op -eq 'install') {
        "$_" | Out-File -Encoding ascii $failed
        Remove-Item $pending -ErrorAction SilentlyContinue
    }
    "failed|$_"
    exit 1
}
