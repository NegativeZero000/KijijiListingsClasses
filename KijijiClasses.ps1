#requires -modules SimplySQL

class DatabaseConnectionProperties{
    # Simple class to control database connection parameters
    # Variables
    [string]$Server
    [int]$Port
    [string]$Database
    [System.Management.Automation.PSCredential]$Credential

    # Constructors
    DatabaseConnectionProperties(
            [string]$Server,
            [int]$Port,
            # Database Name
            [string]$Database,
            # Authentication Credentials
            [System.Management.Automation.PSCredential]$Credential
        ){
        $this.Server = $Server
        $this.Port = $Port
        $this.Database = $Database
        $this.Credential = $Credential
    }

    # Return a hashtable of non null/empty class properties 
    # This can be used for splatting to a db connection
    [hashtable] toHashTable(){
        $hashtable = @{}
        if(-not [string]::IsNullOrEmpty($this.server)){$hashtable.Server = $this.Server}
        if($this.Port){$hashtable.Port = $this.Port}
        if(-not [string]::IsNullOrEmpty($this.Database)){$hashtable.Database = $this.Database}
        if(-not [string]::IsNullOrEmpty($this.Credential)){$hashtable.Credential = $this.Credential}
        return $hashtable
    }
}

class KijijiListing{
    [int]$id
    [uri]$url
    [string]$price
    [string]$title
    [string]$distance
    [string]$location
    [string]$posted
    [string]$shortdescription
    [datetime]$lastsearched
    [uri]$searchURL
    [uri]$imageurl
    [int]$discovered
    [byte[]]$image
    static $parsingRegexes = @{
        id          = '(?sm)data-ad-id="(\w+)"'
	    url         = '(?sm)data-vip-url="(.*?)"'
	    price       = '(?sm)<div class="price">(.*?)</div>'
        image       = '(?sm)<div class="image">.*?<img src="(.*?)"'
	    title       = '(?sm)<div class="title">.*?">(.*?)</a>'
	    distance    = '(?sm)<div class="distance">(.*?)</div>'
	    location    = '(?sm)<div class="location">(.*?)<span'
	    postedTime  = '<span class="date-posted">(.*?)</span>'
	    description = '(?sm)<div class="description">(.*?)<div class="details">'
    }

    KijijiListing([string]$HTML,[uri]$SearchUrl,[datetime]$Processed){
        # Use the raw html of a listing and parse out the present properties. 
        $this.iD               = if($HTML -match [KijijiListing]::parsingRegexes["id"]){$matches[1]};
        $this.uRL              = if($HTML -match [KijijiListing]::parsingRegexes["url"]){$matches[1]};
        $this.price            = if($HTML -match [KijijiListing]::parsingRegexes["price"]){$matches[1].trim().trimstart('$')};
        $this.title            = if($HTML -match [KijijiListing]::parsingRegexes["title"]){[System.Web.HttpUtility]::HtmlDecode($matches[1].trim())};
        $this.distance         = if($HTML -match [KijijiListing]::parsingRegexes["distance"]){[System.Web.HttpUtility]::HtmlDecode($matches[1].trim())};
        $this.location         = if($HTML -match [KijijiListing]::parsingRegexes["location"]){[System.Web.HttpUtility]::HtmlDecode($matches[1].trim())};
        $this.posted           = if($HTML -match [KijijiListing]::parsingRegexes["postedTime"]){[System.Web.HttpUtility]::HtmlDecode($matches[1].trim())};
        $this.shortDescription = if($HTML -match [KijijiListing]::parsingRegexes["description"]){[System.Web.HttpUtility]::HtmlDecode($matches[1].trim())};
        $this.imageURL         = if($HTML -match [KijijiListing]::parsingRegexes["image"]){$matches[1]};
        $this.searchURL        = $SearchURL
        $this.lastsearched     = $Processed 
        $this.discovered       = 0
    }

    # Simple list like output of non hidden properties. 
    [string]toString(){
        $properties = $this.psobject.properties.name 
        $maxPropertyNameLength = ($properties | Measure-Object -Maximum -Property Length).Maximum
        return ($properties | ForEach-Object{Write-Output ("{0}: {1}" -f $_.PadRight($maxPropertyNameLength, " "),$this.$_)}) -join "`n"
    }

