using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace CampusLuma {
    // Feedback is constructed from typed, allowlisted values. Never redact a
    // copy of settings, browser output or a credential file after the fact.
    public static class RunJournal {
        public const int Limit=100;
        const long MaxBytes=512*1024;
        static string Text(IDictionary<string,object> value,string key) {
            object item; return value!=null && value.TryGetValue(key,out item)?Convert.ToString(item,CultureInfo.InvariantCulture):"";
        }
        public static DateTime Time(IDictionary<string,object> value,string key) {
            DateTime result; return DateTime.TryParse(Text(value,key),CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out result)?result:DateTime.MinValue;
        }
        static bool Flag(IDictionary<string,object> value,string key) {
            object item; return value!=null && value.TryGetValue(key,out item) && item is bool && (bool)item;
        }
        static void Number(Dictionary<string,object> safe,IDictionary<string,object> value,string key,long min,long max) {
            long number;
            if(Int64.TryParse(Text(value,key),NumberStyles.Integer,CultureInfo.InvariantCulture,out number) && number>=min && number<=max) safe[key]=number;
        }
        static void Choice(Dictionary<string,object> safe,IDictionary<string,object> value,string key,string[] choices) {
            string text=Text(value,key); if(choices.Contains(text)) safe[key]=text;
        }
        public static Dictionary<string,object> Safe(IDictionary<string,object> value) {
            var safe=new Dictionary<string,object>(); if(value==null) return safe;
            string code=Text(value,"Code"); safe["Code"]=ResultText.Known(code)?code:"UNKNOWN_RESULT";
            safe["Success"]=Flag(value,"Success") && (code=="ALREADY_ONLINE" || code=="ONLINE_AFTER_AUTH");
            safe["AuthenticationAttempted"]=Flag(value,"AuthenticationAttempted");
            foreach(string key in new[]{"Time","CompletedAt","ScheduledSlot"}) { DateTime time=Time(value,key); if(time!=DateTime.MinValue) safe[key]=time.ToString("o",CultureInfo.InvariantCulture); }
            Choice(safe,value,"Origin",new[]{"Manual","Scheduled","LogonCatchUp"});
            Guid id; if(Guid.TryParse(Text(value,"RunId"),out id)) safe["RunId"]=id.ToString("N");
            Number(safe,value,"DurationMs",0,3600000); Number(safe,value,"ExitCode",Int32.MinValue,UInt32.MaxValue);
            Number(safe,value,"StartupAttempts",0,2); Number(safe,value,"RuleVersion",0,100);
            Number(safe,value,"WifiErrorCode",0,UInt32.MaxValue);
            // Reuse the school registry rather than maintaining a second list
            // when contributors add a school. Never export an arbitrary id.
            try { string schoolId=Text(value,"SchoolId"); if(schoolId.Length>0) safe["SchoolId"]=SchoolRegistry.Load(schoolId,false).id; } catch {}
            Choice(safe,value,"ErrorStage",new[]{"LAUNCH_BROWSER","CREATE_CONTEXT","CREATE_PAGE"});
            Choice(safe,value,"ErrorCode",new[]{"EDGE_NOT_FOUND","EDGE_ACCESS_DENIED","EDGE_STARTUP_TIMEOUT","EDGE_PROCESS_CLOSED","EDGE_STARTUP_ERROR"});
            Choice(safe,value,"ErrorType",new[]{"Error","TimeoutError","IOException","UnauthorizedAccessException","ArgumentException","FileNotFoundException","InvalidOperationException","RuntimeException","TypeInitializationException","TargetInvocationException"});
            string auth=Text(value,"AuthenticationCode"); if(ResultText.Known(auth)) safe["AuthenticationCode"]=auth;
            return safe;
        }
        public static List<Dictionary<string,object>> Read(string root,out string status) {
            status="OK"; string path=Path.Combine(root,"run-history.json");
            if(!File.Exists(path)) { status="NOT_YET_RECORDED"; return new List<Dictionary<string,object>>(); }
            try {
                if(new FileInfo(path).Length>MaxBytes) { status="HISTORY_TOO_LARGE"; return new List<Dictionary<string,object>>(); }
                var raw=Store.Json.Deserialize<List<Dictionary<string,object>>>(File.ReadAllText(path,Encoding.UTF8));
                if(raw==null || raw.Count>Limit) throw new InvalidDataException();
                return raw.Where(item=>item!=null).Select(Safe).ToList();
            } catch { status="HISTORY_UNREADABLE"; return new List<Dictionary<string,object>>(); }
        }
        public static bool Record(string root,string json) {
            return Record(root,json,true);
        }
        public static bool Record(string root,string json,bool publishResult) {
            var value=Store.Json.Deserialize<Dictionary<string,object>>(json);
            var safe=Safe(value); Directory.CreateDirectory(root);
            // The current result remains available even if history is locked.
            if(publishResult) Store.Atomic(Path.Combine(root,"last-run.json"),Store.Json.Serialize(safe));
            FileStream guard=null;
            for(int attempt=0;attempt<5 && guard==null;attempt++) {
                try { guard=new FileStream(Path.Combine(root,"run-history.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None); }
                catch(IOException) { if(attempt<4) Thread.Sleep(50); }
            }
            if(guard==null) return false;
            using(guard) {
                string status; var history=Read(root,out status);
                if(status=="HISTORY_UNREADABLE" || status=="HISTORY_TOO_LARGE") return false;
                string id=Text(safe,"RunId");
                if(id.Length==0 || !history.Any(item=>Text(item,"RunId")==id)) history.Add(safe);
                history=history.OrderBy(item=>Time(item,"Time")).Skip(Math.Max(0,history.Count-Limit)).ToList();
                Store.Atomic(Path.Combine(root,"run-history.json"),Store.Json.Serialize(history));
            }
            return true;
        }
        public static Dictionary<string,object> Feedback(string root,IDictionary<string,object> task,DateTime now) {
            string status; var history=Read(root,out status);
            var report=new Dictionary<string,object>{{"SchemaVersion",1},{"GeneratedAt",now.ToString("o",CultureInfo.InvariantCulture)},
                {"HistoryStatus",status},{"Runs",history},{"Limits","Only recorded runs are included; absence does not prove a power or authentication failure."}};
            try {
                string path=Path.Combine(root,"last-run.json");
                if(File.Exists(path) && new FileInfo(path).Length<=MaxBytes)
                    report["LastRun"]=Safe(Store.Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(path,Encoding.UTF8)));
            } catch { report["LastRunUnreadable"]=true; }
            var snapshot=new Dictionary<string,object>();
            if(task!=null) {
                snapshot["Enabled"]=Flag(task,"Enabled");
                snapshot["CatchUpEnabled"]=Flag(task,"CatchUpEnabled");
                Number(snapshot,task,"TaskCount",0,100); Number(snapshot,task,"State",0,4);
                Number(snapshot,task,"LastExitCode",Int32.MinValue,UInt32.MaxValue);
                foreach(string key in new[]{"LastRun","NextRun"}) { DateTime time=Time(task,key); if(time.Year>=2010) snapshot[key]=time.ToString("o",CultureInfo.InvariantCulture); }
                object raw;
                var times=new SortedSet<string>();
                if(task.TryGetValue("Times",out raw) && raw is IEnumerable && !(raw is string))
                    foreach(object item in (IEnumerable)raw) {
                        string text=Convert.ToString(item,CultureInfo.InvariantCulture);
                        try { Schedule.Minute(text); times.Add(text); } catch(ArgumentException) {}
                    }
                snapshot["Times"]=times.Take(288).ToArray();
            }
            report["Schedule"]=snapshot;
            return report;
        }
    }
}
