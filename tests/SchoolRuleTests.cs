using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using CampusLuma;

public static class SchoolRuleTests {
    static int count;
    static void Check(bool ok,string name) { if(!ok) throw new Exception(name); count++;Console.WriteLine("PASS "+name); }
    static void Reject(Action body,string name) { bool rejected=false;try{body();}catch(ArgumentException){rejected=true;}Check(rejected,name); }
    public static void Main(string[] args) {
        string target=Path.Combine(Path.GetFullPath(args[0]),"run-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(target);
        string original=SchoolRegistry.DirectoryPath;
        var json=new JavaScriptSerializer();
        var template=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(original,"xtu.json")));
        File.Copy(Path.Combine(original,"xtu.json"),Path.Combine(target,"xtu.json"),true);
        SchoolRegistry.DirectoryPath=target;
        try {
            var xtu=SchoolRegistry.Load("xtu");Check(xtu.enabled && xtu.name=="湘潭大学","load actual enabled XTU rule");
            Check(SchoolRegistry.Allows(xtu,"https://zz.xtu.edu.cn/portal?a=dynamic"),"allow dynamic parameters on configured origin");
            Check(!SchoolRegistry.Allows(xtu,"https://zz.xtu.edu.cn.evil.invalid/"),"reject lookalike host");
            Check(!SchoolRegistry.Allows(xtu,"https://user:pass@zz.xtu.edu.cn/"),"reject URL credentials");
            Check(!SchoolRegistry.Allows(xtu,"https://zz.xtu.edu.cn:8443/"),"reject unregistered port");
            Reject(()=>SchoolRegistry.Load("../xtu"),"reject traversal before file read");
            Reject(()=>SchoolRegistry.Load("missing"),"reject unknown school");
            File.WriteAllText(Path.Combine(target,"pending.json"),"{\"schemaVersion\":1,\"id\":\"pending\",\"name\":\"待验证学校\",\"enabled\":false}");
            Reject(()=>SchoolRegistry.Load("pending"),"unverified school cannot execute");
            Check(SchoolRegistry.Available().Count==1,"pending school stays out of selectable list");
            template["id"]="fixture-b";template["name"]="模拟乙校";template["defaultSsid"]="Fixture-B";
            template["fallbackPortal"]="https://portal.beta.invalid/login";template["trustedOrigins"]=new[]{"https://portal.beta.invalid"};
            var browser=(Dictionary<string,object>)template["browser"];browser["selfServiceUrl"]="https://portal.beta.invalid/self";
            string beta=Path.Combine(target,"fixture-b.json");File.WriteAllText(beta,json.Serialize(template));
            var second=SchoolRegistry.Defaults("fixture-b");second.Username="fixture-student";Schedule.Validate(second);
            Check(second.School=="模拟乙校" && second.Ssid=="Fixture-B" && second.Portal.EndsWith("/login"),"second school defaults are data driven");
            Check(SchoolRegistry.Available().Count==2,"second verified fixture appears without code changes");
            second.Portal="https://zz.xtu.edu.cn/pc/center";Reject(()=>Schedule.Validate(second),"second school cannot use XTU credentials destination");
            second.Portal="https://portal.beta.invalid/login";
            var first=SchoolRegistry.Defaults();first.Username="fixture-student";
            Store.Root=Path.Combine(target,"private-test-data");Store.Save(first,"fixture-password-not-real");
            var legacyXtu=Store.Credential();
            Reject(()=>Store.Save(second,""),"same username in another school cannot reuse password");
            Store.Save(second,"second-fixture-password-not-real");Check(Store.Credential().SchoolId=="fixture-b","saved credential is bound to school");
            Store.Save(second,"");Check(Store.Load().Adapter=="fixture-b","same school can reuse saved credential");
            Reject(()=>Store.Save(first,""),"switching back also requires the matching credential");
            legacyXtu.SchoolId=null;File.WriteAllText(Store.FilePath("credential.json"),json.Serialize(legacyXtu));
            Reject(()=>Store.Save(second,""),"legacy credential is not reusable by a new school");
            Store.Save(first,"");Check(Store.Load().Adapter=="xtu","legacy XTU credential remains compatible");
            var snnu=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(original,"snnu.json")));
            snnu["enabled"]=true;File.WriteAllText(Path.Combine(target,"snnu.json"),json.Serialize(snnu));
            var snnuSettings=SchoolRegistry.Defaults("snnu");snnuSettings.Username="fixture-student";
            Check(snnuSettings.Ssid=="SNNU" && snnuSettings.Service==null,"SNNU defaults require an explicit service choice");
            Reject(()=>Schedule.Validate(snnuSettings),"SNNU cannot save an unselected service");
            snnuSettings.Service="";Schedule.Validate(snnuSettings);Check(snnuSettings.Service=="","empty campus service remains an explicit choice");
            snnuSettings.Service="unicom";Schedule.Validate(snnuSettings);Check(true,"registered carrier is accepted");
            snnuSettings.Service="unknown";Reject(()=>Schedule.Validate(snnuSettings),"unknown carrier is rejected before scheduling");
            foreach(string id in new[]{"hnust","hunnu"}) {
                var candidate=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(original,id+".json")));
                candidate["enabled"]=true;string file=Path.Combine(target,id+".json");File.WriteAllText(file,json.Serialize(candidate));
                var settings=SchoolRegistry.Defaults(id);settings.Username="fixture-student";
                Check(SchoolRegistry.Services(SchoolRegistry.Load(id)).Length==4,id+" shares minimal service selector");
                Reject(()=>Schedule.Validate(settings),id+" requires an explicit service");
                settings.Service=id=="hnust"?"":"0";Schedule.Validate(settings);Check(true,id+" accepts its own campus service value");
                settings.Service="unknown";Reject(()=>Schedule.Validate(settings),id+" rejects an unknown carrier");
                var protocol=(Dictionary<string,object>)candidate["protocol"];protocol["apiOrigin"]="http://collector.invalid";
                File.WriteAllText(file,json.Serialize(candidate));Reject(()=>SchoolRegistry.Load(id),id+" rejects a changed credential destination");
            }
            foreach(string id in new[]{"cuit","scit","ysu","uestc-telecom"}) {
                var candidate=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(original,id+".json")));
                Check(!(bool)candidate["enabled"],id+" source stays disabled until real campus acceptance");
                candidate["enabled"]=true;string file=Path.Combine(target,id+".json");File.WriteAllText(file,json.Serialize(candidate));
                var rule=SchoolRegistry.Load(id);var settings=SchoolRegistry.Defaults(id);settings.Username="fixture-student";
                Check(SchoolRegistry.Services(rule).Length==(id=="uestc-telecom"?1:4),id+" loads researched browser services");
                if(rule.requiresUserSsid) { settings.Service="telecom";Reject(()=>Schedule.Validate(settings),id+" cannot schedule an unknown Wi-Fi name");settings.Ssid="Fixture-Campus";settings.Service=null; }
                Reject(()=>Schedule.Validate(settings),id+" requires the actual service selection");
                settings.Service="telecom";Schedule.Validate(settings);Check(true,id+" accepts selected service and its own portal");
                settings.Service="unknown";Reject(()=>Schedule.Validate(settings),id+" rejects unknown browser service");
                settings.Service="telecom";settings.Portal="https://zz.xtu.edu.cn/pc/center";Reject(()=>Schedule.Validate(settings),id+" cannot send account to XTU");
            }
            foreach(string id in new[]{"qlu","dlut-panjin","mnnu-yuanshan"}) {
                var candidate=json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(original,id+".json")));
                Check(!(bool)candidate["enabled"],id+" source stays disabled");candidate["enabled"]=true;
                string file=Path.Combine(target,id+".json");File.WriteAllText(file,json.Serialize(candidate));
                var rule=SchoolRegistry.Load(id);var settings=SchoolRegistry.Defaults(id);settings.Username="fixture-student";
                Check(rule.browser.requireGatewayParameters && rule.browser.entryPathPatterns.Length>0,id+" requires a current portal flow");
                Check(SchoolRegistry.Services(rule).Length==(id=="qlu"?1:0),id+" only exposes evidenced service choices");
                if(id=="qlu") {Reject(()=>Schedule.Validate(settings),"QLU requires explicit Internet selection");settings.Service="internet";}
                Schedule.Validate(settings);Check(true,id+" accepts its own settings without fabricated operator values");
                settings.Portal="https://zz.xtu.edu.cn/pc/center";Reject(()=>Schedule.Validate(settings),id+" rejects another school destination");
                var profile=(Dictionary<string,object>)candidate["browser"];profile.Remove("entryPathPatterns");File.WriteAllText(file,json.Serialize(candidate));
                Reject(()=>SchoolRegistry.Load(id),id+" rejects gateway policy without version paths");
            }
            template["schemaVersion"]=999;File.WriteAllText(beta,json.Serialize(template));Reject(()=>SchoolRegistry.Load("fixture-b"),"reject unsupported schema");template["schemaVersion"]=1;
            template["entry"]="../../arbitrary.ps1";File.WriteAllText(beta,json.Serialize(template));Reject(()=>SchoolRegistry.Load("fixture-b"),"rule cannot select an arbitrary program");template["entry"]="engine/campus-network-reconnect.ps1";
            template["trustedOrigins"]=new[]{"https://portal.beta.invalid/login"};File.WriteAllText(beta,json.Serialize(template));Reject(()=>SchoolRegistry.Load("fixture-b"),"origin list cannot contain page paths");
            template["trustedOrigins"]=new[]{"https://portal.beta.invalid"};browser["passwordSelectors"]=new string[0];File.WriteAllText(beta,json.Serialize(template));Reject(()=>SchoolRegistry.Load("fixture-b"),"reject missing password selectors");
            Check(Store.Development && Store.TaskPrefix=="CampusLuma Development","development task namespace is isolated");
            Console.WriteLine("School-rule scenarios passed: "+count);
        } finally {SchoolRegistry.DirectoryPath=original;}
    }
}