    # Hashtable of parameters designed to be splatted to Invoke-SQLUpdate
    [hashtable]getSplattableSQLInsert(){
        return @{
            Query = "INSERT into listings"

        }
    }
}

class KijijiSearch{
    # Variables
    [int]$searchURLID
    [uri]$searchURL
    hidden $_webClient = [System.Net.WebClient]::new()
    # Identifiable name to associate to the MariaDB Connection
    hidden $_databaseConnectionName = "Kijiji"
    [datetime]$SearchExecuted
    # Search result meta data
    $firstListingResultIndex    = 0
    $lastListingResultIndex     = 0 
    $totalNumberOfSearchResults = 0
    $maximumResultsPerSearch = 0
    [datetime]$newListingCutoffDate
    $listings = [System.Collections.ArrayList]::new()
    static $parsingRegexes = @{
        # Current listing index as well as total results. Helps determine number of pages.
        TotalListingNumbers = '(?sm)<div class="showing">.*?Showing (?<FirstListingResultIndex>[\d,]+) - (?<LastListingResultIndex>[\d,]+) of (?<TotalNumberOfSearchResults>[\d,]+) Ads</div>'
        # Determine unique listing html blocks
        Listing = '(?sm)data-ad-id="\w+".*?<div class="details">'
    }
    
