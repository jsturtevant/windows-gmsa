function New-CredentialSpec {
    <#
    This function was borrowed from https://github.com/MicrosoftDocs/Virtualization-Documentation/blob/master/windows-server-container-tools/ServiceAccounts/CredentialSpec.psm1
    but removes all the additional checks
	#>

    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [String]
        $AccountName,

        [Parameter(Mandatory = $false)]
        [String]
        $FileName,

        [Parameter(Mandatory = $false)]
        [String]
        $SpecPath,

        [Parameter(Mandatory = $false)]
        [string]
        $Domain,

        [Parameter(Mandatory = $false)]
        [object[]]
        $AdditionalAccounts,

        [Parameter(Mandatory = $false)]
        [switch]
        $NoClobber = $false
    )

    # Get the location to store the cred spec file either from input params or helper function
    if (-not $SpecPath) {
        $SpecPath = "C:\gmsa"
    }  

    # Validate domain information
    if ($Domain) {
        $ADDomain = Get-ADDomain -Server $Domain -ErrorAction Continue

        if (-not $ADDomain) {
            Write-Error "The specified Active Directory domain ($Domain) could not be found.`nCheck your network connectivity and domain trust settings to ensure the current user can authenticate to a domain controller in that domain."
            return
        }
    } else {
        # Use the logged on user's domain if an explicit domain name is not provided
        $ADDomain = Get-ADDomain -Current LocalComputer -ErrorAction Continue

        if (-not $ADDomain) {
            Write-Error "An error ocurred while loading information for the computer account's domain.`nCheck your network connectivity to ensure the computer can authenticate to a domain controller in this domain."
            return
        }

        $Domain = $ADDomain.DNSRoot
	}
    # Clean up account names and validate formatting
    $AccountName = $AccountName.TrimEnd('$')

    if ($AdditionalAccounts) {
        $AdditionalAccounts = $AdditionalAccounts | ForEach-Object {
            if ($_ -is [hashtable]) {
                # Check for AccountName and Domain keys
                if (-not $_.AccountName -or -not $_.Domain) {
                    Write-Error "Invalid additional account specified: $_`nExpected a samAccountName or a hashtable containing AccountName and Domain keys."
                    return
                }
                else {

                    @{
                        AccountName = $_.AccountName.TrimEnd('$')
                        Domain = $_.Domain
                    }
                }
            }
            elseif ($_ -is [string]) {
                @{
                    AccountName = $_.TrimEnd('$')
                    Domain = $Domain
                }
            }
            else {
                Write-Error "Invalid additional account specified: $_`nExpected a samAccountName or a hashtable containing AccountName and Domain keys."
                return
            }
        }
    }

    if (-not $FileName) {
        $FileName = "{0}_{1}" -f $ADDomain.NetBIOSName.ToLower(), $AccountName.ToLower()
    }

    $FullPath = Join-Path $SpecPath "$($FileName.TrimEnd(".json")).json"
    if ((Test-Path $FullPath) -and $NoClobber) {
        Write-Error "A credential spec already exists with the name `"$FileName`".`nRemove the -NoClobber switch to overwrite this file or select a different name using the -FileName parameter."
        return
    }

    # Start hash table for output
    $output = @{}

    # Create ActiveDirectoryConfig Object
    $output.ActiveDirectoryConfig = @{}
    $output.ActiveDirectoryConfig.GroupManagedServiceAccounts = @( @{"Name" = $AccountName; "Scope" = $ADDomain.DNSRoot } )
    $output.ActiveDirectoryConfig.GroupManagedServiceAccounts += @{"Name" = $AccountName; "Scope" = $ADDomain.NetBIOSName }
    if ($AdditionalAccounts) {
        $AdditionalAccounts | ForEach-Object {
            $output.ActiveDirectoryConfig.GroupManagedServiceAccounts += @{"Name" = $_.AccountName; "Scope" = $_.Domain }
        }
    }
    
    # Create CmsPlugins Object
    $output.CmsPlugins = @("ActiveDirectory")

    # Create DomainJoinConfig Object
    $output.DomainJoinConfig = @{}
    $output.DomainJoinConfig.DnsName = $ADDomain.DNSRoot
    $output.DomainJoinConfig.Guid = $ADDomain.ObjectGUID
    $output.DomainJoinConfig.DnsTreeName = $ADDomain.Forest
    $output.DomainJoinConfig.NetBiosName = $ADDomain.NetBIOSName
    $output.DomainJoinConfig.Sid = $ADDomain.DomainSID.Value
    $output.DomainJoinConfig.MachineAccountName = $AccountName

    $output | ConvertTo-Json -Depth 5 | Out-File -FilePath $FullPath -Encoding ascii -NoClobber:$NoClobber
	
	Install-Module powershell-yaml -Force

    $CredSpecJson = Get-Item $FullPath | Select-Object @{
        Name       = 'Name'
        Expression = { $_.Name }
    },
    @{
        Name       = 'Path'
        Expression = { $_.FullName }
    }
	
    $dockerCredSpecPath = $CredSpecJson.Path
    Sleep 2
    $credSpecContents = Get-Content $dockerCredSpecPath | ConvertFrom-Json
 
	# generate the k8s resource
    $resource = [ordered]@{
        "apiVersion" = "windows.k8s.io/v1alpha1";
        "kind" = 'GMSACredentialSpec';
        "metadata" = @{
        "name" = $AccountName
        };
        "credspec" = $credSpecContents
    }

    $ManifestFile = Join-Path $SpecPath "gmsa-cred-spec-gmsa-e2e.yml"
    ConvertTo-Yaml $resource | Set-Content $ManifestFile

    Write-Output "K8S manifest rendered at $ManifestFile"
}


<#
.Synopsis
 Renders a GMSA kubernetes resource manifest.
#>
Param(
    [Parameter(Position = 0, Mandatory = $true)] [String] $AccountName,
    [Parameter(Position = 1, Mandatory = $true)] [String] $ResourceName,
    [Parameter(Position = 2, Mandatory = $false)] [String] $ManifestFile,
    [Parameter(Mandatory=$false)] $Domain,
    [Parameter(Mandatory=$false)] [string[]] $AdditionalAccounts = @()
)
# Logging for troubleshooting
Start-Transcript -Path "C:\gmsa\CredSpec.txt"
# exit on error
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'

# generate the name of the output file if not specified
if (-not $ManifestFile -or $ManifestFile.Length -eq 0) {
    $ManifestFile = "gmsa-cred-spec-$ResourceName.yml"
}
# check the out file doesn't exist
if ([System.IO.File]::Exists($ManifestFile)) {
    throw "Output file $ManifestFile already exists, refusing to overwrite it"
}

# install the dependencies we need
if (-not (Get-WindowsFeature rsat-ad-powershell).Installed) {
    Add-WindowsFeature rsat-ad-powershell
}
if (-not (Get-Command ConvertTo-Yaml -errorAction SilentlyContinue)) {
    Install-Module powershell-yaml -Force
}

. CredentialSpec.ps1
# generate a unique docker cred spec name
$dockerCredSpecName = "tmp-k8s-cred-spec" + -join ((48..57) + (97..122) | Get-Random -Count 64 | ForEach-Object {[char]$_})

if (-not $Domain) {
    $Domain = Get-ADDomain
}
New-CredentialSpec -FileName $dockerCredSpecName -AccountName $AccountName -Domain $Domain.DnsRoot -AdditionalAccounts $AdditionalAccounts
