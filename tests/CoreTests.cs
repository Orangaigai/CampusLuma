using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using CampusLuma;

public static class CoreTests {
    static int count;
    static void Check(bool value,string name) { if(!value) throw new Exception(name); count++; Console.WriteLine("PASS "+name); }
    static void Reject(Action action,string name) { bool rejected=false; try { action(); } catch(ArgumentException) { rejected=true; } Check(rejected,name); }
    public static void Main(string[] args) {
        Store.Root=Path.GetFullPath(args[0]); Directory.CreateDirectory(Store.Root);
        var s=SchoolRegistry.Defaults(); s.Username="fixture-student";
        Check(Schedule.Expand(s).SequenceEqual(new[]{"07:01"}),"default morning time");
        s.Times=new List<string>{"23:59","00:00","07:01","07:01"};
        Check(Schedule.Expand(s).SequenceEqual(new[]{"00:00","07:01","23:59"}),"sort and deduplicate custom times");
        Reject(()=>Schedule.Minute("24:00"),"reject hour 24"); Reject(()=>Schedule.Minute("7:01"),"require zero-padded time");
        Reject(()=>Schedule.Minute("12:60"),"reject minute 60"); Reject(()=>Schedule.Minute("-1:00"),"reject negative time");
        s.Times.Clear(); Reject(()=>Schedule.Expand(s),"reject empty custom schedule");
        s.Mode="interval"; s.Start="07:01"; s.End="13:01"; s.IntervalMinutes=120;
        Check(Schedule.Expand(s).SequenceEqual(new[]{"07:01","09:01","11:01","13:01"}),"inclusive interval end");
        s.End="13:00"; Check(Schedule.Expand(s).Count==3,"do not overshoot end");
        s.Start="22:00"; s.End="02:00"; Check(Schedule.Expand(s).SequenceEqual(new[]{"00:00","02:00","22:00"}),"cross midnight");
        s.Start="08:00"; s.End="08:00"; Check(Schedule.Expand(s).SequenceEqual(new[]{"08:00"}),"equal times run once");
        s.Start="00:00"; s.End="23:59"; s.IntervalMinutes=5; Check(Schedule.Expand(s).Count==288,"dense schedule can exceed 48 triggers");
        s.IntervalMinutes=1; Reject(()=>Schedule.Expand(s),"reject excessive interval frequency");
        s.IntervalMinutes=1500; Reject(()=>Schedule.Expand(s),"reject interval beyond day");
        s.Mode="custom"; s.Times=new List<string>{"07:01"};
        Check(Schedule.Next(s,new DateTime(2026,10,15,7,1,0))==new DateTime(2026,10,16,7,1,0),"missed time not caught up");
        Check(Schedule.Next(s,new DateTime(2026,10,15,7,0,0))==new DateTime(2026,10,15,7,1,0),"next time same day");
        s.Ssid="校园网测试"; Schedule.Validate(s); Check(true,"Unicode SSID accepted");
        s.Ssid="bad\"name"; Reject(()=>Schedule.Validate(s),"reject SSID command delimiters"); s.Ssid="XTU-FREE-2";
        s.Portal="https://zz.xtu.edu.cn.evil.test/"; Reject(()=>Schedule.Validate(s),"reject lookalike portal host");
        s.Portal="https://evil@zz.xtu.edu.cn/"; Reject(()=>Schedule.Validate(s),"reject credentials in portal URL");
        s.Portal="https://zz.xtu.edu.cn/pc/center";
        Store.Save(s,"fixture-password-not-real");
        Check(!File.ReadAllText(Store.FilePath("credential.json")).Contains("fixture-password-not-real"),"no plaintext password on disk");
        var credential=Store.Credential(); var plain=ProtectedData.Unprotect(Convert.FromBase64String(credential.PasswordCipher),Encoding.UTF8.GetBytes("CampusLuma/v1"),DataProtectionScope.CurrentUser);
        Check(Encoding.UTF8.GetString(plain)=="fixture-password-not-real","DPAPI round trip"); Array.Clear(plain,0,plain.Length);
        Store.Save(s,""); Check(Store.Load().Username==s.Username,"blank password preserves account");
        s.Username="changed-student"; Reject(()=>Store.Save(s,""),"account change requires new password");
        s.Username="fixture-student"; s.Mode="custom"; s.Times=new List<string>();
        for(int minute=0;minute<60;minute++) s.Times.Add("23:"+minute.ToString("00"));
        Store.Save(s,""); Check(Store.Load().Times.Count==60,"persist more than 48 explicit times");
        Console.WriteLine("Core scenarios passed: "+count);
    }
}
