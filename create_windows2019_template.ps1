# PowerCLI 
$VIServer = ""
$VIUsername = ""
$VIPassword = ""
$vmhost = ""
$datastore = ""
$ISO = "C:\VMware\Create_2019_Template\Windows_Server_2019-sddc.iso"
$viConnection = Connect-VIServer $VIServer -User $VIUsername -Password $VIPassword -WarningAction SilentlyContinue

# copy ISO to datastore
$IsoFileName = $ISO.split("\")[-1]
$target_datacenter = Get-Cluster -VMHost $vmhost | Get-Datacenter
Copy-DatastoreItem -Item $ISO vmstore:\$target_datacenter\$datastore\ISO\$IsoFileName -Force

# Create VM
$source_dc = Get-Datacenter -VMHost $vmhost
$vm = New-VM -Server $viConnection -Name "windows_2019_template" -VMHost $vmhost -Datastore $datastore -MemoryGB 16 -NumCpu 8 -CoresPerSocket 8 -DiskGB 200 -NetworkName "VM Network" -GuestId "windows9Server64Guest" -DiskStorageFormat thin -CD # -NetworkName "VM Network" # -Portgroup "DPortGroup" 
$vm | Get-ScsiController | Set-ScsiController -Type ParaVirtual | Out-Null
$vm | Get-NetworkAdapter | Set-NetworkAdapter -Type Vmxnet3 -Confirm:$false | Out-Null
$vm | Get-CDDrive | Set-CDDrive -ISOPath "[$datastore] ISO/$IsoFileName" -StartConnected:$true -Confirm:$false | Out-Null
#$vm | New-VTpm | Out-Null

# Modify to use UEFI not BIOS
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$spec.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
$vm.ExtensionData.ReconfigVM($spec)
# Add USB controller so the mouse works...
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$deviceCfg = New-Object VMware.Vim.VirtualDeviceConfigSpec
$deviceCfg.Operation = "add"
$deviceCfg.Device = New-Object VMware.Vim.VirtualUSBController
$deviceCfg.device.Key = -1
$deviceCfg.Device.Connectable = `
New-Object VMware.Vim.VirtualDeviceConnectInfo
$deviceCfg.Device.Connectable.StartConnected - $true
$deviceCfg.Device.Connectable.AllowGuestControl = $false
$deviceCfg.Device.Connectable.Connected = $true
$deviceCfg.Device.ControllerKey = 100
$deviceCfg.Device.BusNumber = -1
$deviceCfg.Device.autoConnectDevices = $true
$spec.DeviceChange += $deviceCfg
$vm_usb = get-vm  -name $vm | get-view
$vm_usb.ReconfigVM_Task($spec) | Out-Null
# Start the VM
$vm | start-vm | Out-Null
# Wait until the machine has a working VM-Tools
$VMToolStatus = ""
do {
	Start-Sleep 15
    $VMToolStatus = ($vm | Get-View).Guest.ToolsStatus
} until ( $VMToolStatus -eq "toolsOk" )
# Disconnect the ISO.
$vm | Get-CDDrive | Set-CDDrive -NoMedia -Confirm:$false | Out-Null
# Define Guest Credentials
$username="Administrator"
$password=ConvertTo-SecureString "VMware1!" -AsPlainText -Force
$GuestOSCred=New-Object -typename System.Management.Automation.PSCredential -argumentlist $username, $password

My-Logger "Starting configuration"

$script_setup = @'
net stop vmtools
netsh interface ip set address name="Ethernet0" static 10.0.1.90 255.255.255.0 10.0.1.1
Get-NetAdapter -Name Ethernet0 | Set-DnsClientServerAddress -ServerAddresses 192.168.0.3
Set-TimeZone -Name "AUS Eastern Standard Time"
Set-ExecutionPolicy bypass -Force
Install-PackageProvider -Name NuGet -Force
Install-Module -Name PSWindowsUpdate -Force
Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module -Scope AllUsers -Name VMware.PowerCLI
Set-PowerCLIConfiguration -Scope AllUsers -ParticipateInCEIP:$false -Confirm:$false
$Path = $env:TEMP; $Installer = "chrome_installer.exe"; Invoke-WebRequest "https://dl.google.com/chrome/install/latest/chrome_installer.exe" -OutFile $Path\$Installer; Start-Process -FilePath $Path\$Installer -Args "/silent /install" -Verb RunAs -Wait; Remove-Item $Path\$Installer
iex (iwr chocolatey.org/install.ps1)
choco install -y git -params "/GitAndUnixToolsOnPath"
Get-WUInstall -AcceptAll -Install -AutoReboot -Verbose
'@

Invoke-VMScript -scripttext $script_setup -VM $VM -GuestCredential $GuestOSCred -runasync | out-null

# wait for the machine to come back after installing updates
$VMToolStatus = ""
do {
	Start-Sleep 15
    $VMToolStatus = ($vm | Get-View).Guest.ToolsStatus
} until ( $VMToolStatus -eq "toolsOk" )

My-Logger "done with install"

# Shutdown VM and clone to _template
$VM | Shutdown-VMGuest -Confirm:$false

$PowerState = ""
do {
	Start-Sleep 15
    $VM = Get-VM -Name $VM
    $PowerState = $VM.PowerState
} until ( $PowerState -eq "PoweredOff" )

$vm_clone = New-VM -VM $VM -Name "windows_2019_template_clone" -VMHost $vmhost -DiskStorageFormat Thin -Datastore $datastore

# Start the VM
$vm_clone | start-vm | Out-Null
# Wait until the machine has a working VM-Tools
$VMToolStatus = ""
do {
	Start-Sleep 15
    $VMToolStatus = ($vm_clone | Get-View).Guest.ToolsStatus
} until ( $VMToolStatus -eq "toolsOk" )

My-Logger "Machine finished, running sysprep"
$script1 = "c:\windows\system32\sysprep\sysprep.exe /generalize /oobe /unattend:c:\Users\Administrator\Documents\unattend-oobe.xml /shutdown"
Copy-VMGuestFile -Source "C:\VMware\Create_2019_Template\unattend-oobe-win2019.xml" -destination c:\Users\Administrator\Documents\unattend-oobe.xml -VM $vm_clone -LocalToGuest -GuestCredential $GuestOSCred -Force
Invoke-VMScript -ScriptText $script1 -VM $vm_clone -GuestCredential $GuestOSCred -ScriptType bat -RunAsync | out-null

# Wait for the VM to shutdown
$PowerState = ""
do {
	Start-Sleep 15
    $vm_clone = Get-VM -Name $vm_clone
    $PowerState = $vm_clone.PowerState
} until ( $PowerState -eq "PoweredOff" )

My-Logger "VM Powered off - exporting to OVA"
# Export OVA
& 'C:\Program Files\VMware\VMware OVF Tool\ovftool.exe' --shaAlgorithm=SHA1 --noSSLVerify -o vi://${VIusername}:${VIPassword}@$VIServer/$source_dc/vm/$vm_clone C:\VMware\Create_2019_Template\Windows_2019_template.ova
# Finish.
