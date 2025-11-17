 # Ensure we're using Az modules and remove any AzureRM conflicts
Import-Module Az.Accounts, Az.Resources -Force
Get-Module -Name AzureRM* | Remove-Module -Force

# Generate unique environment name with timestamp
$timestamp = Get-Date -Format "MMddHHmm"
$environmentName = "mig$timestamp"

 $subscriptionId = (Get-AzContext).Subscription.Id
 $resourceGroup = "$environmentName-rg"
 $masterSiteName = "$($environmentName)mastersite"
 $migrateProjectName = "${environmentName}-azm"
 $assessmentProjectName = "${environmentName}-asmproject"
 $vmwarecollectorName = "${environmentName}-vmwaresitevmwarecollector"

 $apiVersionOffAzure = "2024-12-01-preview"


 $remoteZipFilePath = "https://github.com/crgarcia12/migrate-modernize-lab/raw/refs/heads/main/lab-material/Azure-Migrate-Discovery.zip"
 $localZipFilePath = Join-Path (Get-Location) "importArtifacts.zip"

 # Create resource group and deploy ARM template
   New-AzResourceGroup -Name "${environmentName}-rg" -Location "swedencentral"
   New-AzResourceGroupDeployment `
       -Name $environmentName `
      -ResourceGroupName "${environmentName}-rg" `
       -TemplateFile '.\templates\lab197959-template2 (v6).json' `
       -prefix $environmentName `
      -Verbose

# # # Get access token for REST API calls
  $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token

  $headers=@{} 
  $headers.Add("authorization", "Bearer $token") 
  $headers.Add("content-type", "application/json") 

   $registerToolApi = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/MigrateProjects/$migrateProjectName/registerTool?api-version=2020-06-01-preview"
   Write-Host "Register Server Discovery"
   $response = Invoke-RestMethod -Uri $registerToolApi `
      -Method POST `
      -Headers $headers `
       -ContentType 'application/json' `
       -Body '{   "tool": "ServerDiscovery" }'

   Write-Host "Register Server Assessment"
   $response = Invoke-RestMethod -Uri $registerToolApi `
      -Method POST `
      -Headers $headers `
      -ContentType 'application/json' `
      -Body '{   "tool": "ServerAssessment" }'

   Invoke-WebRequest $remoteZipFilePath -OutFile $localZipFilePath

# # # # Upload the ZIP file to OffAzure and start import
   $importUriUrl = "https://management.azure.com/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.OffAzure/masterSites/${masterSiteName}/Import?api-version=${apiVersionOffAzure}"
   $importdiscoveredArtifactsResponse = Invoke-RestMethod -Uri $importUriUrl -Method POST -Headers $headers
   $blobUri = $importdiscoveredArtifactsResponse.uri
   $jobArmId = $importdiscoveredArtifactsResponse.jobArmId

   Write-Host "blob URI: $blobUri"
   Write-Host "Job ARM ID: $jobArmId"

   Write-Host "Uploading ZIP to blob.."
   $fileBytes = [System.IO.File]::ReadAllBytes($localZipFilePath)
   $uploadBlobHeaders = @{
      "x-ms-blob-type" = "BlockBlob"
      "x-ms-version"   = "2020-04-08"
   }
   Invoke-RestMethod -Uri $blobUri -Method PUT -Headers $uploadBlobHeaders -Body $fileBytes -ContentType "application/octet-stream"
   Write-Host "Done ZIP to blob.."
   $jobUrl = "https://management.azure.com${jobArmId}?api-version=${apiVersionOffAzure}"

   Write-Host "Polling import job status..."
   $waitTimeSeconds = 20
   $maxAttempts = 50 * (60 / $waitTimeSeconds)  # 50 minutes timeout
   $attempt = 0
   $jobCompleted = $false
 
   do {
       $jobStatus = Invoke-RestMethod -Uri $jobUrl -Method GET -Headers $headers
       $jobResult = $jobStatus.properties.jobResult
       Write-Host "Attempt $($attempt): Job status - $jobResult"

       if ($jobResult -eq "Completed") {
           $jobCompleted = $true
           break
       } elseif ($jobResult -eq "Failed") {
           throw "Import job failed."
       }
       Start-Sleep -Seconds $waitTimeSeconds
       $attempt++
  } while ($attempt -lt $maxAttempts)

  if (-not $jobCompleted) {
      throw "Timed out waiting for import job to complete."
  } else {
       Write-Host "Import job completed. Imported $importedCount machines."
   }

# Get VMware site first
$vmwareSiteUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/VMwareSites/$($environmentName)vmwaresite?api-version=2024-12-01-preview"
$vmwareSiteResponse = Invoke-RestMethod -Uri $vmwareSiteUri -Method GET -Headers $headers
$vmwareSiteId = $vmwareSiteResponse.id
$agentId = $vmwareSiteResponse.properties.agentDetails.id

# Get WebApp site
Write-Host "Getting WebApp Site"
$webAppSiteName = "$($environmentName)webappsite"
$webAppSiteUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/WebAppSites/$($environmentName)webappsite?api-version=2024-12-01-preview"
Write-Host "WebApp Site URI: $webAppSiteUri"

try {
    $webAppSiteResponse = Invoke-RestMethod -Uri $webAppSiteUri -Method GET -Headers $headers
    $webAppSiteId = $webAppSiteResponse.id
    
    # Extract agent ID from siteAppliancePropertiesCollection
    if ($webAppSiteResponse.properties.siteAppliancePropertiesCollection -and $webAppSiteResponse.properties.siteAppliancePropertiesCollection.Count -gt 0) {
        $webAppAgentId = $webAppSiteResponse.properties.siteAppliancePropertiesCollection[0].agentDetails.id
        Write-Host "WebApp Agent ID: $webAppAgentId"
    } else {
        Write-Host "No appliance properties found in WebApp site" -ForegroundColor Yellow
        $webAppAgentId = $null
    }
    
    Write-Host "WebApp Site ID: $webAppSiteId"
    Write-Host "WebApp Site retrieved successfully"
} catch {
    Write-Host "Failed to get WebApp Site: $($_.Exception.Message)" -ForegroundColor Yellow
    $webAppSiteId = $null
    $webAppAgentId = $null
}

# Get SQL Site
Write-Host "Getting SQL Site"
$sqlSiteName = "$($environmentName)sqlsites"
$sqlSiteUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/SqlSites/$($environmentName)sqlsites?api-version=2024-12-01-preview"
Write-Host "SQL Site URI: $sqlSiteUri"

try {
    $sqlSiteResponse = Invoke-RestMethod -Uri $sqlSiteUri -Method GET -Headers $headers
    $sqlSiteId = $sqlSiteResponse.id
    
    # Extract agent ID from siteAppliancePropertiesCollection
    if ($sqlSiteResponse.properties.siteAppliancePropertiesCollection -and $sqlSiteResponse.properties.siteAppliancePropertiesCollection.Count -gt 0) {
        $sqlAgentId = $sqlSiteResponse.properties.siteAppliancePropertiesCollection[0].agentDetails.id
        Write-Host "SQL Agent ID: $sqlAgentId"
    } else {
        Write-Host "No appliance properties found in SQL site" -ForegroundColor Yellow
        $sqlAgentId = $null
    }
    
    Write-Host "SQL Site ID: $sqlSiteId"
    Write-Host "SQL Site retrieved successfully"
} catch {
    Write-Host "Failed to get SQL Site: $($_.Exception.Message)" -ForegroundColor Yellow
    $sqlSiteId = $null
    $sqlAgentId = $null
}

    # Create VMware Collector
     Write-Host "Creating VMware Collector" -ErrorAction Continue
    $assessmentProjectName = "${environmentName}asmproject"
    $vmwarecollectorName = "${environmentName}vmwaresitevmwarecollector"

    # Get site first
    $vmwareSiteUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/VMwareSites/$($environmentName)vmwaresite?api-version=2024-12-01-preview"
    $vmwareSiteResponse = Invoke-RestMethod -Uri $vmwareSiteUri -Method GET -Headers $headers


    $vmwareCollectorUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/vmwarecollectors/$($vmwarecollectorName)?api-version=2018-06-30-preview"
    $vmwareCollectorBody = @{
        "id" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/vmwarecollectors/$vmwarecollectorName"
        "name" = "$vmwarecollectorName"
        "type" = "Microsoft.Migrate/assessmentprojects/vmwarecollectors"
        "properties" = @{
            "agentProperties" = @{
                "id" = "$($vmwareSiteResponse.properties.agentDetails.id)"
                "lastHeartbeatUtc" = "2025-04-24T09:48:04.3893222Z"
                "spnDetails" = @{
                    "authority" = "authority"
                    "applicationId" = "appId"
                    "audience" = "audience"
                    "objectId" = "objectid"
                    "tenantId" = "tenantid"
                }
            }
            "discoverySiteId" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/VMwareSites/$($environmentName)vmwaresite"
        }
    } | ConvertTo-Json -Depth 10
    
    $response = Invoke-RestMethod -Uri $vmwareCollectorUri `
        -Method PUT `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $vmwareCollectorBody    

    # Create WebApp Collector
    Write-Host "Creating WebApp Collector"
    $webAppCollectorName = "${environmentName}webappsitecollector"
    $webAppApiVersion = "2025-09-09-preview"
    $webAppCollectorUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/webappcollectors/$webAppCollectorName" + "?api-version=$webAppApiVersion"
    Write-Host "WebApp Collector URI: $webAppCollectorUri"
    
    $webAppCollectorBody = @{
        "id" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/webappcollectors/$webAppCollectorName"
        "name" = "$webAppCollectorName"
        "type" = "Microsoft.Migrate/assessmentprojects/webappcollectors"
        "properties" = @{
            "agentProperties" = @{
                "id" = $webAppAgentId
                "version" = $null
                "lastHeartbeatUtc" = $null
                "spnDetails" = @{
                    "authority" = "authority"
                    "applicationId" = "appId"
                    "audience" = "audience"
                    "objectId" = "objectid"
                    "tenantId" = "tenantid"
                }
            }
            "discoverySiteId" = $webAppSiteId
        }
    } | ConvertTo-Json -Depth 10
    
    if ($webAppAgentId -and $webAppSiteId) {
        $webAppResponse = Invoke-RestMethod -Uri $webAppCollectorUri `
            -Method PUT `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $webAppCollectorBody
        Write-Host "WebApp Collector created successfully"
    } else {
        Write-Host "Skipping WebApp Collector creation - missing WebApp agent ID or site ID" -ForegroundColor Yellow
    }

    # Create SQL Collector
    Write-Host "Creating SQL Collector"
    $sqlCollectorName = "${environmentName}sqlsitescollector"
    $sqlApiVersion = "2025-09-09-preview"
    $sqlCollectorUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/sqlcollectors/$sqlCollectorName" + "?api-version=$sqlApiVersion"
    Write-Host "SQL Collector URI: $sqlCollectorUri"
    
    $sqlCollectorBody = @{
        "id" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/sqlcollectors/$sqlCollectorName"
        "name" = "$sqlCollectorName"
        "type" = "Microsoft.Migrate/assessmentprojects/sqlcollectors"
        "properties" = @{
            "agentProperties" = @{
                "id" = $sqlAgentId
                "version" = $null
                "lastHeartbeatUtc" = $null
                "spnDetails" = @{
                    "authority" = "authority"
                    "applicationId" = "appId"
                    "audience" = "audience"
                    "objectId" = "objectid"
                    "tenantId" = "tenantid"
                }
            }
            "discoverySiteId" = $sqlSiteId
        }
    } | ConvertTo-Json -Depth 10
    
    if ($sqlAgentId -and $sqlSiteId) {
        $sqlResponse = Invoke-RestMethod -Uri $sqlCollectorUri `
            -Method PUT `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $sqlCollectorBody
        Write-Host "SQL Collector created successfully"
    } else {
        Write-Host "Skipping SQL Collector creation - missing SQL agent ID or site ID" -ForegroundColor Yellow
    }

    # Create Assessment
    Write-Host "Creating Assessment"
    Write-Host "Creating All VM Assessment"
    $assessmentRandomSuffix = -join ((65..90) + (97..122) | Get-Random -Count 3 | % {[char]$_})
    $assessmentName = "assessment$assessmentRandomSuffix"
    Write-Host "Assessment Name: $assessmentName"
    $apiVersion = "2024-03-03-preview"
    $assessmentUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/$assessmentName" + "?api-version=$apiVersion"
    Write-Host "Assessment URI: $assessmentUri"
    
    $assessmentBody = @{
        "type" = "Microsoft.Migrate/assessmentprojects/assessments"
        "apiVersion" = "2024-03-03-preview"
        "name" = "$assessmentProjectName/$assessmentName"
        "location" = "swedencentral"
        "tags" = @{}
        "kind" = "Migrate"
        "properties" = @{
            "settings" = @{
                "performanceData" = @{
                    "timeRange" = "Day"
                    "percentile" = "Percentile95"
                }
                "scalingFactor" = 1
                "azureSecurityOfferingType" = "MDC"
                "azureHybridUseBenefit" = "Yes"
                "linuxAzureHybridUseBenefit" = "Yes"
                "savingsSettings" = @{
                    "savingsOptions" = "RI3Year"
                }
                "billingSettings" = @{
                    "licensingProgram" = "Retail"
                    "subscriptionId" = $subscriptionId
                }
                "azureDiskTypes" = @()
                "azureLocation" = "swedencentral"
                "azureVmFamilies" = @()
                "environmentType" = "Production"
                "currency" = "USD"
                "discountPercentage" = 0
                "sizingCriterion" = "PerformanceBased"
                "azurePricingTier" = "Standard"
                "azureStorageRedundancy" = "LocallyRedundant"
                "vmUptime" = @{
                    "daysPerMonth" = "31"
                    "hoursPerDay" = "24"
                }
            }
            "details" = @{}
            "scope" = @{
                "azureResourceGraphQuery" = "migrateresources`n        | where id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/VMwareSites/$($environmentName)vmwaresite`" or`n            id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/WebAppSites/$($environmentName)webappsite`" or`n            id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/SqlSites/$sqlSiteName`""
                "scopeType" = "AzureResourceGraphQuery"
            }
        }
    } | ConvertTo-Json -Depth 10

    $assessmentResponse = Invoke-RestMethod -Uri $assessmentUri `
        -Method PUT `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $assessmentBody

    Write-Host "Created All VM Assessment created successfully"

    Write-Host "Creating All SQL Assessment"
    $assessmentRandomSuffix = -join ((65..90) + (97..122) | Get-Random -Count 3 | % {[char]$_})
    $assessmentName = "assessment$assessmentRandomSuffix"
    Write-Host "Assessment Name: $assessmentName"
    $apiVersion = "2024-03-03-preview"
    $assessmentUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/sqlassessments/$assessmentName" + "?api-version=$apiVersion"
    Write-Host "Assessment URI: $assessmentUri"
    
    $assessmentBody = @{
        "type" = "Microsoft.Migrate/assessmentprojects/assessments"
        "apiVersion" = "2024-03-03-preview"
        "name" = "$assessmentProjectName/$assessmentName"
        "location" = "swedencentral"
        "tags" = @{}
        "kind" = "Migrate"
        "properties" = @{
            "settings" = @{
                "performanceData" = @{
                    "timeRange" = "Day"
                    "percentile" = "Percentile95"
                }
                "scalingFactor" = 1
                "azureSecurityOfferingType" = "MDC"
                "osLicense" = "Yes"
                "azureLocation" = "koreasouth"
                "preferredTargets" = @(
                    "SqlMI"
                )
                "discountPercentage" = 0
                "currency" = "USD"
                "sizingCriterion" = "PerformanceBased"
                "savingsSettings" = @{
                    "savingsOptions" = "SavingsPlan1Year"
                }
                "billingSettings" = @{
                    "licensingProgram" = "Retail"
                    "subscriptionId" = "4bd2aa0f-2bd2-4d67-91a8-5a4533d58600"
                }
                "sqlServerLicense" = "Yes"
                "azureSqlVmSettings" = @{
                    "instanceSeries" = @(
                        "Ddsv4_series",
                        "Ddv4_series",
                        "Edsv4_series",
                        "Edv4_series"
                    )
                }
                "entityUptime" = @{
                    "daysPerMonth" = 31
                    "hoursPerDay" = 24
                }
                "azureSqlManagedInstanceSettings" = @{
                    "azureSqlInstanceType" = "SingleInstance"
                    "azureSqlServiceTier" = "SqlServiceTier_Automatic"
                }
                "azureSqlDatabaseSettings" = @{
                    "azureSqlComputeTier" = "Provisioned"
                    "azureSqlPurchaseModel" = "VCore"
                    "azureSqlServiceTier" = "SqlServiceTier_Automatic"
                    "azureSqlDataBaseType" = "SingleDatabase"
                }
                "environmentType" = "Production"
                "enableHadrAssessment" = $true
                "disasterRecoveryLocation" = "koreasouth"
                "multiSubnetIntent" = "DisasterRecovery"
                "isInternetAccessAvailable" = $true
                "asyncCommitModeIntent" = "DisasterRecovery"
            }
            "details" = @{}
            "scope" = @{
                "azureResourceGraphQuery" = "migrateresources`n        | where id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/VMwareSites/$($environmentName)vmwaresite`" or`n            id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/WebAppSites/$($environmentName)webappsite`" or`n            id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/SqlSites/$sqlSiteName`""
                "scopeType" = "AzureResourceGraphQuery"
            }
        }
    } | ConvertTo-Json -Depth 10

    $assessmentResponse = Invoke-RestMethod -Uri $assessmentUri `
        -Method PUT `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $assessmentBody

    Write-Host "Created All SQL Assessment created successfully"
    Write-Host "Created Assessment created successfully"

    # Create Optimise for PaaS Business Case
    Write-Host "Creating Business Case"
    Write-Host "Creating OptimizeForPaas Business Case"
    $randomSuffix = -join ((65..90) + (97..122) | Get-Random -Count 3 | % {[char]$_})
    $businessCaseName = "buizzcase$randomSuffix"
    Write-Host "Business Case Name: $businessCaseName"
    $businessCaseApiVersion = "2025-09-09-preview"
    $businessCaseUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/businesscases/$businessCaseName" + "?api-version=$businessCaseApiVersion"
    Write-Host "Business Case URI: $businessCaseUri"
    
    $businessCaseBody = @{
        "type" = "Microsoft.Migrate/assessmentprojects/businesscases"
        "apiVersion" = $businessCaseApiVersion
        "name" = "$assessmentProjectName/$businessCaseName"
        "location" = "swedencentral"
        "kind" = "Migrate"
        "properties" = @{
            "businessCaseScope" = @{
                "scopeType" = "Datacenter"
                "azureResourceGraphQuery" = "migrateresources`n        | where id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/VMwareSites/$($environmentName)vmwaresite`" or`n            id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/WebAppSites/$($environmentName)webappsite`" or`n            id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/SqlSites/$sqlSiteName`""
            }
            "settings" = @{
                "commonSettings" = @{
                    "targetLocation" = "swedencentral"
                    "infrastructureGrowthRate" = 0
                    "currency" = "USD"
                    "workloadDiscoverySource" = "Appliance"
                    "businessCaseType" = "OptimizeForPaas"
                }
                "azureSettings" = @{
                    "savingsOption" = "RI3Year"
                }
            }
            "details" = @{}
        }
    } | ConvertTo-Json -Depth 10

    $businessCaseResponse = Invoke-RestMethod -Uri $businessCaseUri `
        -Method PUT `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $businessCaseBody

    Write-Host "Business Case created successfully for Optimize for PaaS"


    # Create IaaSOnly Business Case
    Write-Host "Creating IaaSOnly Business Case"
    $randomSuffix = -join ((65..90) + (97..122) | Get-Random -Count 3 | % {[char]$_})
    $businessCaseName = "buizzcase$randomSuffix"
    Write-Host "Business Case Name: $businessCaseName"
    $businessCaseApiVersion = "2025-09-09-preview"
    $businessCaseUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/businesscases/$businessCaseName" + "?api-version=$businessCaseApiVersion"
    Write-Host "Business Case URI: $businessCaseUri"
    
    $businessCaseBody = @{
        "type" = "Microsoft.Migrate/assessmentprojects/businesscases"
        "apiVersion" = $businessCaseApiVersion
        "name" = "$assessmentProjectName/$businessCaseName"
        "location" = "swedencentral"
        "kind" = "Migrate"
        "properties" = @{
            "businessCaseScope" = @{
                "scopeType" = "Datacenter"
                "azureResourceGraphQuery" = "migrateresources`n        | where id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/VMwareSites/$($environmentName)vmwaresite`" or`n            id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/WebAppSites/$($environmentName)webappsite`" or`n            id contains `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/SqlSites/$sqlSiteName`""
            }
            "settings" = @{
                "commonSettings" = @{
                    "targetLocation" = "swedencentral"
                    "infrastructureGrowthRate" = 0
                    "currency" = "USD"
                    "workloadDiscoverySource" = "Appliance"
                    "businessCaseType" = "IaaSOnly"
                }
                "azureSettings" = @{
                    "savingsOption" = "RI3Year"
                }
            }
            "details" = @{}
        }
    } | ConvertTo-Json -Depth 10

    $businessCaseResponse = Invoke-RestMethod -Uri $businessCaseUri `
        -Method PUT `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $businessCaseBody

    Write-Host "Business Case created successfully for IaaSOnly"
    Write-Host "Business Case created successfully."

    # Create Heterogeneous Assessment
    Write-Host "Creating Heterogeneous Assessment"
    $heteroAssessmentRandomSuffix = -join ((65..90) + (97..122) | Get-Random -Count 3 | % {[char]$_})
    $heteroAssessmentName = "default-all-workloads$heteroAssessmentRandomSuffix"
    Write-Host "Heterogeneous Assessment Name: $heteroAssessmentName"
    $heteroApiVersion = "2024-03-03-preview"
    $heteroAssessmentUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/heterogeneousAssessments/$heteroAssessmentName" + "?api-version=$heteroApiVersion"
    Write-Host "Heterogeneous Assessment URI: $heteroAssessmentUri"
    
    $heteroAssessmentBody = @{
        "type" = "Microsoft.Migrate/assessmentProjects/heterogeneousAssessments"
        "apiVersion" = "2024-03-03-preview"
        "name" = "$assessmentProjectName/$heteroAssessmentName"
        "location" = "koreasouth"
        "tags" = @{}
        "kind" = "Migrate"
        "properties" = @{
            "assessmentArmIds" = @(
                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/AssessmentProjects/$assessmentProjectName/assessments/assessment*",
                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/sqlassessments/assessment*"
            )
        }
    } | ConvertTo-Json -Depth 10

    $heteroAssessmentResponse = Invoke-RestMethod -Uri $heteroAssessmentUri `
        -Method PUT `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $heteroAssessmentBody

    Write-Host "Heterogeneous Assessment created successfully"

    # Custom Applications generation
    Write-Host "Creating Custom Applications"

    # Export AllInventory using Azure Resource Graph Query
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Exporting AllInventory using Azure Resource Graph Query..." -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Define the Kusto query for AllInventory export
    $kusto_query = @"
