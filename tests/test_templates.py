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
            for name, source in (
                ("main", "main.bicep"),
                ("existing", "existing-agent.bicep"),
                ("activity", "modules/activity-log.bicep"),
            ):
                output = Path(directory) / (name + ".json")
                result = subprocess.run(
                    [az, "bicep", "build", "--file", str(ROOT / source), "--outfile", str(output)],
                    capture_output=True, text=True, encoding="utf-8",
                )
                if result.returncode:
                    raise AssertionError(result.stdout + result.stderr)
                cls.templates[name] = json.loads(output.read_text(encoding="utf-8"))
        cls.main = cls.templates["main"]
        cls.existing = cls.templates["existing"]
        cls.lab = cls.main["resources"]["lab"]["properties"]["template"]

    def module(self, name):
        return self.lab["resources"][name]["properties"]["template"]

    def test_deploy_to_azure_template_is_current(self):
        for source, filename, template in (
            ("main.bicep", "azuredeploy.json", self.main),
            ("existing-agent.bicep", "azuredeploy-existing-agent.json", self.existing),
        ):
            with self.subTest(filename=filename):
                committed = json.loads((ROOT / filename).read_text(encoding="utf-8"))
                self.assertEqual(
                    committed, template,
                    f"{filename} is stale; run: az bicep build --file {source} --outfile {filename}",
                )

    def test_existing_agent_deploys_only_the_shared_lab(self):
        self.assertEqual(set(self.existing["resources"]), {"lab"})
        self.assertEqual(
            self.existing["resources"]["lab"]["properties"]["template"], self.lab,
        )
        self.assertEqual(
            self.existing["resources"]["lab"]["properties"]["parameters"],
            self.main["resources"]["lab"]["properties"]["parameters"],
        )
        self.assertEqual(set(self.main["resources"]), {
            "lab", "sreAgent", "sreAgentAdminRole", "deployerContributorRole",
        })
        agent = self.main["resources"]["sreAgent"]["properties"]["template"]
        self.assertIn("Microsoft.App/agents", {r["type"] for r in agent["resources"]})
        self.assertIn("logAnalyticsWorkspaceId",
                      self.main["resources"]["sreAgent"]["properties"]["parameters"])

        def resources(template):
            values = template["resources"]
            for resource in values.values() if isinstance(values, dict) else values:
                yield resource
                child = resource.get("properties", {}).get("template")
                if child:
                    yield from resources(child)

        for resource in resources(self.existing):
            self.assertNotIn(resource["type"].lower(), {
                "microsoft.app/agents", "microsoft.insights/components",
                "microsoft.alertsmanagement/smartdetectoralertrules",
            })
            if resource["type"].lower() == "microsoft.authorization/roleassignments":
                self.assertIn("Microsoft.Compute/virtualMachines", resource["scope"])
                self.assertEqual(resource["properties"]["principalType"], "ServicePrincipal")
        self.assertEqual(self.existing["parameters"]["adminPassword"]["type"].lower(), "securestring")
        self.assertNotIn("defaultValue", self.existing["parameters"]["adminPassword"])
        self.assertNotIn("defaultValue", self.existing["parameters"]["existingSreAgentResourceId"])
        for name, definition in self.existing["parameters"].items():
            if name != "existingSreAgentResourceId":
                # Region guidance differs because no Agent is deployed in this path.
                self.assertEqual(
                    {k: v for k, v in definition.items() if k != "metadata"},
                    {k: v for k, v in self.main["parameters"][name].items() if k != "metadata"},
                )
        self.assertFalse(any(name.startswith("sreAgent") or name == "deployerPrincipalId"
                             for name in self.existing["parameters"]))

    def test_existing_agent_preserves_operational_outputs(self):
        self.assertEqual(set(self.existing["outputs"]), set(self.main["outputs"]))
        for name, definition in self.main["outputs"].items():
            if name not in {"sreAgentName", "sreAgentPortalUrl"}:
                self.assertEqual(self.existing["outputs"][name], definition)
        self.assertEqual(
            self.existing["outputs"]["sreAgentName"]["value"],
            "[last(split(parameters('existingSreAgentResourceId'), '/'))]",
        )
        self.assertIn("replace(parameters('existingSreAgentResourceId'), '/', '%2F')",
                      self.existing["outputs"]["sreAgentPortalUrl"]["value"])

    def test_reference_button_is_separate_from_main_instructions(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        main_steps = readme.split("## 設定手順\n", 1)[1].split("## 監視とコストの注意", 1)[0]
        self.assertNotIn("azuredeploy-existing-agent.json", main_steps)
        reference = readme.split("## 参考資料\n", 1)[1]
        self.assertIn(
            "[![Deploy to Azure](https://aka.ms/deploytoazurebutton)]"
            "(https://portal.azure.com/#create/Microsoft.Template/uri/"
            "https%3A%2F%2Fraw.githubusercontent.com%2Fyuriwoof%2Fsreagentlab%2Fmain%2F"
            "azuredeploy-existing-agent.json)",
            reference,
        )

    def test_password_and_defaults(self):
        p = self.main["parameters"]
        self.assertEqual(p["adminPassword"]["type"].lower(), "securestring")
        self.assertNotIn("defaultValue", p["adminPassword"])
        self.assertEqual((p["adminPassword"]["minLength"], p["adminPassword"]["maxLength"]), (12, 123))
        self.assertNotIn("sshPublicKey", p)
        self.assertEqual(p["vmCount"]["defaultValue"], 2)
        self.assertEqual(p["vmSize"]["defaultValue"], "Standard_B2ms")
        self.assertEqual(self.module("vm")["parameters"]["vmSize"]["defaultValue"], "Standard_B2ms")
        self.assertEqual(p["location"]["defaultValue"], "japaneast")
        self.assertIn("newGuid()", p["lawName"]["defaultValue"])
        self.assertEqual(
            self.lab["resources"]["monitoring"]["properties"]["parameters"]["lawName"]["value"],
            "[parameters('lawName')]",
        )
        self.assertEqual(p["tags"]["defaultValue"], {"project": "sreagentlab", "env": "demo"})
        parameters = json.loads((ROOT / "main.parameters.json").read_text(encoding="utf-8"))
        self.assertEqual(parameters["parameters"]["adminPassword"]["value"], "")
        self.assertEqual(parameters["parameters"]["vmSize"]["value"], "Standard_B2ms")

    def test_no_automatic_vm_shutdown(self):
        for template in (self.main, self.module("vm")):
            self.assertFalse(any("shutdown" in name.lower() for name in template["parameters"]))
            self.assertFalse(any(
                resource["type"].lower() == "microsoft.devtestlab/schedules"
                for resource in template["resources"].values()
            ))
        parameters = json.loads((ROOT / "main.parameters.json").read_text(encoding="utf-8"))
        self.assertFalse(any("shutdown" in name.lower() for name in parameters["parameters"]))

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
        self.assertEqual(set(chaos["outputs"]["experimentNames"]["value"]), {"cpu", "memory", "iis", "diskio"})

    def test_chaos_rbac_is_vm_scoped(self):
        self.assertNotIn("nsgExperiment", self.module("chaos")["resources"])
        self.assertNotIn("nsgExperimentRole", self.main["resources"])
        for name in ("experimentReaderRoles", "chaosAgentReaderRoles"):
            self.assertIn("Microsoft.Compute/virtualMachines", self.lab["resources"][name]["scope"])

    def test_windows_collection_and_metric_thresholds(self):
        monitoring = self.module("monitoring")
        resources = monitoring["resources"]
        self.assertEqual(resources["law"]["apiVersion"], "2023-09-01")
        self.assertEqual(resources["eventTable"]["apiVersion"], "2022-10-01")
        self.assertEqual(resources["perfTable"]["apiVersion"], "2022-10-01")
        self.assertEqual(resources["amaExtensions"]["properties"]["type"], "AzureMonitorWindowsAgent")
        sources = resources["dcr"]["properties"]["dataSources"]
        self.assertNotIn("syslog", sources)
        self.assertIn("7036", sources["windowsEventLogs"][0]["xPathQueries"][0])
        metrics = {m["metricName"]: m for m in monitoring["variables"]["vmMetricDefinitions"]}
        self.assertEqual(metrics["Percentage CPU"]["threshold"], 60)
        memory = resources["memoryAlert"]["properties"]["criteria"]["allOf"][0]
        self.assertEqual((memory["operator"], memory["threshold"]), ("LessThan", 3 * 1024 ** 3))
        for name in ("memoryAlert", "iisStopAlert"):
            self.assertTrue(resources[name]["properties"]["skipQueryValidation"])
            self.assertEqual(resources[name]["properties"]["scopes"], ["[resourceId('Microsoft.OperationalInsights/workspaces', parameters('lawName'))]"])
        self.assertEqual(metrics["OS Disk IOPS Consumed Percentage"]["threshold"], 90)
        self.assertEqual(metrics["OS Disk Queue Depth"]["threshold"], 10)
        self.assertEqual(resources["vmAlerts"]["properties"]["windowSize"], "PT5M")
        for metric in monitoring["variables"]["appGwMetricDefinitions"][1:]:
            self.assertEqual(metric["dimensions"], [{"name": "HttpStatusGroup", "operator": "Include", "values": ["5xx"]}])
        app_gw_metrics = {m["suffix"]: m for m in monitoring["variables"]["appGwMetricDefinitions"]}
        self.assertEqual(
            (app_gw_metrics["frontend-5xx"]["operator"], app_gw_metrics["frontend-5xx"]["threshold"]),
            ("GreaterThan", 2),
        )
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
        self.assertEqual(dcr["performanceCounters"][0]["samplingFrequencyInSeconds"], 10)
        counters = dcr["performanceCounters"][0]["counterSpecifiers"]
        for counter in ("\\Memory\\Available Bytes", "\\Network Interface(*)\\Bytes Received/sec",
                        "\\Network Interface(*)\\Bytes Sent/sec"):
            self.assertIn(counter, counters)
        self.assertNotIn("activityLog", self.main["resources"])
        self.assertIn("subscriptionDeploymentTemplate", self.templates["activity"]["$schema"])
        self.assertTrue({"sreAgentPortalUrl", "sreAgentName", "appGwPublicIp", "experimentNames"} <= self.main["outputs"].keys())


if __name__ == "__main__":
    unittest.main()
