<#
.SYNOPSIS
    Create the Azure Management Group hirerchy for the entire tenant

.DESCRIPTION
    Create the Azure Management Group hirerchy for the entire tenant by creating management groups hirerchy and move existing subscriptions to apporpriate management group based on an input file

.PARAMETER InputFile
    path to the input file which has the hierechy and subscription placement rules defined.

.PARAMETER silent
    Use this switch to use the surpress login prompt. The script will use the current Azure context (logon session) and it will fail if currently not logged on. Use this switch when using the script in CI/CD pipelines.

.PARAMETER whatif
    Use this switch to evaluate what actions would have been taken without making any changes to your existing environment.

.EXAMPLE
  .\config-managementGroups.ps1 -InputFile C:\Temp\input.json
  Configure tenant's management group hiererchy based on the structure defined in c:\temp\input.json (interactive mode)

.EXAMPLE
  .\config-managementGroups.ps1 -InputFile C:\Temp\input.json -silent -whatif
   Evaluate what would be changed for the tenant's management group hiererchy based on the structure defined in c:\temp\input.json (silent mode)
#>

#Requires -Modules 'Az.Resources'
<#
=============================================================================
AUTHOR:  Tao Yang
DATE:    08/05/2019
Version: 1.1
Version date: 30/10/2020
Changelog:
- 1.1: Replaced parameter *-AzManagementGroup from GroupName to GroupId
Comment: Create Azure Management Group hierechy based on an input JSON file.
=============================================================================
#>

[CmdLetBinding()]
Param (
  [Parameter(Mandatory = $true, ValueFromPipeline = $true, HelpMessage = 'Specify the file paths for the input json file.')]
  [ValidateScript({test-path $_ -PathType Leaf -Include *.json})][String]$InputFile,

  [Parameter(Mandatory = $false, HelpMessage = 'Silent mode. When used, no interative prompt for sign in')]
  [Switch]$silent,

  [Parameter(Mandatory = $false, HelpMessage = 'What-if mode. When used, no real changes will be made')]
  [Switch]$whatif
)


#region functions
Function ProcessAzureSignIn
{
    $null = Connect-AzAccount
    $context = Get-AzContext -ErrorAction Stop
    $Script:currentTenantId = $context.Tenant.Id
    $Script:currentSubId = $context.Subscription.Id
    $Script:currentSubName = $context.Subscription.Name
}

