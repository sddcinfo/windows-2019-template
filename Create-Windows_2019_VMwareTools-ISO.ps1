# Script must run as Administrator
#Requires -RunAsAdministrator

# https://sddc.info/create-windows-2016-template/
# Heavily taken from https://github.com/christophecalvet/Windows-Server-unattended-plus-VMware-Tools/blob/master/New-IsoWindowsUnattendedPlusVMwareTools.ps1

$BaseDIR = "C:\VMware\Create_2019_Template\"
$BaseDIR_Temp = "$BaseDIR\CustomWindowsIso\"

# Check the latest version at https://packages.vmware.com/tools/esx/latest/windows/
$VMwareToolsIsoUrl = "https://packages.vmware.com/tools/esx/latest/windows/VMware-tools-windows-11.3.5-18557794.iso"
$SourceWindowsIsoPath = "$BaseDIR\Windows_Server_2019.iso"
$AutoUnattendXmlPath = "$BaseDIR\autounattend-win2019.xml"

# Prepare path for the Windows ISO destination file
$SourceWindowsIsoFullName = $SourceWindowsIsoPath.split("\")[-1]
$DestinationWindowsIsoPath = "$BaseDIR\" + ($SourceWindowsIsoFullName -replace ".iso","") + '-sddc.iso'

# The Temp folder is only needed during the creation of one ISO.
Remove-Item -Recurse -Force "$BaseDIR_Temp\" -Confirm:$false
New-Item -ItemType Directory -Path $BaseDIR_Temp

# Clean DISM mount point if any. Linked to the PVSCSI drivers injection.
Clear-WindowsCorruptMountPoint 
Dismount-WindowsImage -Path "$BaseDIR_Temp\MountDISM" -Discard 

New-Item -ItemType Directory -Path "$BaseDIR_Temp\"
New-Item -ItemType Directory -Path "$BaseDIR_Temp\WorkingFolder"
New-Item -ItemType Directory -Path "$BaseDIR_Temp\VMwareTools"
New-Item -ItemType Directory -Path "$BaseDIR_Temp\MountDISM"

# Download VMware Tools ISO  
$VMwareToolsIsoFullName = $VMwareToolsIsoUrl.split("/")[-1]
$VMwareToolsIsoPath =  "$BaseDIR_Temp\VMwareTools\" + $VMwareToolsIsoFullName 
(New-Object System.Net.WebClient).DownloadFile($VMwareToolsIsoUrl, $VMwareToolsIsoPath)

# Mount the source Windows iso and get the drive letter assigned to the iso.
$MountSourceWindowsIso = Mount-DiskImage -ImagePath $SourceWindowsIsoPath -PassThru
$DriveSourceWindowsIso = ($MountSourceWindowsIso | Get-Volume).driveletter + ':'

# Mount VMware tools ISO and get the drive letter assigned to the iso.
$MountVMwareToolsIso = Mount-DiskImage -ImagePath $VMwareToolsIsoPath -PassThru
$DriveVMwareToolsIso = ($MountVMwareToolsIso  | Get-Volume).driveletter + ':'

# Copy the content of the Source Windows Iso to a Working Folder
Copy-Item $DriveSourceWindowsIso\* -Destination "$BaseDIR_Temp\WorkingFolder" -Force -Recurse

# Remove the read-only attribtue from the extracted files.
Get-ChildItem "$BaseDIR_Temp\WorkingFolder" -Recurse | %{ if (! $_.psiscontainer) { $_.isreadonly = $false } }

# Copy VMware tools exe in a custom folder in the future ISO
New-Item -ItemType Directory -Path "$BaseDIR_Temp\WorkingFolder\CustomFolder"
# Copy 64 bits VMware tools for installation during OS installation
Copy-Item "$DriveVMwareToolsIso\setup64.exe" -Destination "$BaseDIR_Temp\WorkingFolder\CustomFolder"

# Inject PVSCSI Drivers in boot.wim and install.vim
$pvcsciPath = $DriveVMwareToolsIso + '\Program Files\VMware\VMware Tools\Drivers\pvscsi\Win8\amd64\pvscsi.inf'

# Modify all images in "boot.wim"
Get-WindowsImage -ImagePath "$BaseDIR_Temp\WorkingFolder\sources\boot.wim" | foreach-object {
	Mount-WindowsImage -ImagePath "$BaseDIR_Temp\WorkingFolder\sources\boot.wim" -Index ($_.ImageIndex) -Path "$BaseDIR_Temp\MountDISM"
	Add-WindowsDriver -path "$BaseDIR_Temp\MountDISM" -driver $pvcsciPath -ForceUnsigned
	Dismount-WindowsImage -path "$BaseDIR_Temp\MountDISM" -Save
}

# Modify all images in "install.wim"
Get-WindowsImage -ImagePath "$BaseDIR_Temp\WorkingFolder\sources\install.wim" | foreach-object {
	Mount-WindowsImage -ImagePath "$BaseDIR_Temp\WorkingFolder\sources\install.wim" -Index ($_.ImageIndex) -Path "$BaseDIR_Temp\MountDISM"
	Add-WindowsDriver -Path "$BaseDIR_Temp\MountDISM" -Driver $pvcsciPath -ForceUnsigned
	Dismount-WindowsImage -Path "$BaseDIR_Temp\MountDISM" -Save
}

# Add the autaunattend xml for a basic configuration AND the installation of VMware tools.
Copy-Item $AutoUnattendXmlPath -Destination "$BaseDIR_Temp\WorkingFolder\autounattend.xml"

$OcsdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg"
$oscdimg  = "$OcsdimgPath\oscdimg.exe"
$etfsboot = "$OcsdimgPath\etfsboot.com"
$efisys   = "$OcsdimgPath\efisys_noprompt.bin" # Important for UEFI boot!

$data = '2#p0,e,b"{0}"#pEF,e,b"{1}"' -f $etfsboot, $efisys
Start-Process $oscdimg -args @("-bootdata:$data",'-u2','-udfver102', "$BaseDIR_Temp\WorkingFolder", $DestinationWindowsIsoPath) -Wait -NoNewWindow

# Unmount ISO and VMware tools
$MountSourceWindowsIso | Dismount-DiskImage 
$MountVMwareToolsIso | Dismount-DiskImage
