#!/bin/bash
#Title : NoTrack
#Description : This script will download latest Adblock Domain block files from quidsup.net, then parse them into Dnsmasq.
#Script will also create quick.lists for use by stats.php web page
#Author : QuidsUp
#Date : 2015-01-14
#Usage : sudo bash notrack.sh

#User Configerable Settings (in case config file is missing)---------
#Set NetDev to the name of network device e.g. "eth0" IF you have multiple network cards
NetDev=$(ip -o link show | awk '{print $2,$9}' | grep ": UP" | cut -d ":" -f 1)

#If NetDev fails to recognise a Local Area Network IP Address, then you can use IPVersion to assign a custom IP Address in /etc/notrack/notrack.conf
#e.g. IPVersion = 192.168.1.2
IPVersion="IPv4"

declare -A Config                                #Config array for Block Lists
Config[bl_custom]=""
Config[blocklist_notrack]=1
Config[blocklist_tld]=1
Config[blocklist_qmalware]=1
Config[blocklist_adblockmanager]=0
Config[blocklist_disconnectmalvertising]=0
Config[blocklist_easylist]=0
Config[blocklist_easyprivacy]=0
Config[blocklist_fbannoyance]=0
Config[blocklist_fbenhanced]=0
Config[blocklist_fbsocial]=0
Config[blocklist_hphosts]=0
Config[blocklist_malwaredomainlist]=0
Config[blocklist_malwaredomains]=0
Config[blocklist_pglyoyo]=0
Config[blocklist_someonewhocares]=0
Config[blocklist_spam404]=0
Config[blocklist_swissransom]=0
Config[blocklist_swisszeus]=0
Config[blocklist_winhelp2002]=0
Config[blocklist_chneasy]=0                      #China
Config[blocklist_ruseasy]=0                      #Russia

#Leave these Settings alone------------------------------------------
Version="0.7.15"
BlockingCSV="/etc/notrack/blocking.csv"
BlackListFile="/etc/notrack/blacklist.txt"
WhiteListFile="/etc/notrack/whitelist.txt"
DomainBlackListFile="/etc/notrack/domain-blacklist.txt"
DomainWhiteListFile="/etc/notrack/domain-whitelist.txt"
DomainQuickList="/etc/notrack/domain-quick.list"
DomainCSV="/var/www/html/admin/include/tld.csv"
ConfigFile="/etc/notrack/notrack.conf"

declare -A URLList                               #Array of URL's
#URLList[notrack]="http://quidsup.net/trackers.txt" - Deprecated
URLList[notrack]="https://raw.githubusercontent.com/quidsup/notrack/master/trackers.txt"
URLList[qmalware]="https://raw.githubusercontent.com/quidsup/notrack/master/malicious-sites.txt"
URLList[adblockmanager]="http://adblock.gjtech.net/?format=unix-hosts"
URLList[disconnectmalvertising]="https://s3.amazonaws.com/lists.disconnect.me/simple_malvertising.txt"
URLList[easylist]="https://easylist-downloads.adblockplus.org/easylist_noelemhide.txt"
URLList[easyprivacy]="https://easylist-downloads.adblockplus.org/easyprivacy.txt"
URLList[fbannoyance]="https://easylist-downloads.adblockplus.org/fanboy-annoyance.txt"
URLList[fbenhanced]="https://www.fanboy.co.nz/enhancedstats.txt"
URLList[fbsocial]="https://secure.fanboy.co.nz/fanboy-social.txt"
URLList[hphosts]="http://hosts-file.net/ad_servers.txt"
URLList[malwaredomainlist]="http://www.malwaredomainlist.com/hostslist/hosts.txt"
URLList[malwaredomains]="http://mirror1.malwaredomains.com/files/justdomains"
URLList[spam404]="https://raw.githubusercontent.com/Dawsey21/Lists/master/adblock-list.txt"
URLList[swissransom]="https://ransomwaretracker.abuse.ch/downloads/RW_DOMBL.txt"
URLList[swisszeus]="https://zeustracker.abuse.ch/blocklist.php?download=domainblocklist"
URLList[pglyoyo]="http://pgl.yoyo.org/adservers/serverlist.php?hostformat=;mimetype=plaintext"
URLList[someonewhocares]="http://someonewhocares.org/hosts/hosts"
URLList[winhelp2002]="http://winhelp2002.mvps.org/hosts.txt"
URLList[chneasy]="https://easylist-downloads.adblockplus.org/easylistchina.txt"
URLList[ruseasy]="https://easylist-downloads.adblockplus.org/ruadlist+easylist.txt"

#Global Variables----------------------------------------------------
ChangesMade=0                                    #Number of Lists processed. If left at zero then Dnsmasq won't be restarted
FileTime=0                                       #Return value from Get_FileTime
Force=0
OldLatestVersion="$Version"
UnixTime=$(date +%s)                             #Unix time now
JumpPoint=0                                      #Percentage increment
PercentPoint=0                                   #Number of lines to loop through before a percentage increment is hit
WhiteListFileTime=0
declare -A WhiteList                             #associative array
declare -a CSVList                               #Array to store each list
declare -a DNSList
declare -A DomainList
declare -A SiteList
declare -i Dedup=0                               #Count of Deduplication


