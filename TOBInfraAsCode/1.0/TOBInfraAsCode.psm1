 # Author: Tadhg O Briain
# Date last modified: 27/05/2019
Function New-VMInstance {     
    <#
    .Synopsis
        Creates a new VM (if not already present) based on description in CMDB_Server.json
    .DESCRIPTION
        
    .EXAMPLE
        Example of how to use this cmdlet
    .EXAMPLE
        Another example of how to use this cmdlet
    #>

    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    [OutputType([int])]
    [Alias()]
    [OutputType([int])]

    Param (
        # Param1 help description
        [Parameter(Mandatory=$True,
            ValueFromPipeline=$True)]
        [String[]]$ComputerName,

        # Param2 help description
        [Parameter(Mandatory=$True)]
        [ValidateScript({
            #Syntax validation
            If(-Not ($_ | Test-Path -IsValid) ){
                Throw "Path to file not in a valid format"
            }
            If(-Not ($_ | Test-Path) ){
                Throw "File or folder does not exist"
            }
            If(-Not ($_ | Test-Path -PathType Leaf) ){
                Throw "The ConfigurationFile argument must be a file. Folder paths are not allowed."
            }
            If($_ -notmatch "(\.json)"){
                Throw "The file specified in the ConfigurationFile argument must be of type json"
            }
            #Checking the last character of the file path
            Switch ($_[-1]) {
                '.' {Throw 'A valid filepath cannot end with a period.'}
                '\' {Throw 'A valid filepath cannot end with a backslash.'}
                {$_ -match '\s'} {Throw 'A valid filepath cannot end with a blank character.'}
                Default {$True}
            }
            Return $True 
        })]
        [ValidateNotNullOrEmpty()]
        [String]$ConfigurationFile
    )

    Begin { 
        $CMDB = Get-Content -Raw -Path $ConfigurationFile | ConvertFrom-Json
    }
    Process {
        ForEach ($Computer in $ComputerName) {
            $Machines = $CMDB.Machines | Where-Object Name -Like $Computer.Split('-')[0] #Catch non-exist error
            $Machine = $Machines.Machine | Where-Object Name -Like $Computer.Split('-')[1] #Catch non-exist error
            $HypervisorGroup = $CMDB.Hypervisors | Where-Object {$_.Machine.Name -Like $Machine.Hypervisor}
            $Hypervisor = $HypervisorGroup.Machine | Where-Object Name -Like $Machine.Hypervisor #Catch non-exist error

            Switch -Wildcard ( $Machine.MemoryStartupBytes ){
                '*MB' { $MemoryStartupBytes = [int64]$($Machine.MemoryStartupBytes).Replace('MB','') * 1MB }
                '*GB' { $MemoryStartupBytes = [int64]$($Machine.MemoryStartupBytes).Replace('GB','') * 1GB }
                '*TB' { $MemoryStartupBytes = [int64]$($Machine.MemoryStartupBytes).Replace('TB','') * 1TB }
                Default { Write-Error -Message "No unit (MB/GB/TB) associated with memory allocation for $Computer in $ConfigurationFile"}
            }

            $Generation = [int16]$($Machine.Generation)
            $CPUCount = [int64]$($Machine.CPUCount)

            Switch -Wildcard ($Hypervisor.Name) {
                "CompHypV*" { 
                    $HypervisorFQDN = $Hypervisor.Name + '.' + $Domain
                    $ConfigPath = $Hypervisor.ConfigPath
                    $VHDPath = $Hypervisor.VHDPath                    
                }
                "CompVMW*" {

                }
                Default { Write-Error "No hypervisor defined for VM $Computer" -RecommendedAction "Please check json configuration" }
            }

            If ($PSCmdlet.ShouldProcess($Computer)) {
                #VM
                Write-Output "Creating new VM instance: $Computer"
                Write-Verbose "Memory: $MemoryStartupBytes"
                Write-Verbose "CPU Count: $CPUCount"
                Write-Verbose "Generation: $Generation"
                Write-Verbose "Boot Device: $($Machine.BootDevice)"
                Write-Verbose "Path: $ConfigPath"
                Write-Verbose "Switch: $($Machine.DefaultNIC.vSwitch)"
                Write-Verbose "Hypervisor: $HypervisorFQDN"
                
                Hyper-V\New-VM -Name $Computer -MemoryStartupBytes $MemoryStartupBytes -Generation $Generation -NoVHD -BootDevice $Machine.BootDevice -Path $ConfigPath -SwitchName $Machine.DefaultNIC.vSwitch -ComputerName $HypervisorFQDN
                Set-VMProcessor -VMName $Computer -Count $CPUCount -ComputerName $HypervisorFQDN
                
                #Default NIC
                If ( $Machine.DefaultNIC.MACType -eq 'Static') {
                    Write-Verbose "Setting default NIC to 'STATIC' with MAC address $($Machine.DefaultNIC.Mac)"
                    Set-VMNetworkAdapter -VMName $Computer -StaticMacAddress $Machine.DefaultNIC.Mac -DhcpGuard $Machine.DefaultNIC.DHCPGuard -RouterGuard $Machine.DefaultNIC.RouterGuard -MacAddressSpoofing $Machine.DefaultNIC.MacAddressSpoofing -ComputerName $HypervisorFQDN
                }
                Else {
                     Set-VMNetworkAdapter -VMName $Computer -DhcpGuard $Machine.DefaultNIC.DHCPGuard -RouterGuard $Machine.DefaultNIC.RouterGuard -MacAddressSpoofing $Machine.DefaultNIC.MacAddressSpoofing -ComputerName $HypervisorFQDN 
                }
                
                Write-Verbose "DHCP Guard: $($Machine.DefaultNIC.DHCPGuard)"
                Write-Verbose "Router Guard: $($Machine.DefaultNIC.RouterGuard)"
                Write-Verbose "MAC Address Spoofing: $($Machine.DefaultNIC.MacAddressSpoofing)"

                #VHDs
                ForEach ($VHD in $Machine.VHDs) {
                    Write-Output "Creating new VHD(s) for VM instance: $Computer"  
                    $ControllerLocation = [Int32]$($VHD.ControllerLocation)

                    Switch -Wildcard ( $VHD.SizeBytes ){
                        '*GB' { $SizeBytes = [uint64]$($VHD.SizeBytes).Replace('GB','') * 1GB }
                        '*TB' { $SizeBytes = [uint64]$($VHD.SizeBytes).Replace('TB','') * 1TB }
                        Default { Write-Error -Message "No unit (MB/GB/TB) associated with VHD size in JSON for $Computer"}
                    }

                    If ($VHD.Type -eq 'Fixed') { 
                        New-VHD -Path "$VHDPath\$Computer\$Computer-$($VHD.Name).vhdx" -SizeBytes $SizeBytes -Fixed -ComputerName $HypervisorFQDN  
                    }
                    Else { New-VHD -Path "$VHDPath\$Computer\$Computer-$($VHD.Name).vhdx" -SizeBytes $SizeBytes -ComputerName $HypervisorFQDN }

                    Add-VMHardDiskDrive -VMName $Computer -Path "$($Hypervisor.VHDPath)\$Computer\$Computer-$($VHD.Name).vhdx" -ControllerLocation $ControllerLocation -ComputerName $HypervisorFQDN
                
                # Need to code for multiple NICs
                }#>
            }
        }
    }
    End {
    }
}


Export-ModuleMember -Function New-VMInstance