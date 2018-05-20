﻿#requires -modules SimplySQL
Add-Type -AssemblyName System.Web

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
    [datetime]$posted
    [string]$shortdescription
    [datetime]$lastsearched
    [int]$searchURLID
    [uri]$imageurl
    [int]$discovered
    [byte[]]$image
    [string]$changes

    static [string]$kijijiDateFormat = "dd/MM/yyyy" # Date time format template
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

    KijijiListing([string]$HTML,[int]$SearchUrlID,[datetime]$Processed){
        # Use the raw html of a listing and parse out the present properties. 
        $this.iD               = if($HTML -match [KijijiListing]::parsingRegexes["id"]){$matches[1]};
        $this.uRL              = if($HTML -match [KijijiListing]::parsingRegexes["url"]){$matches[1]};
        $this.price            = if($HTML -match [KijijiListing]::parsingRegexes["price"]){$matches[1].trim().trimstart('$')};
        $this.title            = if($HTML -match [KijijiListing]::parsingRegexes["title"]){[System.Web.HttpUtility]::HtmlDecode($matches[1].trim())};
        $this.distance         = if($HTML -match [KijijiListing]::parsingRegexes["distance"]){[System.Web.HttpUtility]::HtmlDecode($matches[1].trim())};
        $this.location         = if($HTML -match [KijijiListing]::parsingRegexes["location"]){[System.Web.HttpUtility]::HtmlDecode($matches[1].trim())};
        $this.posted           = if($HTML -match [KijijiListing]::parsingRegexes["postedTime"]){
                [KijijiListing]::ConvertFromKijijiDate([System.Web.HttpUtility]::HtmlDecode($matches[1].trim()),$Processed)
        }
        $this.shortDescription = if($HTML -match [KijijiListing]::parsingRegexes["description"]){[System.Web.HttpUtility]::HtmlDecode($matches[1].trim())};
        $this.imageURL         = if($HTML -match [KijijiListing]::parsingRegexes["image"]){$matches[1]};
        $this.searchURLID      = $SearchUrlID
        $this.lastsearched     = $Processed 
        $this.discovered       = 0
    }

    KijijiListing([int]$ID,[string]$ConnectionName){
        # Populate from an id in the database
        $selectIDQuery = "SELECT * FROM listings WHERE id=@id LIMIT 1"

        # Query the database
        try{
            # The following query will throw an exception if there is no active connection. Capture it as a terminating exception
            $listingResult = Invoke-SqlQuery -Query $selectIDQuery -Parameters @{id=$ID} -ConnectionName $ConnectionName -Stream -WarningAction Stop 3> Null
        } catch [System.Management.Automation.ActionPreferenceStopException] {
            throw [System.NotSupportedException]"No active SQL connection"
        }

        if($listingResult){
            # Populate the object from the database data wherever a property match between both is found. 
            $properties = $this.psobject.properties.name 

            foreach($property in $properties){
                # If this property is populated in the database row. Do so to this object
                if($listingResult.$property){$this.$property = $listingResult.$property}
            }
        } else {
            # No match was found in the database. Cannot create the 
            throw [System.ArgumentException] "No record found for the id "
        }
    }

    # Simple list like output of non hidden properties. 
    [string]toString(){
        $properties = $this.psobject.properties.name 
        $maxPropertyNameLength = ($properties | Measure-Object -Maximum -Property Length).Maximum
        return ($properties | ForEach-Object{Write-Output ("{0}: {1}" -f $_.PadRight($maxPropertyNameLength, " "),$this.$_)}) -join "`n"
    }

    # Invoke-SQLUpdate to add record to database
    [object]AddtoDB([string]$ConnectionName){
        $InvokeSQLUpdateParameters = @{
            Query = "INSERT INTO listings SET id=@id, url=@url, price=@price, title=@title, distance=@distance, 
                        location=@location, posted=@posted, shortdescription=@shortdescription, imageurl=@imageurl,searchurlid=@searchurlid,
                        lastsearched=@lastsearched,discovered=@discovered, new=@new, changes=@changes"
            Parameters = @{iD = $this.iD; uRL = $this.uRL; price = $this.price; title = $this.title; distance = $this.distance;
                    location = $this.location; posted = $this.posted; shortDescription = $this.shortDescription; 
                    imageURL = $this.imageURL; searchURLID = $this.searchURLID; lastsearched = $this.lastsearched;
                    discovered = $this.discovered; new = 1; changes=""}
            Connectionn = $ConnectionName
        }

        return (Invoke-SqlUpdate @InvokeSQLUpdateParameters)
    }

    CompareListing([KijijiListing]$DifferenceListing){
        # Using the differencelisting show all properties that are different. Return a list of properties and their differences
        $differentProperties = [System.Collections.ArrayList]::new()

        # Populate the object from the database data.
        $properties = $this.psobject.properties.name 

        foreach($property in $properties){
            # If this property is populated in the database row. Do so to this object
            if($DifferenceListing.$property -ne $this.$property){
                # Some properties have special rules for determining difference
                $findings = "Property has changed"
                switch($property){
                    "price"{
                        # If both prices are numbers then compare. Else give default reason
                        if($this.price -as [double] -and $DifferenceListing.price -as [double]){
                            if([double]$this.price -lt [double]$DifferenceListing.price){
                                $findings = "Price has increased"
                            } else {
                                $findings = "Price has decreased"
                            }
                        }
                    }
                }

                # Add this property and its notes to the list to be returned. 
                $differentProperties.Add([pscustomobject]@{Property=$property;Findings=$findings})
            }
        }

        # Add the finding back to the $this.changes in json form.
        $this.changes = $differentProperties | ConvertTo-Json -Depth 2
    }

    # Make changes to an existing listing in a database
    [object]UpdateInDB([string]$ConnectionName,[int]$Discovered){
        $InvokeSQLUpdateParameters = @{
            Query = "UPDATE listings SET url=@url, price=@price, title=@title, distance=@distance, 
                        location=@location, posted=@posted, shortdescription=@shortdescription, imageurl=@imageurl,searchurlid=@searchurlid,
                        lastsearched=@lastsearched,discovered=@discovered, new=@new, changes=@changes
                     WHERE id=@id"
            # Add all properties using ones in current object. If we are doing an update increase the 
            Parameters = @{id = $this.iD; uRL = $this.uRL; price = $this.price; title = $this.title; distance = $this.distance;
                    location = $this.location; posted = $this.posted; shortDescription = $this.shortDescription; 
                    imageURL = $this.imageURL; searchURLID = $this.searchURLID; lastsearched = $this.lastsearched;
                    discovered = $Discovered + 1; new = 1; changes=$this.changes}
            Connectionn = $ConnectionName
        }

        return (Invoke-SqlUpdate @InvokeSQLUpdateParameters)
    }

    static [datetime] ConvertFromKijijiDate([string]$DateString,[datetime]$BaseDate){
         # Trim data that does not need to be in the string
        $DateString = $DateString.Replace("ago","").Replace("<","").Trim()

        # Determine the string format and adjust the current date accordingly from the base date.
        switch  -Wildcard ($DateString){
            "*minutes*"  {
                return $BaseDate.AddMinutes(-($DateString.Replace(" minutes","")))
                break
            }
            "*hours*"    {
                return $BaseDate.AddHours(-($DateString.Replace(" hours","")))
                break
            }
            "*yesterday*"{
                # Return yesterday but remove the time
                return $BaseDate.AddDays(-1).Date
                break
            }
            default{
                # If none of the other options worked assume this is a normal dd/MM/yyyy string
                try{
                    return [DateTime]::ParseExact($DateString, [KijijiListing]::kijijiDateFormat, $null) 
                } catch {
                    return $null
                }
            }
        }
        return $null
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
    $maximumResultsPerSearch    = 0
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
        # Initialize the webclient for searching Kijiji. WebClient is used as Invoke-WebRequest has historically halted when browsing Kijiji
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
            $this.searchURLID = $this.GetSQLSearchURLID()
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

    [int]GetSQLSearchURLID(){
        function Invoke-SQLGetSearchID{
            return Invoke-SqlScalar "SELECT urlid FROM searchurls WHERE url = @url" -Parameters @{url=$this.searchURL} -ConnectionName $this._databaseConnectionName
        }

        # See if this search url is in the URL table. If not add it.
        $urlID = Invoke-SQLGetSearchID
        if(-not $urlID){
            # This ID is not in the database. Add it.
            try{
                # Insert the URL record into the database.  
                Invoke-SqlUpdate "INSERT INTO searchurls (url) VALUES (@url)" -Parameters @{url=$this.searchURL} -ConnectionName $this._databaseConnectionName
                # Get the new id
                $urlID = Invoke-SQLGetSearchID
            } catch {Write-Warning ("GetSQLSearchURLID: " + $_[0].Exception.Message)}
        }

        return $urlID
    }

    # Instance Methods
    Search(){
        # Performs a kijiji web search. All found listings are added to an arraylist property for evaluation.

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
            $listingsHTML = [regex]::Matches($rawHTML,[KijijiSearch]::parsingRegexes["Listing"]).Value
            ForEach($singleListingHTML in $listingsHTML){
                $this.listings.add([KijijiListing]::new($singleListingHTML, $this.searchURLID, $this.SearchExecuted))
            }
        }
    }

    UpdateSQLListings(){
        # Load the currentl listings into the database. New ones will be added outright. If there are conflicts outside a date thresholds then
        # updates to current data may be done.
        $duplicateListing = $null
        
        foreach($listing in $this.listings){
            # Check each listing to see if it already exists in the database
            try{
                $duplicateListing = [KijijiListing]::new($listing.id,$this._databaseConnectionName)       
            } catch [System.NotSupportedException] {
                # Could not connect to SQL database using named connection
                throw $_
            } catch [System.ArgumentException] {
                # No matching listing was found. Continue
            } catch {
                # Rethrow this exception.
                throw $_
            }

            # If a duplicate listing is found we will need to update it appropriately else
            # just add this listing as a new listing.
            if($duplicateListing){
                # This id historically exists. Check to see if it was found recently.
                if($duplicateListing.lastsearched -lt $this.newListingCutoffDate){
                    # Record the difference between this one and the duplicate listing
                    $listing.CompareListing($duplicateListing)
                    # Update the listing in the DB with new information
                    $listing.UpdateInDB($this._databaseConnectionName, $duplicateListing.discovered)
                } else {
                    # This listing is too recent to be considered rediscovered. Ignore it.
                }
            } else {
                # This ID is not located in the database. Add It
                $listing.AddtoDB($this._databaseConnectionName)
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

