# Create Windows 2019 OVA Template 
Create an sysprep'd OVA image from a vanilla Windows 2019 ISO
Script to take a vanilla Windows 2019 Server ISO, inject it with PVSCSI/VMXNet3 drivers, build a master VM that's fully patched, sysprep'd which can be cloned and create an OVA. 

## Download Windows ISO
https://www.microsoft.com/en-US/evalcenter/evaluate-windows-server-2019?filetype=ISO
## Ensure you have Windows ADK tools installed (Deployment Tools Only)
https://developer.microsoft.com/en-us/windows/hardware/windows-assessment-deployment-kit
## Ensure the script is run as Administrator
