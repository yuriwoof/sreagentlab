"""Build and verify generated ARM contracts without accessing an Azure account."""
import base64
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TemplateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        az = shutil.which("az")
        if not az:
            raise RuntimeError("Azure CLI with Bicep is required for template tests")
        cls.templates = {}
        with tempfile.TemporaryDirectory(prefix="sreagentlab-build-") as directory:
            for name, source in (("main", "main.bicep"), ("activity", "modules/activity-log.bicep")):
                output = Path(directory) / (name + ".json")
                result = subprocess.run(
                    [az, "bicep", "build", "--file", str(ROOT / source), "--outfile", str(output)],
                    capture_output=True, text=True, encoding="utf-8",
                )
                if result.returncode:
                    raise AssertionError(result.stdout + result.stderr)
                cls.templates[name] = json.loads(output.read_text(encoding="utf-8"))
        cls.main = cls.templates["main"]

    def module(self, name):
        return self.main["resources"][name]["properties"]["template"]

    def test_deploy_to_azure_template_is_current(self):
        committed = json.loads((ROOT / "azuredeploy.json").read_text(encoding="utf-8"))
        self.assertEqual(
            committed,
            self.main,
            "azuredeploy.json is stale; run: az bicep build --file main.bicep --outfile azuredeploy.json",
        )

    def test_password_and_defaults(self):
        p = self.main["parameters"]
        self.assertEqual(p["adminPassword"]["type"].lower(), "securestring")
        self.assertNotIn("defaultValue", p["adminPassword"])
        self.assertEqual((p["adminPassword"]["minLength"], p["adminPassword"]["maxLength"]), (12, 123))
        self.assertNotIn("sshPublicKey", p)
        self.assertEqual(p["vmCount"]["defaultValue"], 2)
        self.assertEqual(p["location"]["defaultValue"], "eastus2")
        self.assertEqual(p["tags"]["defaultValue"], {"project": "sreagentlab", "env": "demo"})
        parameters = json.loads((ROOT / "main.parameters.json").read_text(encoding="utf-8"))
        self.assertEqual(parameters["parameters"]["adminPassword"]["value"], "")

    def test_windows_vm_storage_and_identity(self):
        vm = self.module("vm")["resources"]["vms"]
        self.assertIn("vmCount", vm["copy"]["count"])
        os = vm["properties"]["osProfile"]
        self.assertEqual(os["windowsConfiguration"], {
            "provisionVMAgent": True, "enableAutomaticUpdates": False,
        })
        self.assertNotIn("linuxConfiguration", os)
        self.assertEqual(vm["properties"]["storageProfile"]["imageReference"], {
            "publisher": "MicrosoftWindowsServer", "offer": "WindowsServer",
            "sku": "2022-datacenter-azure-edition", "version": "latest",
        })
        disk = vm["properties"]["storageProfile"]["osDisk"]
        self.assertEqual((disk["diskSizeGB"], disk["caching"]), (127, "None"))
        self.assertEqual(disk["managedDisk"]["storageAccountType"], "Standard_LRS")
        self.assertEqual(vm["identity"]["type"], "SystemAssigned, UserAssigned")
        tag_resource = self.module("vm")["resources"]["osDiskTags"]
        self.assertIn("Microsoft.Compute/disks", tag_resource["scope"])
        self.assertEqual(tag_resource["properties"]["tags"], "[parameters('tags')]")

    def test_rdp_is_opt_in_and_egress_explicit(self):
        vm = self.module("vm")
        self.assertFalse(vm["parameters"]["enableRdpPublicIp"]["defaultValue"])
        self.assertEqual(vm["resources"]["rdpPublicIps"]["condition"], "[parameters('enableRdpPublicIp')]")
        network = self.module("network")["resources"]
        vnet = next(r for r in network if r["type"] == "Microsoft.Network/virtualNetworks")
        subnets = vnet["properties"]["subnets"]
        self.assertFalse(subnets[0]["properties"]["defaultOutboundAccess"])
        self.assertIn("natGateway", subnets[0]["properties"])
        self.assertEqual(subnets[1]["properties"]["addressPrefix"], "[variables('appGwSubnetAddressPrefix')]")
        self.assertTrue(any(r["type"] == "Microsoft.Network/natGateways" for r in network))

    def test_gateway_probe_and_affinity(self):
        p = self.module("appGw")["resources"]["appGw"]["properties"]
        self.assertEqual(p["sku"], {"name": "Standard_v2", "tier": "Standard_v2", "capacity": 1})
        probe = p["probes"][0]["properties"]
        self.assertEqual(
            [probe[k] for k in ("path", "interval", "timeout", "unhealthyThreshold")],
            ["/health.htm", 15, 10, 2],
        )
        self.assertEqual(probe["match"]["statusCodes"], ["200"])
        self.assertEqual(p["backendHttpSettingsCollection"][0]["properties"]["cookieBasedAffinity"], "Disabled")

    def test_iis_payload_is_local_and_roundtrips(self):
        variables = self.module("vm")["variables"]
        source = (ROOT / "scripts" / "setup-iis.ps1").read_text(encoding="utf-8")
        # loadTextContent is embedded as a literal; base64 is evaluated by ARM.
        embedded = next(v for v in variables.values()
                        if isinstance(v, str) and "Install-WindowsFeature" in v)
        self.assertEqual(source.replace("\r\n", "\n"), embedded.replace("\r\n", "\n"))
        self.assertLess(len(base64.b64encode(source.encode("utf-8"))) + 250, 8191)
        for required in ("health.htm", "Cache-Control", "no-store", "W3SVC", "C:\\ChaosTemp"):
            self.assertIn(required, source)

    def test_fault_parameters_and_targeting(self):
        chaos = self.module("chaos")
        definitions = chaos["variables"]["definitions"]
        self.assertEqual([x["key"] for x in definitions], ["cpu", "memory", "iis", "diskio"])
        self.assertEqual([x["firstVmOnly"] for x in definitions], [False, False, True, True])
        self.assertEqual(definitions[2]["parameters"], [{"key": "serviceName", "value": "W3SVC"}])
        disk = definitions[3]
        self.assertEqual(disk["urn"], "urn:csci:microsoft:agent:diskIOPressure/1.1")
        self.assertEqual(disk["duration"], "PT10M")
        self.assertEqual({p["key"]: p["value"] for p in disk["parameters"]},
                         {"pressureMode": "PremiumStorageP10IOPS", "targetTempDirectory": "C:\\ChaosTemp"})
        self.assertEqual(chaos["resources"]["agents"]["properties"]["type"], "ChaosWindowsAgent")
        selector = chaos["resources"]["experiments"]["properties"]["selectors"][0]
        self.assertNotIn("copy", selector)
        selector_targets = selector["targets"]
        self.assertIn("variables('vmTargetSelectors')", selector_targets)
        self.assertNotIn("extensionResourceId", selector_targets)
        self.assertEqual(set(chaos["outputs"]["experimentNames"]["value"]), {"cpu", "memory", "iis", "diskio", "nsg"})

    def test_nsg_fault_and_scoped_rbac(self):
        experiment = self.module("chaos")["resources"]["nsgExperiment"]
        action = experiment["properties"]["steps"][0]["branches"][0]["actions"][0]
        self.assertEqual(action["name"], "urn:csci:microsoft:networkSecurityGroup:securityRule/1.0")
        self.assertEqual(action["duration"], "PT10M")
        parameters = {p["key"]: p["value"] for p in action["parameters"]}
        self.assertEqual(parameters["priority"], "100")
        self.assertEqual(parameters["action"], "Deny")
        # ARM escapes a literal initial '[' as '[['.
        self.assertEqual(json.loads(parameters["destinationPortRanges"][1:]), ["80"])
        for name in ("experimentReaderRoles", "chaosAgentReaderRoles"):
            self.assertIn("Microsoft.Compute/virtualMachines", self.main["resources"][name]["scope"])
        role = self.main["resources"]["nsgExperimentRole"]
        self.assertIn("Microsoft.Network/networkSecurityGroups", role["scope"])
        self.assertIn("4d97b98b-1d4f-4787-a291-c67834d212e7", role["properties"]["roleDefinitionId"])

    def test_windows_collection_and_metric_thresholds(self):
        monitoring = self.module("monitoring")
        resources = monitoring["resources"]
        self.assertEqual(resources["amaExtensions"]["properties"]["type"], "AzureMonitorWindowsAgent")
        sources = resources["dcr"]["properties"]["dataSources"]
        self.assertNotIn("syslog", sources)
        self.assertIn("7036", sources["windowsEventLogs"][0]["xPathQueries"][0])
        metrics = {m["metricName"]: m for m in monitoring["variables"]["vmMetricDefinitions"]}
        self.assertEqual(metrics["Percentage CPU"]["threshold"], 60)
        memory = resources["memoryAlert"]["properties"]["criteria"]["allOf"][0]
        self.assertEqual((memory["operator"], memory["threshold"]), ("LessThan", 3 * 1024 ** 3))
        self.assertEqual(metrics["OS Disk IOPS Consumed Percentage"]["threshold"], 90)
        self.assertEqual(metrics["OS Disk Queue Depth"]["threshold"], 10)
        self.assertEqual(resources["vmAlerts"]["properties"]["windowSize"], "PT5M")
        for metric in monitoring["variables"]["appGwMetricDefinitions"][1:]:
            self.assertEqual(metric["dimensions"], [{"name": "HttpStatusGroup", "operator": "Include", "values": ["5xx"]}])
        severities = {m["suffix"]: m["severity"] for m in monitoring["variables"]["appGwMetricDefinitions"]}
        self.assertEqual(severities, {"unhealthy-host": 1, "frontend-5xx": 3, "backend-5xx": 1})
        diagnostic = resources["appGwDiagnostics"]["properties"]
        self.assertNotIn("logs", diagnostic)
        self.assertEqual(diagnostic["metrics"], [{"category": "AllMetrics", "enabled": True}])

    def test_live_report_sources_and_subscription_boundary(self):
        # Live reports are an SRE Agent portal feature; no workbook is deployed.
        self.assertNotIn("dashboard", self.main["resources"])
        self.assertNotIn("workbookId", self.main["outputs"])
        dcr = self.module("monitoring")["resources"]["dcr"]["properties"]["dataSources"]
        counters = dcr["performanceCounters"][0]["counterSpecifiers"]
        for counter in ("\\Memory\\Available Bytes", "\\Network Interface(*)\\Bytes Received/sec",
                        "\\Network Interface(*)\\Bytes Sent/sec"):
            self.assertIn(counter, counters)
        self.assertNotIn("activityLog", self.main["resources"])
        self.assertIn("subscriptionDeploymentTemplate", self.templates["activity"]["$schema"])
        self.assertTrue({"sreAgentPortalUrl", "sreAgentName", "appGwPublicIp", "experimentNames"} <= self.main["outputs"].keys())


if __name__ == "__main__":
    unittest.main()