Function UpdateManagementGroups
{
  [CmdLetBinding()]
  Param (
    [Parameter(Mandatory = $true)][System.Collections.ArrayList]$managementGroups
  )
  Foreach ($mg in $managementGroups)
  {
    Write-Verbose "  - Updating MG '$($mg.name)'..."
    $parentMg = Get-AzManagementGroup -GroupId $mg.parent
    $updateResult = Update-AzManagementGroup -GroupId $($mg.name.tostring()) -DisplayName $($mg.displayName.tostring()) -ParentId $($parentMg.Id.tostring())
  }
}
Function CreateManagementGroups
{
  [CmdLetBinding()]
  Param (
    [Parameter(Mandatory = $true)][System.Collections.ArrayList]$managementGroups
  )
  $arrCompletedMG = New-Object System.Collections.ArrayList
  #Create tier 1 first
  Foreach ($mg in ($managementGroups | where-object {$_.parent.length -eq 0}))
  {
    Write-verbose " - Creating management group '$($mg.name)' with display name '$($mg.displayName)', placed under the Tenant Root MG"
    $CreateMGResult = New-AzManagementGroup -GroupId $($mg.name.tostring()) -DisplayName $($mg.displayName.tostring())
    $arrCompletedMG.add($mg.name)
  }

  #Loop through the rest to create the hierechy
  $i = 0 #maximum loop 5 times because the MG hierechy can only be 6 levels deep including the Tenant Root MG
  Do {
    $i = $i++
    foreach ($mg in $managementGroups)
    {
      if ((!$arrCompletedMG.Contains($mg.name)) -and $arrCompletedMG.contains($mg.parent))
      {
        Write-verbose " - Creating management group '$($mg.name)' with display name '$($mg.displayName)', placed under the '$($mg.parent)'"
        $parentMg = Get-AzManagementGroup -GroupId $mg.parent
        $CreateMGResult = New-AzManagementGroup -GroupId $($mg.name.tostring()) -DisplayName $($mg.displayName.tostring()) -ParentId $($parentMg.Id.tostring())
        $arrCompletedMG.add($mg.name)
      }
    }
  } Until ($arrCompletedMG.count -eq $managementGroups.count -or $i -eq 5)
  If ($arrCompletedMG.count -eq $managementGroups.count)
  {
    Write-Verbose " - All management groups have been created!"
  } else {
    Write-Error "Only $($arrCompletedMG.count) out of $($managementGroups.count) management groups have been created."
  }
}
Function CheckSubMGMembership
{
  [CmdLetBinding()]
  Param (
    [Parameter(Mandatory = $true)][string]$subscriptionId,
    [Parameter(Mandatory = $true)][string]$managementGroupName
  )
  $MG = Get-AzManagementGroup -GroupId $managementGroupName -Expand
  $bSubInMg = $false
  Foreach ($child in $MG.Children)
  {
    if ($child.type -ieq '/subscriptions' -and $child.name -ieq $subscriptionId)
    {
      $bSubInMg = $true
    }
  }
  $bSubInMg
}
Function MoveSubToMG
{
  [CmdLetBinding()]
  Param (
    [Parameter(Mandatory = $true)][System.Collections.ArrayList]$subscriptionPlacements
  )
  Foreach ($placementRule in $subscriptionPlacements)
  {
    Write-Verbose " - Check if subscription '$($placementRule.subName)' with Id $($placementRule.subId) is already placed in management group '$($placementRule.managementGroup)'"
    $bSubInMg = CheckSubMGMembership -subscriptionId $placementRule.subId -managementGroupName $placementRule.managementGroup
    If ($bSubInMg)
    {
      Write-Verbose "  - Subscription '$($placementRule.subName)' with Id $($placementRule.subId) is already placed in management group '$($placementRule.managementGroup)'. Skipped."
    } else {
      Write-Verbose "  - Placing subscription '$($placementRule.subName)' with Id $($placementRule.subId) to management group '$($placementRule.managementGroup)'"
      $moveSubResult = New-AzManagementGroupSubscription -GroupId $($placementRule.managementGroup) -SubscriptionId $($placementRule.SubId) -PassThru
      If ($moveSubResult -eq $true)
      {
        Write-Verbose "   - Successfully placed subscription '$($placementRule.subName)' with Id $($placementRule.subId) to management group '$($placementRule.managementGroup)'"
      }
    }
  }
}

Function ListSubscriptions
{
  [CmdLetBinding()]
  Param (
    [Parameter(Mandatory = $true)][String]$oAuthToken
  )
  $RequestURI = "https://management.azure.com/subscriptions?api-version=2016-06-01"
  $RequestHeaders = @{
    'Authorization' = $oAuthToken
    "Content-Type" = 'application/json'
  }
  Try {
    $ListSubscriptionsResponse = Invoke-WebRequest -UseBasicParsing -Uri $RequestURI -Headers $RequestHeaders -Method GET

    If ($ListSubscriptionsResponse.StatusCode -ge 200 -and $ListSubscriptionsResponse.StatusCode -le 299)
    {
      $subscriptions = (ConvertFrom-Json $ListSubscriptionsResponse.Content).value

    }
  } Catch {
    Throw $_.Exception
  }
  $subscriptions
}
#endregion

#region management groups
#variables
$managementGroups = new-object System.Collections.ArrayList
$mgNames = new-object System.Collections.ArrayList
if ($whatif)
{
  $script:whatif = $true
} else {
  $script:whatif = $false
}
$bValidInputFile = $true
#ensure signed in to Azure
if ($silent)
{
  Write-Verbose "Running script in silent mode."
}
Try
{
    $context = Get-AzContext -ErrorAction SilentlyContinue
    $Script:currentTenantId = $context.Tenant.Id
    $Script:currentSubId = $context.Subscription.Id
    $Script:currentSubName = $context.Subscription.Name
    if ($context -ne $null)
    {
      Write-output "You are currently signed to to tenant '$Script:currentTenantId', subscription '$Script:currentSubName'  using account '$($context.Account.Id).'"
      if (!$silent)
      {
        Write-Output '', "Press any key to continue using current sign-in session or Esc to login using another user account."
        $KeyPress = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        If ($KeyPress.virtualKeyCode -eq 27)
        {
          #sign out first
          Disconnect-AzAccount -AzureContext $context
          #sign in
          ProcessAzureSignIn
        }
      }
    } else {
      if (!$silent)
      {
        Write-Output '', "You are currently not signed in to Azure. Please sign in from the pop-up window."
        ProcessAzureSignIn
      } else {
        Throw "You are not signed in to Azure!"
      }

    }
} Catch {
    if (!$silent)
    {
      #sign in
      ProcessAzureSignIn
    } else {
      Throw "You are not signed in to Azure!"
    }

}
#Get oAuth Token cache from context
#$Context = Get-AzContext
$CachedTokens = $context.TokenCache.readItems()
$CachedToken = "Bearer $(($CachedTokens | Where-Object {$_.authority -imatch $Script:currentTenantId}).AccessToken)"
Write-Verbose "cached token: '$CachedToken'"
if ($script:whatif)
{
  Write-Output "Script running in the 'whatif' mode. no real changes will be made."
}
#read input file
Try {
  $objInput = (Get-Content -Path $InputFile -Raw) | ConvertFrom-Json
  Foreach ($mg in $objInput.managementGroups)
  {
    [void]$managementGroups.add($mg)
    [void]$mgNames.add($mg.name.ToLower())
  }
} Catch {
  Throw $_.exception
  Exit -1
}

