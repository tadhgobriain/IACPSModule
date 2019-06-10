 # Author: Tadhg O Briain
# Date last modified: 06/06/2019
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
        [String]$ConfigurationFile,

        # Param3 help description
        [Parameter(Mandatory=$False)]
        [Switch]$PortForward
    )

    Begin {
       Try {
            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Continue'
        
            $CMDB = Get-Content -Raw -Path $ConfigurationFile | ConvertFrom-Json

            Set-PowerCLIConfiguration -Scope AllUsers -ParticipateInCEIP $False -Confirm:$False | Out-Null
        }
        Catch {
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }    
    }
    Process {
        Try {
            ForEach ($Computer in $ComputerName) { 
                $Machines = $CMDB.Machines | Where-Object Name -Like $Computer.Split('-')[0]
                If ($Null -eq $Machines) {
                    Write-Error "Ran into an issue: $PSItem $($Computer.Split('-')[0]) not defined in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration"
                }

                $Machine = $Machines.Machine | Where-Object Name -Like $Computer.Split('-')[1] -ErrorAction Stop
                If ($Null -eq $Machine) {
                    Write-Error "Ran into an issue: $PSItem $($Computer.Split('-')[1]) not defined in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration"
                }

                If ($Machine.Hypervisor) { $Hypervisor = $Machine.Hypervisor }
                ElseIf ($Machines.Hypervisor) { $Hypervisor = $Machines.Hypervisor }
                Else { Write-Error "Ran into an issue: $PSItem Hypervisor not defined in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }

                $HypervisorGroup = $CMDB.Hypervisors | Where-Object Name -Like $Hypervisor.Split('-')[0]
                If ($Null -eq $HypervisorGroup){
                    Write-Error "Ran into an issue: $PSItem Hypervisor Group not defined in configuration file" -RecommendedAction "Please check json configuration"
                }
            
                $Hypervisor = $HypervisorGroup.Machine | Where-Object Name -Like $Hypervisor.Split('-')[1]
                If ($Null -eq $Hypervisor){
                    Write-Error "Ran into an issue: $PSItem Hypervisor not defined in configuration file" -RecommendedAction "Please check json configuration"
                }

                Switch -Wildcard ($HypervisorGroup.Name) {
                    "CompHypV*" { 
                        Switch -Wildcard ( $Machine.MemoryStartupBytes ){
                            '*MB' { $MemoryStartupBytes = [int64]$($Machine.MemoryStartupBytes).Replace('MB','') * 1MB }
                            '*GB' { $MemoryStartupBytes = [int64]$($Machine.MemoryStartupBytes).Replace('GB','') * 1GB }
                            '*TB' { $MemoryStartupBytes = [int64]$($Machine.MemoryStartupBytes).Replace('TB','') * 1TB }
                            Default { Write-Error -Message "Ran into an issue: $PSItem No unit (MB/GB/TB) associated with memory allocation for $Computer" -RecommendedAction "Please check json configuration"}
                        }
            
                        $Generation = [int16]$($Machine.Generation)
                        $CPUCount = [int64]$($Machine.CPUCount)

                        $HypervisorFQDN = $Hypervisor.Name + '.' + $Domain
                        $ConfigPath = $Hypervisor.ConfigPath
                        $VHDPath = $Hypervisor.VHDPath
                    
                        If ($PSCmdlet.ShouldProcess($Computer)) {
                            #VM
                            Write-Output "Creating new VM instance: $Computer on $($Hypervisor.Name)"
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
                            }
                        }
                    }
                    "PCL*" {
                        If ($Machine.NumCPU) { $NumCPU = [int32]$($Machine.NumCPU) }
                        ElseIf ($Machines.NumCPU) { $NumCPU = [int32]$($Machines.NumCPU) }
                        Else { Write-Error "Ran into an issue: $PSItem NumCPU not defined in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }

                        If ($Machine.MemoryGB) { $MemoryGB = [decimal]$($Machine.NumCPU) }
                        ElseIf ($Machines.MemoryGB) { $MemoryGB = [decimal]$($Machines.NumCPU) }
                        Else { Write-Error "Ran into an issue: $PSItem MemoryGB not defined in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }

                        If ($Machine.GuestID) { $GuestID = $($Machine.GuestID) }
                        ElseIf ($Machines.GuestID) { $GuestID = $($Machines.GuestID) }
                        Else { Write-Error "Ran into an issue: $PSItem GuestID not defined in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }

                        
                        If ($PSCmdlet.ShouldProcess($Computer)) {
                            #VM
                            Write-Output "Creating new VM instance: $Computer on $($Hypervisor.Name)"
                            Write-Verbose "Memory: $MemoryGB"
                            Write-Verbose "CPU Count: $NumCPU"

                            If ($PortForward) {
                                $HypervisorIP = "$($HypervisorGroup.PFIPRange).$($Hypervisor.Name)"
                                $HypervisorPort = $HypervisorGroup.PFPort  
                            }
                            Else {
                                $HypervisorIP = "$($HypervisorGroup.IPRange).$($Hypervisor.Name)"
                                $HypervisorPort = 443
                            }

                            Connect-VIServer -Server $HypervisorIP -Port $HypervisorPort
                            
                            VMware.VimAutomation.Core\New-VM -Name $Computer -NumCpu $NumCPU -MemoryGB $MemoryGB -GuestId $GuestID -NetworkName 'Virtual Machine Network'
                            <#Set-VMProcessor -VMName $Computer -Count $CPUCount -ComputerName $HypervisorFQDN
                            
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
                            } #>
                        }
                    }
                    Default { Write-Error "Ran into an issue: $PSItem Hypervisor $($HypervisorGroup.Name) defined for ComputerName $Computer not a recognised hypervisor" -RecommendedAction "Please check json configuration" }
                }  
            }
        }
        Catch {
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }
    }
    End {
        Try{

        }
        Catch {
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }
    }
}