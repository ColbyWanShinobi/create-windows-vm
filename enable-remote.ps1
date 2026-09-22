# Run this once from an elevated PowerShell prompt inside Windows 10 or 11.
# It enables encrypted WinRM and, when Windows Update supplies the capability,
# OpenSSH Server.  It does not create users or change existing passwords.

$ErrorActionPreference = 'Stop'

Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name LocalAccountTokenFilterPolicy -Type DWord -Value 1
Set-NetFirewallRule -DisplayGroup 'Windows Remote Management' -Enabled True -Profile Any

Write-Host 'WinRM is enabled on TCP 5985.'

try {
    $sshCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($sshCapability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
    }
    Write-Host 'OpenSSH Server is enabled on TCP 22.'
} catch {
    Write-Warning "WinRM is ready, but OpenSSH Server could not be installed: $($_.Exception.Message)"
    Write-Warning 'Connect the guest to the Internet/Windows Update and run this script again to add SSH.'
}
