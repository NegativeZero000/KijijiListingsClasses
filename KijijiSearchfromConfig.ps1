# Import the classes into scope
Add-Type -AssemblyName System.Web

. M:\code\KijijiListingsClasses\KijijiClasses.ps1

$previousVerbosePreference = $VerbosePreference
$VerbosePreference = [System.Management.Automation.ActionPreference]::Continue

# Import the search alert monitor configs
$ConfigsPath = "D:\task"
$searchConfigFiles = Get-ChildItem $ConfigsPath -filter "*.cfg.json"

foreach($searchConfigFile in $searchConfigFiles){ 
    $searchConfig = $searchConfigFile | Get-Content -raw | ConvertFrom-Json

    # Rebuild the credentials from file
    $databaseCredentials = [System.Management.Automation.PSCredential]::new($searchConfig.db.username, ($searchConfig.db.password | ConvertTo-SecureString))

    # Initiate the search object
    $connection = [DatabaseConnectionProperties]::new($searchConfig.db.server,$searchConfig.db.port,$searchConfig.db.name,$databaseCredentials)

    # Loop the searches in this file
    for($searchIndex = 0; $searchIndex -lt $searchConfig.searchURLS.Count; $searchIndex++){
        # Build the search object
        $kijijiSearch = [KijijiSearch]::new($searchConfig.searchURLS[$searchIndex], $searchConfig.searchThreshold, $searchConfig.newListingThreshold, $connection)
        # Start the search based on config options
        $kijijiSearch.Search()
        # Load any new listings and update existing ones where applicable
        $kijijiSearch.UpdateSQLListings()
        # Close the search object.
        $kijijiSearch.Completed()
    }
}


# Reset verbosity preference
$VerbosePreference = $previousVerbosePreference
