<#
.SYNOPSIS
    Registers or removes iCam Camera on this computer.

.DESCRIPTION
    The Windows Frame Server loads camera sources as a service, and a service
    only sees COM classes registered machine-wide. That is why this needs
    administrator rights once, and why a per-user registration is not enough.

    It writes exactly one key:

        HKLM\SOFTWARE\Classes\CLSID\{6EA042AA-06DB-4533-BADC-ADDF389ED998}

    and copies the DLL to %ProgramData%\iCam\VirtualCamera, which the Frame
    Server can read. -Remove undoes both. Nothing else on the system is touched.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File register.ps1
    powershell -ExecutionPolicy Bypass -File register.ps1 -Remove
#>

[CmdletBinding()]
param(
    [string] $DllPath,
    [switch] $Remove
)

$ErrorActionPreference = 'Stop'

$clsid       = '{6EA042AA-06DB-4533-BADC-ADDF389ED998}'
$friendly    = 'iCam Camera'
$installRoot = Join-Path $env:ProgramData 'iCam\VirtualCamera'
$installed   = Join-Path $installRoot 'iCam.VirtualCamera.dll'
$clsidKey    = "HKLM:\SOFTWARE\Classes\CLSID\$clsid"

function Assert-Elevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This must run as administrator. Windows will not let a service see a per-user COM registration.'
    }
}

Assert-Elevated

if ($Remove) {
    if (Test-Path $clsidKey) {
        Remove-Item $clsidKey -Recurse -Force
        Write-Host "Removed $clsidKey"
    } else {
        Write-Host 'Nothing was registered.'
    }
    if (Test-Path $installRoot) {
        Remove-Item $installRoot -Recurse -Force
        Write-Host "Removed $installRoot"
    }
    Write-Host 'iCam Camera has been removed.'
    return
}

if (-not $DllPath) {
    # Beside the script when shipped with iCam, under build/ when run from a
    # source tree. Looking in both means one script serves either.
    $candidates = @(
        (Join-Path $PSScriptRoot 'iCam.VirtualCamera.dll'),
        (Join-Path $PSScriptRoot 'build\Release\iCam.VirtualCamera.dll')
    )
    $DllPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $DllPath -or -not (Test-Path $DllPath)) {
    throw 'Could not find iCam.VirtualCamera.dll. Build it first with build.cmd.'
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null

# Copied rather than registered in place: the Frame Server has to be able to
# read it, and a path under a user profile is not somewhere a service can go.
Copy-Item $DllPath $installed -Force
Write-Host "Installed $installed"

New-Item -Path $clsidKey -Force | Out-Null
Set-ItemProperty -Path $clsidKey -Name '(default)' -Value $friendly

$serverKey = Join-Path $clsidKey 'InprocServer32'
New-Item -Path $serverKey -Force | Out-Null
Set-ItemProperty -Path $serverKey -Name '(default)' -Value $installed
# Both, so the Frame Server can create the object on whichever apartment it
# happens to be using.
Set-ItemProperty -Path $serverKey -Name 'ThreadingModel' -Value 'Both'

Write-Host "Registered $clsid"
Write-Host ''
Write-Host 'iCam Camera is registered. Start iCam to make it appear as a camera.'
