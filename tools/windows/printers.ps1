# printers.ps1 - makes this guest's openVM queues match what the host published.
# Run by the agent (as SYSTEM) on every change of the host's printer list. Each
# queue is the stock Microsoft Print to PDF driver on a file port in the spool,
# so a job becomes a PDF the agent can hand to the host. Names were validated by
# the host and the agent ([A-Za-z0-9._-]).
param([string]$Names = '')
$ErrorActionPreference = 'Stop'
$spool = 'C:\openvm\spool'
$driver = 'Microsoft Print To PDF'
$wanted = @($Names -split ',' | Where-Object { $_ })

Get-Printer | Where-Object { $_.PortName -like "$spool\*" -and $wanted -notcontains $_.Name } | ForEach-Object {
    $port = $_.PortName
    Remove-Printer -Name $_.Name
    Remove-PrinterPort -Name $port -ErrorAction SilentlyContinue
}
foreach ($name in $wanted) {
    if (Get-Printer -Name $name -ErrorAction SilentlyContinue) { continue }
    $port = "$spool\$name.pdf"
    if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name $port
    }
    Add-Printer -Name $name -DriverName $driver -PortName $port
}
