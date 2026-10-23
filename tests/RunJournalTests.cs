using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using CampusLuma;

public static class RunJournalTests {
    static int count;
    static void Check(bool ok,string name) { if(!ok) throw new Exception(name);count++;Console.WriteLine("PASS "+name); }
    static Dictionary<string,object> Run(DateTime time,string code) {
        return new Dictionary<string,object>{{"RunId",Guid.NewGuid().ToString("N")},{"Time",time.ToString("o")},{"Code",code},
            {"Success",code=="ONLINE_AFTER_AUTH"},{"AuthenticationAttempted",code=="ONLINE_AFTER_AUTH"},{"DurationMs",1234L},{"ExitCode",0}};
    }
    public static void Main(string[] args) {
        string root=Path.GetFullPath(args[0]); Directory.CreateDirectory(root);
        DateTime morning=new DateTime(2026,10,23,7,1,0);
        var run=Run(morning,"ONLINE_AFTER_AUTH");
        run["Username"]="CANARY_ACCOUNT_4242";run["Password"]="CANARY_PASSWORD_4242";
        run["ErrorType"]="CANARY_ACCOUNT_4242";run["ErrorMessage"]="https://private.test/?token=CANARY_TOKEN_4242";
        run["Settings"]=new Dictionary<string,object>{{"PasswordCipher","CANARY_CIPHER_4242"}};
        Check(RunJournal.Record(root,Store.Json.Serialize(run)),"successful auth record saved");
        Check(!File.ReadAllText(Path.Combine(root,"run-history.json")).Contains("CANARY"),"history excludes raw fields and nested credentials");
        Check(!File.ReadAllText(Path.Combine(root,"last-run.json")).Contains("CANARY"),"current result uses the same allowlist");
        var safe=RunJournal.Safe(new Dictionary<string,object>{{"Code","CANARY_PASSWORD_4242"},{"Success",true},{"SchoolId","CANARY"},{"ErrorStage","CANARY"},{"DurationMs",-4L}});
        Check((string)safe["Code"]=="UNKNOWN_RESULT" && !(bool)safe["Success"] && !Store.Json.Serialize(safe).Contains("CANARY"),"unknown values cannot become shared diagnostic text or success");
        Check(!safe.ContainsKey("DurationMs"),"invalid duration omitted");
        string skipRoot=Path.Combine(root,"skipped-recovery");
        RunJournal.Record(skipRoot,Store.Json.Serialize(run));
        string original=File.ReadAllText(Path.Combine(skipRoot,"last-run.json"));
        var skipped=Run(morning.AddMinutes(1),"CATCHUP_ALREADY_HANDLED");skipped["Origin"]="LogonCatchUp";skipped["PlanToken"]="CANARY_PRIVATE_RECEIPT";
        RunJournal.Record(skipRoot,Store.Json.Serialize(skipped),false);
        Check(File.ReadAllText(Path.Combine(skipRoot,"last-run.json"))==original,"skipped logon recovery cannot replace the last real connection result");
        string skipStatus;var skipHistory=RunJournal.Read(skipRoot,out skipStatus);
        Check(skipHistory.Count==2 && (string)skipHistory[1]["Origin"]=="LogonCatchUp" && !Store.Json.Serialize(skipHistory).Contains("CANARY"),"skip reason retained without exporting private plan tokens");
        var startup=Run(morning,"BROWSER_START_FAILED");startup["ErrorCode"]="EDGE_PROCESS_CLOSED";startup["ErrorStage"]="CREATE_CONTEXT";startup["ErrorType"]="Error";startup["StartupAttempts"]=2;
        var startupSafe=RunJournal.Safe(startup);
        Check((string)startupSafe["ErrorCode"]=="EDGE_PROCESS_CLOSED" && (string)startupSafe["ErrorStage"]=="CREATE_CONTEXT" && (long)startupSafe["StartupAttempts"]==2,"browser startup metadata matches the production provider contract");
        Check(RunJournal.Record(root,Store.Json.Serialize(run)),"same run receipt accepted idempotently");
        string status;
        Check(RunJournal.Read(root,out status).Count==1,"duplicate receipt not appended twice");
        for(int i=1;i<=105;i++) RunJournal.Record(root,Store.Json.Serialize(Run(morning.AddDays(i),i%2==0?"ALREADY_ONLINE":"CAMPUS_NOT_VISIBLE")));
        var history=RunJournal.Read(root,out status);
        Check(history.Count==100 && RunJournal.Time(history[0],"Time")==morning.AddDays(6),"retains newest 100 runs in chronological order");
        var task=new Dictionary<string,object>{{"Enabled",true},{"TaskCount",1},{"State",3},{"Times",new object[]{"07:01","25:01","CANARY_SSID"}},
            {"LastRun",morning.AddDays(-1).ToString("o")},{"LastExitCode",0},{"NextRun",morning.AddDays(1).ToString("o")},{"Arguments","CANARY_PATH"}};
        var yesterday=Run(morning.AddDays(-1),"ONLINE_AFTER_AUTH");
        Check(ResultText.ScheduleNotice(task,yesterday,morning.AddMinutes(3))==null,"allows bounded startup and run grace period");
        Check(ResultText.ScheduleNotice(task,yesterday,morning.AddMinutes(6)).Contains("没有执行记录"),"stale success cannot conceal missing morning record");
        Check(ResultText.ScheduleNotice(task,Run(morning.AddSeconds(3),"CAMPUS_NOT_VISIBLE"),morning.AddMinutes(6))==null,"campus not visible remains an actual run outcome");
        task["Enabled"]=false;
        Check(ResultText.ScheduleNotice(task,yesterday,morning.AddMinutes(6))==null,"paused schedule does not claim missed execution");
        task["Enabled"]=true;task["State"]=4;
        Check(ResultText.ScheduleNotice(task,yesterday,morning.AddMinutes(6)).Contains("正在执行"),"active system task not marked failed");
        task["State"]=3;task["LastRun"]=morning.AddMinutes(10).ToString("o");task["LastExitCode"]=-2147020576L;
        Check(ResultText.ScheduleNotice(task,yesterday,morning.AddMinutes(20)).Contains("800710E0"),"signed scheduler error renders stable hexadecimal value");
        var report=RunJournal.Feedback(root,task,morning);
        string json=Store.Json.Serialize(report);
        Check(!json.Contains("CANARY") && !json.Contains(root),"feedback excludes settings, SSID, raw arguments, account, password and paths");
        Check(((string[])((Dictionary<string,object>)report["Schedule"])["Times"]).SequenceEqual(new[]{"07:01"}),"feedback time values validated independently");
        File.WriteAllText(Path.Combine(root,"run-history.json"),"malformed CANARY_PASSWORD_4242");
        report=RunJournal.Feedback(root,task,morning);
        Check((string)report["HistoryStatus"]=="HISTORY_UNREADABLE" && !Store.Json.Serialize(report).Contains("CANARY"),"corrupt file reported without exporting its bytes");
        Check(!RunJournal.Record(root,Store.Json.Serialize(Run(morning,"ALREADY_ONLINE"))),"unreadable history preserved instead of overwritten");
        Check(File.ReadAllText(Path.Combine(root,"run-history.json")).StartsWith("malformed"),"unreadable evidence stays intact");
        Check((string)Store.Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(root,"last-run.json")))["Code"]=="ALREADY_ONLINE","history failure does not hide latest outcome");
        File.WriteAllText(Path.Combine(root,"run-history.json"),new string('x',512*1024+1));
        RunJournal.Read(root,out status);Check(status=="HISTORY_TOO_LARGE","oversized history bounded before JSON parse");
        Check(RunJournal.Feedback(Path.Combine(root,"missing"),null,morning).ContainsKey("Schedule"),"new installation has usable feedback without data");
        Console.WriteLine("Run journal scenarios passed: "+count);
    }
}