#Error_Exit----------------------------------------------------------
Error_Exit() {
  echo "$1"
  echo "Aborting"
  exit 2
}
#Check File Exists and Abort if it doesn't exist---------------------
Check_File_Exists() {
  if [ ! -e "$1" ]; then
    echo "Error file $1 is missing.  Aborting."
    exit 2
  fi
}
#Create File---------------------------------------------------------
CreateFile() {
  if [ ! -e "$1" ]; then
    echo "Creating file: $1"
    touch "$1"
  fi
}
#Delete old file if it Exists----------------------------------------
DeleteOldFile() {
  if [ -e "$1" ]; then
    echo "Deleting file $1"
    rm "$1"
    ((ChangesMade++))                            #Deleting a file counts as a change, and may require Dnsmasq to be restarted
  fi
}
#Add Site to List-----------------------------------------------------
function AddSite() {
  #$1 = Site to Add
  #$2 = Comment
  #Add Site checks whether a Site is in the Users whitelist or has previously been added
  #1. Disregard zero length strings
  #2. Extract site.domain from subdomains
  #3. Check if .domain is in TLD List
  #4. Check if site.domain has been added do $SiteList array
  #5. Check if sub.site.domain has been added do $SiteList array
  #6. Check if Site is in $WhiteList array
  #7. Add $Site into $DNSList, $CSVList and $SiteList arrays
    
  local Site="$1"
  
  if [ ${#Site} == 0 ]; then return 0; fi        #Ignore zero length str
  if [[ $Site =~ ^www\. ]]; then                 #Drop www.
    Site="${Site:4}"
  fi
  
  #Remove sub-domains, and extract just the domain.
  #Allowences have to be made for .org, .co, .au which are sometimes the TLD
  #e.g. bbc.co.uk
  [[ $Site =~ [A-Za-z1-9\-]*\.(org\.|co\.|au\.)?[A-Za-z1-9\-]*$ ]]
  local NoSubDomain="${BASH_REMATCH[0]}"
    
  if [ ${#NoSubDomain} == 0 ]; then              #Has NoSubDomain extract failed?
    NoSubDomain="$Site"                          #If zero length, make it $Site
  fi
  
  if [ "${DomainList[.${Site##*.}]}" ]; then     #Drop if .domain is in TLD
    #echo "Dedup TLD $Site"
    ((Dedup++))
    return 0
  fi
  
  if [ "${SiteList[$NoSubDomain]}" ]; then       #Drop if site.domain has been added
    #echo "Dedup Domain $Site"
    ((Dedup++))
    return 0
  fi
  
  if [ "${SiteList[$Site]}" ]; then              #Drop if sub.site.domain has been added
    #echo "Dedup Duplicate $Site"
    ((Dedup++))
    return 0
  fi
  
  #Is Site or NoSubDomain in WhiteList Array?
  if [ "${WhiteList[$Site]}" ] || [ "${WhiteList[$NoSubDomain]}" ]; then 
    CSVList+=("$Site,Disabled,$2")
  else                                           #No match in whitelist    
    DNSList+=("address=/$Site/$IPAddr")
    CSVList+=("$Site,Active,$2")
    SiteList[$Site]=1
  fi
}
#Calculate Percent Point in list files-------------------------------
CalculatePercentPoint() {
  #$1 = File to Calculate
  #1. Count number of lines in file with "wc"
  #2. Calculate Percentage Point (number of for loop passes for 1%)
  #3. Calculate Jump Point (increment of 1 percent point on for loop)
  #E.g.1 20 lines = 1 for loop pass to increment percentage by 5%
  #E.g.2 200 lines = 2 for loop passes to increment percentage by 1%
  local NumLines=0
  
  NumLines=$(wc -l "$1" | cut -d " " -f 1)       #Count number of lines
  if [ "$NumLines" -ge 100 ]; then
    PercentPoint=$((NumLines/100))
    JumpPoint=1
  else
    PercentPoint=1
    JumpPoint=$((100/NumLines))
  fi
}
#Read Config File----------------------------------------------------
#Default values are set at top of this script
#Config File contains Key & Value on each line for some/none/or all items
#If the Key is found in the case, then we write the value to the Variable
Read_Config_File() {  
  if [ -e "$ConfigFile" ]; then
    echo "Reading Config File"
    while IFS='= ' read -r Key Value             #Seperator '= '
    do
      if [[ ! $Key =~ ^\ *# && -n $Key ]]; then
        Value="${Value%%\#*}"    # Del in line right comments
        Value="${Value%%*( )}"   # Del trailing spaces
        Value="${Value%\"*}"     # Del opening string quotes 
        Value="${Value#\"*}"     # Del closing string quotes 
        
        case "$Key" in
          IPVersion) IPVersion="$Value";;
          NetDev) NetDev="$Value";;
          LatestVersion) OldLatestVersion="$Value";;
          BL_Custom) Config[bl_custom]="$Value";;
          BlockList_NoTrack) Config[blocklist_notrack]="$Value";;
          BlockList_TLD) Config[blocklist_tld]="$Value";;
          BlockList_QMalware) Config[blocklist_qmalware]="$Value";;
          BlockList_DisconnectMalvertising) Config[blocklist_disconnectmalvertising]="$Value";;
          BlockList_AdBlockManager) Config[blocklist_adblockmanager]="$Value";;
          BlockList_EasyList) Config[blocklist_easylist]="$Value";;
          BlockList_EasyPrivacy) Config[blocklist_easyprivacy]="$Value";;
          BlockList_FBAnnoyance) Config[blocklist_fbannoyance]="$Value";;
          BlockList_FBEnhanced) Config[blocklist_fbenhanced]="$Value";;
          BlockList_FBSocial) Config[blocklist_fbsocial]="$Value";;
          BlockList_hpHosts) Config[blocklist_hphosts]="$Value";;
          BlockList_MalwareDomainList) Config[blocklist_malwaredomainlist]="$Value";;
          BlockList_MalwareDomains) Config[blocklist_malwaredomains]="$Value";;          
          BlockList_PglYoyo) Config[blocklist_pglyoyo]="$Value";;
          BlockList_SomeoneWhoCares) Config[blocklist_someonewhocares]="$Value";;
          BlockList_Spam404) Config[blocklist_spam404]="$Value";;
          BlockList_SwissRansom) Config[blocklist_swissransom]="$Value";;
          BlockList_SwissZeus) Config[blocklist_swisszeus]="$Value";;
          BlockList_Winhelp2002) Config[blocklist_winhelp2002]="$Value";;
          BlockList_CHNEasy) Config[blocklist_chneasy]="$Value";;
          BlockList_RUSEasy) Config[blocklist_ruseasy]="$Value";;          
        esac            
      fi
    done < $ConfigFile
  fi 
}

