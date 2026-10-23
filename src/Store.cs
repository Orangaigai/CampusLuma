using System;
using System.IO;
using System.Text;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace CampusLuma {
    public sealed class SavedCredential {
        public string SchoolId;
        public string Username;
        public string PasswordCipher;
    }
    public static class Store {
        // Development builds use their own settings, credentials and task names.
        public static readonly bool Development = File.Exists(Path.Combine(Path.GetDirectoryName(typeof(Store).Assembly.Location),"development.mode"));
        public static readonly string TrialSchool = ReadTrialSchool();
        public static readonly bool SnnuTrial = TrialSchool=="snnu";
        static string ReadTrialSchool() {
            if(!Development) return null;
            string marker=File.ReadAllText(Path.Combine(Path.GetDirectoryName(typeof(Store).Assembly.Location),"development.mode")).Trim();
            foreach(string id in new[]{"snnu","hnust","hunnu","sam"}) if(marker==id+"-trial") return id;
            return null;
        }
        public static string TaskPrefix { get { return TrialSchool!=null?"CampusLuma Trial-"+TrialSchool:Development?"CampusLuma Development":"CampusLuma Reconnect"; } }
        static string DefaultRoot() { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),TrialSchool!=null?"CampusLuma-"+TrialSchool.ToUpperInvariant()+"-Trial":Development?"CampusLuma-Dev":"CampusLuma"); }
        public static string Root = DefaultRoot();
        public static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        static readonly byte[] Entropy = Encoding.UTF8.GetBytes("CampusLuma/v1");
        static string Locator { get { return Path.Combine(Path.GetDirectoryName(typeof(Store).Assembly.Location),"data-location.json"); } }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern uint GetFinalPathNameByHandle(SafeFileHandle file,StringBuilder path,uint size,uint flags);
        public static string CanonicalRoot(string root) {
            root=Path.GetFullPath(root);
            string file=Path.Combine(root,"settings.json");
            if(!File.Exists(file)) file=Path.Combine(root,"credential.json");
            if(!File.Exists(file)) return root;
            using(var stream=File.Open(file,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
                var path=new StringBuilder(32768);
                uint length=GetFinalPathNameByHandle(stream.SafeFileHandle,path,(uint)path.Capacity,0);
                if(length==0 || length>=path.Capacity) throw new IOException("无法确认设置文件的实际位置。");
                string physical=path.ToString();
                if(physical.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase)) physical=@"\\"+physical.Substring(8);
                else if(physical.StartsWith(@"\\?\",StringComparison.Ordinal)) physical=physical.Substring(4);
                return Path.GetDirectoryName(physical);
            }
        }
        public static string UserRoot() {
            string root=DefaultRoot();
            if(File.Exists(Locator)) {
                var saved=Json.Deserialize<Dictionary<string,string>>(File.ReadAllText(Locator,Encoding.UTF8));
                if(saved.ContainsKey("OwnerSid") && saved["OwnerSid"]==WindowsIdentity.GetCurrent().User.Value && saved.ContainsKey("DataDirectory"))
                    root=Path.GetFullPath(saved["DataDirectory"]);
            }
            return CanonicalRoot(root);
        }
        public static void RememberRoot() {
            Root=CanonicalRoot(Root);
            // Record only the existing private directory, never credentials.
            // This keeps Explorer launches and scheduled tasks in the same
            // filesystem view when the parent process redirects AppData.
            var saved=new Dictionary<string,string>{{"OwnerSid",WindowsIdentity.GetCurrent().User.Value},{"DataDirectory",Root}};
            string json=Json.Serialize(saved);
            if(!File.Exists(Locator) || File.ReadAllText(Locator,Encoding.UTF8)!=json) Atomic(Locator,json);
        }
        public static string FilePath(string name) { return Path.Combine(Root, name); }
        public static void Atomic(string path, string text) {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllText(temporary, text, new UTF8Encoding(false));
                if (File.Exists(path)) {
                    try { File.Replace(temporary, path, null); }
                    catch (UnauthorizedAccessException) { ReplaceWithoutMetadataMerge(temporary, path); }
                    catch (IOException error) {
                        int code=error.HResult & 0xffff;
                        if(code!=5 && code!=17 && code!=50 && code!=87 && code!=1175) throw;
                        ReplaceWithoutMetadataMerge(temporary, path);
                    }
                }
                else File.Move(temporary, path);
            } finally { TryDelete(temporary); }
        }
        static void ReplaceWithoutMetadataMerge(string temporary, string path) {
            // Some encrypted/protected folders reject ReplaceFile's metadata
            // merge even though normal writes are allowed. Keep their attributes
            // and a recovery copy; this fallback is recoverable, not an atomic rename.
            if(!File.Exists(path) || !File.Exists(temporary) || (File.GetAttributes(path)&FileAttributes.ReadOnly)!=0)
                throw new UnauthorizedAccessException("无法更新配置文件："+path);
            string backup=temporary+".recovery";
            File.Copy(path,backup,false);
            bool complete=false;
            try {
                try { File.Copy(temporary,path,true); }
                catch {
                    try { File.Copy(backup,path,true); complete=true; }
                    catch { throw new IOException("保存失败，恢复副本保留在："+backup); }
                    throw;
                }
                complete=true;
            } finally { if(complete) TryDelete(backup); }
        }
        static void TryDelete(string path) {
            try { if(File.Exists(path)) File.Delete(path); }
            catch(IOException) {} catch(UnauthorizedAccessException) {}
        }
        public static Settings Load() {
            string path = FilePath("settings.json");
            return File.Exists(path) ? Json.Deserialize<Settings>(File.ReadAllText(path, Encoding.UTF8)) : SchoolRegistry.Defaults();
        }
        public static void Save(Settings settings, string password) {
            Schedule.Validate(settings);
            var old = Credential();
            if (String.IsNullOrEmpty(password)) {
                if (old == null || old.Username != settings.Username || (old.SchoolId??"xtu")!=settings.Adapter)
                    throw new ArgumentException("首次使用、修改学校或账号后，请填写密码。");
            } else {
                var bytes = Encoding.UTF8.GetBytes(password);
                try {
                    var saved = new SavedCredential { SchoolId=settings.Adapter, Username = settings.Username,
                        PasswordCipher = Convert.ToBase64String(ProtectedData.Protect(bytes, Entropy, DataProtectionScope.CurrentUser)) };
                    Atomic(FilePath("credential.json"), Json.Serialize(saved));
                } finally { Array.Clear(bytes, 0, bytes.Length); }
            }
            Atomic(FilePath("settings.json"), Json.Serialize(settings));
        }
        public static SavedCredential Credential() {
            string path = FilePath("credential.json");
            return File.Exists(path) ? Json.Deserialize<SavedCredential>(File.ReadAllText(path, Encoding.UTF8)) : null;
        }
        public static Dictionary<string, object> ReadResult() {
            string path = FilePath("last-run.json");
            return File.Exists(path) ? Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Encoding.UTF8)) : null;
        }
    }
}
