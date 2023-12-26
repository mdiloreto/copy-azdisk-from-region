Function Copy_AzDiskToDifferentRegion {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDiskName,

        [Parameter(Mandatory)]
        [string]$SourceResourceGroupName,

        [Parameter(Mandatory)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory)]
        [string]$TargetRegion,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    # Ensure Az-Module installation: 
    try{
        if (Get-Module -Name $ModuleName -ListAvailable | Where-Object { $_.Version -ge [Version]$MinimumVersion }) {
            Write-Host "Module $ModuleName is already installed."
        } else {
            Write-Host "Installing module $ModuleName..."
            Install-Module -Name $ModuleName -MinimumVersion $MinimumVersion -Force -AllowClobber -Scope CurrentUser
            Import-Module -Name $ModuleName -Force
            Write-Host "$ModuleName module installed successfully."
        }
    catch {
        Write-Host  "PowerShell Az Module could not be installed: $_"
        return
    }

    try {
        # Ensures you do not inherit an AzContext in your runbook
        Disable-AzContextAutosave -Scope Process

        # Connect to Az Tenant and Subscription
        Connect-AzAccount -TenantId $TenantId -ErrorAction Stop
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    } catch {
        Write-Host "Error connecting to Azure: $_"
        return
    }

    # Check if AzCopy is installed
    try {
        azcopy --version | Out-Null
        Write-Host "AzCopy is already installed."
    } catch {
        Write-Host "AzCopy is not installed. Installing now..."
        Install-AzCopy
    }

    #Start copy operations 
    try {
        # Retrieve the source disk
        $sourceDisk = Get-AzDisk -ResourceGroupName $SourceResourceGroupName -DiskName $SourceDiskName -ErrorAction Stop
    
        # Create the target disk configuration
        $targetDiskconfig = New-AzDiskConfig -SkuName $sourceDisk.Sku.Name -osType $targetOS -UploadSizeInBytes $($sourceDisk.DiskSizeBytes+512)  -Location $TargetRegion -CreateOption 'Upload' -HyperVGeneration $targetVmGeneration -ErrorAction Stop

        # Copy Security Profile Security Type. 
        if ($sourceDisk.SecurityProfile -ne $null -and $sourceDisk.SecurityProfile.SecurityType -ne $null) {
            # Set the security type from the source disk to the target disk
            Set-AzDiskSecurityProfile -Disk $targetDiskconfig -SecurityType $sourceDisk.SecurityProfile.SecurityType
        
            Write-Host "Security profile set successfully."
        } else {
            Write-Host "Source disk does not have a defined SecurityProfile or SecurityType."
        }
        # Create the target disk
        $targetDisk = New-AzDisk -ResourceGroupName $TargetResourceGroupName -DiskName $TargetDiskName -Disk $targetDiskconfig -ErrorAction Stop

    } catch {
        Write-Host "Error occurred while preparing the disks: $_"
        return
    }
    
    try {
        # Grant SAS access to the source disk
        $sourceDiskSas = Grant-AzDiskAccess -ResourceGroupName $SourceResourceGroupName -DiskName $SourceDiskName -DurationInSecond 86400 -Access 'Read' -ErrorAction Stop
    
        # Grant SAS access to the target disk
        $targetDiskSas = Grant-AzDiskAccess -ResourceGroupName $TargetResourceGroupName -DiskName $TargetDiskName -DurationInSecond 86400 -Access 'Write' -ErrorAction Stop
    } catch {
        Write-Host "Error occurred while granting access to disks: $_"
        return
    }
    
    try {
        # Use AzCopy to copy the disk
        azcopy copy $sourceDiskSas.AccessSAS $targetDiskSas.AccessSAS --blob-type PageBlob
    } catch {
        Write-Host "Error occurred during AzCopy operation: $_"
        return
    }
    
    try {
        # Revoke SAS access for the source disk
        Revoke-AzDiskAccess -ResourceGroupName $SourceResourceGroupName -DiskName $SourceDiskName -ErrorAction Stop
    
        # Revoke SAS access for the target disk
        Revoke-AzDiskAccess -ResourceGroupName $TargetResourceGroupName -DiskName $TargetDiskName -ErrorAction Stop
    } catch {
        Write-Host "Error occurred while revoking access to disks: $_"
        return
    }

}

function Install-AzCopy {
    param (
        [string]$InstallPath = 'C:\AzCopy'
    )

    try {
        # Cleanup Destination
        if (Test-Path $InstallPath) {
            Get-ChildItem $InstallPath | Remove-Item -Confirm:$false -Force -ErrorAction Stop
        }

        # Create the installation folder (e.g., C:\AzCopy)
        $null = New-Item -Type Directory -Path $InstallPath -Force -ErrorAction Stop

        # Zip Destination
        $zip = "$InstallPath\AzCopy.zip"

        # Download AzCopy zip for Windows
        Start-BitsTransfer -Source "https://aka.ms/downloadazcopy-v10-windows" -Destination $zip -ErrorAction Stop

        # Expand the Zip file
        Expand-Archive $zip $InstallPath -Force -ErrorAction Stop

        # Move to $InstallPath
        Get-ChildItem "$($InstallPath)\*\*" | Move-Item -Destination "$($InstallPath)\" -Force -ErrorAction Stop

        # Cleanup – delete ZIP and old folder
        Remove-Item $zip -Force -Confirm:$false -ErrorAction Stop
        Get-ChildItem "$($InstallPath)\*" -Directory | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -Confirm:$false -ErrorAction Stop }

        # Add InstallPath to the System Path if it does not exist
        if ($env:PATH -notcontains $InstallPath) {
            $path = ($env:PATH -split ";")
            if (!($path -contains $InstallPath)) {
                $path += $InstallPath
                $env:PATH = ($path -join ";")
                $env:PATH = $env:PATH -replace ";;",";"
            }
            [Environment]::SetEnvironmentVariable("Path", ($env:path), [System.EnvironmentVariableTarget]::Machine)
        }
        Write-Host "AzCopy has been installed successfully."
    } catch {
        Write-Host "Error during AzCopy installation: $_"
    }
}

$sourceRG = "TW_Virtual-Machine"
$sourceDiskName = "tw-vm2_osdisk-test-copy"
$targetDiskName = "tw-vm2_osdisk-test-copy2"
$targetRG = "TW_Virtual-Machine"
$targetLocate = "eastus"
$targetVmGeneration = "V2" # either V1 or V2
#Expected value for OS is either "Windows" or "Linux"
$targetOS = "Windows"
$SubscriptionId = "f64ded84-0267-4150-b30c-a1f7ed8abe5f"
$TenantId = "88940f07-5551-49e6-8453-c578e8759aaf"

# Function call with your variables
Copy_AzDiskToDifferentRegion `
    -SourceDiskName $sourceDiskName `
    -SourceResourceGroupName $sourceRG `
    -TargetResourceGroupName $targetRG `
    -TargetRegion $targetLocate `
    -TenantId $TenantId `
    -SubscriptionId $SubscriptionId