#Validating input
Write-verbose "Validating input"

Foreach ($mg in $managementGroups)
{
  if ($mg.parent -ne $null)
  {
    if ($mgNames.contains($mg.parent.tolower()))
    {
      write-verbose " - the parent for MG '$($mg.name)' is '$($mg.parent)'. It is defined in input file."
    } else {
      Write-Error "the parent for MG '$($mg.name)' is '$($mg.parent)'. It is NOT defined in input file. Validation failed!"
      $bValidInputFile = $false
    }
  } else {
    write-verbose " - the management group'$($mg.name)' does not have a parent management group defined. it will be placed under the tenant root."
  }
}
if (!$bValidInputFile)
{
  Throw "Input file validation failed."
  Exit -1
}

#Process management groups from the input
if ($script:whatif)
{
  Write-Output "Processing Management Groups"
} else {
  Write-verbose "Processing Management Groups"
}

$arrUpdate = New-Object System.Collections.ArrayList
$arrCreate = New-object System.Collections.ArrayList
$arrSkip = New-object System.Collections.ArrayList

<#
#Get existing management groups
$arrExistingMGs = New-object System.Collections.ArrayList
$ExistingManagementGroups = Get-AzManagementGroup
Foreach ($MG in $ExistingManagementGroups)
{
  [void]$arrExistingMGs.Add((Get-AzManagementGroup -GroupId $MG.name -Expand))
}
Write-Verbose "Total existing management groups: $($arrExistingMGs.count)"
$TenantRootMG = $ExistingManagementGroups | where-object {$_.TenantId -eq $_.Name}
#>
$TenantRootMG = Get-AzManagementGroup -GroupId $Script:currentTenantId

#Process management groups defined in the input file
Foreach ($mg in $managementGroups)
{
  #checking if the MG already exists
  $bExisting = $false
  $mgParent = $mg.parent
  if ($mgParent.length -eq 0)
  {
    $mgParent = "Tenant Root Management Group"
    $mgParentName = $TenantRootMG.Name
  } else {
    $mgParentName = $mg.parent
  }
  $ExistingMg = Get-AzManagementGroup -GroupId $($mg.name) -Expand -ErrorAction SilentlyContinue
  If ($ExistingMg)
  {
    $bExisting = $true
    $ExistingMgName = $ExistingMg.Name
    $ExistingMgDisplayname = $ExistingMg.DisplayName
    $ExistingMgParentName = $ExistingMg.ParentName
    #Write-Verbose "comparing $($mg.name) and $ExistingMgName"
    if ($mgParentName -ieq $ExistingMgParentName -and $mg.displayName -eq $ExistingMgDisplayname)
    {
      $msg = " - Management Group $($mg.name) already exists and it's placed in the correct location in the hierarchy with correct display name. Skipped."
      [void]$arrSkip.add($mg)
    } else {
      Write-verbose "  - $($mg.name): defined display name: $($mg.displayName), current display name: $ExistingMGDisplayname"
      Write-verbose "  - $($mg.name): defined parent: $mgParentName, current parent: $ExistingMgParentName"
      $msg = " - Management Group $($mg.name) already exists. It will be updated with displayName '$($mg.displayName)' and placed under its parent management group '$mgParent'."
      [void]$arrUpdate.add($mg)
    }
  }
  if (!$bExisting)
  {
    $msg = " - Management Group $($mg.name) does not exist. It will be created with displayName '$($mg.displayName)' and placed under its parent management group '$mgParent'."
    [void]$arrCreate.add($mg)
  }
  #Write-Output $msg
  if ($script:whatif)
  {
    Write-Output $msg
  } else {
    Write-verbose $msg
  }
}
#process tenant root MG