migrateresources
        | where type in~ ("microsoft.offazure/vmwaresites/machines","microsoft.offazure/hypervsites/machines","microsoft.offazure/serversites/machines","microsoft.offazure/importsites/machines","microsoft.offazure/mastersites/sqlsites/sqlservers","microsoft.offazure/mastersites/webappsites/iiswebapplications","Microsoft.ApplicationMigration/PGSQLSites/PGSQLInstances","microsoft.offazure/mastersites/webappsites/tomcatwebapplications")
        | where id has "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.offazure/vmwaresites/$($environmentName)vmwaresite" or id has "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.applicationmigration/pgsqlsites/$($environmentName)pgsql" or id has "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.mysqldiscovery/mysqlsites/$($environmentName)mysql" or id has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/SqlSites/$($environmentName)sqlsites" or id has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/WebAppSites/$($environmentName)webappsite" or id has "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.applicationmigration/pgsqlsites/$($environmentName)pgsql" or id has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/WebAppSites/$($environmentName)webappsite" or id has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/VMwareSites/$($environmentName)vmwaresite" or id has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName"
        | extend type=tolower(type)
        | extend id = tolower(id)
        | join kind = leftouter (
            migrateresources
            | where type =~ "microsoft.applicationmigration/discoveryhubs/applications/members"
            | where properties.memberResourceId has "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.offazure/vmwaresites/$($environmentName)vmwaresite" or properties.memberResourceId has "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.applicationmigration/pgsqlsites/$($environmentName)pgsql" or properties.memberResourceId has "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.mysqldiscovery/mysqlsites/$($environmentName)mysql" or properties.memberResourceId has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/SqlSites/$($environmentName)sqlsites" or properties.memberResourceId has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/WebAppSites/$($environmentName)webappsite" or properties.memberResourceId has "/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.applicationmigration/pgsqlsites/$($environmentName)pgsql" or properties.memberResourceId has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName/WebAppSites/$($environmentName)webappsite" or properties.memberResourceId has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/VMwareSites/$($environmentName)vmwaresite" or properties.memberResourceId has "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.OffAzure/MasterSites/$masterSiteName"
            | extend memberResourceId = tolower(properties.memberResourceId)
            | parse kind=regex id with applicationId '/members/'
            | project memberResourceId, applicationId
            )
            on `$left.id == `$right.memberResourceId
        | summarize applicationId = strcat_array(make_set(applicationId), ", "), properties = take_any(properties), type = take_any(type) by id
        | extend properties_machineArmIds = iif(array_length(properties.machineArmIds) == 0, pack_array(id), properties.machineArmIds)
        | mv-expand properties_machineArmIds
        | extend machineArmIds=tostring(properties_machineArmIds)
        | extend parentId = case(type contains "/machines", id, machineArmIds)
        | extend id = tolower(id), siteId = case(id has "machines", tostring(split(tolower(id),"/machines/")[0]), id has "sqlsites", tostring(split(tolower(id),"/sqlsites/")[0]), id has "webappsites", tostring(split(tolower(id),"/webappsites/")[0]), "")
        | extend parentId = tolower(parentId),
            armId = id,
            resourceType = type,
            host = case(
                id contains "microsoft.offazure/vmwaresites", "VMware",
                id contains "microsoft.offazure/hypervsites", "Hyper-V",
                id contains "microsoft.offazure/serversites", "Physical",
                id contains "microsoft.offazure/importsites" and properties.hypervisor =~ "VMWare", "VMware",
                id contains "microsoft.offazure/importsites" and strlen(properties.hypervisor) > 0 and properties.hypervisor !~ "VMWare", properties.hypervisor,
                "-"),
            resourceTags = properties.tags,
            resourceName = tostring(case(type contains "/sqlservers", properties.sqlServerName, case(type contains "/pgsqlinstances", strcat(properties.hostName, ":", properties.portNumber), properties.displayName))),
            osName = tostring(case(id has "/machines/", coalesce(properties.guestOSDetails.osName, properties.operatingSystemDetails.osName), id has "/sqlsites/", "", id has "/webappsites/", properties.version, properties.version)),
            databaseEdition = tostring(case(id has "/machines/", "-", id has "/sqlsites/", properties.edition, id has "/webappsites/", properties.version, properties.edition)),
            osType = tostring(coalesce(properties.guestOSDetails.osType, properties.operatingSystemDetails.osType)),
            osArchitecture = tostring(coalesce(properties.guestOSDetails.osArchitecture, properties.operatingSystemDetails.osArchitecture)),
            powerOnStatus = case(properties.powerStatus == "ON" or properties.powerStatus == "Running", "On", properties.powerStatus == "OFF" or properties.powerStatus == "PowerOff" or properties.powerStatus == "Saved" or properties.powerStatus == "Paused", "Off", "-"),
            source = case(type contains "vmwaresites", properties.vCenterFQDN, type contains "hypervsites", coalesce(properties.clusterFqdn, properties.hostFqdn), ""),
            discoverySource = case(id contains "microsoft.offazure/importsites", "Import", id contains "/sqlsites/" and properties.discoveryState == "Imported", "Import", "Appliance"),
            dbProperties = case(id has "/sqlsites/", properties, parse_json("")),
            dbEngineStatus =  tostring(case(id has "/sqlsites/" or id has "/pgsqlinstances/", properties.status, "")),
            userdatabases = tostring(case(id has "/sqlsites/", properties.numberOfUserDatabases, case(id has "/pgsqlinstances/", properties.numberOfDatabase, ""))),
            totalSizeInGB =  properties.totalDiskSizeInGB,
            ipAddressList = properties.ipAddresses,
            totalWebAppCount = tolong(case(id has "/machines/", case(coalesce(tolong(properties.webAppDiscovery.totalWebApplicationCount), 0) == 0, coalesce(tolong(properties.iisDiscovery.totalWebApplicationCount), 0) + coalesce(tolong(properties.tomcatDiscovery.totalWebApplicationCount), 0), coalesce(tolong(properties.webAppDiscovery.totalWebApplicationCount), 0)), 0)),
            totalDatabaseInstances = tolong(case(id has "/machines/", coalesce(tolong(properties.totalInstanceCount), 0), 0)),
            memoryInMB = case(id has "/sqlsites/", tolong(properties.maxServerMemoryInUseInMb), case(id has "/pgsqlinstances/", tolong(properties.hostMachineProperties.allocatedMemoryInMb), tolong(properties.allocatedMemoryInMB))),
            dbhadrConfiguration = tostring(case(id has "/sqlsites/", (case(toboolean(properties.isClustered) and toboolean(properties.isHighAvailabilityEnabled), "Both", case(toboolean(properties.isClustered), "FailoverClusterInstance", case(toboolean(properties.isHighAvailabilityEnabled), "AvailabilityGroup", "")))), "")),
            diskCount = array_length(properties.disks),
            supportStatus = coalesce(properties.productSupportStatus.supportStatus, properties.supportStatus),
            supportEndsIn = case(datetime_diff("day", todatetime(properties.productSupportStatus.supportEndDate), todatetime(now())) < 0, " ",tostring(datetime_diff("day", todatetime(properties.productSupportStatus.supportEndDate), todatetime(now())))),
            depmapErrorCount = array_length(properties.dependencyMapDiscovery.errors),
            serverName = tostring(case(type contains "/sqlservers", properties.machineOverviewList[0].displayName, type has "/webappsites/", properties.machineDisplayName, "")),
            numberOfSecurityRisks = properties.numberOfSecurityRisks,
            numberOfSoftware = properties.numberOfSoftware,
            frameworkVersion = tostring(case(id has "/webappsites/", properties.frameworks[0].version, "-"))
