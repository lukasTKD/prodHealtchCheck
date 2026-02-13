<%@ Page Language="C#" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Text.RegularExpressions" %>
<%@ Import Namespace="System.Diagnostics" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>
<%@ Import Namespace="System.Collections.Generic" %>
<%@ Import Namespace="System.Linq" %>

<script runat="server">
    // =========================================================================
    // KONFIGURACJA
    // =========================================================================
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
        return new AppPaths
        {
            basePath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck",
            dataPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data",
            logsPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\logs",
            configPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\config",
            eventLogsPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\EventLogs"
        };
    }

    // =========================================================================
    // CSV PARSER — prosty i niezawodny
    // =========================================================================
    private string[] ParseCsvLine(string line)
    {
        var fields = new List<string>();
        bool inQuotes = false;
        var field = new System.Text.StringBuilder();
        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (c == '"')
            {
                if (inQuotes && i + 1 < line.Length && line[i + 1] == '"')
                {
                    field.Append('"');
                    i++;
                }
                else
                {
                    inQuotes = !inQuotes;
                }
            }
            else if (c == ',' && !inQuotes)
            {
                fields.Add(field.ToString());
                field.Clear();
            }
            else
            {
                field.Append(c);
            }
        }
        fields.Add(field.ToString());
        return fields.ToArray();
    }

    private List<Dictionary<string, string>> ParseCsv(string filePath)
    {
        var result = new List<Dictionary<string, string>>();
        if (!File.Exists(filePath)) return result;

        string[] lines = File.ReadAllLines(filePath, System.Text.Encoding.UTF8);
        if (lines.Length < 2) return result;

        // Usun BOM jesli jest
        string headerLine = lines[0].TrimStart('\uFEFF');
        string[] headers = ParseCsvLine(headerLine);

        for (int i = 1; i < lines.Length; i++)
        {
            if (string.IsNullOrWhiteSpace(lines[i])) continue;
            string[] values = ParseCsvLine(lines[i]);
            var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int j = 0; j < headers.Length && j < values.Length; j++)
            {
                row[headers[j].Trim()] = values[j];
            }
            result.Add(row);
        }
        return result;
    }

    private string GetVal(Dictionary<string, string> row, string key)
    {
        if (row != null && row.ContainsKey(key)) return row[key] ?? "";
        return "";
    }

    private double GetNum(Dictionary<string, string> row, string key)
    {
        string val = GetVal(row, key).Replace(",", ".");
        double result;
        if (double.TryParse(val, System.Globalization.NumberStyles.Any,
            System.Globalization.CultureInfo.InvariantCulture, out result))
            return result;
        return 0;
    }

    private string GetLastUpdate(params string[] paths)
    {
        DateTime newest = DateTime.MinValue;
        foreach (string p in paths)
        {
            if (File.Exists(p))
            {
                DateTime lw = File.GetLastWriteTime(p);
                if (lw > newest) newest = lw;
            }
        }
        return newest == DateTime.MinValue ? "-" : newest.ToString("yyyy-MM-dd HH:mm:ss");
    }

    // =========================================================================
    // INFRA: KLASTRY WINDOWS — czyta cluster_nodes.csv + cluster_roles.csv
    // =========================================================================
    private void ServeClusters(AppPaths paths)
    {
        string nodesPath = Path.Combine(paths.dataPath, "cluster_nodes.csv");
        string rolesPath = Path.Combine(paths.dataPath, "cluster_roles.csv");

        var nodes = ParseCsv(nodesPath);
        var roles = ParseCsv(rolesPath);

        if (nodes.Count == 0 && roles.Count == 0)
        {
            Response.StatusCode = 404;
            Response.Write("{\"error\":\"Brak danych o klastrach (cluster_nodes.csv / cluster_roles.csv)\"}");
            return;
        }

        string lastUpdate = GetLastUpdate(nodesPath, rolesPath);

        // Znajdz unikalne klastry
        var clusterNames = new List<string>();
        var clusterTypes = new Dictionary<string, string>();
        foreach (var row in nodes)
        {
            string cn = GetVal(row, "ClusterName");
            if (!string.IsNullOrEmpty(cn) && !clusterNames.Contains(cn))
            {
                clusterNames.Add(cn);
                clusterTypes[cn] = GetVal(row, "ClusterType");
            }
        }
        foreach (var row in roles)
        {
            string cn = GetVal(row, "ClusterName");
            if (!string.IsNullOrEmpty(cn) && !clusterNames.Contains(cn))
            {
                clusterNames.Add(cn);
                clusterTypes[cn] = GetVal(row, "ClusterType");
            }
        }

        var clusters = new List<object>();
        foreach (string cn in clusterNames)
        {
            var cNodes = new List<object>();
            foreach (var n in nodes)
            {
                if (GetVal(n, "ClusterName") == cn)
                {
                    cNodes.Add(new Dictionary<string, object> {
                        { "Name", GetVal(n, "NodeName") },
                        { "State", GetVal(n, "State") },
                        { "NodeWeight", GetVal(n, "NodeWeight") },
                        { "DynamicWeight", GetVal(n, "DynamicWeight") },
                        { "IPAddresses", GetVal(n, "IPAddresses") }
                    });
                }
            }

            var cRoles = new List<object>();
            foreach (var r in roles)
            {
                if (GetVal(r, "ClusterName") == cn)
                {
                    cRoles.Add(new Dictionary<string, object> {
                        { "Name", GetVal(r, "RoleName") },
                        { "State", GetVal(r, "State") },
                        { "OwnerNode", GetVal(r, "OwnerNode") },
                        { "IPAddresses", GetVal(r, "IPAddresses") }
                    });
                }
            }

            clusters.Add(new Dictionary<string, object> {
                { "ClusterName", cn },
                { "ClusterType", clusterTypes.ContainsKey(cn) ? clusterTypes[cn] : "" },
                { "Status", "Online" },
                { "Nodes", cNodes },
                { "Roles", cRoles },
                { "Error", null }
            });
        }

        var result = new Dictionary<string, object> {
            { "LastUpdate", lastUpdate },
            { "TotalClusters", clusters.Count },
            { "OnlineCount", clusters.Count },
            { "FailedCount", 0 },
            { "Clusters", clusters }
        };

        var serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = int.MaxValue;
        Response.Write(serializer.Serialize(result));
    }

    // =========================================================================
    // INFRA: UDZIALY SIECIOWE — czyta fileShare.csv
    // =========================================================================
    private void ServeFileShares(AppPaths paths)
    {
        string csvPath = Path.Combine(paths.dataPath, "fileShare.csv");
        var rows = ParseCsv(csvPath);

        if (rows.Count == 0)
        {
            Response.StatusCode = 404;
            Response.Write("{\"error\":\"Brak danych o udzialach (fileShare.csv)\"}");
            return;
        }

        string lastUpdate = GetLastUpdate(csvPath);

        // Grupuj po ServerName
        var serverNames = new List<string>();
        foreach (var row in rows)
        {
            string sn = GetVal(row, "ServerName");
            if (!string.IsNullOrEmpty(sn) && !serverNames.Contains(sn)) serverNames.Add(sn);
        }

        var servers = new List<object>();
        foreach (string sn in serverNames)
        {
            var shares = new List<object>();
            string error = null;
            foreach (var row in rows)
            {
                if (GetVal(row, "ServerName") != sn) continue;
                if (GetVal(row, "ShareState") == "Error")
                {
                    error = GetVal(row, "SharePath");
                    continue;
                }
                shares.Add(new Dictionary<string, object> {
                    { "ShareName", GetVal(row, "ShareName") },
                    { "SharePath", GetVal(row, "SharePath") },
                    { "ShareState", GetVal(row, "ShareState") }
                });
            }

            servers.Add(new Dictionary<string, object> {
                { "ServerName", sn },
                { "ShareCount", shares.Count },
                { "Shares", shares },
                { "Error", error }
            });
        }

        var result = new Dictionary<string, object> {
            { "LastUpdate", lastUpdate },
            { "TotalServers", servers.Count },
            { "FileServers", servers }
        };

        var serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = int.MaxValue;
        Response.Write(serializer.Serialize(result));
    }

    // =========================================================================
    // INFRA: INSTANCJE SQL — czyta sql_db_details.csv
    // =========================================================================
    private void ServeSqlInstances(AppPaths paths)
    {
        // Szukaj CSV w kilku lokalizacjach
        string csvPath = null;
        string[] possiblePaths = new string[] {
            Path.Combine(paths.dataPath, "sql_db_details.csv"),
            Path.Combine(paths.configPath, "sql_db_details.csv"),
            @"D:\PROD_REPO_DATA\IIS\Cluster\data\sql_db_details.csv"
        };
        foreach (string p in possiblePaths)
        {
            if (File.Exists(p)) { csvPath = p; break; }
        }

        if (csvPath == null)
        {
            Response.StatusCode = 404;
            Response.Write("{\"error\":\"Brak pliku sql_db_details.csv\"}");
            return;
        }

        var rows = ParseCsv(csvPath);
        string lastUpdate = GetLastUpdate(csvPath);

        // Grupuj po sql_server
        var serverNames = new List<string>();
        foreach (var row in rows)
        {
            string sn = GetVal(row, "sql_server");
            if (!string.IsNullOrEmpty(sn) && !serverNames.Contains(sn)) serverNames.Add(sn);
        }

        var instances = new List<object>();
        foreach (string sn in serverNames)
        {
            var dbs = new List<object>();
            double totalSize = 0;
            string sqlVersion = "N/A";

            foreach (var row in rows)
            {
                if (GetVal(row, "sql_server") != sn) continue;

                if (sqlVersion == "N/A")
                {
                    string v = GetVal(row, "SQLServerVersion");
                    if (!string.IsNullOrEmpty(v)) sqlVersion = v;
                }

                double dataSize = GetNum(row, "DataFileSizeMB");
                double logSize = GetNum(row, "LogFileSizeMB");
                double total = GetNum(row, "TotalSizeMB");
                totalSize += total;

                dbs.Add(new Dictionary<string, object> {
                    { "DatabaseName", GetVal(row, "DatabaseName") },
                    { "CompatibilityLevel", GetVal(row, "CompatibilityLevel") },
                    { "DataFileSizeMB", Math.Round(dataSize, 2) },
                    { "LogFileSizeMB", Math.Round(logSize, 2) },
                    { "TotalSizeMB", Math.Round(total, 2) }
                });
            }

            instances.Add(new Dictionary<string, object> {
                { "ServerName", sn },
                { "SQLVersion", sqlVersion },
                { "DatabaseCount", dbs.Count },
                { "TotalSizeMB", Math.Round(totalSize, 2) },
                { "Databases", dbs },
                { "Error", null }
            });
        }

        var result = new Dictionary<string, object> {
            { "LastUpdate", lastUpdate },
            { "TotalInstances", instances.Count },
            { "Instances", instances }
        };

        var serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = int.MaxValue;
        Response.Write(serializer.Serialize(result));
    }

    // =========================================================================
    // INFRA: KOLEJKI MQ — czyta mq_queue_list.csv
    // =========================================================================
    private void ServeMqQueues(AppPaths paths)
    {
        string csvPath = Path.Combine(paths.dataPath, "mq_queue_list.csv");
        var rows = ParseCsv(csvPath);

        if (rows.Count == 0)
        {
            Response.StatusCode = 404;
            Response.Write("{\"error\":\"Brak danych o kolejkach MQ (mq_queue_list.csv)\"}");
            return;
        }

        string lastUpdate = GetLastUpdate(csvPath);

        // Grupuj: ServerName -> QManager -> lista kolejek
        // Zbierz unikalne serwery (zachowaj kolejnosc)
        var serverNames = new List<string>();
        var serverGroups = new Dictionary<string, string>();
        foreach (var row in rows)
        {
            string sn = GetVal(row, "ServerName");
            if (!string.IsNullOrEmpty(sn) && !serverNames.Contains(sn))
            {
                serverNames.Add(sn);
                serverGroups[sn] = GetVal(row, "GroupName");
            }
        }

        var servers = new List<object>();
        foreach (string sn in serverNames)
        {
            // Zbierz QManagery dla tego serwera
            var qmNames = new List<string>();
            var qmStatus = new Dictionary<string, string>();
            var qmPort = new Dictionary<string, string>();
            var qmQueues = new Dictionary<string, List<object>>();

            foreach (var row in rows)
            {
                if (GetVal(row, "ServerName") != sn) continue;
                string qm = GetVal(row, "QManager");
                if (string.IsNullOrEmpty(qm)) continue;

                if (!qmNames.Contains(qm))
                {
                    qmNames.Add(qm);
                    qmStatus[qm] = GetVal(row, "Status");
                    qmPort[qm] = GetVal(row, "Port");
                    qmQueues[qm] = new List<object>();
                }

                string qn = GetVal(row, "QueueName");
                if (!string.IsNullOrEmpty(qn))
                {
                    qmQueues[qm].Add(new Dictionary<string, object> {
                        { "QueueName", qn }
                    });
                }
            }

            var qManagers = new List<object>();
            foreach (string qm in qmNames)
            {
                qManagers.Add(new Dictionary<string, object> {
                    { "QueueManager", qm },
                    { "Status", qmStatus.ContainsKey(qm) ? qmStatus[qm] : "" },
                    { "Port", qmPort.ContainsKey(qm) ? qmPort[qm] : "" },
                    { "QueueCount", qmQueues.ContainsKey(qm) ? qmQueues[qm].Count : 0 },
                    { "Queues", qmQueues.ContainsKey(qm) ? qmQueues[qm] : new List<object>() }
                });
            }

            servers.Add(new Dictionary<string, object> {
                { "ServerName", sn },
                { "Description", serverGroups.ContainsKey(sn) ? serverGroups[sn] : "" },
                { "QueueManagers", qManagers },
                { "Error", null }
            });
        }

        var result = new Dictionary<string, object> {
            { "LastUpdate", lastUpdate },
            { "TotalServers", servers.Count },
            { "Servers", servers }
        };

        var serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = int.MaxValue;
        Response.Write(serializer.Serialize(result));
    }

    // =========================================================================
    // INFRA: PRZELACZENIA ROL — czyta role_switches.csv
    // =========================================================================
    private void ServeRoleSwitches(AppPaths paths)
    {
        string csvPath = Path.Combine(paths.dataPath, "role_switches.csv");
        var rows = ParseCsv(csvPath);

        string lastUpdate = GetLastUpdate(csvPath);

        var switches = new List<object>();
        foreach (var row in rows)
        {
            string tc = GetVal(row, "TimeCreated");
            if (string.IsNullOrEmpty(tc)) continue;

            int eventId;
            int.TryParse(GetVal(row, "EventId"), out eventId);

            switches.Add(new Dictionary<string, object> {
                { "TimeCreated", tc },
                { "EventId", eventId },
                { "EventType", GetVal(row, "EventType") },
                { "ClusterName", GetVal(row, "ClusterName") },
                { "ClusterType", GetVal(row, "ClusterType") },
                { "RoleName", GetVal(row, "RoleName") },
                { "SourceNode", GetVal(row, "SourceNode") },
                { "TargetNode", GetVal(row, "TargetNode") }
            });
        }

        var result = new Dictionary<string, object> {
            { "LastUpdate", lastUpdate },
            { "DaysBack", 30 },
            { "TotalEvents", switches.Count },
            { "Switches", switches }
        };

        var serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = int.MaxValue;
        Response.Write(serializer.Serialize(result));
    }

    // =========================================================================
    // PAGE LOAD — glowny routing
    // =========================================================================
    protected void Page_Load(object sender, EventArgs e)
    {
        Response.ContentType = "application/json";
        Response.Cache.SetCacheability(HttpCacheability.NoCache);
        Response.TrySkipIisCustomErrors = true;

        var paths = GetPaths();
        string action = Request.QueryString["action"];
        string taskName = "Update II prodHealtchCheck";

        // =================================================================
        // Endpoint: getLogTypes
        // =================================================================
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

        // =================================================================
        // Endpoint: getLogs
        // =================================================================
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
                if (!Regex.IsMatch(srvName, @"^[a-zA-Z0-9\-_\.]+$")) continue;

                if (!first) jsonBuilder.Append(",");
                first = false;

                jsonBuilder.Append("\"" + srvName.Replace("\"", "\\\"") + "\":");

                try
                {
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

        // =================================================================
        // Endpoint: taskstatus
        // =================================================================
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

        // =================================================================
        // Endpoint: refresh
        // =================================================================
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

        // =================================================================
        // DANE INFRASTRUKTURALNE — czytane z CSV
        // =================================================================
        if (type == "infra")
        {
            if (string.IsNullOrEmpty(group) || !Regex.IsMatch(group, "^[a-zA-Z]+$"))
            {
                Response.StatusCode = 400;
                Response.Write("{\"error\":\"Nieprawidlowa nazwa grupy infrastruktury\"}");
                return;
            }

            try
            {
                switch (group)
                {
                    case "ClustersWindows":
                        ServeClusters(paths);
                        break;
                    case "UdzialySieciowe":
                        ServeFileShares(paths);
                        break;
                    case "InstancjeSQL":
                        ServeSqlInstances(paths);
                        break;
                    case "KolejkiMQ":
                        ServeMqQueues(paths);
                        break;
                    case "PrzelaczeniaRol":
                        ServeRoleSwitches(paths);
                        break;
                    default:
                        Response.StatusCode = 404;
                        Response.Write("{\"error\":\"Nieznana zakladka: " + group + "\"}");
                        break;
                }
            }
            catch (Exception ex)
            {
                Response.StatusCode = 500;
                Response.Write("{\"error\":\"" + ex.Message.Replace("\"", "'") + "\"}");
            }
            return;
        }

        // =================================================================
        // DANE KONDYCJI SERWEROW — serverHealth_{group}.json (bez zmian)
        // =================================================================
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
