using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using CampusLuma;

public static class ScheduleRecoveryTests {
    static int count;
    static void Check(bool value,string name){if(!value)throw new Exception(name);count++;Console.WriteLine("PASS "+name);}
    static Settings Settings(){return new Settings {Adapter="xtu",Username="fictional-account",Ssid="XTU-FREE-2",Interface="WLAN",Portal="https://zz.xtu.edu.cn/pc/center",CatchUpOnLogon=true};}
    static string Receipt(Settings settings,DateTime at,string revision="revision-A") {return Store.Json.Serialize(new ScheduleReceipt {Version=1,PlanToken=ScheduleRecovery.PlanToken(settings,revision),LastAttemptAt=at.ToString("o")});}
    public static void Main(string[] args){
        var now=new DateTime(2026,10,23,7,22,0);var settings=Settings();
        Check(!new Settings().CatchUpOnLogon,"legacy installations default to no logon recovery");
        var decision=ScheduleRecovery.Decide(settings,now,null,"revision-A");
        Check(decision.Allowed && DateTime.Parse(decision.Slot)==now.Date.AddHours(7).AddMinutes(1),"late login selects the missed morning slot");
        Check(ScheduleRecovery.Decide(settings,now.Date.AddHours(7).AddMinutes(1),null,"revision-A").Allowed,"exact scheduled boundary permitted");
        Check(!ScheduleRecovery.Decide(settings,now.Date.AddHours(6),null,"revision-A").Allowed,"before morning schedule no old-day backfill");
        Check(ScheduleRecovery.Decide(settings,now.Date.AddHours(9).AddMinutes(1),null,"revision-A").Allowed,"two-hour window inclusive");
        Check(ScheduleRecovery.Decide(settings,now.Date.AddHours(9).AddMinutes(1).AddTicks(1),null,"revision-A").Code=="CATCHUP_OUTSIDE_WINDOW","window cannot expand by rounding");
        string receipt=Receipt(settings,now.AddMinutes(-20));
        Check(ScheduleRecovery.Decide(settings,now,receipt,"revision-A").Code=="CATCHUP_ALREADY_HANDLED","completed or failed scheduled invocation prevents repeated logon attempts");
        Check(ScheduleRecovery.Decide(settings,now,Receipt(settings,now.Date.AddHours(6)),"revision-A").Allowed,"attempt before today's slot cannot suppress it");
        Check(ScheduleRecovery.Decide(settings,now,receipt,"revision-B").Allowed,"changed encrypted credential revision permits corrected credentials");
        foreach(string text in new[]{""," ","{broken","null",new string('x',4097),"{\"Version\":99}"})
            Check(ScheduleRecovery.Decide(settings,now,text,"revision-A").Code=="CATCHUP_STATE_UNAVAILABLE","malformed receipt fails closed: case "+count);
        Check(ScheduleRecovery.Decide(settings,now,Receipt(settings,now.AddSeconds(1)),"revision-A").Code=="CATCHUP_STATE_UNAVAILABLE","clock rollback cannot cause another attempt");
        foreach(Action<Settings> change in new Action<Settings>[] {s=>s.Username="different-account",s=>s.Ssid="different-wifi",s=>s.Interface="Wi-Fi 2",s=>s.Portal="https://zz.xtu.edu.cn/",s=>s.Service="changed",s=>s.Times=new List<string>{"07:02"}}){
            var changed=Store.Json.Deserialize<Settings>(Store.Json.Serialize(settings));change(changed);
            Check(ScheduleRecovery.Decide(changed,now,receipt,"revision-A").Allowed,"plan or identity changes do not reuse another receipt: case "+count);
        }
        settings.Times=new List<string>{"23:50"};
        Check(DateTime.Parse(ScheduleRecovery.Decide(settings,now.Date.AddMinutes(10),null,"revision-A").Slot)==now.Date.AddDays(-1).AddHours(23).AddMinutes(50),"midnight selects the preceding day's recent slot");
        settings.Times=new List<string>{"07:01","08:01"};
        Check(DateTime.Parse(ScheduleRecovery.Decide(settings,now.Date.AddHours(8).AddMinutes(10),null,"revision-A").Slot).Hour==8,"multiple missed times produce only the newest candidate");
        settings.Mode="interval";settings.Start="22:00";settings.End="02:00";settings.IntervalMinutes=120;
        Check(DateTime.Parse(ScheduleRecovery.Decide(settings,now.Date.AddHours(1),null,"revision-A").Slot)==now.Date,"cross-midnight interval recovery uses expanded local times");
        string root=Path.GetFullPath(args[0]);Directory.CreateDirectory(root);settings=Settings();
        File.WriteAllText(Path.Combine(root,"credential.json"),"fictional-encrypted-storage");
        Check(ScheduleRecovery.ReadDecision(root,settings,now).Allowed,"missing receipt is eligible");
        ScheduleRecovery.MarkAttempt(root,settings,now.AddMinutes(-1));
        Check(ScheduleRecovery.ReadDecision(root,settings,now).Code=="CATCHUP_ALREADY_HANDLED","on-disk receipt survives a subsequent invocation");
        File.WriteAllText(Path.Combine(root,"schedule-receipt.json"),"");
        Check(ScheduleRecovery.ReadDecision(root,settings,now).Code=="CATCHUP_STATE_UNAVAILABLE","empty on-disk receipt is not treated as absent");
        settings.CatchUpOnLogon=false;
        Check(ScheduleRecovery.ReadDecision(root,settings,now).Code=="CATCHUP_DISABLED","disabled feature ignores even an unreadable receipt");
        settings.CatchUpOnLogon=true;
        Check(ScheduleRecovery.ReadDecision(root,settings,now.AddHours(4)).Code=="CATCHUP_OUTSIDE_WINDOW","outside-window login ignores malformed private state without accessing the engine");
        Check(ScheduleRecovery.LockName(root)==ScheduleRecovery.LockName(root.ToUpperInvariant()+Path.DirectorySeparatorChar),"same Windows state directory has one execution lock");
        Console.WriteLine("Schedule recovery scenarios passed: "+count);
    }
}
