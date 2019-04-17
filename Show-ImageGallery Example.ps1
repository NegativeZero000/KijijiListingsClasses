# Import the classes into scope
Add-Type -AssemblyName System.Web



$previousVerbosePreference = $VerbosePreference
$VerbosePreference = [System.Management.Automation.ActionPreference]::Continue

$url = "https://www.kijiji.ca/b-ottawa/board-game/k0l1700185?dc=true"

$kijijiSearch = [KijijiSearch]::new($url, 30)
# Start the search based on config options
$kijijiSearch.Search()
# Load any new listings and update existing ones where applicable

# Get the initial text from the page
$kijijiWebClient = New-Object System.Net.WebClient
$kijijiSearch.listings | ForEach-Object{ 
    $_ | Add-Member -Name "ImageBytes" -MemberType NoteProperty -Value $kijijiWebClient.DownloadData($_.ImageURL)
}

$kijijiSearch.listings  | Show-ImageGallery


$VerbosePreference = $previousVerbosePreference