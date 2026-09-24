"""Offline Bash contract tests: python -m unittest discover -s tests -v.

Uses Python stdlib and Bash (Git Bash on Windows); no Azure access, jq or installs.
All test files live under this repository and are removed after each test.
"""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
if os.name == "nt":
    BASH = str(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git" / "bin" / "bash.exe")
SUB = "11111111-1111-1111-1111-111111111111"
RG = "rg-sreagentlab"
SCOPE = f"/subscriptions/{SUB}/resourceGroups/{RG}"
LAW = f"{SCOPE}/providers/Microsoft.OperationalInsights/workspaces/actual-law"
DIAG = f"sreagentlab-activity-{RG}"
PASSWORD = "Example-Only-Password42!"


def bash_path(path):
    value = str(path).replace("\\", "/")
    if os.name == "nt" and len(value) > 1 and value[1] == ":":
        value = "/" + value[0].lower() + value[2:]
    return value


def deployment(name="actual-main", timestamp="2026-01-01T00:00:00Z"):
    outputs = {
        "experimentNames": {key: "actual-" + key for key in ("cpu", "memory", "iis", "diskio", "nsg")},
        "sreAgentPortalUrl": "https://portal.azure.com/#actual-agent",
        "appGwName": "actual-gateway",
        "appGwPublicIp": "192.0.2.10",
        "probeName": "actual-probe",
        "nsgName": "actual-nsg",
        "appGwSubnetPrefix": "10.0.1.0/24",
        "vmSubnetPrefix": "10.0.0.0/24",
        "vmNames": ["actual-vm-01", "actual-vm-02"],
        "lawId": LAW,
    }
    return {
        "name": name,
        "id": SCOPE + "/providers/Microsoft.Resources/deployments/" + name,
        "properties": {
            "provisioningState": "Succeeded",
            "timestamp": timestamp,
            "outputs": {key: {"value": value} for key, value in outputs.items()},
        },
    }


def manual_rule(**changes):
    rule = dict(name="ManualDenyAppGatewayHTTP", priority=100, access="Deny",
                direction="Inbound", protocol="Tcp", sourceAddressPrefix="10.0.1.0/24",
                destinationAddressPrefix="10.0.0.0/24", sourcePortRange="*",
                destinationPortRange="80")
    rule.update(changes)
    return rule


def diagnostic(name=DIAG, workspace=LAW):
    return {"name": name, "properties": {"workspaceId": workspace,
            "logs": [{"category": "Administrative", "enabled": True}]}}


FAKE_AZ = r'''
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
config=json.loads(Path(os.environ["FAKE_CONFIG"]).read_text())
def native(value):
    if os.name=="nt" and len(value)>3 and value[0]=="/" and value[2]=="/":
        return value[1]+":"+value[2:]
    return value
def arg(flag): return args[args.index(flag)+1]
record={"args":args}
record["password_env_present"]=bool(os.environ.get("PASSWORD") or os.environ.get("CONFIRM_PASSWORD"))
secret=None
if args[:3]==["deployment","group","create"]:
    path=Path(native(arg("--parameters")[1:]))
    params=json.loads(path.read_text())["parameters"]
    secret=params["adminPassword"]["value"]
    record["secure_file"]=str(path)
    record["secret_present"]=bool(secret)
    record["mode"]=path.stat().st_mode & 0o777
    record["tags"]=params["tags"]["value"]
    record["location"]=params["location"]["value"]
with open(os.environ["FAKE_LOG"],"a",encoding="utf-8") as f:
    f.write(json.dumps(record)+"\n")
if args[:len(config.get("fail",["never"]))]==config.get("fail",["never"]):
    if secret: print("simulated secret-bearing Azure error: "+secret,file=sys.stderr)
    else: print("simulated query/operation failure",file=sys.stderr)
    sys.exit(1)
if args[:2]==["account","show"]:
    result={"id":config["subscription"]}
elif args[:2]==["account","set"]:
    result={}
elif args[:3]==["deployment","group","list"]:
    result=config["deployments"]
elif args[:3]==["deployment","group","show"]:
    result=config.get("shown",config["deployments"][0])
elif args[:4]==["network","nsg","rule","list"]:
    result=config["rules"]
elif args[:4]==["network","application-gateway","probe","show"]:
    result={"path":config["probe"]}
elif args[:3]==["vm","run-command","invoke"]:
    result=config["iis"]
elif args[:1]==["rest"]:
    url=arg("--url")
    if "diagnosticSettings" in url and arg("--method")=="get":
        result={"value":config["diagnostics"]}
    elif "/executions?" in url:
        if "page=2" in url: result={"value":[{"id":"second-page"}]}
        elif config.get("paginate"):
            result={"value":[{"id":"first-page"}],"nextLink":url+"&page=2"}
        else: result={"value":[]}
    else: result={}
else:
    allowed=(["bicep","build"],["provider","register"],["group","create"],["group","delete"],
             ["deployment","group","create"],["deployment","sub","create"],
             ["network","nsg","rule","create"],["network","nsg","rule","delete"],
             ["network","application-gateway","probe","update"])
    if not any(args[:len(prefix)]==prefix for prefix in allowed):
        sys.exit("Unexpected fake Azure command: "+repr(args))
    result={}
print(json.dumps(result))
'''


@unittest.skipUnless(BASH and Path(BASH).exists(), "Bash required (Git Bash on Windows)")
class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.work = ROOT / "tests" / (".script-test-" + uuid.uuid4().hex)
        self.repo = self.work / "repo"
        self.bin = self.work / "bin"
        self.bin.mkdir(parents=True)
        self.repo.mkdir()
        shutil.copytree(ROOT / "scripts", self.repo / "scripts")
        shutil.copy2(ROOT / "main.bicep", self.repo / "main.bicep")
        self.config_path = self.work / "config.json"
        self.log_path = self.work / "calls.jsonl"
        self.config = dict(subscription=SUB, deployments=[deployment()], rules=[],
                           diagnostics=[], probe="/health.htm",
                           iis={"value": [{"code": "ComponentStatus/StdOut/succeeded",
                                           "message": "IIS_RECOVERY_HTTP_200"}]})
        fake = self.work / "fake_az.py"
        fake.write_text(FAKE_AZ, encoding="utf-8")
        wrapper = self.bin / "az"
        wrapper.write_text('#!/usr/bin/env bash\nexec python3 "' + str(fake).replace("\\", "/") + '" "$@"\n',
                           encoding="utf-8", newline="\n")
        wrapper.chmod(0o755)
        self.params = {
            "parameters": {
                "prefix": {"value": "srelab"},
                "adminUsername": {"value": "azureuser"},
                "adminPassword": {"value": ""},
                "alertEmail": {"value": "lab@example.org"},
                "deployerPrincipalId": {"value": SUB},
            }
        }
        self.write_params()

    def tearDown(self):
        shutil.rmtree(self.work)

    def write_params(self, filename="main.parameters.json"):
        (self.repo / filename).write_text(json.dumps(self.params), encoding="utf-8")

    def run_script(self, script, *args, stdin="", env=None, trace=False):
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        environment = os.environ.copy()
        for key in ("RESOURCE_GROUP", "SUBSCRIPTION_ID", "DEPLOYMENT_NAME", "PARAMETERS_FILE", "LOCATION"):
            environment.pop(key, None)
        environment.update(FAKE_CONFIG=str(self.config_path), FAKE_LOG=str(self.log_path))
        environment.update(env or {})
        command = [BASH, "--noprofile", "--norc", "-c",
                   'export PATH="$1:$PATH"; shift; exec bash "$@"', "test",
                   bash_path(self.bin)]
        if trace:
            command.append("-x")
        command.extend([bash_path(self.repo / "scripts" / script), *args])
        result = subprocess.run(command, cwd=self.work, env=environment, input=stdin.encode(),
                                capture_output=True, timeout=60)
        result.stdout = result.stdout.decode(errors="replace")
        result.stderr = result.stderr.decode(errors="replace")
        return result

    def calls(self, prefix=None):
        calls = [json.loads(line) for line in self.log_path.read_text().splitlines()] if self.log_path.exists() else []
        return [c for c in calls if prefix is None or c["args"][:len(prefix)] == prefix]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_no_secret_files(self):
        self.assertEqual(list(self.repo.glob(".deploy-*")), [])

    def test_bash_syntax(self):
        for file in (ROOT / "scripts").glob("*.sh"):
            with self.subTest(script=file.name):
                self.assertNotIn(b"\r", file.read_bytes(), "Shell scripts require LF endings for Linux/Cloud Shell.")
                result = subprocess.run([BASH, "-n", bash_path(file)], capture_output=True, text=True)
                self.assert_success(result)

    def test_chaos_scenarios_dispatch_and_output_names(self):
        for scenario in ("cpu", "memory", "iis", "diskio", "nsg"):
            with self.subTest(scenario=scenario):
                self.assert_success(self.run_script("run-chaos.sh", scenario))
                url = self.calls(["rest"])[-1]["args"]
                self.assertIn("post", url)
                self.assertIn(f"/experiments/actual-{scenario}/start?api-version=2024-01-01", " ".join(url))
        self.assert_success(self.run_script("run-chaos.sh"))

    def test_chaos_stop_does_not_claim_recovery(self):
        result = self.run_script("run-chaos.sh", "stop", "iis")
        self.assert_success(result)
        self.assertIn("not confirmed recovered", result.stdout)
        self.assertIn("/cancel?api-version=2024-01-01", " ".join(self.calls(["rest"])[-1]["args"]))

    def test_status_paginates(self):
        self.config["paginate"] = True
        result = self.run_script("run-chaos.sh", "status", "memory")
        self.assert_success(result)
        self.assertIn("first-page", result.stdout)
        self.assertIn("second-page", result.stdout)
        self.assertEqual(len(self.calls(["rest"])), 2)

    def test_unknown_scenario_never_calls_azure(self):
        self.assertNotEqual(self.run_script("run-chaos.sh", "nginx").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_select_latest_successful_main_not_nested_or_failed(self):
        nested = deployment("deploy-chaos", "2029")
        del nested["properties"]["outputs"]["sreAgentPortalUrl"]
        failed = deployment("failed-main", "2030")
        failed["properties"]["provisioningState"] = "Failed"
        newest = deployment("latest-main", "2028")
        self.config["deployments"] += [nested, failed, newest]
        result = self.run_script("run-chaos.sh", "cpu")
        self.assert_success(result)
        self.assertIn("Main deployment: latest-main", result.stdout)

    def test_explicit_deployment_and_subscription(self):
        result = self.run_script("run-chaos.sh", "cpu",
                                 env={"DEPLOYMENT_NAME": "actual-main", "SUBSCRIPTION_ID": SUB})
        self.assert_success(result)
        self.assertEqual(len(self.calls(["account", "set"])), 1)
        self.assertEqual(len(self.calls(["deployment", "group", "show"])), 1)
        self.assertEqual(self.calls(["deployment", "group", "list"]), [])

    def test_query_failure_empty_invalid_or_wrong_scope_never_injects(self):
        for mode in ("failed-query", "empty", "failed-main", "wrong-scope", "bad-agent-url", "bad-name"):
            with self.subTest(mode=mode):
                self.config["deployments"] = [deployment()]
                self.config.pop("fail", None)
                if mode == "failed-query":
                    self.config["fail"] = ["deployment", "group", "list"]
                elif mode == "empty":
                    self.config["deployments"] = []
                elif mode == "failed-main":
                    self.config["deployments"][0]["properties"]["provisioningState"] = "Failed"
                elif mode == "wrong-scope":
                    self.config["deployments"][0]["id"] = "/subscriptions/other/deployments/main"
                elif mode == "bad-agent-url":
                    self.config["deployments"][0]["properties"]["outputs"]["sreAgentPortalUrl"]["value"] = {}
                else:
                    self.config["deployments"][0]["properties"]["outputs"]["experimentNames"]["value"]["cpu"] = "$(touch injected)"
                result = self.run_script("run-chaos.sh", "cpu")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(["rest"]), [])
                self.assertFalse((self.work / "injected").exists())

    def test_manual_nsg_exact_rule_and_idempotence(self):
        self.assert_success(self.run_script("break-nsg.sh"))
        args = self.calls(["network", "nsg", "rule", "create"])[0]["args"]
        for item in ("actual-nsg", "ManualDenyAppGatewayHTTP", "100", "10.0.1.0/24", "10.0.0.0/24", "80", "Deny"):
            self.assertIn(item, args)
        self.config["rules"] = [manual_rule()]
        self.assert_success(self.run_script("break-nsg.sh"))
        self.assertEqual(len(self.calls(["network", "nsg", "rule", "create"])), 1)
        self.assert_success(self.run_script("fix-nsg.sh"))
        self.assertIn("ManualDenyAppGatewayHTTP", self.calls(["network", "nsg", "rule", "delete"])[0]["args"])

    def test_nsg_protects_unrelated_rules_and_chaos_conflicts(self):
        for rule in (manual_rule(name="other-rule"), manual_rule(name="ChaosDenyAppGatewayHTTP"),
                     manual_rule(name="MANUALDENYAPPGATEWAYHTTP", priority=200),
                     manual_rule(destinationPortRange="443")):
            self.config["rules"] = [rule]
            self.assertNotEqual(self.run_script("break-nsg.sh").returncode, 0)
        self.assertNotEqual(self.run_script("fix-nsg.sh").returncode, 0)
        self.assertEqual(self.calls(["network", "nsg", "rule", "create"]), [])
        self.assertEqual(self.calls(["network", "nsg", "rule", "delete"]), [])
        self.config["rules"] = [manual_rule()]
        self.assertNotEqual(self.run_script("run-chaos.sh", "nsg").returncode, 0)
        self.assertEqual(self.calls(["rest"]), [])

    def test_fix_nsg_ignores_chaos_and_missing_manual(self):
        self.config["rules"] = [manual_rule(name="ChaosDenyAppGatewayHTTP")]
        result = self.run_script("fix-nsg.sh")
        self.assert_success(result)
        self.assertIn("absent", result.stdout)
        self.assertIn("stop nsg", result.stdout)
        self.assertEqual(self.calls(["network", "nsg", "rule", "delete"]), [])

    def test_failed_nsg_or_probe_queries_do_not_mutate(self):
        for script, prefix in (("break-nsg.sh", ["network", "nsg", "rule", "list"]),
                               ("fix-appgw-probe.sh", ["network", "application-gateway", "probe", "show"])):
            self.config["fail"] = prefix
            self.assertNotEqual(self.run_script(script).returncode, 0)
        self.assertEqual(self.calls(["network", "nsg", "rule", "create"]), [])
        self.assertEqual(self.calls(["network", "application-gateway", "probe", "update"]), [])

    def test_probe_known_paths_idempotence_and_custom_protection(self):
        self.assert_success(self.run_script("break-appgw-probe.sh"))
        args = self.calls(["network", "application-gateway", "probe", "update"])[0]["args"]
        for expected in ("actual-gateway", "actual-probe", "/healthz"):
            self.assertIn(expected, args)
        self.config["probe"] = "/healthz"
        self.assert_success(self.run_script("break-appgw-probe.sh"))
        self.assertEqual(len(self.calls(["network", "application-gateway", "probe", "update"])), 1)
        self.assert_success(self.run_script("fix-appgw-probe.sh"))
        self.config["probe"] = "/custom-health"
        self.assertNotEqual(self.run_script("fix-appgw-probe.sh").returncode, 0)
        self.assertNotEqual(self.run_script("break-appgw-probe.sh").returncode, 0)
        self.assertEqual(len(self.calls(["network", "application-gateway", "probe", "update"])), 2)

    def test_iis_targets_vm01_and_checks_guest_result(self):
        result = self.run_script("fix-iis.sh")
        self.assert_success(result)
        args = self.calls(["vm", "run-command", "invoke"])[0]["args"]
        for expected in ("actual-vm-01", "RunPowerShellScript"):
            self.assertIn(expected, args)
        self.assertIn("Set-Service -Name W3SVC -StartupType Automatic", " ".join(args))
        self.config["iis"] = {"value": [{"code": "ComponentStatus/StdErr/succeeded", "message": "Failed"}]}
        self.assertNotEqual(self.run_script("fix-iis.sh").returncode, 0)

    def test_activity_independent_subscription_deployment(self):
        result = self.run_script("enable-activity-log.sh")
        self.assert_success(result)
        args = self.calls(["deployment", "sub", "create"])[0]["args"]
        for expected in (SUB, DIAG, "lawId=" + LAW, "diagnosticSettingName=" + DIAG):
            self.assertIn(expected, args)
        self.assertEqual(self.calls(["deployment", "group", "create"]), [])

    def test_activity_refuses_other_workspace_and_duplicate_export(self):
        for diag in (diagnostic(workspace=LAW + "-other"),
                     diagnostic(name=DIAG.upper(), workspace=LAW + "-other"), diagnostic(name="other-setting")):
            self.config["diagnostics"] = [diag]
            self.assertNotEqual(self.run_script("enable-activity-log.sh").returncode, 0)
        self.assertEqual(self.calls(["deployment", "sub", "create"]), [])

    def test_activity_refuses_cross_subscription_law_and_long_name(self):
        self.config["deployments"][0]["properties"]["outputs"]["lawId"]["value"] = LAW.replace(SUB, "22222222-2222-2222-2222-222222222222")
        self.assertNotEqual(self.run_script("enable-activity-log.sh").returncode, 0)
        self.assertEqual(self.calls(["deployment", "sub", "create"]), [])
        self.config["deployments"] = [deployment()]
        long_rg = "rg-" + "a" * 50
        main = self.config["deployments"][0]
        main["id"] = main["id"].replace(RG, long_rg)
        main["properties"]["outputs"]["lawId"]["value"] = LAW.replace(RG, long_rg)
        self.assertNotEqual(self.run_script("enable-activity-log.sh", env={"RESOURCE_GROUP": long_rg}).returncode, 0)
        self.assertEqual(self.calls(["deployment", "sub", "create"]), [])

    def test_cleanup_deletes_only_matching_subscription_setting_before_rg(self):
        self.config["diagnostics"] = [diagnostic(), diagnostic(name="unrelated")]
        self.assert_success(self.run_script("cleanup.sh", stdin=RG + "\n"))
        calls = self.calls()
        deletes = [c for c in calls if c["args"][:1] == ["rest"] and "delete" in c["args"]]
        self.assertEqual(len(deletes), 1)
        self.assertIn(f"/subscriptions/{SUB}/providers/Microsoft.Insights/diagnosticSettings/{DIAG}?",
                      " ".join(deletes[0]["args"]))
        group = self.calls(["group", "delete"])[0]
        self.assertLess(calls.index(deletes[0]), calls.index(group))
        self.assertIn(SUB, group["args"])
        self.assertIn(RG, group["args"])

    def test_cleanup_abort_mismatch_and_failed_query_delete_nothing(self):
        self.assert_success(self.run_script("cleanup.sh", stdin="no\n"))
        self.config["diagnostics"] = [diagnostic(workspace=LAW + "-other")]
        self.assertNotEqual(self.run_script("cleanup.sh", stdin=RG + "\n").returncode, 0)
        self.config["fail"] = ["rest"]
        self.assertNotEqual(self.run_script("cleanup.sh", stdin=RG + "\n").returncode, 0)
        self.assertEqual(self.calls(["group", "delete"]), [])
        self.assertFalse(any("delete" in c["args"] for c in self.calls(["rest"])))

    def test_cleanup_missing_lab_setting_preserves_other_configs(self):
        self.config["diagnostics"] = [diagnostic(name="unrelated")]
        self.assert_success(self.run_script("cleanup.sh", stdin=RG + "\n"))
        self.assertEqual(len(self.calls(["group", "delete"])), 1)
        self.assertFalse(any("delete" in c["args"] for c in self.calls(["rest"])))

    def test_deploy_secret_file_cleanup_on_success_and_no_argv_leaks(self):
        self.params["parameters"]["tags"] = {"value": {"env": "test", "owner": "lab"}}
        self.write_params()
        result = self.run_script("deploy.sh", stdin=f"{PASSWORD}\n{PASSWORD}\n",
                                 env={"DEPLOYMENT_NAME": "actual-main", "LOCATION": "westus2",
                                      "PASSWORD": "previous-export", "CONFIRM_PASSWORD": "previous-export"}, trace=True)
        self.assert_success(result)
        self.assertNotIn(PASSWORD, result.stdout + result.stderr + self.log_path.read_text())
        call = self.calls(["deployment", "group", "create"])[0]
        self.assertTrue(call["secret_present"])
        self.assertFalse(call["password_env_present"])
        self.assertEqual(call["tags"], {"project": "sreagentlab", "env": "test", "owner": "lab"})
        self.assertEqual(call["location"], "westus2")
        if os.name != "nt":
            self.assertEqual(call["mode"], 0o600)
        self.assertFalse(Path(call["secure_file"]).exists())
        self.assert_no_secret_files()
        self.assertIn("Microsoft.Portal", " ".join(" ".join(c["args"]) for c in self.calls(["provider"])))
        self.assertEqual(self.calls(["role"]), [])
        self.assertIn("http://192.0.2.10", result.stdout)
        self.assertIn("https://portal.azure.com/#actual-agent", result.stdout)
        self.assertIn("Live Reports", result.stdout)

    def test_deploy_failure_discards_secret_bearing_stderr_and_files(self):
        self.config["fail"] = ["deployment", "group", "create"]
        result = self.run_script("deploy.sh", stdin=f"{PASSWORD}\n{PASSWORD}\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(PASSWORD, result.stdout + result.stderr)
        self.assert_no_secret_files()

    def test_deploy_password_mismatch_and_weak_password_cleanup(self):
        for first, second in ((PASSWORD, "different"), ("weak", "weak")):
            self.assertNotEqual(self.run_script("deploy.sh", stdin=f"{first}\n{second}\n").returncode, 0)
            self.assert_no_secret_files()
        self.assertEqual(self.calls(["deployment", "group", "create"]), [])

    def test_deploy_validates_parameters_before_mutation(self):
        original = copy.deepcopy(self.params)
        for key, value in (("adminPassword", "stored-secret"),
                           ("alertEmail", "<YOUR_EMAIL_ADDRESS>"),
                           ("adminUsername", "administrator"), ("prefix", "too-long-prefix"),
                           ("vmCount", 0), ("vmCount", 100), ("vmCount", True)):
            with self.subTest(key=key, value=value):
                self.params = copy.deepcopy(original)
                self.params["parameters"][key] = {"value": value}
                self.write_params()
                result = self.run_script("deploy.sh", stdin=f"{PASSWORD}\n{PASSWORD}\n")
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_secret_files()
        self.assertEqual(self.calls(["provider"]), [])
        self.assertEqual(self.calls(["group", "create"]), [])

    def test_deploy_rdp_restrictions(self):
        self.params["parameters"]["enableRdpPublicIp"] = {"value": True}
        for source in ("*", "0.0.0.0/0", "127.0.0.1/32", "10.0.0.1", "::/0"):
            self.params["parameters"]["allowedRdpSource"] = {"value": source}
            self.write_params()
            self.assertNotEqual(self.run_script("deploy.sh", stdin=f"{PASSWORD}\n{PASSWORD}\n").returncode, 0)
        self.assertEqual(self.calls(["group", "create"]), [])
        self.params["parameters"]["allowedRdpSource"] = {"value": "192.0.2.1/32"}
        self.write_params()
        self.assert_success(self.run_script("deploy.sh", stdin=f"{PASSWORD}\n{PASSWORD}\n"))

    def test_deploy_local_default_and_explicit_parameter_override(self):
        self.params["parameters"]["alertEmail"]["value"] = "<INVALID>"
        self.write_params()
        self.params["parameters"]["alertEmail"]["value"] = "local@example.org"
        self.write_params("main.parameters.local.json")
        self.assert_success(self.run_script("deploy.sh", stdin=f"{PASSWORD}\n{PASSWORD}\n"))
        self.assertNotEqual(self.run_script("deploy.sh", env={"PARAMETERS_FILE": "main.parameters.json"}).returncode, 0)
        self.write_params("custom.json")
        self.assert_success(self.run_script("deploy.sh", stdin=f"{PASSWORD}\n{PASSWORD}\n",
                                           env={"PARAMETERS_FILE": "custom.json"}))


if __name__ == "__main__":
    unittest.main()
