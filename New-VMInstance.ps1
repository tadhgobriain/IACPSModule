# Author: Tadhg O Briain
# Date last modified: 14/06/2019

Function Test-ValidProperty {
# Tests to see whether an objects property exists and is not empty
    Param (
        [Parameter(Mandatory=$True)]
        $Object,

        [Parameter(Mandatory=$True)]
        $ObjectProperty
    )

    (Get-Member -InputObject $Object -Name $ObjectProperty) -And $($Object.$ObjectProperty)
}
Function New-VMInfrastructure {     
    <#
    .Synopsis
        Creates a new piece of virtual infrastructure based on description in provided configuration file
    .DESCRIPTION
        (if not already present) JSON
    .EXAMPLE
        Example of how to use this cmdlet
    .EXAMPLE
        Another example of how to use this cmdlet
    #>

    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    [OutputType([int])]
    [Alias()]

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
        [Switch]$PortForward,

        # Param4 help description
        [Parameter(Mandatory=$False)]
        [Switch]$Force
    )

    Begin {
       Try {
            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Continue'
        
            $CMDB = Get-Content -Raw -Path $ConfigurationFile | ConvertFrom-Json

            Set-PowerCLIConfiguration -Scope AllUsers -ParticipateInCEIP $False -Confirm:$False | Out-Null
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$False | Out-Null
        }
        Catch {
            $PSCmdlet.ThrowTerminatingError($PSItem)
        }    
    }
    Process {
        Try {
            ForEach ($Computer in $ComputerName) { 
                If (Test-ValidProperty $CMDB 'Machines') { 
                    $Machines = $CMDB.Machines | Where-Object Name -Like $Computer.Split('-')[0] 
                    If ($Null -eq $Machines) { Write-Error "Ran into an issue: Machines $($Computer.Split('-')[0]) not found in configuration file" -RecommendedAction "Please check json configuration" }
                }
                Else {
                    Write-Error "Ran into an issue: Machines $($Computer.Split('-')[0]) not defined or blank in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration"
                }

                If (Test-ValidProperty $Machines 'Machine') {
                    $Machine = $Machines.Machine | Where-Object Name -Like $Computer.Split('-')[1]
                    If ($Null -eq $Machine) { Write-Error "Ran into an issue: $($Computer.Split('-')[1]) not found in configuration file for machines $($Computer.Split('-')[0])" -RecommendedAction "Please check json configuration" }
                }
                Else {
                    Write-Error "Ran into an issue: $($Computer.Split('-')[1]) not defined or blank in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration"
                }

                # Check is there a hypervisor defined on either machines or machine, precedence given to machine property
                $VMHypervisor = $Null
                If (Test-ValidProperty $Machines 'Hypervisor') { $VMHypervisor = $Machines.Hypervisor }
                If (Test-ValidProperty $Machine 'Hypervisor') { $VMHypervisor = $Machine.Hypervisor }
                If ($Null -eq $VMHypervisor) { Write-Error "Ran into an issue: Hypervisor not defined, blank or not found in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }
                
                # Get the hypervisor group details based on VMHypervisor
                $HypervisorGroup = $CMDB.Hypervisors | Where-Object Name -Like $VMHypervisor.Split('-')[0]
                If ($Null -eq $HypervisorGroup){
                    Write-Error "Ran into an issue: Hypervisor Group $($VMHypervisor.Split('-')[0]) not found in configuration file" -RecommendedAction "Please check json configuration"
                }
            
                # Get the hypervisor details based on VMHypervisor
                $Hypervisor = $HypervisorGroup.Machine | Where-Object Name -Like $VMHypervisor.Split('-')[1]
                If ($Null -eq $Hypervisor){
                    Write-Error "Ran into an issue: Hypervisor $VMHypervisor not found in configuration file" -RecommendedAction "Please check json configuration"
                }

                # Check is the hypervisor type defined
                If (!(Test-ValidProperty $HypervisorGroup 'Type')) {
                    Write-Error "Ran into an issue: HypervisorGroup Type not defined or blank in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration"
                }


                Switch -Wildcard ($HypervisorGroup.Type) {
                    "HyperV" { 
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
                    "ESXi" {
                        # Check is NumCPU defined on either machines or machine, precedence given to machine property
                        $NumCPU = $Null # Might need this if doing diff machine groups. Check scoping
                        If (Test-ValidProperty $Machines 'NumCPU') { $NumCPU = [int32]$($Machines.NumCPU) }
                        If (Test-ValidProperty $Machine 'NumCPU') { $NumCPU = [int32]$($Machine.NumCPU) }
                        If ($Null -eq $NumCPU) { Write-Error "Ran into an issue: NumCPU not defined or blank in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }

                        # Check is MemoryGB defined on either machines or machine, precedence given to machine property
                        $MemoryGB = $Null # Might need this if doing diff machine groups. Check scoping
                        If (Test-ValidProperty $Machines 'MemoryGB') { $MemoryGB = [decimal]$($Machines.NumCPU) }
                        If (Test-ValidProperty $Machine 'MemoryGB') { $MemoryGB = [decimal]$($Machine.NumCPU) }
                        If ($Null -eq $MemoryGB) { Write-Error "Ran into an issue: MemoryGB not defined or blank in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }

                        # Check is GuestID defined on either machines or machine, precedence given to machine property
                        $GuestID = $Null # Might need this if doing diff machine groups. Check scoping
                        If (Test-ValidProperty $Machines 'GuestID') { $GuestID = $($Machines.GuestID) }
                        If (Test-ValidProperty $Machine 'GuestID') { $GuestID = $($Machine.GuestID) }
                        If ($Null -eq $GuestID) { Write-Error "Ran into an issue: GuestID not defined or blank in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }
                        

                        # Check is PortGroups defined on either machines or machine, precedence given to machine property
                        $PortGroups = $Null
                        If (Test-ValidProperty $Machines 'PortGroups') { $PortGroups = $($Machines.PortGroups) }
                        If (Test-ValidProperty $Machine 'PortGroups') { $PortGroups = $($Machine.PortGroups) }
                        If ($Null -eq $PortGroups) { Write-Error "Ran into an issue: PortGroups not defined or blank in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }
                      
                        #VM
                        Write-Output "Creating new VM instance: $Computer on $($Hypervisor.Name)"
                        Write-Verbose "Memory: $MemoryGB"
                        Write-Verbose "CPU Count: $NumCPU"
                        Write-Verbose "CPU Count: $GuestID"
                        ForEach ($Portgroup in $PortGroups) { Write-Verbose "Portgroup: $($Portgroup.Name)" }

                        If ($PSCmdlet.ShouldProcess($Computer)) {
                            
                            If ($PortForward) {
                                $PFIPRange = $Null
                                If (Test-ValidProperty $HypervisorGroup 'PFIPRange') { $PFIPRange = $($HypervisorGroup.PFIPRange) }
                                If (Test-ValidProperty $Hypervisor 'PFIPRange') { $PFIPRange = $($Hypervisor.$PFIPRange) }
                                If ($Null -eq $PFIPRange) { Write-Error "Ran into an issue: PFIPRange not defined or blank in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }
                      
                                $HypervisorIP = "$($HypervisorGroup.PFIPRange).$($Hypervisor.Name)"
                                $HypervisorPort = $HypervisorGroup.PFPort  
                            }
                            Else {
                                If (Test-ValidProperty $Machines 'PortGroups') { $PortGroups = $($Machines.PortGroups) }
                                If (Test-ValidProperty $Machine 'PortGroups') { $PortGroups = $($Machine.PortGroups) }
                                If ($Null -eq $PortGroups) { Write-Error "Ran into an issue: PortGroups not defined or blank in configuration file for ComputerName $Computer" -RecommendedAction "Please check json configuration" }
                      
                                $HypervisorIP = "$($HypervisorGroup.IPRange).$($Hypervisor.Name)"
                                $HypervisorPort = 443
                            }

                            Connect-VIServer -Server $HypervisorIP -Port $HypervisorPort
                            
                            If (!(Get-VM -Name $Computer)) { 
                                VMware.VimAutomation.Core\New-VM -Name $Computer -NumCpu $NumCPU -MemoryGB $MemoryGB -GuestId $GuestID
                            }
                            ElseIf ((Get-VM -Name $Computer) -And $Force -And ($PSCmdlet.ShouldContinue($Computer, 'Overwriting existing VM with same name')) {
                                VMware.VimAutomation.Core\Remove-VM VM -DeletePermanently -Confirm:$False
                                VMware.VimAutomation.Core\New-VM -Name $Computer -NumCpu $NumCPU -MemoryGB $MemoryGB -GuestId $GuestID
                            }
                            Else { Write-Error "Ran into an issue: $Computer already exists on $Hypervisor" -RecommendedAction "Please check json configuration" }

                            # NICs
                            ForEach ($Portgroup in $PortGroups) {
                                $PG = Get-VirtualPortGroup -Name $($Portgroup.Name) #checkexist
                                $MAC = ($Machines.MACRoot + '-' + $Machine.MAC) -replace ':','-' #checkexist
                                Write-Verbose "New network Adapter: Portgroup $PG, MAC $MAC"
                                New-NetworkAdapter -VM $Computer -Portgroup $PG -StartConnected -Confirm:$False
                            }
                            <#
                            # Disks
                               
                            
                            #>
                        }
                    }
                    Default { Write-Error "Ran into an issue: Hypervisor $($HypervisorGroup.Type) defined for ComputerName $Computer not a recognised hypervisor" -RecommendedAction "Please check json configuration" }
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