    # Contructors
    KijijiSearch(
            # Kijiji Search URL
            [uri]$URL,
            [int]$MaximumResults,
            # Database connection parameters
            [int]$NewListingThresholdHours,
            [DatabaseConnectionProperties]$ConnectionParameters
        ){
        # Initialize the webclient for searching Kijiji. WebClient is used as Invoke-WebRequest has historically stalled
        $this._webClient.Encoding = [System.Text.Encoding]::UTF8
        $this._webClient.CachePolicy = [System.Net.Cache.RequestCachePolicy]::new([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)

        # Initialize the database connection
        try{
            $databaseConnectionParameters = $ConnectionParameters.toHashTable()
            Open-MySqlConnection @databaseConnectionParameters -ConnectionName $this._databaseConnectionName
        } catch {
            throw "Unable to open SQL connection: $($_[0].Exception.message)"
        } finally {
            # Remove the connection parameters from memory
            Remove-Variable databaseConnectionParameters
        }

        # Ensure the search URL is validated and run the search.
        if([KijijiSearch]::ValidateKijijiURL($URL)){
            $this.searchURL = $URL
            $this.searchURLID = $this.GetSQLSearchURLID($URL)
            $this.maximumResultsPerSearch = $MaximumResults
            $this.searchURL = [KijijiSearch]::_AddPageNumber($this.searchURL)
            $this.newListingCutoffDate = (Get-Date).AddHours(-$NewListingThresholdHours)
        }
    }


    # Simple list like output of non hidden properties. 
    [string]toString(){
        $properties = $this.psobject.properties.name 
        $maxPropertyNameLength = ($properties | Measure-Object -Maximum -Property Length).Maximum
        return ($properties | ForEach-Object{Write-Output ("{0}: {1}" -f $_.PadRight($maxPropertyNameLength, " "),$this.$_)}) -join "`n"
    }

    [int] GetSQLSearchURLID([uri]$URL){
        # See if this search url is in the URL table. If not add it.
        $urlID = Invoke-SqlScalar "SELECT urlid FROM searchurls WHERE url = @url" -Parameters @{url=$URL} -ConnectionName $this._databaseConnectionName
        if(-not $urlID){
            # This ID is not in the database. Add it.
            try{
                # Insert the URL record into the database.  
                Invoke-SqlUpdate "INSERT INTO searchurls (url) VALUES (@url)" -Parameters @{url=$URL} -ConnectionName $this._databaseConnectionName
                # Get the new id
                $urlID = Invoke-SqlScalar "SELECT urlid FROM searchurls WHERE url = @url" -Parameters @{url=$URL} -ConnectionName $this._databaseConnectionName
            } catch {Write-Warning ("GetSQLSearchURLID: " + $_[0].Exception.Message)}
        }

        return $urlID
    }

    # Instance Methods
    Search(){
        # Performs a kijiji web search

        # Set the search execution time to now
        $this.SearchExecuted = Get-Date

        # Run the search and parse the page.
        $rawHTML = $this._webClient.DownloadString($this.searchURL)

        # Get search meta data from the first page of the search.
        if($rawHTML -match [KijijiSearch]::parsingRegexes["TotalListingNumbers"]){
            $this.firstListingResultIndex    = $Matches["FirstListingResultIndex"] -as [int]
            $this.lastListingResultIndex     = $Matches["LastListingResultIndex"] -as [int]
            $this.totalNumberOfSearchResults = $Matches["TotalNumberOfSearchResults"] -as [int]
        }

        # Parse any listings into class objects
        if($this.totalNumberOfSearchResults -gt 0){
            $listingHTML = [regex]::Matches($rawHTML,[KijijiSearch]::parsingRegexes["Listing"]).Value
            $listingHTML | ForEach-Object{
                $this.listings.add([KijijiListing]::new($_,$this.searchURL,$this.SearchExecuted))
            }
        }
    }

    UpdateSQLListings(){
        # Load the currentl listings into the database. New ones will be added outright. If there are conflicts outside a date thresholds then
        # updates to current data may be done.
        
        # Listings that will be added to the database as new entries
        $listingsToAdd  = [System.Collections.ArrayList]::new()
        # Listings that will be compared to exising entries
        $listingsToUpdate = [System.Collections.ArrayList]::new() 

        # Check each listing to see if it already exists in the database
        $this.listings | ForEach-Object{
            $sqlResult = Invoke-SqlQuery "Select id, lastsearched from listings where id = @id" -Parameters @{id=$_.id} -ConnectionName $this._databaseConnectionName
            if($sqlResult){
                # This id historically exists. Check to see if it was found recently.
                Write-host $sqlResult
            } else {
                # This ID is not located in the database. 
            }
        }
        
    }

    Completed(){
        # Called to finilize search. Currently just close database connection
        if(Get-SqlConnection -ConnectionName $this._databaseConnectionName){Close-SqlConnection -ConnectionName $this._databaseConnectionName}
    }

    hidden static [uri]_AddPageNumber([uri]$url){
        # Deep Kijiji searches are done using page numbers. The first page of the search typically does not have one. 
        # Add a page number if this url does not have one. 
        $pageSegmentRegex = "page\-\d+"

        if( $url.Segments -match $pageSegmentRegex){
            # This url has a page number amongst its segments. Return as is
            return $url
        } else {
            # No page segment located. Add one as the second last segment
            return ([System.UriBuilder]::new(
                    $URL.Scheme,
                    $URL.Host,
                    $URL.port, 
                    -join @($url.Segments[0..($url.Segments.Count-2)]) + "page-1/" + $url.Segments[-1],
                    $URL.Query)
                ).Uri.AbsoluteUri -as [uri]   
        }
    }

    # Static Methods
    [boolean] static ValidateKijijiURL([uri]$URL){
        # Ensure that the URL is well formed kijiji url
        return ($url.Host -eq "www.kijiji.ca")
    }
}

<#
    Class Testing
#>

# Import the search alert monitor configs
$ConfigsPath = "D:\task"
$searchConfigFile = Get-ChildItem $ConfigsPath -filter "*.cfg.json" | select -First 1
$searchConfig = $searchConfigFile | Get-Content -raw | ConvertFrom-Json

# Rebuild the credentials from file
$databaseCredentials = [System.Management.Automation.PSCredential]::new($searchConfig.db.username, ($searchConfig.db.password | ConvertTo-SecureString))

# Initiate the search object
$connection = [DatabaseConnectionProperties]::new($searchConfig.db.server,$searchConfig.db.port,$searchConfig.db.name,$databaseCredentials)
$kijijiSearch = [KijijiSearch]::new($searchConfig.searchURLS[0], $searchConfig.searchThreshold, $searchConfig.newListingThreshold, $connection)

$kijijiSearch.Search()
$kijijiSearch.UpdateSQLListings()

$kijijiSearch.Completed()