#action
If ($objInput.tenantRootDisplayName -ine $TenantRootMG.DisplayName)
{
  $msg = " - Tenant Root Management Group display name will be changed from '$($TenantRootMG.DisplayName)' to '$($objInput.tenantRootDisplayName)'"
  if ($script:whatif)
  {
    Write-Output $msg
  } else {
    Write-verbose $msg
    $UpdateTenantRootMGResult = Update-AzManagementGroup -GroupId $TenantRootMG.Name -displayName $objInput.tenantRootDisplayName
  }
}
if (!$script:whatif)
{
  #Create new management groups
  if ($arrCreate.count -gt 0)
  {
    Write-Verbose "Creating $($arrCreate.Count) new management Group(s)."
    $CreateResult = CreateManagementGroups -managementGroups $arrCreate
  }
  #Update existing
  if ($arrUpdate.count -gt 0){
    Write-Verbose "Updating $($arrUpdate.count) existing management Group(s)."
    $UpdateResult = UpdateManagementGroups -managementGroups $arrUpdate
  }
} else {
  $msg = " - The current Tenant Root Management Group display name matches '$($objInput.tenantRootDisplayName)'. It will not be renamed"
  if ($script:whatif)
  {
    Write-Output $msg
  } else {
    Write-verbose $msg
  }
}

#Processing Management group results
if ($script:whatif)
{
  Write-Output "Management Setup Result:"
  Write-output " - Total number of Management Group would have been created: $($arrCreate.count)"
  Write-output " - Total number of Management Group would have been updated: $($arrUpdate.count)"
  Write-output " - Total number of Management Group would have been skipped: $($arrSkip.count)"
} else {
  Write-Verbose "Management Setup Result:"
  Write-Verbose " - Total number of Management Group created: $($arrCreate.count)"
  Write-Verbose " - Total number of Management Group updated: $($arrUpdate.count)"
  Write-Verbose " - Total number of Management Group skipped: $($arrSkip.count)"
}
#endregion

#region subscriptions
#variables
$arrSubPlacements = New-Object System.Collections.ArrayList
#get all subs
$AllSubscriptions = ListSubscriptions -oAuthToken $CachedToken
if ($script:whatif)
{
  Write-Output "Determining subscription placements:"
} else {
  Write-Verbose "Determining subscription placements:"
}

$subPlacementRules = $objInput.subscriptionPlacements
Foreach ($sub in $AllSubscriptions)
{
  $bPlaced = $false
  Foreach ($rule in $subPlacementRules)
  {
    if ($sub.displayName -imatch $rule.subNameRegex -and $sub.subscriptionPolicies.quotaId -imatch $rule.subQuotaIdRegex)
    {
      $msg = " - Subscription '$($sub.displayName)' with Id $($sub.subscriptionId) matches name regular expression '$($rule.subNameRegex)' and quota Id regular expression '$($rule.subQuotaIdRegex)'. It will be placed to management group '$($rule.managementGroup)'"
      $objSubPlacement = [PSCustomObject]@{
        subName = $sub.displayName;
        subId = $sub.subscriptionId
        managementGroup = $rule.managementGroup
      }
      [void]$arrSubPlacements.Add($objSubPlacement)
      $bPlaced = $true
      break;
    }
  }
  if (!$bplaced)
  {
    $msg = " - Subscription '$($sub.displayName)' with Id $($sub.subscriptionId) and quota Id $($sub.subscriptionPolicies.quotaId) does not match any regular expressions defined in the subscription placement rules. It will be placed to the default management group '$($objInput.defaultManagementGroup)'"
    $objSubPlacement = [PSCustomObject]@{
      subName = $sub.displayName;
      subId = $sub.subscriptionId
      managementGroup = $objInput.defaultManagementGroup
    }
    [void]$arrSubPlacements.Add($objSubPlacement)
    $bPlaced = $true
  }
  If ($script:whatif)
  {
    Write-output $msg
  } else {
    Write-Verbose $msg
  }
}
If (!$script:whatif)
{
  Write-verbose "Placing subscriptions to management groups:"
  $MoveSubResult = MoveSubToMG -subscriptionPlacements $arrSubPlacements
}
#endregion
