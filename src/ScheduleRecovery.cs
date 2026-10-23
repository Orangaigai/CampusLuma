using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace CampusLuma {
    public sealed class RecoveryDecision {
        public bool Allowed;
        public string Code;
        public string Slot;
    }
    public sealed class ScheduleReceipt {
        public int Version;
        public string PlanToken;
        public string LastAttemptAt;
    }
    public static class ScheduleRecovery {
        public const int WindowMinutes=120;
        static string Digest(byte[] bytes) {
            using(var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant();
        }
        public static string LockName(string root) {
            return @"Local\CampusLumaExecution-"+Digest(Encoding.UTF8.GetBytes(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant()));
        }
        public static string CredentialRevision(string root) {
            string path=Path.Combine(root,"credential.json");
            if(!File.Exists(path)) return "missing";
            if(new FileInfo(path).Length>65536) throw new InvalidDataException("Credential file is too large.");
            // Hash encrypted storage only. No decryption or plaintext material.
            return Digest(File.ReadAllBytes(path));
        }
        public static string PlanToken(Settings settings,string revision) {
            var plan=new { settings.Adapter,settings.Username,settings.Service,settings.Ssid,settings.Interface,settings.Portal,
                Times=Schedule.Expand(settings),CredentialRevision=revision };
            return Digest(Encoding.UTF8.GetBytes(Store.Json.Serialize(plan)));
        }
        public static DateTime LatestSlot(Settings settings,DateTime now) {
            return Schedule.Expand(settings).Select(value=>now.Date.AddMinutes(Schedule.Minute(value)))
                .Select(value=>value<=now?value:value.AddDays(-1)).Max();
        }
        public static RecoveryDecision Decide(Settings settings,DateTime now,string receiptJson,string revision) {
            var decision=new RecoveryDecision { Allowed=false,Code="CATCHUP_DISABLED" };
            if(!settings.CatchUpOnLogon) return decision;
            DateTime slot=LatestSlot(settings,now);
            decision.Slot=slot.ToString("o",CultureInfo.InvariantCulture);
            if(now-slot>TimeSpan.FromMinutes(WindowMinutes)) { decision.Code="CATCHUP_OUTSIDE_WINDOW";return decision; }
            if(receiptJson!=null) {
                try {
                    if(String.IsNullOrWhiteSpace(receiptJson) || receiptJson.Length>4096) throw new InvalidDataException();
                    var receipt=Store.Json.Deserialize<ScheduleReceipt>(receiptJson);DateTime attempted;
                    if(receipt==null || receipt.Version!=1 || !Regex.IsMatch(receipt.PlanToken??"",@"^[a-f0-9]{64}$") ||
                        !DateTime.TryParseExact(receipt.LastAttemptAt,"o",CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out attempted)) throw new InvalidDataException();
                    if(receipt.PlanToken==PlanToken(settings,revision)) {
                        if(attempted>now) throw new InvalidDataException();
                        if(attempted>=slot) { decision.Code="CATCHUP_ALREADY_HANDLED";return decision; }
                    }
                } catch { decision.Code="CATCHUP_STATE_UNAVAILABLE";return decision; }
            }
            decision.Allowed=true;decision.Code="CATCHUP_ELIGIBLE";return decision;
        }
        public static RecoveryDecision ReadDecision(string root,Settings settings,DateTime now) {
            var initial=Decide(settings,now,null,"");
            if(!initial.Allowed) return initial;
            try {
                string path=Path.Combine(root,"schedule-receipt.json");
                if(File.Exists(path) && new FileInfo(path).Length>4096) throw new InvalidDataException();
                return Decide(settings,now,File.Exists(path)?File.ReadAllText(path,Encoding.UTF8):null,CredentialRevision(root));
            } catch { return new RecoveryDecision { Allowed=false,Code="CATCHUP_STATE_UNAVAILABLE" }; }
        }
        public static void MarkAttempt(string root,Settings settings,DateTime now) {
            var receipt=new ScheduleReceipt { Version=1,PlanToken=PlanToken(settings,CredentialRevision(root)),LastAttemptAt=now.ToString("o",CultureInfo.InvariantCulture) };
            Store.Atomic(Path.Combine(root,"schedule-receipt.json"),Store.Json.Serialize(receipt));
        }
    }
}
