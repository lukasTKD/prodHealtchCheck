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

        if (action == "refresh")
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "schtasks.exe";
                psi.Arguments = "/Run /TN \"Update IIS prodHealtchCheck\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                Process.Start(psi);
                Response.Write("{\"status\":\"ok\",\"message\":\"Task uruchomiony\"}");
            }
            catch (Exception ex)
            {
                Response.StatusCode = 500;
                Response.Write("{\"error\":\"" + ex.Message.Replace("\"", "'") + "\"}");
            }
            return;
        }

        string group = Request.QueryString["group"];

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
