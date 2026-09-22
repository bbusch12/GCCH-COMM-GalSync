/*
  Optional: Azure Firewall Premium egress policy for the GalSync workload.

  Use this when the sync runs on a Hybrid Runbook Worker (or Function App with
  VNet integration) inside a spoke, with forced tunnelling through a hub
  firewall - which is the normal pattern in a GCC High-aligned landing zone.

  Two deliberate choices:
    * TLS inspection is BYPASSED for the two identity endpoints. Both Graph
      SDK and Exchange Online PowerShell perform certificate-bound client
      authentication; a man-in-the-middle proxy breaks the token exchange.
    * Everything else is allow-listed by FQDN, so the egress surface of a
      cross-boundary connector is enumerable for the SSP.

  Scope: resource group containing the Azure Firewall Policy.
*/

targetScope = 'resourceGroup'

@description('Name of the existing Azure Firewall Policy to attach the rule collection group to.')
param firewallPolicyName string

@description('Priority of the rule collection group within the policy.')
@minValue(100)
@maxValue(65000)
param ruleCollectionGroupPriority int = 1200

@description('Source address space of the subnet hosting the sync compute.')
param syncSourceAddresses array

@description('Set false when the runbook imports its modules from the PowerShell Gallery at build time only.')
param allowPowerShellGallery bool = false

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' existing = {
  name: firewallPolicyName
}

// Firewall allow-lists are literal by nature; the environment() function returns
// only the deploying cloud's endpoints and cannot express the partner cloud.
// The no-hardcoded-env-urls linter rule is disabled for this file in bicepconfig.json.
var commercialM365Fqdns = [
  'login.microsoftonline.com'
  'login.windows.net'
  'graph.microsoft.com'
  'outlook.office365.com'
  'outlook.office.com'
  'autodiscover-s.outlook.com'
]

var gcchM365Fqdns = [
  'login.microsoftonline.us'
  'graph.microsoft.us'
  'outlook.office365.us'
  'autodiscover-s.office365.us'
]

var azureGovPlatformFqdns = [
  'management.usgovcloudapi.net'
  '*.vault.usgovcloudapi.net'
  '*.blob.core.usgovcloudapi.net'
  '*.azure-automation.us'
  '*.ods.opinsights.azure.us'
  '*.oms.opinsights.azure.us'
  '*.agentsvc.azure.us'
]

var galleryFqdns = [
  'www.powershellgallery.com'
  'psg-prod-eastus.azureedge.net'
  'devopsgallerystorage.blob.core.windows.net'
]

resource ruleGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: firewallPolicy
  name: 'rcg-galsync-egress'
  properties: {
    priority: ruleCollectionGroupPriority
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'rc-galsync-allow'
        priority: 200
        action: { type: 'Allow' }
        rules: concat(
          [
            {
              ruleType: 'ApplicationRule'
              name: 'gcch-m365'
              description: 'Identity, Graph and Exchange Online endpoints in the US Government cloud.'
              sourceAddresses: syncSourceAddresses
              targetFqdns: gcchM365Fqdns
              protocols: [ { protocolType: 'Https', port: 443 } ]
              terminateTLS: false
            }
            {
              ruleType: 'ApplicationRule'
              name: 'commercial-m365'
              description: 'Identity, Graph and Exchange Online endpoints in the worldwide cloud. This is the cross-boundary flow: outbound only, allow-listed by FQDN.'
              sourceAddresses: syncSourceAddresses
              targetFqdns: commercialM365Fqdns
              protocols: [ { protocolType: 'Https', port: 443 } ]
              terminateTLS: false
            }
            {
              ruleType: 'ApplicationRule'
              name: 'azure-government-platform'
              description: 'Key Vault, storage, Automation and Log Analytics in Azure Government.'
              sourceAddresses: syncSourceAddresses
              targetFqdns: azureGovPlatformFqdns
              protocols: [ { protocolType: 'Https', port: 443 } ]
              terminateTLS: false
            }
          ],
          allowPowerShellGallery ? [
            {
              ruleType: 'ApplicationRule'
              name: 'powershell-gallery'
              description: 'Module acquisition. Enable only during build or module refresh windows.'
              sourceAddresses: syncSourceAddresses
              targetFqdns: galleryFqdns
              protocols: [ { protocolType: 'Https', port: 443 } ]
              terminateTLS: false
            }
          ] : []
        )
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'rc-galsync-deny-residual'
        priority: 300
        action: { type: 'Deny' }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'deny-all-other-web'
            description: 'Explicit residual deny so that a mis-scoped rule elsewhere in the policy cannot widen this workload egress.'
            sourceAddresses: syncSourceAddresses
            targetFqdns: [ '*' ]
            protocols: [
              { protocolType: 'Https', port: 443 }
              { protocolType: 'Http', port: 80 }
            ]
          }
        ]
      }
    ]
  }
}

output ruleCollectionGroupId string = ruleGroup.id