| order by tolower(resourceName) asc
| project id, parentId, resourceName, serverName, resourceType, osName, properties.dependencyMapping, applicationId, numberOfSoftware, supportStatus, numberOfSecurityRisks, discoverySource, host, source, properties.tags, totalDatabaseInstances, dbProperties.numberOfUserDatabases, totalWebAppCount, properties, dbProperties, properties.numberOfProcessorCore, memoryInMB, diskCount, totalSizeInGB, osType, supportEndsIn, powerOnStatus, siteId, databaseEdition, frameworkVersion, dbProperties.status, dbhadrConfiguration, depmapErrorCount, properties.dependencyMapDiscovery.discoveryScopeStatus, properties.autoEnableDependencyMapping, ipAddressList
| project-rename armId=id, dependencyMapping=properties_dependencyMapping, resourceTags=properties_tags, userdatabases=dbProperties_numberOfUserDatabases, cores=properties_numberOfProcessorCore, dbEngineStatus=dbProperties_status, depMapDiscoveryScopeStatus=properties_dependencyMapDiscovery_discoveryScopeStatus, autoEnableDependencyMapping=properties_autoEnableDependencyMapping
"@

    # Create the request body for ARG query
    $requestBody = @{
        "options" = @{
            "`$top" = 1000
            "`$skip" = 0
        }
        "subscriptions" = @($subscriptionId)
        "query" = $kusto_query
    } | ConvertTo-Json -Depth 10

    # Define the API endpoint
    $apiUri = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2018-09-01-preview"

    # Make the REST API call
    try {
        Write-Host "Executing Azure Resource Graph query..." -ForegroundColor Green
        $response = Invoke-RestMethod -Uri $apiUri `
            -Method POST `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $requestBody

        Write-Host "Query executed successfully!" -ForegroundColor Green
        Write-Host "Total count: $($response.totalRecords)" -ForegroundColor Cyan
        Write-Host "Results count: $($response.count)" -ForegroundColor Cyan
        
        # Handle Azure Resource Graph specific response structure with data.columns and data.rows
        if ($response.data -and $response.data.columns -and $response.data.rows) {
            Write-Host "`nFound structured data with columns and rows" -ForegroundColor Green
            $columns = $response.data.columns
            $dataRows = $response.data.rows
            
            Write-Host "Columns count: $($columns.Count)" -ForegroundColor Cyan
            Write-Host "Rows count: $($dataRows.Count)" -ForegroundColor Cyan
            
            # Convert rows to structured objects using column names
            $dataArray = @()
            foreach ($row in $dataRows) {
                $rowObject = [PSCustomObject]@{}
                for ($i = 0; $i -lt $columns.Count; $i++) {
                    $columnName = $columns[$i].name
                    $value = if ($i -lt $row.Count) { $row[$i] } else { $null }
                    $rowObject | Add-Member -MemberType NoteProperty -Name $columnName -Value $value
                }
                $dataArray += $rowObject
            }
            
            Write-Host "`nSuccessfully converted $($dataArray.Count) rows to structured objects" -ForegroundColor Green
            
            # Transform data to target CSV format
            if ($dataArray -and $dataArray.Count -gt 0) {
                Write-Host "`nProcessing $($dataArray.Count) results..." -ForegroundColor Yellow
                
                $processedData = @()
                foreach ($item in $dataArray) {
                    # Extract properties JSON for complex data
                    $propertiesJson = $null
                    if ($item.properties) {
                        try {
                            $propertiesJson = $item.properties | ConvertFrom-Json
                        } catch {
                            $propertiesJson = $null
                        }
                    }
                    
                    # Create transformed record matching target structure
                    $processedItem = [PSCustomObject]@{
                        'Id' = $item.armId
                        'parentId' = $item.parentId
                        'Workload' = $item.resourceName
                        'Server' = if ($item.serverName) { $item.serverName } else { "-" }
                        'Category' = switch -Regex ($item.resourceType) {
                            'webapplications' { 'Web app' }
                            'machines' { 'Server' }
                            'pgsqlinstances' { 'Database' }
                            'sqlservers' { 'Database' }
                            default { 'Other' }
                        }
                        'Type' = switch -Regex ($item.resourceType) {
                            'webapplications' { '.NET/IIS' }
                            'machines' { if ($item.osType -eq 'Linux') { 'Linux server' } else { 'Windows server' } }
                            'pgsqlinstances' { 'PostgreSQL server' }
                            'sqlservers' { 'SQL server' }
                            default { 'Unknown' }
                        }
                        'OS name' = if ($item.osName) { $item.osName } else { "-" }
                        'Dependencies' = if ($item.dependencyMapping -eq 'Enabled') { 'Enabled' } else { 'Disabled' }
                        'Application name(s)' = if ($item.applicationId) { $item.applicationId } else { "default" }
                        'Softwares(#)' = if ($item.numberOfSoftware) { $item.numberOfSoftware } else { "-" }
                        'Support status' = if ($item.supportStatus) { $item.supportStatus } else { "-" }
                        'Security risks' = if ($item.numberOfSecurityRisks) { $item.numberOfSecurityRisks } else { "-" }
                        'Discovery method' = if ($item.discoverySource) { $item.discoverySource } else { "-" }
                        'Hypervisor type' = if ($item.host) { $item.host } else { " -" }
                        'Host' = if ($item.source) { $item.source } else { "-" }
                        'Tags' = if ($item.resourceTags) { $item.resourceTags } else { "{}" }
                        'DB instances(#)' = if ($item.totalDatabaseInstances) { $item.totalDatabaseInstances } else { "-" }
                        'Databases(#)' = if ($item.userdatabases) { $item.userdatabases } else { "-" }
                        'Webapps(#)' = if ($item.totalWebAppCount) { $item.totalWebAppCount } else { "-" }
                        'vCores(#)' = if ($item.cores) { $item.cores } else { "-" }
                        'Memory (MB)' = if ($item.memoryInMB) { $item.memoryInMB } else { "-" }
                        'Disks(#)' = if ($item.diskCount) { $item.diskCount } else { "-" }
                        'Allocated storage (GB)' = if ($item.totalSizeInGB) { $item.totalSizeInGB } else { "-" }
                        'OS Family' = if ($item.osType) { $item.osType } else { "-" }
                        'Support ends in (Days)' = if ($item.supportEndsIn -and $item.supportEndsIn -ne " ") { $item.supportEndsIn } else { "-" }
                        'Power status' = if ($item.powerOnStatus) { $item.powerOnStatus } else { " -" }
                        'Connected appliance' = if ($item.host -eq 'VMware') { 'app130collector' } else { " -" }
                        'First discovered at' = if ($propertiesJson -and $propertiesJson.createdTimestamp) { $propertiesJson.createdTimestamp } else { "-" }
                        'Last updated at' = if ($propertiesJson -and $propertiesJson.updatedTimestamp) { $propertiesJson.updatedTimestamp } else { "-" }
                        'Processor' = if ($propertiesJson -and $propertiesJson.hostProcessorInfo -and $propertiesJson.hostProcessorInfo.name) { $propertiesJson.hostProcessorInfo.name } else { "-" }
                        'Database edition' = if ($item.databaseEdition) { $item.databaseEdition } else { " -" }
                        'Framework version' = if ($item.frameworkVersion) { $item.frameworkVersion } else { " -" }
                        'DB engine status' = if ($item.dbEngineStatus) { $item.dbEngineStatus } else { "-" }
                        'HADR configuration' = if ($item.dbhadrConfiguration) { $item.dbhadrConfiguration } else { "-" }
                        'IPv6/IPv4' = if ($item.ipAddressList) { $item.ipAddressList } else { "-" }
                    }
                    
                    $processedData += $processedItem
                }
                
                # Export to CSV with AllInventory naming format
                $timestamp = Get-Date -Format "yyyy-MM-ddTHH_mm_ss.fffZ"
                $exportPath = "AllInventory-$timestamp.csv"
                $fullExportPath = Join-Path (Get-Location) $exportPath
                
                try {
                    # Export using custom method to match exact target format
                    $targetHeaders = @('Id', 'parentId', 'Workload', 'Server', 'Category', 'Type', 'OS name', 'Dependencies', 'Application name(s)', 'Softwares(#)', 'Support status', 'Security risks', 'Discovery method', 'Hypervisor type', 'Host', 'Tags', 'DB instances(#)', 'Databases(#)', 'Webapps(#)', 'vCores(#)', 'Memory (MB)', 'Disks(#)', 'Allocated storage (GB)', 'OS Family', 'Support ends in (Days)', 'Power status', 'Connected appliance', 'First discovered at', 'Last updated at', 'Processor', 'Database edition', 'Framework version', 'DB engine status', 'HADR configuration', 'IPv6/IPv4')
                    
                    # Create CSV content manually to match exact target format
                    $csvContent = @()
                    $csvContent += $targetHeaders -join ','
                    
                    foreach ($record in $processedData) {
                        $rowValues = @()
                        foreach ($header in $targetHeaders) {
                            $value = $record.$header
                            if ($null -eq $value -or $value -eq "") {
                                $rowValues += '"-"'
                            } elseif ($value -eq "-" -or $value -eq " -") {
                                $rowValues += "`"$value`""
                            } else {
                                $rowValues += "`"$value`""
                            }
                        }
                        $csvContent += $rowValues -join ','
                    }
                    
                    # Write to file
                    $csvContent | Out-File -FilePath $fullExportPath -Encoding UTF8
                    
                    Write-Host "`nSuccessfully exported $($processedData.Count) records to CSV!" -ForegroundColor Green
                    Write-Host "File location: $fullExportPath" -ForegroundColor Cyan
                    Write-Host "File size: $([math]::Round((Get-Item $fullExportPath).Length / 1KB, 2)) KB" -ForegroundColor Cyan
                    Write-Host "Columns exported: $(($targetHeaders).Count)" -ForegroundColor Cyan
                    
                } catch {
                    Write-Host "Error exporting to CSV: $($_.Exception.Message)" -ForegroundColor Red
                }
                
            } else {
                Write-Host "No data returned from the query." -ForegroundColor Yellow
            }
        } else {
            Write-Host "No structured data found in response" -ForegroundColor Yellow
        }

    } catch {
        Write-Host "Error executing Azure Resource Graph query:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }

    # Fetch SAS URI for Application Data Import
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Fetching SAS URI for Application Data Import..." -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    try {
        $discoveryHubName = "$($environmentName)hub"
        $sasUriApiVersion = "2025-02-01-preview"
        $sasUriUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApplicationMigration/discoveryHubs/$discoveryHubName/fetchSasUri?api-version=$sasUriApiVersion"
        
        Write-Host "Discovery Hub: $discoveryHubName" -ForegroundColor Yellow
        Write-Host "API Endpoint: $sasUriUrl" -ForegroundColor Yellow
        
        $sasUriResponse = Invoke-RestMethod -Uri $sasUriUrl `
            -Method POST `
            -Headers $headers `
            -ContentType 'application/json'
        
        if ($sasUriResponse.importApplicationsSasUri) {
            Write-Host "`nSAS URI fetched successfully!" -ForegroundColor Green
            Write-Host "Import Applications SAS URI: $($sasUriResponse.importApplicationsSasUri)" -ForegroundColor Cyan
            
            # Upload the generated CSV to the SAS URI
            if (Test-Path $fullExportPath) {
                Write-Host "`nUploading CSV to SAS URI..." -ForegroundColor Yellow
                
                try {
                    $csvFileBytes = [System.IO.File]::ReadAllBytes($fullExportPath)
                    $uploadHeaders = @{
                        "x-ms-blob-type" = "BlockBlob"
                        "x-ms-version"   = "2020-04-08"
                    }
                    
                    Invoke-RestMethod -Uri $sasUriResponse.importApplicationsSasUri `
                        -Method PUT `
                        -Headers $uploadHeaders `
                        -Body $csvFileBytes `
                        -ContentType "text/csv"
                    
                    Write-Host "CSV uploaded successfully to SAS URI!" -ForegroundColor Green
                    Write-Host "Uploaded file: $fullExportPath" -ForegroundColor Cyan
                    Write-Host "File size: $([math]::Round((Get-Item $fullExportPath).Length / 1KB, 2)) KB" -ForegroundColor Cyan
                    
                    # Initiate Application Import
                    Write-Host "`nInitiating Application Import..." -ForegroundColor Yellow
                    
                    try {
                        $startImportUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApplicationMigration/discoveryHubs/$discoveryHubName/startImportApplications?api-version=$sasUriApiVersion"
                        
                        $importRequestBody = @{
                            "importApplicationsSasUri" = $sasUriResponse.importApplicationsSasUri
                        } | ConvertTo-Json -Depth 10
                        
                        Write-Host "Start Import API: $startImportUrl" -ForegroundColor Yellow
                        
                        $startImportResponse = Invoke-RestMethod -Uri $startImportUrl `
                            -Method POST `
                            -Headers $headers `
                            -ContentType 'application/json' `
                            -Body $importRequestBody
                        
                        Write-Host "Application import initiated successfully!" -ForegroundColor Green
                        
                        # Log the full response
                        Write-Host "`nImport Response Details:" -ForegroundColor Cyan
                        Write-Host ($startImportResponse | ConvertTo-Json -Depth 10) -ForegroundColor White
                        
                        if ($startImportResponse.jobArmId) {
                            Write-Host "`nImport Job ARM ID: $($startImportResponse.jobArmId)" -ForegroundColor Cyan
                        }
                        
                        if ($startImportResponse.operationStatus) {
                            Write-Host "Operation Status: $($startImportResponse.operationStatus)" -ForegroundColor Cyan
                        }
                        
                        if ($startImportResponse.status) {
                            Write-Host "Status: $($startImportResponse.status)" -ForegroundColor Cyan
                        }
                        
                        if ($startImportResponse.properties) {
                            Write-Host "`nProperties:" -ForegroundColor Cyan
                            Write-Host ($startImportResponse.properties | ConvertTo-Json -Depth 5) -ForegroundColor White
                        }
                        
                    } catch {
                        Write-Host "Error initiating application import:" -ForegroundColor Red
                        Write-Host $_.Exception.Message -ForegroundColor Red
                        if ($_.Exception.Response) {
                            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                            $reader.BaseStream.Position = 0
                            $responseBody = $reader.ReadToEnd()
                            Write-Host "Response Body: $responseBody" -ForegroundColor Red
                        }
                    }
                    
                } catch {
                    Write-Host "Error uploading CSV to SAS URI:" -ForegroundColor Red
                    Write-Host $_.Exception.Message -ForegroundColor Red
                }
            } else {
                Write-Host "CSV file not found at: $fullExportPath" -ForegroundColor Red
            }
            
        } else {
            Write-Host "SAS URI response received but no importApplicationsSasUri found in response" -ForegroundColor Yellow
            Write-Host "Response: $($sasUriResponse | ConvertTo-Json -Depth 5)" -ForegroundColor Yellow
        }
        
    } catch {
        Write-Host "Error fetching SAS URI for Application Data:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $reader.BaseStream.Position = 0
            $responseBody = $reader.ReadToEnd()
            Write-Host "Response Body: $responseBody" -ForegroundColor Red
        }
    }

    # Create Comprehensive Application Assessments using ARM Deployment
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Creating Application Assessments..." -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    try {
        $assessmentDeploymentName = "Microsoft.MigrateAssessment-AssessmentCreation-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $discoveryHubName = "$($environmentName)hub"
        
        # Define the Azure Resource Graph query for the default application
        $argQueryForDefaultApp = "migrateresources`n                | where type =~ `"microsoft.applicationmigration/discoveryhubs/applications`"`n                | where ['id'] has `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApplicationMigration/discoveryHubs/$discoveryHubName/`"`n                | where properties.applicationType has `"`"`n                | extend appId = tolower(id)`n                | where true`n                | join kind = leftouter (migrateresources`n                        | where type =~ `"microsoft.applicationmigration/discoveryhubs/applications/members`"`n                        | where ['id'] has `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApplicationMigration/discoveryHubs/$discoveryHubName/`"`n                        | extend appId = tolower(tostring(split(id,`"/members/`")[0]))`n                        | summarize memberCount = count(), memberResourceIds = make_set(properties.memberResourceId) by appId`n                        )`n                        on `$left.appId == `$right.appId`n                        | project armId = tolower(id), id = tolower(id), type, appId, memberCount, memberResourceIds, properties, name, systemData.CreatedAt | where id in~ (`"/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.applicationmigration/discoveryhubs/$discoveryHubName/applications/default`") | sort by id"
        
        # Create the deployment body
        $deploymentBody = @{
            "properties" = @{
                "mode" = "incremental"
                "parameters" = @{}
                "template" = @{
                    "`$schema" = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
                    "contentVersion" = "1.0.0.0"
                    "variables" = @{
                        "azureResourceGraphQuery" = $argQueryForDefaultApp
                    }
                    "resources" = @(
                        @{
                            "apiVersion" = "2025-09-09-preview"
                            "type" = "Microsoft.Migrate/assessmentprojects/assessments"
                            "name" = "$assessmentProjectName/defaultapplication-vm"
                            "properties" = @{
                                "settings" = @{
                                    "performanceData" = @{ "timeRange" = "Day"; "percentile" = "Percentile95" }
                                    "scalingFactor" = 1
                                    "azureSecurityOfferingType" = "MDC"
                                    "azureHybridUseBenefit" = "Yes"
                                    "linuxAzureHybridUseBenefit" = "Yes"
                                    "savingsSettings" = @{ "savingsOptions" = "RI3Year" }
                                    "billingSettings" = @{ "licensingProgram" = "Retail"; "subscriptionId" = $subscriptionId }
                                    "azureDiskTypes" = @("Premium", "StandardSSD", "Ultra", "PremiumV2")
                                    "azureLocation" = "SwedenCentral"
                                    "azureVmFamilies" = @("Av2_series", "Dadsv5_series", "Dasv4_series", "Dasv5_series", "Dav4_series", "Ddsv4_series", "Ddsv5_series", "Ddv4_series", "Ddv5_series", "Dpdsv6_series", "Dpldsv6_series", "Dplsv6_series", "Dpsv6_series", "Dsv4_series", "Dsv5_series", "Dv4_series", "Dv5_series", "Edsv5_series", "Edv5_series", "Esv5_series", "Ev5_series", "Edsv6_series", "Esv6_series", "Eadsv5_series", "Easv4_series", "Easv5_series", "Eav4_series", "Ebdsv5_series", "Ebsv5_series", "Edsv4_series", "Edv4_series", "Epdsv6_series", "Epsv6_series", "Esv4_series", "Ev4_series", "F_series", "Fs_series", "Fsv2_series", "Lasv3_series", "Lsv3_series", "M_series", "Mbdsv3_series", "Mbsv3_series", "Mdsv2_series", "Msv2_series", "Mdsv3_series", "Msv3_series", "Mv2_series")
                                    "environmentType" = "Production"
                                    "currency" = "USD"
                                    "discountPercentage" = 0
                                    "sizingCriterion" = "PerformanceBased"
                                    "azurePricingTier" = "Standard"
                                    "azureStorageRedundancy" = "LocallyRedundant"
                                    "vmUptime" = @{ "daysPerMonth" = 31; "hoursPerDay" = 24 }
                                    "azureVmSecurityOptions" = @("Standard", "TVM")
                                }
                                "details" = @{}
                                "scope" = @{ "azureResourceGraphQuery" = "[variables('azureResourceGraphQuery')]"; "scopeType" = "AzureResourceGraphQuery" }
                                "fallbackMachineAssessmentArmId" = ""
                            }
                            "dependsOn" = @()
                        },
                        @{
                            "apiVersion" = "2025-09-09-preview"
                            "type" = "Microsoft.Migrate/assessmentprojects/webAppAssessments"
                            "name" = "$assessmentProjectName/defaultapplication-webApp"
                            "properties" = @{
                                "settings" = @{
                                    "appSvcContainerSettings" = @{ "isolationRequired" = $false }
                                    "appSvcNativeSettings" = @{ "isolationRequired" = $false }
                                    "savingsSettings" = @{ "savingsOptions" = "RI3Year" }
                                    "billingSettings" = @{ "licensingProgram" = "Retail"; "subscriptionId" = $subscriptionId }
                                    "azureLocation" = "SwedenCentral"
                                    "azureSecurityOfferingType" = "MDC"
                                    "currency" = "USD"
                                    "discountPercentage" = 0
                                    "environmentType" = "Production"
                                    "performanceData" = @{ "timeRange" = "Day"; "percentile" = "Percentile95" }
                                    "sizingCriterion" = "PerformanceBased"
                                    "scalingFactor" = 1
                                }
                                "scope" = @{ "azureResourceGraphQuery" = "[variables('azureResourceGraphQuery')]"; "scopeType" = "AzureResourceGraphQuery" }
                                "fallbackMachineAssessmentArmId" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm"
                            }
                            "dependsOn" = @()
                        },
                        @{
                            "apiVersion" = "2025-09-09-preview"
                            "type" = "Microsoft.Migrate/assessmentprojects/aksAssessments"
                            "name" = "$assessmentProjectName/defaultapplication-aks"
                            "properties" = @{
                                "settings" = @{
                                    "environmentType" = "Production"
                                    "billingSettings" = @{ "licensingProgram" = "Retail" }
                                    "currency" = "USD"
                                    "savingsSettings" = @{ "savingsOptions" = "RI3Year" }
                                    "azureLocation" = "SwedenCentral"
                                    "pricingTier" = "Standard"
                                    "category" = "All"
                                    "consolidation" = "Full"
                                    "discountPercentage" = 0
                                    "sizingCriterion" = "PerformanceBased"
                                    "performanceData" = @{ "timeRange" = "Day"; "percentile" = "Percentile95" }
                                    "azureSecurityOfferingType" = "MDC"
                                }
                                "scope" = @{ "azureResourceGraphQuery" = "[variables('azureResourceGraphQuery')]"; "scopeType" = "AzureResourceGraphQuery" }
                                "fallbackMachineAssessmentArmId" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm"
                            }
                            "dependsOn" = @()
                        },
                        @{
                            "apiVersion" = "2025-09-09-preview"
                            "type" = "Microsoft.Migrate/assessmentprojects/sqlAssessments"
                            "name" = "$assessmentProjectName/defaultapplication-sql"
                            "properties" = @{
                                "settings" = @{
                                    "performanceData" = @{ "timeRange" = "Day"; "percentile" = "Percentile95" }
                                    "scalingFactor" = 1
                                    "azureSecurityOfferingType" = "MDC"
                                    "osLicense" = "Yes"
                                    "azureLocation" = "swedencentral"
                                    "preferredTargets" = @("SqlMI")
                                    "discountPercentage" = 0
                                    "currency" = "USD"
                                    "sizingCriterion" = "PerformanceBased"
                                    "savingsSettings" = @{ "savingsOptions" = "RI3Year" }
                                    "billingSettings" = @{ "subscriptionId" = $subscriptionId; "licensingProgram" = "Retail" }
                                    "sqlServerLicense" = "Yes"
                                    "azureSqlVmSettings" = @{ "instanceSeries" = @("Dadsv5_series", "Dasv4_series", "Ddsv4_series", "Ddsv5_series", "Edsv5_series", "Eadsv5_series", "Easv4_series", "Ebdsv5_series", "Ebsv5_series", "Edsv4_series", "M_series", "Mdsv2_series", "Mv2_series") }
                                    "entityUptime" = @{ "daysPerMonth" = 31; "hoursPerDay" = 24 }
                                    "azureSqlManagedInstanceSettings" = @{ "azureSqlInstanceType" = "SingleInstance"; "azureSqlServiceTier" = "SqlServiceTier_Automatic" }
                                    "azureSqlDatabaseSettings" = @{ "azureSqlComputeTier" = "Provisioned"; "azureSqlPurchaseModel" = "VCore"; "azureSqlServiceTier" = "SqlServiceTier_Automatic"; "azureSqlDataBaseType" = "SingleDatabase" }
                                    "environmentType" = "Production"
                                    "enableHadrAssessment" = $true
                                    "disasterRecoveryLocation" = "swedencentral"
                                    "multiSubnetIntent" = "DisasterRecovery"
                                    "isInternetAccessAvailable" = $true
                                    "asyncCommitModeIntent" = "DisasterRecovery"
                                }
                                "scope" = @{ "azureResourceGraphQuery" = "[variables('azureResourceGraphQuery')]"; "scopeType" = "AzureResourceGraphQuery" }
                                "fallbackMachineAssessmentArmId" = ""
                            }
                            "dependsOn" = @()
                        },
                        @{
                            "apiVersion" = "2025-09-09-preview"
                            "type" = "Microsoft.Migrate/assessmentprojects/pgSqlAssessments"
                            "name" = "$assessmentProjectName/defaultapplication-pgsql"
                            "properties" = @{
                                "settings" = @{
                                    "environmentType" = "Production"
                                    "billingSettings" = @{ "licensingProgram" = "Retail"; "subscriptionId" = $subscriptionId }
                                    "currency" = "USD"
                                    "savingsSettings" = @{ "savingsOptions" = "RI3Year" }
                                    "azureLocation" = "SwedenCentral"
                                    "serviceTier" = @("GeneralPurpose", "MemoryOptimized")
                                    "storageType" = @("SSDV1")
                                    "discountPercentage" = 0
                                    "sizingCriterion" = "AsOnPremises"
                                    "performanceData" = @{}
                                    "scalingFactor" = 1
                                }
                                "scope" = @{ "azureResourceGraphQuery" = "[variables('azureResourceGraphQuery')]"; "scopeType" = "AzureResourceGraphQuery" }
                                "fallbackMachineAssessmentArmId" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm"
                            }
                            "dependsOn" = @("/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm")
                        },
                        @{
                            "apiVersion" = "2025-09-09-preview"
                            "type" = "Microsoft.Migrate/assessmentprojects/avsAssessments"
                            "name" = "$assessmentProjectName/defaultapplication-avs"
                            "properties" = @{
                                "settings" = @{
                                    "performanceData" = @{ "percentile" = "Percentile95"; "timeRange" = "Day" }
                                    "scalingFactor" = 1
                                    "azureSecurityOfferingType" = "MDC"
                                    "failuresToTolerateAndRaidLevelList" = @("Ftt1Raid1", "Ftt2Raid6")
                                    "vcpuOversubscription" = 4
                                    "dedupeCompression" = 1.5
                                    "memOvercommit" = 1
                                    "isStretchClusterEnabled" = $false
                                    "isVcfByolEnabled" = $false
                                    "externalStorageTypes" = @("AnfPremium", "AnfStandard", "AnfUltra", "vsan")
                                    "avsAssessmentScenario" = "NewAvsSddc"
                                    "cpuHeadroom" = 0
                                    "azureElasticSanSettings" = @{ "networkIngressEgressCostPercentage" = 0 }
                                    "azureHybridUseBenefit" = "Yes"
                                    "linuxAzureHybridUseBenefit" = "Yes"
                                    "azureLocation" = "swedencentral"
                                    "currency" = "USD"
                                    "discountPercentage" = 0
                                    "sizingCriterion" = "PerformanceBased"
                                    "savingsSettings" = @{ "savingsOptions" = "RI3Year" }
                                    "environmentType" = "Production"
                                    "billingSettings" = @{ "licensingProgram" = "Retail"; "subscriptionId" = $subscriptionId }
                                    "nodeTypes" = @("AV36", "AV64", "AV48")
                                }
                                "scope" = @{ "azureResourceGraphQuery" = "[variables('azureResourceGraphQuery')]"; "scopeType" = "AzureResourceGraphQuery" }
                                "fallbackMachineAssessmentArmId" = ""
                            }
                            "dependsOn" = @()
                        },
                        @{
                            "apiVersion" = "2025-09-09-preview"
                            "type" = "Microsoft.Migrate/assessmentprojects/webAppCompoundAssessments"
                            "name" = "$assessmentProjectName/defaultapplication-webapp"
                            "properties" = @{
                                "targetAssessmentArmIds" = @{
                                    "azureAppService" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/webAppAssessments/defaultapplication-webApp"
                                    "azureAppServiceContainer" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/webAppAssessments/defaultapplication-webApp"
                                    "aks" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/aksAssessments/defaultapplication-aks"
                                }
                                "fallbackMachineAssessmentArmId" = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm"
                            }
                            "dependsOn" = @(
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/webAppAssessments/defaultapplication-webApp",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/aksAssessments/defaultapplication-aks",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm"
                            )
                        },
                        @{
                            "apiVersion" = "2025-09-09-preview"
                            "type" = "Microsoft.Migrate/assessmentprojects/applicationAssessments"
                            "name" = "$assessmentProjectName/defaultapplication"
                            "properties" = @{
                                "assessmentArmIds" = @(
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm",
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/sqlAssessments/defaultapplication-sql",
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/pgSqlAssessments/defaultapplication-pgsql",
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/avsAssessments/defaultapplication-avs",
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/webAppCompoundAssessments/defaultapplication-webapp"
                                )
                                "settings" = @{ "recommendRehostForCots" = $true }
                                "details" = @{ "status" = "Created" }
                                "scope" = @{ "azureResourceGraphQuery" = "[variables('azureResourceGraphQuery')]"; "scopeType" = "AzureResourceGraphQuery" }
                            }
                            "dependsOn" = @(
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/sqlAssessments/defaultapplication-sql",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/pgSqlAssessments/defaultapplication-pgsql",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/avsAssessments/defaultapplication-avs",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/webAppCompoundAssessments/defaultapplication-webapp"
                            )
                        },
                        @{
                            "apiVersion" = "2025-09-09-preview"
                            "type" = "Microsoft.Migrate/assessmentprojects/heterogeneousAssessments"
                            "name" = "$assessmentProjectName/defaultapplication"
                            "properties" = @{
                                "assessmentArmIds" = @(
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm",
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/sqlAssessments/defaultapplication-sql",
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/pgSqlAssessments/defaultapplication-pgsql",
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/avsAssessments/defaultapplication-avs",
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/webAppCompoundAssessments/defaultapplication-webapp",
                                    "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/applicationAssessments/defaultapplication"
                                )
                            }
                            "dependsOn" = @(
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/assessments/defaultapplication-vm",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/sqlAssessments/defaultapplication-sql",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/pgSqlAssessments/defaultapplication-pgsql",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/avsAssessments/defaultapplication-avs",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/webAppCompoundAssessments/defaultapplication-webapp",
                                "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/applicationAssessments/defaultapplication"
                            )
                        }
                    )
                }
            }
        } | ConvertTo-Json -Depth 30

        $deploymentUri = "https://management.azure.com/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/Microsoft.Resources/deployments/$assessmentDeploymentName`?api-version=2021-04-01"
        
        Write-Host "Deployment URI: $deploymentUri" -ForegroundColor Yellow
        Write-Host "Initiating ARM deployment..." -ForegroundColor Yellow

        $deploymentResponse = Invoke-RestMethod -Uri $deploymentUri `
            -Method PUT `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $deploymentBody

        Write-Host "`nComprehensive assessments deployment initiated successfully!" -ForegroundColor Green
        Write-Host "Deployment Name: $assessmentDeploymentName" -ForegroundColor Cyan
        Write-Host "Provisioning State: $($deploymentResponse.properties.provisioningState)" -ForegroundColor Cyan

    } catch {
        Write-Host "Error creating comprehensive assessments:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $reader.BaseStream.Position = 0
            $responseBody = $reader.ReadToEnd()
            Write-Host "Response Body: $responseBody" -ForegroundColor Red
        }
    }

    # Create Application-Scoped Business Case
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Creating Application-Scoped Business Case..." -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    try {
        $businessCaseNameApp = "default1applicationbuiz"
        $businessCaseApiVersion = "2025-09-09-preview"
        $discoveryHubName = "$($environmentName)hub"
        
        # Define the Azure Resource Graph query for the default application
        $argQueryForBizCase = "(migrateresources`n                | where type =~ `"microsoft.applicationmigration/discoveryhubs/applications`"`n                | where ['id'] has `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApplicationMigration/discoveryHubs/$discoveryHubName/`"`n                | where properties.applicationType has `"`"`n                | extend appId = tolower(id)`n                | where true`n                | join kind = leftouter (migrateresources`n                        | where type =~ `"microsoft.applicationmigration/discoveryhubs/applications/members`"`n                        | where ['id'] has `"/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApplicationMigration/discoveryHubs/$discoveryHubName/`"`n                        | extend appId = tolower(tostring(split(id,`"/members/`")[0]))`n                        | summarize memberCount = count(), memberResourceIds = make_set(properties.memberResourceId) by appId`n                        )`n                        on `$left.appId == `$right.appId`n                        | project armId = tolower(id), id = tolower(id), type, appId, memberCount, memberResourceIds, properties, name, systemData.CreatedAt | where id in~ (`"/subscriptions/$subscriptionId/resourcegroups/$resourceGroup/providers/microsoft.applicationmigration/discoveryhubs/$discoveryHubName/applications/default`") | sort by id)"
        
        $businessCaseUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Migrate/assessmentprojects/$assessmentProjectName/businessCases/$businessCaseNameApp`?api-version=$businessCaseApiVersion"
        
        $businessCaseBody = @{
            "name" = $businessCaseNameApp
            "properties" = @{
                "settings" = @{
                    "commonSettings" = @{
                        "targetLocation" = "koreasouth"
                        "infrastructureGrowthRate" = 5
                        "discountPercentage" = 0
                        "currency" = "USD"
                        "businessCaseType" = "OptimizeForPaas"
                    }
                    "azureSettings" = @{
                        "savingsOption" = "RI3Year"
                    }
                }
                "businessCaseScope" = @{
                    "scopeType" = "AzureResourceGraphQuery"
                    "azureResourceGraphQuery" = $argQueryForBizCase
                }
            }
        } | ConvertTo-Json -Depth 10
        
        Write-Host "Business Case Name: $businessCaseNameApp" -ForegroundColor Yellow
        Write-Host "Business Case URI: $businessCaseUri" -ForegroundColor Yellow
        Write-Host "Target Location: koreasouth" -ForegroundColor Yellow
        Write-Host "Business Case Type: OptimizeForPaas" -ForegroundColor Yellow
        Write-Host "`nInitiating business case creation..." -ForegroundColor Yellow

        $businessCaseResponse = Invoke-RestMethod -Uri $businessCaseUri `
            -Method PUT `
            -Headers $headers `
            -ContentType 'application/json' `
            -Body $businessCaseBody

        Write-Host "`nApplication-scoped business case created successfully!" -ForegroundColor Green
        Write-Host "Business Case Name: $businessCaseNameApp" -ForegroundColor Cyan
        Write-Host "Business Case Type: OptimizeForPaas" -ForegroundColor Cyan
        Write-Host "Target Location: koreasouth" -ForegroundColor Cyan
        Write-Host "Savings Option: RI3Year" -ForegroundColor Cyan
        Write-Host "Infrastructure Growth Rate: 5%" -ForegroundColor Cyan
        
        if ($businessCaseResponse.id) {
            Write-Host "Business Case ARM ID: $($businessCaseResponse.id)" -ForegroundColor Cyan
        }

    } catch {
        Write-Host "Error creating application-scoped business case:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $reader.BaseStream.Position = 0
            $responseBody = $reader.ReadToEnd()
            Write-Host "Response Body: $responseBody" -ForegroundColor Red
        }
    }
    
    # Script execution completed
    Write-Host "`nScript execution completed" -ForegroundColor Green


