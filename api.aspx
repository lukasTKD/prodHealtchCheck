<%@ Page Language="C#" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Text.RegularExpressions" %>
<%@ Import Namespace="System.Diagnostics" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>

<script runat="server">
    // Klasa do deserializacji app-config.json
    public class AppPaths
    {
        public string basePath { get; set; }
        public string dataPath { get; set; }
        public string logsPath { get; set; }
        public string configPath { get; set; }
        public string eventLogsPath { get; set; }
    }

    public class AppConfig
    {
        public AppPaths paths { get; set; }
    }

    // Pobierz ścieżki z app-config.json
    private AppPaths GetPaths()
    {
        string configPath = Server.MapPath("~/app-config.json");
        if (File.Exists(configPath))
        {
            try
            {
                string json = File.ReadAllText(configPath);
                var serializer = new JavaScriptSerializer();
                var config = serializer.Deserialize<AppConfig>(json);
                return config.paths;
            }
            catch { }
        }

        // Domyślne ścieżki
        return new AppPaths
        {
            basePath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck",
            dataPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data",
            logsPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\logs",
            configPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config",
            eventLogsPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\EventLogs"
        };
    }

    protected void Page_Load(object sender, EventArgs e)
    {
        Response.ContentType = "application/json";
        Response.Cache.SetCacheability(HttpCacheability.NoCache);

        var paths = GetPaths();
        string action = Request.QueryString["action"];
        string taskName = "Update II prodHealtchCheck";

        // =====================================================================
        // Endpoint: getLogTypes - zwraca konfigurację typów logów
        // =====================================================================
        if (action == "getLogTypes")
        {
            try
            {
                string eventLogsConfigPath = Path.Combine(paths.configPath, "EventLogsConfig.json");
                if (File.Exists(eventLogsConfigPath))
                {
                    Response.Write(File.ReadAllText(eventLogsConfigPath));
                }
                else
                {
                    Response.Write("[{\"name\":\"Application\",\"displayName\":\"Application\"},{\"name\":\"System\",\"displayName\":\"System\"}]");
                }
            }
            catch (Exception ex)
            {
                Response.StatusCode = 500;
                Response.Write("{\"error\":\"" + ex.Message.Replace("\"", "'") + "\"}");
            }
            return;
        }

        // =====================================================================
        // Endpoint: getLogs - pobiera logi Windows Event Log z serwerów
        // =====================================================================
        if (action == "getLogs")
        {
            string logServers = Request.QueryString["servers"];
            string logType = Request.QueryString["logType"];
            string periodStr = Request.QueryString["period"];

            if (string.IsNullOrEmpty(logServers) || string.IsNullOrEmpty(logType) || string.IsNullOrEmpty(periodStr))
            {
                Response.StatusCode = 400;
                Response.Write("{\"error\":\"Brak wymaganych parametrow: servers, logType, period\"}");
                return;
            }

            int minutesBack = 60;
            switch (periodStr.ToLower())
            {
                case "10min": minutesBack = 10; break;
                case "30min": minutesBack = 30; break;
                case "1h":   minutesBack = 60; break;
                case "2h":   minutesBack = 120; break;
                case "6h":   minutesBack = 360; break;
                case "12h":  minutesBack = 720; break;
                case "24h":  minutesBack = 1440; break;
            }

            string[] serverList = logServers.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
            string scriptPath = Server.MapPath("~/scripts/GetLogs.ps1");

            System.Text.StringBuilder jsonBuilder = new System.Text.StringBuilder("{");
            bool first = true;

            foreach (string srv in serverList)
            {
                string srvName = srv.Trim();
                if (string.IsNullOrEmpty(srvName)) continue;

                // Walidacja nazwy serwera
                if (!Regex.IsMatch(srvName, @"^[a-zA-Z0-9\-_\.]+$"))
                {
                    continue;
                }

                if (!first) jsonBuilder.Append(",");
                first = false;

                jsonBuilder.Append("\"" + srvName.Replace("\"", "\\\"") + "\":");

                try
                {
                    // Escape logType dla PowerShell
                    string safeLogType = logType.Replace("'", "''");

                    ProcessStartInfo logPsi = new ProcessStartInfo();
                    logPsi.FileName = "powershell.exe";
                    logPsi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command \"& '" + scriptPath + "' -ServerName '" + srvName + "' -LogName '" + safeLogType + "' -MinutesBack " + minutesBack + "\"";
                    logPsi.UseShellExecute = false;
                    logPsi.CreateNoWindow = true;
                    logPsi.RedirectStandardOutput = true;
                    logPsi.RedirectStandardError = true;

                    Process logProcess = Process.Start(logPsi);
                    string logOutput = logProcess.StandardOutput.ReadToEnd();
                    string logError = logProcess.StandardError.ReadToEnd();
                    logProcess.WaitForExit(120000);

                    if (logProcess.ExitCode != 0 && !string.IsNullOrEmpty(logError))
                    {
                        string safeError = logError.Replace("\"", "'").Replace("\r\n", " ").Replace("\n", " ");
                        if (safeError.Length > 500) safeError = safeError.Substring(0, 500);
                        jsonBuilder.Append("{\"success\":false,\"error\":\"" + safeError + "\"}");
                    }
                    else
                    {
                        string logs = string.IsNullOrWhiteSpace(logOutput) ? "[]" : logOutput.Trim();
                        jsonBuilder.Append("{\"success\":true,\"logs\":" + logs + "}");
                    }
                }
                catch (Exception ex)
                {
                    jsonBuilder.Append("{\"success\":false,\"error\":\"" + ex.Message.Replace("\"", "'") + "\"}");
                }
            }

            jsonBuilder.Append("}");
            Response.Write(jsonBuilder.ToString());
            return;
        }

        // Endpoint do sprawdzania statusu tasku
        if (action == "taskstatus")
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -Command \"(Get-ScheduledTask -TaskName '" + taskName + "').State\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;

                Process process = Process.Start(psi);
                string output = process.StandardOutput.ReadToEnd().Trim();
                string error = process.StandardError.ReadToEnd();
                process.WaitForExit();

                if (process.ExitCode != 0 || !string.IsNullOrEmpty(error))
                {
                    Response.Write("{\"status\":\"error\",\"message\":\"Nie mozna pobrac statusu taska\",\"debug\":\"" + error.Replace("\"", "'").Replace("\r\n", " ") + "\"}");
                    return;
                }

                Response.Write("{\"status\":\"ok\",\"taskState\":\"" + output + "\"}");
            }
            catch (Exception ex)
            {
                Response.StatusCode = 500;
                Response.Write("{\"status\":\"error\",\"message\":\"" + ex.Message.Replace("\"", "'") + "\"}");
            }
            return;
        }

        if (action == "refresh")
        {
            try
            {
                ProcessStartInfo checkPsi = new ProcessStartInfo();
                checkPsi.FileName = "powershell.exe";
                checkPsi.Arguments = "-NoProfile -Command \"(Get-ScheduledTask -TaskName '" + taskName + "').State\"";
                checkPsi.UseShellExecute = false;
                checkPsi.CreateNoWindow = true;
                checkPsi.RedirectStandardOutput = true;
                checkPsi.RedirectStandardError = true;

                Process checkProcess = Process.Start(checkPsi);
                string taskState = checkProcess.StandardOutput.ReadToEnd().Trim();
                string error = checkProcess.StandardError.ReadToEnd();
                checkProcess.WaitForExit();

                if (checkProcess.ExitCode != 0 || !string.IsNullOrEmpty(error))
                {
                    Response.Write("{\"status\":\"error\",\"message\":\"Task nie istnieje lub blad: " + taskName.Replace("\"", "'") + "\",\"debug\":\"" + error.Replace("\"", "'").Replace("\r\n", " ") + "\"}");
                    return;
                }

                if (taskState.Equals("Running", StringComparison.OrdinalIgnoreCase))
                {
                    Response.Write("{\"status\":\"running\",\"message\":\"Task juz dziala\"}");
                    return;
                }

                if (taskState.Equals("Ready", StringComparison.OrdinalIgnoreCase))
                {
                    ProcessStartInfo runPsi = new ProcessStartInfo();
                    runPsi.FileName = "schtasks.exe";
                    runPsi.Arguments = "/Run /TN \"" + taskName + "\"";
                    runPsi.UseShellExecute = false;
                    runPsi.CreateNoWindow = true;
                    runPsi.RedirectStandardOutput = true;
                    runPsi.RedirectStandardError = true;

                    Process runProcess = Process.Start(runPsi);
                    string runOutput = runProcess.StandardOutput.ReadToEnd();
                    string runError = runProcess.StandardError.ReadToEnd();
                    runProcess.WaitForExit();

                    if (runProcess.ExitCode == 0)
                    {
                        Response.Write("{\"status\":\"started\",\"message\":\"Task uruchomiony\"}");
                    }
                    else
                    {
                        Response.Write("{\"status\":\"error\",\"message\":\"Nie udalo sie uruchomic taska\",\"debug\":\"" + runError.Replace("\"", "'").Replace("\r\n", " ") + "\"}");
                    }
                    return;
                }

                Response.Write("{\"status\":\"blocked\",\"message\":\"Task nie jest gotowy do uruchomienia\",\"taskState\":\"" + taskState + "\"}");
            }
            catch (Exception ex)
            {
                Response.StatusCode = 500;
                Response.Write("{\"status\":\"error\",\"message\":\"" + ex.Message.Replace("\"", "'") + "\"}");
            }
            return;
        }

        string group = Request.QueryString["group"];
        string type = Request.QueryString["type"];

        // Obsługa danych infrastrukturalnych
        if (type == "infra")
        {
            if (string.IsNullOrEmpty(group) || !Regex.IsMatch(group, "^[a-zA-Z]+$"))
            {
                Response.StatusCode = 400;
                Response.Write("{\"error\":\"Nieprawidlowa nazwa grupy infrastruktury\"}");
                return;
            }

            string infraPath = Path.Combine(paths.dataPath, "infra_" + group + ".json");

            try
            {
                if (File.Exists(infraPath))
                {
                    string json = File.ReadAllText(infraPath);
                    Response.Write(json);
                }
                else
                {
                    Response.StatusCode = 404;
                    Response.Write("{\"error\":\"Brak danych infrastruktury dla: " + group + "\"}");
                }
            }
            catch (Exception ex)
            {
                Response.StatusCode = 500;
                Response.Write("{\"error\":\"" + ex.Message.Replace("\"", "'") + "\"}");
            }
            return;
        }

        // Walidacja nazwy grupy
        if (string.IsNullOrEmpty(group) || !Regex.IsMatch(group, "^[a-zA-Z]+$"))
        {
            group = "DCI";
        }

        string jsonPath = Path.Combine(paths.dataPath, "serverHealth_" + group + ".json");

        try
        {
            if (File.Exists(jsonPath))
            {
                string json = File.ReadAllText(jsonPath);
                Response.Write(json);
            }
            else
            {
                Response.StatusCode = 404;
                Response.Write("{\"error\":\"Brak danych dla grupy: " + group + "\"}");
            }
        }
        catch (Exception ex)
        {
            Response.StatusCode = 500;
            Response.Write("{\"error\":\"" + ex.Message.Replace("\"", "'") + "\"}");
        }
    }
</script>
