[cmdletbinding()]
param(
    # Path where json config files are stored.
    [Parameter(Mandatory=$true)]
    [Alias("Path")]
    [string]$ConfigPath
)

# Enum to help give better information about exit code. 
Enum ExitCode{
    CantFindConfigFile = 10
    CantReadConfigFile = 11 
}


# Import the classes into scope
Add-Type -AssemblyName System.Web

. "$PSScriptRoot\KijijiClasses.ps1"

if($Verbose.IsPresent){
    $previousVerbosePreference = $VerbosePreference
    $VerbosePreference = [System.Management.Automation.ActionPreference]::Continue
}

# Import the search alert monitor configs
if(Test-Path $ConfigPath -PathType Leaf){
    try{
        $searchConfig = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    } catch {
        exit [ExitCode]::CantReadConfigFile
    }
} else {
    # throw [System.ArgumentException]"Could not find file."
    exit [ExitCode]::CantFindConfigFile
}

# Rebuild the database credentials from file
$databaseCredentials = [System.Management.Automation.PSCredential]::new($searchConfig.db.username, ($searchConfig.db.password | ConvertTo-SecureString))

# Initiate the database connection object
$connection = [DatabaseConnectionProperties]::new($searchConfig.db.server,$searchConfig.db.port,$searchConfig.db.name,$databaseCredentials)

# Cycle each individual search configuration located in this file
foreach($search in $searchConfig.search_config){
    if($search.enabled){ 
        # Loop the search urls in this configuration
        foreach($searchURL in $search.search_URLS){
            # Build the search object
            $kijijiSearch = [KijijiSearch]::new($searchURL, $search.searchThreshold, $search.newListingThreshold, $search.oldListingThreshold, $search.flagOnlyChanges, $connection)
            # Start the search based on config options
            $kijijiSearch.Search()
            # Load any new listings and update existing ones where applicable
            $kijijiSearch.UpdateSQLListings()
            # Close the search object.
            $kijijiSearch.Completed()
        }
    }
}

# Reset verbosity preference
if($Verbose.IsPresent){
    $VerbosePreference = $previousVerbosePreference
}