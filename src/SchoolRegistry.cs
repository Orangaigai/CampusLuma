using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace CampusLuma {
    public sealed class SchoolRule {
        public int schemaVersion;
        public string id, name, kind, entry, defaultSsid, fallbackPortal, verification;
        public bool enabled;
        public bool requiresUserSsid;
        public string[] trustedOrigins;
        public BrowserRule browser;
        public FormPortalRule researchProfile;
        public DrcomRule protocol;
        public override string ToString() { return name; }
    }
    public sealed class ServiceRule {
        public string label, value;
        public string[] aliases;
        public override string ToString() { return label; }
    }
    public sealed class DrcomRule {
        public int schemaVersion;
        public string mode, apiOrigin, loginPath, configPath, jsVersion, aesKey;
        public string[] roots;
        public ServiceRule[] services;
    }
    public sealed class FormPortalRule {
        public int schemaVersion;
        public string mode, loginPage, loginAction, statusPage, formMethod, usernameField, passwordField, serviceField, captchaField;
        public string responseEncoding, requestEncoding;
        public string[] roots, allowedOrigins;
        public ServiceRule[] services;
    }
    public sealed class BrowserRule {
        public string selfServiceUrl;
        public string[] discoveryProbes, usernameSelectors, passwordSelectors, submitSelectors, captchaSelectors, captchaImageSelectors;
        public string agreementPattern;
        public string[] accountTabTexts;
        public string successPath, successStorageKey;
        public bool requireNetworkRedirect;
        public bool requireGatewayParameters;
        public string[] entryPathPatterns;
        public ServiceRule[] services;
        public BrowserServiceSelection serviceSelection;
    }
    public sealed class BrowserServiceSelection {
        public string promptPattern;
        public string[] containerSelectors,optionSelectors,confirmSelectors;
    }
    public static class SchoolRegistry {
        public static string DirectoryPath=Path.Combine(Path.GetDirectoryName(typeof(SchoolRegistry).Assembly.Location),"adapters");
        static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
        public static string RulePath(string id) {
            if(id==null || !Regex.IsMatch(id,@"^[a-z][a-z0-9_-]{0,47}$")) throw new ArgumentException("学校标识无效。");
            return Path.Combine(DirectoryPath,id+".json");
        }
        public static SchoolRule Load(string id,bool requireEnabled=true) {
            string path=RulePath(id);
            if(!File.Exists(path)) throw new ArgumentException("尚未支持这所学校。");
            var rule=Json.Deserialize<SchoolRule>(File.ReadAllText(path,Encoding.UTF8));
            if(rule==null || rule.schemaVersion!=1 || rule.id!=id || String.IsNullOrWhiteSpace(rule.name))
                throw new ArgumentException("学校规则格式无效。");
            if(requireEnabled && !rule.enabled) throw new ArgumentException("这所学校尚待现场验证，暂未启用。");
            if(!rule.enabled && !requireEnabled) return rule;
            if((rule.kind!="browser" && rule.kind!="snnu-jsp" && rule.kind!="drcom-query" && rule.kind!="drcom-aes") || rule.entry!="engine/campus-network-reconnect.ps1")
                throw new ArgumentException("学校规则使用了尚未支持的认证方式。");
            if(rule.trustedOrigins==null || rule.trustedOrigins.Length==0 || rule.trustedOrigins.Length>32)
                throw new ArgumentException("学校规则缺少可信认证地址。");
            foreach(string origin in rule.trustedOrigins) {
                Uri uri;
                if(!Uri.TryCreate(origin,UriKind.Absolute,out uri) || (uri.Scheme!="https" && uri.Scheme!="http") ||
                    !String.IsNullOrEmpty(uri.UserInfo) || !String.IsNullOrEmpty(uri.Query) || !String.IsNullOrEmpty(uri.Fragment) ||
                    uri.AbsolutePath!="/" || origin.TrimEnd('/')!=uri.GetLeftPart(UriPartial.Authority))
                    throw new ArgumentException("可信认证地址必须为明确的 HTTP/HTTPS 来源。");
            }
            if(!Allows(rule,rule.fallbackPortal)) throw new ArgumentException("学校认证入口不在其可信地址中。");
            if(rule.kind=="drcom-query" || rule.kind=="drcom-aes") {
                var p=rule.protocol;
                bool hnust=rule.id=="hnust" && rule.kind=="drcom-query", hunnu=rule.id=="hunnu" && rule.kind=="drcom-aes";
                var origins=hnust?new[]{"http://login.hnust.cn","http://192.168.254.226","http://192.168.254.226:801"}:new[]{"http://192.168.250.250","http://192.168.250.250:801"};
                if((!hnust && !hunnu) || p==null || p.schemaVersion!=1 || p.mode!=rule.kind || p.apiOrigin!=origins.Last() ||
                    p.loginPath!="/eportal/portal/login" || p.jsVersion!="4.2.1" || rule.trustedOrigins.Length!=origins.Length || origins.Any(o=>!rule.trustedOrigins.Contains(o)))
                    throw new ArgumentException("学校 Portal 协议规则无效。");
                if(p.roots==null || p.roots.Length==0 || p.roots.Length>3 || p.roots.Any(u=>!Allows(rule,u) || new Uri(u).AbsolutePath!="/" || !String.IsNullOrEmpty(new Uri(u).Query)))
                    throw new ArgumentException("学校 Portal 发现入口无效。");
                var values=hnust?new[]{"","telecom","cmcc","unicom"}:new[]{"0","1","2","3"};
                if(p.services==null || p.services.Length!=values.Length || values.Any(v=>p.services.Count(s=>s!=null && s.value==v && !String.IsNullOrWhiteSpace(s.label))!=1))
                    throw new ArgumentException("学校 Portal 运营商选项无效。");
                if(hunnu && (p.configPath!="/eportal/portal/page/loadConfig" || p.aesKey!="5c1d5ad4dea0e8dd")) throw new ArgumentException("学校 Portal 加密规则无效。");
                return rule;
            }
            if(rule.kind=="snnu-jsp") {
                var p=rule.researchProfile;
                if(rule.id!="snnu" || p==null || p.schemaVersion!=1 || p.mode!="snnu-jsp" || p.formMethod!="POST" ||
                    p.loginPage!="/snnuportal/login.jsp" || p.loginAction!="/snnuportal/login" || p.statusPage!="/snnuportal/userstatus.jsp" ||
                    p.requestEncoding!="gb2312" || p.responseEncoding!="gb2312") throw new ArgumentException("陕师大表单规则无效。");
                if(p.allowedOrigins==null || p.allowedOrigins.Length!=rule.trustedOrigins.Length || p.allowedOrigins.Any(o=>!rule.trustedOrigins.Contains(o)))
                    throw new ArgumentException("表单来源与学校可信地址不一致。");
                foreach(string origin in p.allowedOrigins) { var uri=new Uri(origin);if(uri.Scheme!="http" || (uri.Host!="202.117.144.205" && uri.Host!="net.snnu.edu.cn")) throw new ArgumentException("陕师大认证来源无效。"); }
                if(p.roots==null || p.roots.Length<1 || p.roots.Length>2 || p.roots.Any(u=>!Allows(rule,u) || new Uri(u).AbsolutePath!="/")) throw new ArgumentException("表单发现入口无效。");
                if(p.services==null || p.services.Length==0 || p.services.Any(s=>s==null || s.value==null || String.IsNullOrWhiteSpace(s.label)) ||
                    p.services.Select(s=>s.value).Distinct().Count()!=p.services.Length) throw new ArgumentException("运营商选项无效。");
                foreach(string field in new[]{p.usernameField,p.passwordField,p.serviceField,p.captchaField})
                    if(field==null || !Regex.IsMatch(field,@"^[a-zA-Z][a-zA-Z0-9_]{0,63}$")) throw new ArgumentException("表单字段无效。");
                return rule;
            }
            if(rule.browser==null ||
                (rule.browser.selfServiceUrl!=null && !Allows(rule,rule.browser.selfServiceUrl)))
                throw new ArgumentException("学校认证入口不在其可信地址中。");
            foreach(string[] selectors in new[]{rule.browser.usernameSelectors,rule.browser.passwordSelectors,rule.browser.submitSelectors,rule.browser.captchaSelectors,rule.browser.captchaImageSelectors})
                if(selectors==null || selectors.Length==0 || selectors.Length>32 || selectors.Any(String.IsNullOrWhiteSpace))
                    throw new ArgumentException("学校规则缺少网页控件定位规则。");
            if((String.IsNullOrWhiteSpace(rule.defaultSsid) && !rule.requiresUserSsid) || String.IsNullOrWhiteSpace(rule.browser.agreementPattern))
                throw new ArgumentException("学校规则缺少网络或协议信息。");
            var entryPatterns=rule.browser.entryPathPatterns;
            if(entryPatterns!=null) {
                if(entryPatterns.Length==0 || entryPatterns.Length>8 || entryPatterns.Any(p=>p==null || !p.StartsWith("^/") || p.Length>300)) throw new ArgumentException("学校入口版本规则无效。");
                foreach(var pattern in entryPatterns)new Regex(pattern);
            }
            if(rule.browser.requireGatewayParameters && entryPatterns==null)throw new ArgumentException("学校入口缺少会话规则。");
            if(rule.browser.accountTabTexts!=null && (rule.browser.accountTabTexts.Length==0 || rule.browser.accountTabTexts.Length>8 || rule.browser.accountTabTexts.Any(t=>String.IsNullOrWhiteSpace(t) || t.Length>40))) throw new ArgumentException("账号登录标签规则无效。");
            if(rule.browser.services!=null) {
                var services=rule.browser.services;var choice=rule.browser.serviceSelection;
                if(services.Length==0 || services.Length>8 || services.Select(s=>s==null?null:s.value).Distinct().Count()!=services.Length ||
                    services.Any(s=>s==null || s.value==null || !Regex.IsMatch(s.value,@"^[a-z][a-z0-9_-]{0,31}$") || String.IsNullOrWhiteSpace(s.label) || s.aliases==null || s.aliases.Length==0 || s.aliases.Length>8 || s.aliases.Any(a=>String.IsNullOrWhiteSpace(a) || a.Length>80)))
                    throw new ArgumentException("网页运营商规则无效。");
                var aliases=services.SelectMany(s=>s.aliases).Select(a=>Regex.Replace(a,@"\s","")).ToArray();
                if(aliases.Distinct().Count()!=aliases.Length || choice==null || String.IsNullOrWhiteSpace(choice.promptPattern) || choice.promptPattern.Length>300)
                    throw new ArgumentException("网页运营商选项存在歧义。");
                new Regex(choice.promptPattern);
                foreach(var list in new[]{choice.containerSelectors,choice.optionSelectors,choice.confirmSelectors})
                    if(list==null || list.Length==0 || list.Length>16 || list.Any(s=>String.IsNullOrWhiteSpace(s) || s.Length>512)) throw new ArgumentException("网页运营商控件规则无效。");
            }
            return rule;
        }
        public static bool Allows(SchoolRule rule,string url) {
            Uri uri;
            if(rule==null || rule.trustedOrigins==null || !Uri.TryCreate(url,UriKind.Absolute,out uri) ||
                (uri.Scheme!="http" && uri.Scheme!="https") || !String.IsNullOrEmpty(uri.UserInfo)) return false;
            string origin=uri.GetLeftPart(UriPartial.Authority);
            return rule.trustedOrigins.Any(value=>String.Equals(value.TrimEnd('/'),origin,StringComparison.OrdinalIgnoreCase));
        }
        public static List<SchoolRule> Available() {
            return System.IO.Directory.GetFiles(DirectoryPath,"*.json").Select(path=>Load(Path.GetFileNameWithoutExtension(path),false))
                .Where(rule=>rule.enabled).OrderBy(rule=>rule.name,StringComparer.CurrentCulture).ToList();
        }
        public static ServiceRule[] Services(SchoolRule rule) {
            return rule.kind=="snnu-jsp"?rule.researchProfile.services:rule.protocol!=null?rule.protocol.services:rule.browser!=null && rule.browser.services!=null?rule.browser.services:new ServiceRule[0];
        }
        public static Settings Defaults(string id="xtu") {
            var rule=Load(id);
            var settings=new Settings();Apply(settings,rule);return settings;
        }
        public static void Apply(Settings settings,SchoolRule rule) {
            settings.Adapter=rule.id;settings.School=rule.name;settings.Ssid=rule.defaultSsid;settings.Portal=rule.fallbackPortal;settings.Service=null;
        }
    }
}