#Read White List-----------------------------------------------------
Read_WhiteList() {
  while IFS='# ' read -r Line _
  do
    if [[ ! $Line =~ ^\ *# && -n $Line ]]; then
      Line="${Line%%\#*}"                        #Delete comments
      Line="${Line%%*( )}"                       #Delete trailing spaces
      WhiteList[$Line]=1
    fi
  done < $WhiteListFile
}
#Generate BlackList--------------------------------------------------
Generate_BlackList() {
  local -a Tmp                                   #Local array to build contents of file
  
  echo "Creating blacklist"
  touch "$BlackListFile"
  Tmp+=("#Use this file to create your own custom block list")
  Tmp+=("#Run notrack script (sudo notrack) after you make any changes to this file")
  Tmp+=("#doubleclick.net")
  Tmp+=("#googletagmanager.com")
  Tmp+=("#googletagservices.com")
  printf "%s\n" "${Tmp[@]}" > $BlackListFile     #Write Array to file with line seperator
}
#Generate WhiteList--------------------------------------------------
Generate_WhiteList() {
  local -a Tmp                                   #Local array to build contents of file
  
  echo "Creating whitelist"
  touch "$WhiteListFile"
  Tmp+=("#Use this file to remove sites from block list")
  Tmp+=("#Run notrack script (sudo notrack) after you make any changes to this file")
  Tmp+=("#doubleclick.net")
  Tmp+=("#google-analytics.com")
  printf "%s\n" "${Tmp[@]}" > $WhiteListFile     #Write Array to file with line seperator
}
#Get IP Address of System--------------------------------------------
Get_IPAddress() {    
  if [ "$IPVersion" == "IPv4" ]; then
    echo "Internet Protocol Version 4 (IPv4)"
    echo "Reading IPv4 Address from $NetDev"
    IPAddr=$(ip addr list "$NetDev" | grep inet | head -n 1 | cut -d ' ' -f6 | cut -d/ -f1)
    
  elif [ "$IPVersion" == "IPv6" ]; then
    echo "Internet Protocol Version 6 (IPv6)"
    echo "Reading IPv6 Address"
    IPAddr=$(ip addr list "$NetDev" | grep inet6 | head -n 1 | cut -d ' ' -f6 | cut -d/ -f1)
  else
    echo "Custom IP Address used"
    IPAddr="$IPVersion";                         #Use IPVersion to assign a manual IP Address
  fi
  echo "System IP Address: $IPAddr"
  echo
}
#Get File Time-------------------------------------------------------
Get_FileTime() {
  #$1 = File to be checked
  if [ -e "$1" ]; then                           #Does file exist?
    FileTime=$(stat -c %Z "$1")                  #Return time of last status change, seconds since Epoch
  else
    FileTime=0                                   #Otherwise retrun 0
  fi
}

#Custom BlackList----------------------------------------------------
GetList_BlackList() {
  local BlFileTime=0                             #Blacklist File Time
  local ListFileTime=0                           #Processed List File Time
  
  Get_FileTime "/etc/dnsmasq.d/custom.list"
  ListFileTime=$FileTime
  Get_FileTime "$BlackListFile"
  BlFileTime=$FileTime
  
  #Are the Whitelist & Blacklist older than 36 Hours, and the Processed List of any age?
  if [ $WhiteListFileTime -lt $((UnixTime-187200)) ] && [ $BlFileTime -lt $((UnixTime-187200)) ] && [ $ListFileTime -gt 0 ] && [ $Force == 0 ]; then
    if [ "$(wc -l /etc/notrack/custom.csv | cut -d " " -f 1)" -gt 1 ]; then
      cat /etc/notrack/custom.csv >> "$BlockingCSV"
    fi
    echo "Custom Black List is in date, no need for processing"
    echo
    return 0
  fi

  echo "Processing Custom Black List"
  
  Process_PlainList "$BlackListFile"
  
  printf "%s\n" "${CSVList[@]}" > "/etc/notrack/custom.csv"
  printf "%s\n" "${DNSList[@]}" > "/etc/dnsmasq.d/custom.list"
  if [ "$(wc -l /etc/notrack/custom.csv | cut -d " " -f 1)" -gt 1 ]; then
    cat /etc/notrack/custom.csv >> "$BlockingCSV"
  fi
  echo "Finished processing Custom Black List"
  echo
  ((ChangesMade++))
}
#Get Custom List-----------------------------------------------------
function Get_Custom() {
  local -A CustomListArray
  local CSVFile=""
  local DLFile=""
  local ListFile=""
  local DLFileTime=0                             #Downloaded File Time
  local ListFileTime=0                           #Processed List File Time
  local CustomCount=1                            #For displaying count of custom list
    

  if [[ ${Config[bl_custom]} == "" ]]; then
    echo "No Custom Block Lists in use"
    for FileName in /etc/dnsmasq.d/custom_*; do  #Clean up old custom lists
      FileName=${FileName##*/}                   #Get filename from path
      FileName=${FileName%.*}                    #Remove file extension
      DeleteOldFile "/etc/dnsmasq.d/$FileName.list"
      DeleteOldFile "/etc/notrack/$FileName.csv"
      DeleteOldFile "/tmp/$FileName.txt"
    done
    return
  fi
  
  echo "Processing Custom Block Lists"
  #Split comma seperated list into individual URL's
  IFS=',' read -ra CustomList <<< "${Config[bl_custom]}"
  for ListUrl in "${CustomList[@]}"; do
    echo "$CustomCount: $ListUrl"
    FileName=${ListUrl##*/}                      #Get filename from URL
    FileName=${FileName%.*}                      #Remove file extension
    DLFile="/tmp/custom_$FileName.txt"
    CSVFile="/etc/notrack/custom_$FileName.csv"
    ListFile="/etc/dnsmasq.d/custom_$FileName.list"    
    CustomListArray[$FileName]="$FileName"       #Used later    
    
    Get_FileTime "$DLFile"
    DLFileTime="$FileTime"
    if [[ $ListUrl =~ ^(https?|ftp):// ]]; then  #Is URL a HTTP(s) or FTP?
      if [ $DLFileTime -lt $((UnixTime-345600)) ]; then #Is list older than 4 days
        echo "Downloading $FileName"      
        wget -qO "$DLFile" "$ListUrl"            #Yes, download it
      else
        echo "File in date, not downloading"
      fi
    elif [ -e "$ListUrl" ]; then                 #Is it a file on the server?        
      echo "$ListUrl File Found on system"
      Get_FileTime "$ListUrl"                    #Get date of file
      
      if [ $FileTime -gt $DLFileTime ]; then     #Is the original file newer than file in /tmp?
        echo "Copying to $DLFile"                #Yes, copy file
        cp "$ListUrl" "$DLFile"
      else
        echo "File in date, not copying"
      fi
    else                                         #Don't know what to do, skip to next file
      echo "Unable to identify what $ListUrl is"
      echo
      continue
    fi      
      
    Get_FileTime "$ListFile"                     #Get time of list file /etc/dnsmasq.d
    
    #Is downloaded list newer, or Force on?
    if [ $DLFileTime -gt $FileTime ] || [ $Force == 1 ] ; then  
      if [ -s "$DLFile" ]; then                  #Only process if filesize > 0
        CSVList=()                               #Zero Arrays
        DNSList=()  
      
        #Adblock EasyList can be identified by first line of file
        Line=$(head -n1 "$DLFile")               #What is on the first line?
        if [[ ${Line:0:13} == "[Adblock Plus" ]]; then #First line identified as EasyList
          echo "Block list identified as Adblock Plus EasyList"
          Process_EasyList "$DLFile"
        else                                     #Other, lets grab URL from each line
          echo "Processing as Custom List"
          Process_CustomList "$DLFile"
        fi
      
        if [ ${#DNSList[@]} -gt 0 ]; then        #Are there any URL's in the block list?
          CreateFile "$CSVFile"                  #Create CSV File
          CreateFile "$ListFile"                 #Create List File
          printf "%s\n" "${CSVList[@]}" > "$CSVFile"  #Output arrays to file
          printf "%s\n" "${DNSList[@]}" > "$ListFile"
          cat "$CSVFile" >> "$BlockingCSV"
          echo "Finished processing $FileName"
          ((ChangesMade++))
        else                                     #No URL's in block list
          DeleteOldFile "$CSVFile"               #Delete CSV File
          DeleteOldFile "$ListFile"              #Delete List File
          echo "No URL's extracted from Block list"
        fi
      else                                       #File not downloaded
        echo "Error $DLFile not found"
      fi
    else
      echo "Block list in date, not processing"
      cat "$CSVFile" >> "$BlockingCSV"
    fi
    echo
    ((CustomCount++))
  done
  
  
  for FileName in /etc/dnsmasq.d/custom_*; do    #Clean up old custom lists
    FileName=${FileName##*/}                     #Get filename from path
    FileName=${FileName%.*}                      #Remove file extension
    FileName=${FileName:7}                       #Remove custom_    
    if [ ! "${CustomListArray[$FileName]}" ]; then
      DeleteOldFile "/etc/dnsmasq.d/custom_$FileName.list"
      DeleteOldFile "/etc/notrack/custom_$FileName.csv"
    fi
  done  
}
#GetList-------------------------------------------------------------
function GetList() {
  #$1 = List to be Processed
  #$2 = Process Method
  #$3 = Time (in seconds) between needing to process a new list
  local Lst="$1"
  local CSVFile="/etc/notrack/$1.csv"
  local DLFile="/tmp/$1.txt"
  local ListFile="/etc/dnsmasq.d/$1.list"
  local DLFileTime=0                             #Downloaded File Time
  local ListFileTime=0                           #Processed List File Time
  
  if [ "${Config[blocklist_$Lst]}" == 0 ]; then  #Should we process this list according to the Config settings?
    DeleteOldFile "$ListFile"                    #If not delete the old file, then leave the function
    DeleteOldFile "$CSVFile"
    DeleteOldFile "$DLFile"
    return 0
  fi
  
  Get_FileTime "$ListFile"
  ListFileTime=$FileTime
  Get_FileTime "$DLFile"
  DLFileTime=$FileTime
  
  #Is the Whitelist older than 36 Hours, and the Processed List younger than $3. If so leave the function without processing
  if [ $WhiteListFileTime -lt $((UnixTime-187200)) ] && [ $ListFileTime -gt $((UnixTime-$3)) ]; then
    cat "$CSVFile" >> "$BlockingCSV"
    echo "$Lst is in date, no need for processing"
    echo
    return 0
  fi
  
  #If the Downloaded List is older than $3 then don't download it again
  if [ $DLFileTime -gt $((UnixTime-$3)) ]; then  
    echo "$Lst in date. Not downloading"    
  else  
    echo "Downloading $Lst"
    wget -qO "$DLFile" "${URLList[$Lst]}"
  fi
  
  if [ ! -s "$DLFile" ]; then                    #Check if list has been downloaded
    echo "File not downloaded"
    return 1
  fi
  
  CSVList=()                                     #Zero Arrays
  DNSList=()  
    
  echo "Processing list $Lst"                    #Inform user
  
  case $2 in                                     #What type of processing is required?
    "easylist") Process_EasyList "$DLFile" ;;
    "plain") Process_PlainList "$DLFile" ;;
    "notrack") Process_NoTrackList "$DLFile" ;;
    "tldlist") Process_TLDList ;;
    "unix") Process_UnixList "$DLFile" ;;    
    *) Error_Exit "Unknown option $2"
  esac
  
  
  if [ ${#DNSList[@]} -gt 0 ]; then              #Are there any URL's in the block list?
    CreateFile "$CSVFile"                        #Create CSV File
    CreateFile "$ListFile"                       #Create List File
    printf "%s\n" "${CSVList[@]}" > "$CSVFile"   #Output arrays to file
    printf "%s\n" "${DNSList[@]}" > "$ListFile"
    cat "/etc/notrack/$Lst.csv" >> "$BlockingCSV"  
    echo "Finished processing $Lst"  
    ((ChangesMade++))
  else                                           #No URL's in block list
    DeleteOldFile "$CSVFile"                     #Delete CSV File
    DeleteOldFile "$ListFile"                    #Delete List File
    echo "No URL's extracted from Block list"
  fi
  
  echo  
}
#--------------------------------------------------------------------
function Process_CustomList() {
  #$1 = SourceFile
  CalculatePercentPoint "$1"
  i=1                                            #Progress counter
  j=$JumpPoint                                   #Jump in percent
      
  while IFS=$'#\n\r' read -r Line Comment _
  do
    if [[ ! $Line =~ ^\ *# ]] && [[ -n $Line ]]; then
      Line="${Line%%\#*}"                        #Delete comments
      Line="${Line%%*( )}"                       #Delete trailing spaces      
      [[ $Line =~ ([A-Za-z1-9\-]*\.)?([A-Za-z1-9\-]*\.)?[A-Za-z1-9\-]*\.[A-Za-z1-9\-]*$ ]]
      AddSite "${BASH_REMATCH[0]}" "$Comment"
    fi
    
    if [ $i -ge $PercentPoint ]; then            #Display progress
      echo -ne " $j%  \r"                        #Echo without return
      j=$((j + JumpPoint))
      i=0
    fi
    ((i++))
  done < "$1"
  echo " 100%"
}
#Process EasyList----------------------------------------------------
Process_EasyList() {
  #EasyLists contain a mixture of Element hiding rules and third party sites to block.
  #DNS is only capable of blocking sites, therefore NoTrack can only use the lines with $third party in
  
  #$1 = SourceFile
  
  CalculatePercentPoint "$1"
  i=1                                            #Progress counter
  j=$JumpPoint                                   #Jump in percent
    
  while IFS=$' \n' read -r Line
  do
    #||somesite.com^ or ||somesite.com/
    if [[ $Line =~ ^\|\|[a-z0-9\.\-]*\^?/?$ ]]; then
      AddSite "${Line:2:-1}" ""
    ##[href^="http://somesite.com/"]
    elif [[ $Line =~ ^##\[href\^=\"http:\/\/[a-z0-9\.\-]*\/\"\]$ ]]; then
      AddSite "${Line:17:-3}" ""      
    #||somesite.com^$third-party
    elif [[ $Line =~ ^\|\|[a-z0-9\.\-]*\^\$third-party$ ]]; then
      #Basic method of ignoring IP addresses (\d doesn't work)
      if  [[ ! $Line =~ ^\|\|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\^\$third-party$ ]]; then
        AddSite "${Line:2:-13}" ""
      fi
    #||somesite.com^$popup,third-party
    elif [[ $Line =~ ^\|\|[a-z0-9\.\-]*\^\$popup\,third-party$ ]]; then
      AddSite "${Line:2:-19}" ""
    elif [[ $Line =~ ^\|\|[a-z0-9\.\-]*\^\$third-party\,domain=~ ]]; then
      #^$third-party,domain= apepars mid line, we need to replace it with a | pipe seperator like the rest of the line has
      Line=$(sed "s/\^$third-party,domain=~/\|/g" <<< "$Line")
      IFS='|~', read -r -a ArrayOfLine <<< "$Line" #Explode into array using seperator | or ~
      for Line in "${ArrayOfLine[@]}"            #Loop through array
      do
        if [[ $Line =~ ^\|\|[a-z0-9\.\-]*$ ]]; then #Check Array line is a URL
          AddSite "$Line" ""
        fi
      done  
    fi
    
    if [ $i -ge $PercentPoint ]; then            #Display progress
      echo -ne " $j%  \r"                        #Echo without return
      j=$((j + JumpPoint))
      i=0
    fi
    ((i++))
  done < "$1"
  echo " 100%"
}
#Process NoTrack List------------------------------------------------
Process_NoTrackList() {
  #NoTrack list is just like PlainList, but contains latest version number
  #which is used by the Admin page to inform the user an upgrade is available
  
  #$1 = SourceFile
  
  DNSList+=("#Tracker Block list last updated $(date)")
  DNSList+=("#Don't make any changes to this file, use $BlackListFile and $WhiteListFile instead")
    
  CalculatePercentPoint "$1"
  i=1                                            #Progress counter
  j=$JumpPoint                                   #Jump in percent
  
  while IFS='# ' read -r Line Comment
  do
    if [[ ! $Line =~ ^\ *# && -n $Line ]]; then
      Line="${Line%%\#*}"                        #Delete comments
      Line="${Line%%*( )}"                       #Delete trailing spaces      
      AddSite "$Line" "$Comment"      
    elif [[ "${Comment:0:13}" == "LatestVersion" ]]; then
      LatestVersion="${Comment:14}"              #Substr version number only
      if [[ $OldLatestVersion != "$LatestVersion" ]]; then 
        echo "New version of NoTrack available v$LatestVersion"
        #Check if config line LatestVersion exists
        #If not add it in with tee
        #If it does then use sed to update it
        if [[ $(grep "LatestVersion" "$ConfigFile") == "" ]]; then
          echo "LatestVersion = $LatestVersion" | sudo tee -a "$ConfigFile"
        else
          sed -i "s/^\(LatestVersion *= *\).*/\1$LatestVersion/" $ConfigFile
        fi
      fi      
    fi
    
    if [ $i -ge $PercentPoint ]; then            #Display progress
      echo -ne " $j%  \r"                        #Echo without return
      j=$((j + JumpPoint))
      i=0
    fi
    ((i++))
  done < "$1"
  echo " 100%"
}
#Process PlainList---------------------------------------------------
#Plain Lists are styled like:
# #Comment
# Site
# Site #Comment
Process_PlainList() {
  #$1 = SourceFile
  CalculatePercentPoint "$1"
  i=1                                            #Progress counter
  j=$JumpPoint                                   #Jump in percent
    
  while IFS=$'# \n' read -r Line Comment _
  do
    if [[ ! $Line =~ ^\ *# && -n $Line ]]; then
      Line="${Line%%\#*}"                        #Delete comments
      Line="${Line%%*( )}"                       #Delete trailing spaces      
      #echo "$Line $2 $Comment"
      AddSite "$Line" "$Comment"
    fi
    
    if [ $i -ge $PercentPoint ]; then            #Display progress
      echo -ne " $j%  \r"                        #Echo without return
      j=$((j + JumpPoint))
      i=0
    fi
    ((i++))
  done < "$1"
  echo " 100%"
}
#Process TLD List----------------------------------------------------
Process_TLDList() {
  #1. Load Domain whitelist into associative array
  #2. Read downloaded TLD list, and compare with Domain WhiteList
  #3. Read users custom TLD list, and compare with Domain WhiteList
  #4. Results are stored in CSVList, and DNSList. These arrays are sent back to GetList() for writing to file.
  #The Downloaded & Custom lists are handled seperately to reduce number of disk writes in say cat'ting the files together
  #DomainQuickList is used to speed up processing in stats.php
  
  local -A DomainBlackList
  local -A DomainWhiteList
  
  Get_FileTime "$DomainWhiteListFile"
  local DomainWhiteFileTime=$FileTime
  Get_FileTime "$DomainCSV"
  local DomainCSVFileTime=$FileTime
  Get_FileTime "/etc/dnsmasq.d/tld.list"
  local TLDListFileTime=$FileTime
  
  if [ "${Config[blocklist_tld]}" == 0 ]; then   #Should we process this list according to the Config settings?
    DeleteOldFile "/etc/dnsmasq.d/tld.list"      #If not delete the old file, then leave the function
    DeleteOldFile "/etc/notrack/tld.csv"
    DeleteOldFile "$DomainQuickList"
    echo
    return 0
  fi
  
  CSVList=()                                     #Zero Arrays
  DNSList=()
    
  echo "Processing Top Level Domain List"
  
  CreateFile "$DomainQuickList"                  #Quick lookup file for stats.php
  cat /dev/null > "$DomainQuickList"             #Empty file
  
  while IFS=$'#\n' read -r Line _
  do
    if [[ ! $Line =~ ^\ *# ]] && [[ -n $Line ]]; then
      Line="${Line%%\#*}"                        #Delete comments
      Line="${Line%%*( )}"                       #Delete trailing spaces
      DomainWhiteList[$Line]=1                   #Add domain to associative array      
    fi
  done < "$DomainWhiteListFile"
  
  while IFS=$'#\n' read -r Line _
  do
    if [[ ! $Line =~ ^\ *# ]] && [[ -n $Line ]]; then
      Line="${Line%%\#*}"                        #Delete comments
      Line="${Line%%*( )}"                       #Delete trailing spaces
      DomainBlackList[$Line]=1                   #Add domain to associative array      
    fi
  done < "$DomainBlackListFile"
  
  while IFS=$',\n' read -r TLD Name Risk _; do
    if [[ $Risk == 1 ]]; then
      if [ ! "${DomainWhiteList[$TLD]}" ]; then  #Is site not in WhiteList
        DNSList+=("address=/$TLD/$IPAddr")
        CSVList+=("$TLD,Active,$Name")
        DomainList[$TLD]=1        
      fi    
    else
      if [ "${DomainBlackList[$TLD]}" ]; then
        DNSList+=("address=/$TLD/$IPAddr")
        CSVList+=("$TLD,Active,$Name")
        DomainList[$TLD]=1        
      fi
    fi
  done < "$DomainCSV"
  
  #Are the Whitelist and CSV younger than processed list in dnsmasq.d?
  if [ $DomainWhiteFileTime -lt $TLDListFileTime ] && [ $DomainCSVFileTime -lt $TLDListFileTime ] && [ $Force == 0 ]; then
    cat "/etc/notrack/tld.csv" >> "$BlockingCSV"
    echo "Top Level Domain List is in date, not saving"
    echo
    return 0    
  fi
  
  printf "%s\n" "${!DomainList[@]}" > $DomainQuickList
  printf "%s\n" "${CSVList[@]}" > "/etc/notrack/tld.csv"
  printf "%s\n" "${DNSList[@]}" > "/etc/dnsmasq.d/tld.list"
  
  echo "Finished processing Top Level Domain List"
  echo
  ((ChangesMade++))  
}
#Process UnixList----------------------------------------------------
Process_UnixList() {
  #All Unix lists that I've come across are Windows formatted, therefore we use the carriage return IFS \r
  #1. Calculate Percentage and Jump points
  #2. Read IP, Line, Comment, from file  
  #3. Parse Line and Comment to AddSite
  #5. Display progress
  #6. loop back to 2.
  
  #$1 = SourceFile
  CalculatePercentPoint "$1"
  i=1                                            #Progress counter
  j=$JumpPoint                                   #Jump in percent
  
  while IFS=$' \t#\r' read -r IP Line Comment _  #Space, Tab, Hash, Return
  do    
    if [[ ${IP:0:9} == "127.0.0.1" ]] || [[ ${IP:0:7} == "0.0.0.0" ]]; then  #Does line start with IP?     
      if [[ ! $Line =~ ^(#|localhost|EOF|\[).*$ ]]; then  #Negate localhost, and EOF
        Line="${Line%%\#*}"                      #Delete comments
        Line="${Line%%*( )}"                     #Delete trailing spaces
        AddSite "$Line" "$Comment"
      fi
    fi   
    
    if [ $i -ge $PercentPoint ]; then            #Display progress
      echo -ne " $j%  \r"                        #Echo without return
      j=$((j + JumpPoint))
      i=0
    fi
    ((i++))
  done < "$1"
  echo " 100%"
 }
#Help----------------------------------------------------------------
Show_Help() {
  echo "Usage: notrack"
  echo "Downloads and Installs updated tracker lists"
  echo
  echo "The following options can be specified:"
  echo -e "  -h, --help\tDisplay this help and exit"
  echo -e "  -t, --test\tConfig Test"
  echo -e "  -v, --version\tDisplay version information and exit"
  echo -e "  -u, --upgrade\tRun a full upgrade"
}
#Show Version--------------------------------------------------------
Show_Version() {
  echo "NoTrack Version v$Version"
  echo
}
#Test----------------------------------------------------------------
Test() {
  echo "NoTrack Config Test"
  echo
  echo "NoTrack version v$Version"
  if [ -e "$ConfigFile" ]; then
    echo "Config file $ConfigFile"
  else
    echo "No Config file available"
  fi
  Read_Config_File                               #Load saved variables
  Get_IPAddress                                  #Read IP Address of NetDev
  
  echo "Block Lists Utilised:"
  echo "BlockList_NoTrack ${Config[blocklist_notrack]}"
  echo "BlockList_TLD ${Config[blocklist_tld]}"
  echo "BlockList_QMalware ${Config[blocklist_qmalware]}"
  echo "BlockList_AdBlockManager ${Config[blocklist_adblockmanager]}"
  echo "BlockList_DisconnectMalvertising ${Config[blocklist_disconnectmalvertising]}"
  echo "BlockList_EasyList ${Config[blocklist_easylist]}"
  echo "BlockList_EasyPrivacy ${Config[blocklist_easyprivacy]}"
  echo "BlockList_FBAnnoyance ${Config[blocklist_fbannoyance]}"
  echo "BlockList_FBEnhanced ${Config[blocklist_fbenhanced]}"
  echo "BlockList_FBSocial ${Config[blocklist_fbsocial]}"
  echo "BlockList_hpHosts ${Config[blocklist_hphosts]}"
  echo "BlockList_MalwareDomainList ${Config[blocklist_malwaredomainlist]}"
  echo "BlockList_MalwareDomains ${Config[blocklist_malwaredomains]}"
  echo "BlockList_PglYoyo ${Config[blocklist_pglyoyo]}"
  echo "BlockList_SomeoneWhoCares ${Config[blocklist_someonewhocares]}"
  echo "BlockList_Spam404 ${Config[blocklist_spam404]}"
  echo "BlockList_SwissRansom ${Config[blocklist_swissransom]}"
  echo "BlockList_SwissZeus ${Config[blocklist_swisszeus]}"
  echo "BlockList_Winhelp2002 ${Config[blocklist_winhelp2002]}"
  echo "BlockList_CHNEasy ${Config[blocklist_chneasy]}"
  echo "BlockList_RUSEasy ${Config[blocklist_ruseasy]}"
  echo "Custom ${Config[bl_custom]}"
}
#Upgrade-------------------------------------------------------------
Upgrade() {
  #As of v0.7.9 Upgrading is now handled by ntrk-upgrade.sh
  #This function attempts to run it from /usr/local/sbin
  #If that fails, then it looks in the users home folder
  if [ -e /usr/local/sbin/ntrk-upgrade ]; then
    echo "Running ntrk-upgrade"
    /usr/local/sbin/ntrk-upgrade
    exit 0
  fi

  echo "Warning. ntrk-upgrade missing from /usr/local/sbin/"
  echo "Attempting to find alternate copy..."  

  for HomeDir in /home/*; do
    if [ -d "$HomeDir/NoTrack" ]; then 
      InstallLoc="$HomeDir/NoTrack"
      break
    elif [ -d "$HomeDir/notrack" ]; then 
      InstallLoc="$HomeDir/notrack"
      break
    fi
  done

  if [[ $InstallLoc == "" ]]; then
    if [ -d "/opt/notrack" ]; then
      InstallLoc="/opt/notrack"      
    else
      echo "Error Unable to find NoTrack folder"
      echo "Aborting"
      exit 22
    fi
  else    
    Check_File_Exists "$InstallLoc/ntrk-upgrade.sh"
    echo "Found alternate copy in $InstallLoc"
    sudo bash "$InstallLoc/ntrk-upgrade.sh"
  fi
}
#Main----------------------------------------------------------------
if [ "$1" ]; then                                #Have any arguments been given
  if ! options="$(getopt -o fhvtu -l help,force,version,upgrade,test -- "$@")"; then
    # something went wrong, getopt will put out an error message for us
    exit 1
  fi

  set -- $options

  while [ $# -gt 0 ]
  do
    case $1 in      
      -f|--force)
        Force=1
        UnixTime=2524608000     #Change time forward to Jan 2050, which will force all lists to update
      ;;
      -h|--help) 
        Show_Help
        exit 0
      ;;
      -t|--test)
        Test
        exit 0
      ;;
      -v|--version) 
        Show_Version
        exit 0
      ;;
      -u|--upgrade)
        Upgrade
        exit 0
      ;;
      (--) 
        shift
        break
      ;;
      (-*)         
        Error_Exit "$0: error - unrecognized option $1"
      ;;
      (*) 
        break
      ;;
    esac
    shift
  done
fi
  
#--------------------------------------------------------------------
#At this point the functionality of notrack.sh is to update Block Lists
#1. Check if user is running as root
#2. Create folder /etc/notrack
#3. Load config file (or use default values)
#4. Get IP address of system, e.g. 192.168.1.2
#5. Get last time (in Epoch) of when WhiteList was changed (If its more than 36 hours then we don't process BlackLists unless they have changed)
#6. Generate WhiteList if it doens't exist
#7. Load WhiteList file into WhiteList associative array
#8. Create csv file of blocked sites, or empty it if it exists
#9. Create BlackList, TLD BlackList, and TLD WhiteList if they don't exist
#10. Process Users Custom BlackList
#11. Process Other block lists according to Config
#12. Tell user how many sites are blocked by counting number of lines with "Active" in
#13. If the number if changes is 1 or more then restart Dnsmasq
if [ "$(id -u)" != 0 ]; then                     #Check if running as root
  Error_Exit "Error this script must be run as root"
fi
  
if [ ! -d "/etc/notrack" ]; then                 #Check /etc/notrack folder exists
  echo "Creating notrack folder under /etc"
  echo
  mkdir "/etc/notrack"
  if [ ! -d "/etc/notrack" ]; then               #Check again
    Error_Exit "Error Unable to create folder /etc/notrack"      
  fi
fi
  
Read_Config_File                                 #Load saved variables
Get_IPAddress                                    #Read IP Address of NetDev
  
Get_FileTime "$WhiteListFile"
WhiteListFileTime=$FileTime
  
if [ ! -e $WhiteListFile ]; then Generate_WhiteList
fi
  
Read_WhiteList                                   #Load Whitelist into array
CreateFile "$BlockingCSV"
cat /dev/null > $BlockingCSV                     #Empty csv file
  
if [ ! -e "$BlackListFile" ]; then Generate_BlackList
fi

CreateFile "$DomainWhiteListFile"                #Create Black & White lists
CreateFile "$DomainBlackListFile"

#Legacy files as of v0.7.14
DeleteOldFile /etc/notrack/domains.txt
DeleteOldFile /tmp/tld.txt

Process_TLDList
GetList_BlackList                                #Process Users Blacklist
  
GetList "notrack" "notrack" 172800               #2 Days
GetList "qmalware" "plain" 345600                #4 Days
GetList "adblockmanager" "unix" 604800           #7 Days
GetList "disconnectmalvertising" "plain" 345600  #4 Days
GetList "easylist" "easylist" 345600             #4 Days
GetList "easyprivacy" "easylist" 345600          #4 Days
GetList "fbannoyance" "easylist" 172800          #2 Days
GetList "fbenhanced" "easylist" 172800           #2 Days
GetList "fbsocial" "easylist" 345600             #4 Days
GetList "hphosts" "unix" 345600                  #4 Days
GetList "malwaredomainlist" "unix" 345600        #4 Days
GetList "malwaredomains" "plain" 345600          #4 Days
GetList "pglyoyo" "plain" 345600                 #4 Days
GetList "someonewhocares" "unix" 345600          #4 Days
GetList "spam404" "easylist" 172800              #2 Days
GetList "swissransom" "plain" 86400              #1 Day
GetList "swisszeus" "plain" 86400                #1 Day
GetList "winhelp2002" "unix" 604800              #7 Days
GetList "chneasy" "easylist" 345600              #China
GetList "ruseasy" "easylist" 345600              #Russia

Get_Custom                                       #Process Custom Block lists

if [ "${Config[blocklist_tld]}" == 0 ]; then
  DeleteOldFile "$DomainQuickList"
fi
  
echo "Imported $(grep -c "Active" "$BlockingCSV") Domains into Block List"
echo "Deduplicated $Dedup Domains"
echo

if [ $ChangesMade -gt 0 ]; then                  #Have any lists been processed?
  echo "Restarting Dnsnmasq"
  service dnsmasq restart                        #Restart dnsmasq  
fi
