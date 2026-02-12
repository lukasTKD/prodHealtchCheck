<%@ Page Language="C#" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Text.RegularExpressions" %>
<%@ Import Namespace="System.Diagnostics" %>

<script runat="server">
    protected void Page_Load(object sender, EventArgs e)
    {
        Response.ContentType = "application/json";
        Response.Cache.SetCacheability(HttpCacheability.NoCache);

        string action = Request.QueryString["action"];

        string taskName = "Update II prodHealtchCheck";

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

                // Zwroc status: Ready, Running, Disabled, Queued
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
                // Sprawdz status taska przez PowerShell
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

                // Running - task juz dziala
                if (taskState.Equals("Running", StringComparison.OrdinalIgnoreCase))
                {
                    Response.Write("{\"status\":\"running\",\"message\":\"Task juz dziala\"}");
                    return;
                }

                // Ready - mozna uruchomic
                if (taskState.Equals("Ready", StringComparison.OrdinalIgnoreCase))
                {
                    // Uruchom task
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

                // Inny status (Disabled, Queued, itp.)
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
            // Walidacja nazwy grupy infra - tylko litery
            if (string.IsNullOrEmpty(group) || !Regex.IsMatch(group, "^[a-zA-Z]+$"))
            {
                Response.StatusCode = 400;
                Response.Write("{\"error\":\"Nieprawidlowa nazwa grupy infrastruktury\"}");
                return;
            }

            string infraPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\infra_" + group + ".json";

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

        // Walidacja nazwy grupy - tylko litery
        if (string.IsNullOrEmpty(group) || !Regex.IsMatch(group, "^[a-zA-Z]+$"))
        {
            group = "DCI";
        }

        string jsonPath = @"D:\PROD_REPO_DATA\IIS\prodHealtchCheck\data\serverHealth_" + group + ".json";

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
